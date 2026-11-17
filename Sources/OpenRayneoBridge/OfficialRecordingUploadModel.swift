// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import AVFoundation
import Foundation

@MainActor
final class OfficialRecordingUploadModel: ObservableObject {
    static let shared = OfficialRecordingUploadModel()
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var activeEntryID: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var notice = "使用官方账号上传所选完整录音；不会自动上传。"
    @Published private(set) var records: [String: OfficialRecordingUploadRecord] = [:]
    @Published private(set) var models: [OfficialSummaryModel] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelNotice = ""
    @Published private(set) var results: [UUID: [String: Any]] = [:]
    @Published private(set) var pollingEntryIDs = Set<UUID>()
    @Published var selectedModel = ""
    @Published var sourceLanguage = "auto"
    @Published var separateSpeakers = true
    @Published var backupAudio = false
    @Published var requestTranscription = true
    @Published var resumeAutomatically = true
    @Published var regionCode = "CN"
    private var configuration: OfficialFirmwareConfiguration?
    private var service: OfficialMemoryService?
    private var store: OfficialRecordingUploadStore?
    private var task: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var modelRequestID = UUID()
    private var operationID = UUID()
    private var transferGeneration = UUID()
    private var accountSubscription: AnyCancellable?
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var pollIDs: [UUID: UUID] = [:]
    private var userRequestedPause = false
    lazy var background = OfficialRecordingUploadBackground(model: self)
    var ownerScope: String? { store?.ownerScope }
    var uploadDirectory: URL? { store?.directory }
    var userRequestedUploadTaskIDs: Set<String> {
        Set(records.values.filter { $0.queueSource == "userInitiatedSync" && $0.needsUpload }.map(\.taskID))
    }
    private var transferOwner: OfficialOSSTransferQueue.Owner? {
        ownerScope.map { .init(scope: $0, generation: transferGeneration, accountEpoch: configuration?.identityEpoch) }
    }

    private init() {
        reloadAccount()
        accountSubscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.background.suspendForAccountChange()
                let previousOwner = self.transferOwner
                let previous = self.task
                previous?.cancel(); self.operationID = UUID(); self.busy = previous != nil; self.activeEntryID = nil
                let transition = self.operationID
                self.stopPolling(); self.results = [:]
                self.models = []; self.selectedModel = ""
                self.reloadAccount()
                if let previousOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: previousOwner) }
                if let previous { await previous.value }
                guard self.operationID == transition else { return }
                self.busy = false; self.task = nil
                self.background.accountChanged()
            }
        }
    }

    private func reloadAccount() {
        transferGeneration = UUID()
        modelTask?.cancel(); modelTask = nil; modelRequestID = UUID(); modelsLoading = false; modelNotice = ""
        records = [:]; configuration = nil; service = nil; store = nil; configured = false
        do {
            let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
            guard !configuration.accessToken.isEmpty else { notice = "请先在“官方账号”页登录或导入已有会话。"; return }
            let store = try OfficialRecordingUploadStore(configuration: configuration)
            self.configuration = configuration; self.service = OfficialMemoryService(configuration: configuration)
            self.store = store; records = store.records; configured = true
            regionCode = configuration.region == .domestic ? "CN" : ""
            notice = "官方上传已配置；选择录音后手动开始。"
        } catch { notice = error.localizedDescription }
    }

    func record(for entryID: UUID) -> OfficialRecordingUploadRecord? { records[entryID.uuidString] }
    func record(for entry: RecordingLibraryEntry) -> OfficialRecordingUploadRecord? {
        record(for: entry.id) ?? entry.nativeIdentity.flatMap { identity in records.values.first { $0.nativeIdentity == identity } }
    }
    var usableModel: OfficialSummaryModel? { models.first { $0.id == selectedModel && $0.usable } }

    func loadModels() {
        guard !modelsLoading, let service else { return }
        let id = UUID(); modelRequestID = id; modelsLoading = true
        modelNotice = "正在读取官方转写所用摘要模型…"
        modelTask = Task {
            defer {
                if modelRequestID == id { modelsLoading = false; modelTask = nil }
            }
            do {
                let models = try await service.summaryModels()
                try Task.checkCancellation()
                guard modelRequestID == id else { return }
                self.models = models
                if !models.contains(where: { $0.id == selectedModel && $0.usable }) {
                    let usable = models.filter(\.usable)
                    selectedModel = (usable.first(where: \.selected) ?? usable.first(where: \.isDefaultModel)
                        ?? usable.first(where: \.isFreeModel))?.id ?? ""
                }
                modelNotice = "已读取 \(models.count) 个官方模型。"
            } catch { if modelRequestID == id { modelNotice = error.localizedDescription } }
        }
    }

    func start(entry: RecordingLibraryEntry, recordingStart: Date, allowResubmission: Bool = false) {
        guard let service, let store, let configuration else { return }
        if busy {
            requestUsingCurrentUpload(entry: entry, store: store)
            return
        }
        var record = record(for: entry) ?? OfficialRecordingUploadRecord(entryID: entry.id,
            taskID: UUID().uuidString, title: entry.title, startMilliseconds: Int64(recordingStart.timeIntervalSince1970 * 1000),
            timeZone: TimeZone.current.identifier, region: regionCode, backupAudio: backupAudio,
            requestedTranscription: requestTranscription, sourceLanguage: sourceLanguage.isEmpty ? "auto" : sourceLanguage,
            separateSpeakers: separateSpeakers, summaryModel: usableModel?.id, markers: entry.markers)
        if record.stagedFilePath == nil, !entry.finalized || !entry.available {
            notice = "请先完成录音保存，再开始上传。"; return
        }
        guard !record.region.isEmpty else { notice = "请填写录音所在地区代码。"; return }
        guard !OfficialCloudAudioModel.shared.isSuppressed(taskID: record.taskID, ownerScope: ownerScope) else {
            notice = "该任务已被删除或暂停恢复，请先处理原云会话状态。"; return
        }
        if record.backupAudio, UInt64(configuration.accountID) == nil {
            notice = "正式云备份需要数值形式的官方账号 ID。"; return
        }
        if requestTranscription, !record.requestedTranscription {
            addTranscriptionRequest(to: &record, entry: entry)
        }
        guard record.backupAudio || record.requestedTranscription else { notice = "请选择云备份或转写。"; return }
        if record.requestedTranscription, record.summaryModel == nil { notice = "请读取并选择账号可用的官方摘要模型。"; return }
        if ["accepted", "completed"].contains(record.transcriptionState) {
            notice = "转写已受理，请刷新云任务结果。"; return
        }
        if ["submitting", "uncertain", "failed"].contains(record.transcriptionState), !allowResubmission {
            notice = "请先刷新云任务状态；需要再次提交时使用单独的重新提交入口。"; return
        }
        if allowResubmission {
            record.transcriptionState = "not_submitted"
            if let model = usableModel { record.summaryModel = model.id }
        }
        record.automaticallyResume = resumeAutomatically; record.paused = false
        if record.priority == nil { record.priority = 0 }
        record.nativeIdentity = record.nativeIdentity ?? entry.nativeIdentity
        record.queueSource = "userInitiatedSync"
        if record.queuedAtMilliseconds == nil { record.queuedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000) }
        execute(record, entry: entry, service: service, store: store, configuration: configuration)
    }

    func canUseCurrentUpload(for entry: RecordingLibraryEntry) -> Bool {
        guard busy, task?.isCancelled == false, !userRequestedPause,
              let record = record(for: entry), activeEntryID == record.entryID else { return false }
        return record.backupAudio && record.paused != true && record.object != nil
            && record.object?.registered != true && record.transcriptionState == "not_submitted"
    }

    private func addTranscriptionRequest(to record: inout OfficialRecordingUploadRecord, entry: RecordingLibraryEntry) {
        record.requestedTranscription = true; record.summaryModel = usableModel?.id
        record.sourceLanguage = sourceLanguage.isEmpty ? "auto" : sourceLanguage
        record.separateSpeakers = separateSpeakers; record.markers = entry.markers
    }

    private func requestUsingCurrentUpload(entry: RecordingLibraryEntry, store: OfficialRecordingUploadStore) {
        guard canUseCurrentUpload(for: entry), var record = record(for: entry) else { return }
        if requestTranscription, !record.requestedTranscription {
            guard usableModel != nil else { notice = "请读取并选择账号可用的官方摘要模型。"; return }
            addTranscriptionRequest(to: &record, entry: entry)
        }
        record.queueSource = "userInitiatedSync"
        do {
            try store.save(record); records = store.records
            let taskID = record.taskID, owner = transferOwner
            Task {
                if let owner { await OfficialOSSTransferQueue.shared.promoteToUserInitiated(taskID: taskID, owner: owner) }
            }
            notice = record.requestedTranscription ? "已复用当前云备份，完成后提交官方转写。" : "当前云备份已转为手动同步。"
        } catch { notice = "手动同步请求未能保存：" + error.localizedDescription }
    }

    private func execute(_ initialRecord: OfficialRecordingUploadRecord, entry: RecordingLibraryEntry,
                         service: OfficialMemoryService, store: OfficialRecordingUploadStore,
                         configuration: OfficialFirmwareConfiguration) {
        var record = initialRecord
        var entry = entry; entry.id = record.entryID
        let id = begin(entryID: entry.id, message: "正在准备官方录音上传…")
        task = Task {
            defer { finish(id) }
            do {
                try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                if record.stagedFilePath == nil {
                    record.phase = "准备完整音频"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    let audio = try await OfficialRecordingUploadAudio.prepare(entry: entry,
                        destinationDirectory: store.taskDirectory(record)) { fraction in
                            if self.operationID == id { self.progress = fraction * 0.1 }
                        }
                    try ensureCurrent(id)
                    record.stagedFilePath = audio.fileURL.path
                    record.durationMilliseconds = audio.durationMilliseconds; record.channelCount = audio.channelCount
                    try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                guard let path = record.stagedFilePath else { throw OfficialMemoryFailure(message: "上传音频尚未准备完整。") }
                let duration = record.durationMilliseconds
                let fileURL = URL(fileURLWithPath: path)
                if !record.sessionCreated {
                    record.phase = "创建官方云会话"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    try await service.createSession(OfficialSessionCreateRequest(taskID: record.taskID, name: record.title,
                        timeZone: record.timeZone, region: record.region,
                        startTimeMs: record.startMilliseconds,
                        endTimeMs: record.endMilliseconds, createTimeMs: record.startMilliseconds,
                        audioSaveFlag: record.backupAudio, recordingDurationMs: duration))
                    try ensureCurrent(id)
                    record.sessionCreated = true; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                if record.object == nil {
                    record.phase = "读取官方音频桶"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    let buckets = try await service.getBucketInfo()
                    try ensureCurrent(id)
                    let bucket = record.backupAudio ? buckets.bucket : buckets.tempBucket
                    guard !bucket.isEmpty else { throw OfficialMemoryFailure(message: "未取得官方音频桶，请稍后重试。") }
                    let key: String
                    if record.backupAudio {
                        guard let account = UInt64(configuration.accountID) else {
                            throw OfficialMemoryFailure(message: "正式云备份需要数值形式的官方账号 ID。")
                        }
                        key = "users/\(String(format: "%03llu", account % 1000))/\(configuration.accountID)/\(fileURL.lastPathComponent)"
                    } else { key = "recording/" + fileURL.lastPathComponent }
                    record.object = .init(bucketName: bucket, objectKey: key)
                    try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                var object = record.object!
                if record.backupAudio, object.fileID == nil {
                    record.phase = "校验官方云备份额度"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    object.fileID = try await service.uploadCheck(taskID: record.taskID,
                        bucketName: object.bucketName, objectKey: object.objectKey, fileSize: Int64(size))
                    try ensureCurrent(id)
                    record.object = object; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                if !object.uploaded {
                    record.phase = "上传音频到官方 OSS"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    try await upload(fileURL: fileURL, object: object, record: record, service: service, store: store, operation: id)
                    try ensureCurrent(id)
                    object.uploaded = true; record.object = object; progress = 0.9
                    try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                if record.backupAudio, !object.registered, let fileID = object.fileID {
                    record.phase = "登记正式云备份"; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    _ = try await service.uploadRecord(fileID: fileID)
                    try ensureCurrent(id)
                    object.registered = true; record.object = object; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                }
                if record.requestedTranscription, record.transcriptionState == "not_submitted", let model = record.summaryModel {
                    guard let channels = record.channelCount else {
                        throw OfficialMemoryFailure(message: "音频已备份，但声道信息尚未确认，未提交转写。")
                    }
                    record.phase = "提交官方转写"; record.transcriptionState = "submitting"
                    try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                    try await service.submitTranscription(OfficialSessionTranscriptionRequest(taskID: record.taskID,
                        recordingStartTimeMs: record.startMilliseconds, bucketName: object.bucketName,
                        objectKey: object.objectKey, sourceLanguage: record.sourceLanguage,
                        separateSpeakers: record.separateSpeakers, summaryModel: model, channelNumber: channels,
                        marks: record.markers?.map { marker in
                            OfficialSessionUploadMark(markId: marker.id,
                                markTime: record.startMilliseconds + Int64(marker.positionSeconds * 1000),
                                remarks: [.init(hashtag: nil, remark: marker.content)])
                        }))
                    try ensureCurrent(id)
                    record.transcriptionState = "accepted"; record.phase = "转写已受理，等待云结果"
                } else { record.phase = "正式云备份已登记" }
                record.lastError = nil; try checkpoint(&record, store: store, operation: id, enforcePolicy: true)
                progress = 1; notice = record.phase
                if record.needsResult { startPolling(entryID: entry.id, service: service, store: store) }
            } catch {
                guard operationID == id else { return }
                mergeUserRequest(into: &record, store: store)
                if record.transcriptionState == "submitting" { record.transcriptionState = "uncertain" }
                if userRequestedPause { record.paused = true }
                record.lastError = Task.isCancelled ? "本机操作已取消；已创建的云会话及已上传对象保留。" : error.localizedDescription
                record.phase = "当前阶段未完成"
                do { try store.save(record); records = store.records }
                catch { notice = "上传中断，且任务日志保存失败：" + error.localizedDescription; return }
                notice = record.lastError ?? "上传中断。"
            }
        }
    }

    private func upload(fileURL: URL, object: OfficialRecordingUploadRecord.Object, record: OfficialRecordingUploadRecord,
                        service: OfficialMemoryService, store: OfficialRecordingUploadStore, operation: UUID) async throws {
        try ensureCurrent(operation)
        let uploader = OfficialOSSUploader()
        for attempt in 0...1 {
            try checkTransferPolicy(record, store: store)
            let credentials = try await service.getTempAk(bucketName: object.bucketName)
            try ensureCurrent(operation)
            try checkTransferPolicy(record, store: store)
            guard let owner = transferOwner else { throw CancellationError() }
            let current = store.records[record.entryID.uuidString] ?? record
            guard let endpoint = URL(string: credentials.endpoint) else { throw OfficialMemoryFailure(message: "官方 OSS endpoint 无法解析。") }
            let scopedCredentials = OfficialOSSUploader.Credentials(accessKeyID: credentials.ak, secretAccessKey: credentials.sk,
                securityToken: credentials.st, endpoint: endpoint)
            let resumeURL = store.taskDirectory(record).appendingPathComponent("oss-resume.json")
            do {
                try await OfficialOSSTransferQueue.shared.run(owner: owner, taskID: record.taskID, kind: .upload,
                    priority: (current.priority ?? 0) > 0 ? .high : .normal,
                    source: .init(rawValue: current.queueSource ?? "") ?? .unspecified, timeoutPolicy: .recordingUpload) { progress in
                    _ = try await uploader.upload(fileURL: fileURL, bucketName: object.bucketName, objectKey: object.objectKey,
                        credentials: scopedCredentials, ownerScope: owner.scope, resumeStateURL: resumeURL) { value in
                            if value.phase == .uploading { progress.received() }
                            Task { @MainActor in
                                if self.operationID == operation { self.progress = 0.1 + value.fraction * 0.8 }
                            }
                        }
                }
                return
            } catch let error as OfficialOSSUploader.Failure where attempt == 0 && error.isCredentialRejected {
                try ensureCurrent(operation)
            }
        }
    }

    func refreshResult(entryID: UUID) {
        guard !busy, let service, let store, var record = record(for: entryID), record.sessionCreated else { return }
        let id = begin(entryID: entryID, message: "正在读取官方云任务结果…")
        task = Task {
            defer { finish(id) }
            do {
                let value = try await service.session(taskID: record.taskID)
                try ensureCurrent(id)
                let details = value as? [[String: Any]] ?? []
                guard let detail = details.first(where: { item in
                    ["aiTask", "recording"].contains { key in
                        OfficialMemoryRow.text((item[key] as? [String: Any])?["taskId"]) == record.taskID
                    }
                }) else { throw OfficialMemoryFailure(message: "官方尚未返回此 taskId 的详情；保留原有提交状态。") }
                applyResult(detail, to: &record)
                record.lastError = nil; try checkpoint(&record, store: store, operation: id)
                results[entryID] = detail; notice = record.phase
                if record.needsResult { startPolling(entryID: entryID, service: service, store: store) }
            } catch { if operationID == id { notice = error.localizedDescription } }
        }
    }

    func cancel() {
        userRequestedPause = true
        if let activeEntryID, let store, var record = record(for: activeEntryID) {
            record.paused = true
            do { try store.save(record); records = store.records }
            catch { notice = "暂停状态未能保存：" + error.localizedDescription }
        }
        task?.cancel()
        if let activeEntryID, let record = record(for: activeEntryID), let ownerScope {
            Task { await OfficialOSSTransferQueue.shared.cancelTask(taskID: record.taskID, ownerScope: ownerScope) }
        }
    }

    func startBackground(library: RecordingLibraryModel) { background.start(library: library) }

    @discardableResult
    func enqueueCloudRepair(item: OfficialCloudAudioItem, entry: RecordingLibraryEntry, ownerScope: String, automatic: Bool) -> UUID? {
        guard let store, store.ownerScope == ownerScope, let path = entry.audioPath, entry.finalized, entry.available,
              !OfficialCloudAudioModel.shared.isSuppressed(taskID: item.taskID, ownerScope: ownerScope) else { return nil }
        if let existing = records.values.first(where: { $0.taskID == item.taskID }), activeEntryID == existing.entryID { return existing.entryID }
        do {
            let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
            var record = records.values.first { $0.taskID == item.taskID }
                ?? OfficialRecordingUploadRecord(entryID: entry.id, taskID: item.taskID, title: entry.title,
                    startMilliseconds: item.createdAtMilliseconds ?? Int64(entry.createdAt.timeIntervalSince1970 * 1000),
                    timeZone: TimeZone.current.identifier, region: regionCode, backupAudio: true,
                    requestedTranscription: false, sourceLanguage: "auto", separateSpeakers: true)
            guard record.paused != true else { return nil }
            record.backupAudio = true
            record.sessionCreated = true; record.object = nil
            record.stagedFilePath = entry.cloudCompressedPath ?? path
            if let file {
                record.durationMilliseconds = Int64(Double(file.length) / file.processingFormat.sampleRate * 1000)
                record.channelCount = Int(file.processingFormat.channelCount)
            }
            record.transferDirectoryID = record.transferDirectoryID ?? UUID()
            record.automaticallyResume = true; record.paused = false
            if record.queueSource != "userInitiatedSync" { record.queueSource = "systemCloudSync" }
            record.officialPolicyRequired = true
            record.queuedAtMilliseconds = record.queuedAtMilliseconds ?? Int64(Date().timeIntervalSince1970 * 1000)
            record.phase = "云快照确认缺音频，等待补传"
            try store.save(record); records = store.records
            background.wake(reason: "完整快照确认补云", force: !automatic, entryID: record.entryID, wakeCloud: false)
            return record.entryID
        } catch { notice = "补云任务未能入队：" + error.localizedDescription; return nil }
    }

    func pauseForCloudDeletion(taskID: String, ownerScope: String) {
        guard self.ownerScope == ownerScope, let record = records.values.first(where: { $0.taskID == taskID }) else { return }
        setPaused(true, entryID: record.entryID)
    }

    func suspendForCloudDeletion(taskID: String, ownerScope: String) {
        guard self.ownerScope == ownerScope else { return }
        Task { await OfficialOSSTransferQueue.shared.cancelTask(taskID: taskID, ownerScope: ownerScope) }
        guard let activeEntryID,
              record(for: activeEntryID)?.taskID == taskID else { return }
        task?.cancel()
    }

    @discardableResult
    func enqueueNative(entry: RecordingLibraryEntry, transcribe: Bool, summaryModel: String?,
                       sourceLanguage: String, separateSpeakers: Bool, region: String) -> Bool {
        guard let store, let start = entry.startedAtMilliseconds, let identity = entry.nativeIdentity,
              !region.isEmpty, !transcribe || summaryModel != nil else { return false }
        if records.values.contains(where: { $0.nativeIdentity == identity || $0.entryID == entry.id }) { return true }
        var record = OfficialRecordingUploadRecord(entryID: entry.id, taskID: UUID().uuidString,
            title: entry.title, startMilliseconds: start, timeZone: TimeZone.current.identifier, region: region,
            backupAudio: true, requestedTranscription: transcribe, sourceLanguage: sourceLanguage,
            separateSpeakers: separateSpeakers, summaryModel: summaryModel, markers: entry.markers)
        record.automaticallyResume = true; record.paused = false; record.priority = 0
        record.officialPolicyRequired = true
        record.queueSource = "systemCloudSync"; record.nativeIdentity = identity
        record.queuedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        record.phase = "已加入后台上传队列"
        do { try store.save(record); records = store.records; return true }
        catch { notice = "自动录音任务未能保存：" + error.localizedDescription; return false }
    }

    func prioritize(entryID: UUID) {
        guard activeEntryID != entryID else { return }
        guard let store, var record = record(for: entryID) else { return }
        stopPolling(entryID: entryID)
        record.priority = 1; record.paused = false; record.automaticallyResume = true
        record.prioritySequence = store.nextSequence
        record.queueSource = "userInitiatedSync"
        do { try store.save(record); records = store.records; background.prioritize(entryID: entryID) }
        catch { notice = error.localizedDescription }
    }

    func preemptBackgroundUpload() -> UUID? {
        guard busy, let activeEntryID, let record = record(for: activeEntryID), (record.priority ?? 0) == 0,
              record.phase == "上传音频到官方 OSS" else { return nil }
        // URLSession cancellation is drained by the upload task before busy becomes false.
        task?.cancel()
        return activeEntryID
    }

    func requeueInterruptedUpload(entryID: UUID) -> Bool {
        guard let store, var record = record(for: entryID), record.paused != true,
              (record.priority ?? 0) == 0 else { return false }
        record.queueSequence = store.nextSequence
        record.phase = "等待优先任务完成后继续上传"; record.lastError = nil
        do { try store.save(record); records = store.records; return true }
        catch { notice = "被中断任务的重新排队顺序未能保存：" + error.localizedDescription; return false }
    }

    func stopSystemUploadForPolicy() {
        guard let owner = transferOwner else { return }
        let blockedByLocal = !background.permitsSystemWork
        let blockedByOfficial = !OfficialCloudAudioModel.shared.permitsRepair(ownerScope: ownerScope, wifi: background.wifi)
        guard blockedByLocal || blockedByOfficial else { return }
        let blockedTaskIDs: Set<String>? = blockedByLocal ? nil
            : Set(records.values.filter { $0.officialPolicyRequired == true && $0.needsUpload }.map(\.taskID))
        let manualTaskIDs = userRequestedUploadTaskIDs
        Task {
            for taskID in manualTaskIDs { await OfficialOSSTransferQueue.shared.promoteToUserInitiated(taskID: taskID, owner: owner) }
            await OfficialOSSTransferQueue.shared.cancel(owner: owner, source: .systemCloudSync, taskIDs: blockedTaskIDs)
        }
        if let activeEntryID, let record = record(for: activeEntryID), record.queueSource == "systemCloudSync",
           record.phase == "上传音频到官方 OSS", blockedTaskIDs == nil || blockedTaskIDs?.contains(record.taskID) == true {
            task?.cancel()
        }
    }

    func suspendForTermination() async {
        background.stop()
        stopPolling()
        modelTask?.cancel()
        task?.cancel()
        if let owner = transferOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: owner) }
        if let task { await task.value }
    }

    func suspendForSignOut() async {
        background.suspendForAccountChange()
        stopPolling(); modelTask?.cancel(); task?.cancel()
        if let owner = transferOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: owner) }
        if let task { await task.value }
    }

    func setPaused(_ paused: Bool, entryID: UUID) {
        if busy && activeEntryID == entryID {
            if paused { cancel() }
            return
        }
        guard let store, var record = record(for: entryID) else { return }
        if paused { stopPolling(entryID: entryID) }
        record.paused = paused; record.automaticallyResume = true
        do { try store.save(record); records = store.records }
        catch { notice = error.localizedDescription }
        if paused, let ownerScope {
            Task { await OfficialOSSTransferQueue.shared.cancelTask(taskID: record.taskID, ownerScope: ownerScope) }
        }
        if !paused { background.wake(reason: "手动恢复", force: true, entryID: entryID) }
    }

    /// Only already-authorized journal rows enter here. No UI draft changes the job.
    @discardableResult
    func resumeQueued(entryID: UUID, entry: RecordingLibraryEntry?) -> Bool {
        guard !busy, let service, let store, let configuration, let record = record(for: entryID),
              record.automaticallyResume == true, record.paused != true else { return false }
        guard !OfficialCloudAudioModel.shared.isSuppressed(taskID: record.taskID, ownerScope: store.ownerScope) else { return false }
        if !record.needsUpload, ["submitting", "uncertain", "accepted", "completed"].contains(record.transcriptionState) {
            guard record.sessionCreated else { return false }
            refreshResult(entryID: entryID)
            return true
        }
        guard record.transcriptionState != "failed" || record.needsUpload else { return false }
        let source: RecordingLibraryEntry
        if let entry { source = entry }
        else if let path = record.stagedFilePath {
            source = RecordingLibraryEntry(id: record.entryID, audioPath: path, title: record.title,
                createdAt: record.recordingStart, source: "upload_staging")
        } else { return false }
        execute(record, entry: source, service: service, store: store, configuration: configuration)
        return true
    }

    func stopPolling(entryID: UUID? = nil) {
        if let entryID {
            pollTasks.removeValue(forKey: entryID)?.cancel(); pollIDs.removeValue(forKey: entryID)
            pollingEntryIDs.remove(entryID)
        } else {
            for task in pollTasks.values { task.cancel() }
            pollTasks = [:]; pollIDs = [:]; pollingEntryIDs = []
        }
    }

    private func startPolling(entryID: UUID, service: OfficialMemoryService, store: OfficialRecordingUploadStore) {
        stopPolling(entryID: entryID)
        let id = UUID(); pollIDs[entryID] = id; pollingEntryIDs.insert(entryID)
        pollTasks[entryID] = Task {
            defer {
                if pollIDs[entryID] == id {
                    pollTasks.removeValue(forKey: entryID); pollIDs.removeValue(forKey: entryID); pollingEntryIDs.remove(entryID)
                }
            }
            for delay in [4, 8, 16, 32, 64] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard pollIDs[entryID] == id, var record = records[entryID.uuidString] else { return }
                    let value = try await service.session(taskID: record.taskID)
                    try Task.checkCancellation()
                    guard pollIDs[entryID] == id else { return }
                    guard let detail = (value as? [[String: Any]])?.first(where: { item in
                        ["aiTask", "recording"].contains { key in
                            OfficialMemoryRow.text((item[key] as? [String: Any])?["taskId"]) == record.taskID
                        }
                    }) else { continue }
                    applyResult(detail, to: &record)
                    try store.save(record); records = store.records; results[entryID] = detail
                    if !busy || activeEntryID == entryID { notice = record.phase }
                    if record.transcriptionState == "failed" || (record.transcriptionState == "completed"
                        && ["completed", "failed"].contains(record.summaryState ?? "")) { return }
                } catch {
                    if Task.isCancelled || pollIDs[entryID] != id { return }
                    if !busy { notice = "云结果读取暂未完成：" + error.localizedDescription }
                }
            }
            if pollIDs[entryID] == id, !busy { notice = "本轮自动等待已结束，云端结果仍未确认，可稍后手动刷新。" }
        }
    }

    private func applyResult(_ detail: [String: Any], to record: inout OfficialRecordingUploadRecord) {
        let taskStatus = ((detail["aiTask"] as? [String: Any])?["status"] as? NSNumber)?.intValue
        let recordingStatus = ((detail["recording"] as? [String: Any])?["status"] as? NSNumber)?.intValue
        if recordingStatus == 3 { record.transcriptionState = "completed"; record.phase = "官方转写已完成" }
        else if recordingStatus == 4 || taskStatus == 3 { record.transcriptionState = "failed"; record.phase = "官方任务失败，可查看云会话详情" }
        else if recordingStatus == 2 || taskStatus == 1 { record.transcriptionState = "accepted"; record.phase = "官方任务处理中" }
        else { record.phase = "已读取云任务，转写完成状态仍未确认" }
        if record.requestedTranscription {
            let statuses = (detail["summary"] as? [[String: Any]] ?? []).map { ($0["status"] as? NSNumber)?.intValue }
            if !statuses.isEmpty, statuses.allSatisfy({ $0 == 2 }) { record.summaryState = "completed" }
            else if !statuses.isEmpty, statuses.allSatisfy({ $0 == 2 || $0 == 3 }) { record.summaryState = "failed" }
            else { record.summaryState = "waiting" }
            if record.transcriptionState == "completed" {
                record.phase += record.summaryState == "completed" ? "；摘要已完成"
                    : record.summaryState == "failed" ? "；部分或全部摘要失败" : "；摘要结果仍在等待"
            }
        }
    }

    private func mergeUserRequest(into record: inout OfficialRecordingUploadRecord, store: OfficialRecordingUploadStore) {
        guard let latest = store.records[record.entryID.uuidString] else { return }
        if latest.queueSource == "userInitiatedSync" { record.queueSource = latest.queueSource }
        if latest.requestedTranscription, !record.requestedTranscription {
            record.requestedTranscription = true; record.summaryModel = latest.summaryModel
            record.sourceLanguage = latest.sourceLanguage; record.separateSpeakers = latest.separateSpeakers
            record.markers = latest.markers
        }
    }

    private func checkpoint(_ record: inout OfficialRecordingUploadRecord, store: OfficialRecordingUploadStore, operation: UUID, enforcePolicy: Bool = false) throws {
        try ensureCurrent(operation)
        mergeUserRequest(into: &record, store: store)
        try store.save(record); records = store.records; notice = record.phase
        if OfficialCloudAudioModel.shared.isSuppressed(taskID: record.taskID, ownerScope: store.ownerScope) { throw CancellationError() }
        if enforcePolicy { try checkTransferPolicy(record, store: store) }
    }
    private func checkTransferPolicy(_ record: OfficialRecordingUploadRecord, store: OfficialRecordingUploadStore) throws {
        if OfficialCloudAudioModel.shared.isSuppressed(taskID: record.taskID, ownerScope: store.ownerScope) { throw CancellationError() }
        let current = store.records[record.entryID.uuidString] ?? record
        guard current.queueSource == "systemCloudSync" else { return }
        if !background.permitsSystemWork { throw CancellationError() }
        if current.officialPolicyRequired == true, current.needsUpload,
           !OfficialCloudAudioModel.shared.permitsRepair(ownerScope: store.ownerScope, wifi: background.wifi) { throw CancellationError() }
    }
    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }
    private func begin(entryID: UUID?, message: String) -> UUID {
        if let entryID { stopPolling(entryID: entryID) }
        userRequestedPause = false
        let id = UUID(); operationID = id; activeEntryID = entryID; busy = true; progress = 0; notice = message
        return id
    }
    private func finish(_ id: UUID) {
        if operationID == id { operationID = UUID(); busy = false; activeEntryID = nil; task = nil }
    }
}
