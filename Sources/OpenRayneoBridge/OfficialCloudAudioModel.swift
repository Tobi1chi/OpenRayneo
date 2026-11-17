// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Foundation

@MainActor
final class OfficialCloudAudioModel: ObservableObject {
    static let shared = OfficialCloudAudioModel()
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var activeTaskID: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var notice = "选择云会话后可将音频下载到 Mac。"
    @Published private(set) var records: [String: OfficialCloudAudioRecord] = [:]
    @Published private(set) var cloudItems: [OfficialCloudAudioItem] = []
    @Published private(set) var difference: OfficialCloudAudioDifference?
    @Published private(set) var cloudConfiguration: OfficialCloudSyncConfiguration?
    @Published private(set) var automaticallyDownload = false
    @Published var syncEnabledDraft = false
    @Published var automaticDownloadDraft = true
    @Published var wifiOnlyDraft = false
    @Published private(set) var writingConfiguration = false
    @Published private(set) var configurationReadbackPending = false
    @Published private(set) var configurationNotice = "请先读取官方配置。"
    private var configuration: OfficialFirmwareConfiguration?
    private var service: OfficialMemoryService?
    private var store: OfficialCloudAudioStore?
    private weak var library: RecordingLibraryModel?
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var operationID = UUID()
    private var transferGeneration = UUID()
    private var started = false
    private var signOutSuspended = false
    private var online = false
    private var wifi = false
    private var automaticOperation = false
    private var transferPolicyRequired = false
    private var deleting = Set<String>()
    private var deletionTickets: [String: UUID] = [:]
    private var followupNeeded = false
    var ownerScope: String? { store?.ownerScope }
    var accountReference: OfficialFirmwareConfiguration? { configuration }
    private var transferOwner: OfficialOSSTransferQueue.Owner? {
        ownerScope.map { .init(scope: $0, generation: transferGeneration, accountEpoch: configuration?.identityEpoch) }
    }

    private init() {
        reloadAccount()
        subscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousOwner = self.transferOwner
                let previous = self.task
                previous?.cancel(); self.debounce?.cancel(); self.operationID = UUID()
                let transition = self.operationID
                self.busy = previous != nil; self.activeTaskID = nil
                self.configured = false; self.automaticallyDownload = false; self.followupNeeded = false
                self.writingConfiguration = false; self.configurationReadbackPending = false
                self.syncEnabledDraft = false; self.automaticDownloadDraft = true; self.wifiOnlyDraft = false
                self.configurationNotice = "官方账号已变化，请重新读取配置。"
                self.configuration = nil; self.service = nil; self.store = nil; self.records = [:]
                self.cloudItems = []; self.difference = nil; self.cloudConfiguration = nil; self.deleting = []; self.deletionTickets = [:]
                if let previousOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: previousOwner) }
                if let previous { await previous.value }
                guard self.operationID == transition else { return }
                self.task = nil; self.busy = false; self.reloadAccount(); self.signOutSuspended = false; self.wake(reason: "账号就绪")
            }
        }
    }

    private func reloadAccount() {
        transferGeneration = UUID()
        configured = false; automaticallyDownload = false
        do {
            let value = try OfficialFirmwareConfiguration.fromEnvironment()
            guard !value.accessToken.isEmpty else { notice = "登录官方账号后可下载云音频。"; return }
            let store = try OfficialCloudAudioStore(configuration: value)
            configuration = value; service = OfficialMemoryService(configuration: value); self.store = store
            records = store.records; automaticallyDownload = store.automaticallyDownload; configured = true
            notice = "云音频下载已配置。"
        } catch { notice = error.localizedDescription }
    }

    func start(library: RecordingLibraryModel) { self.library = library; started = true; wake(reason: "应用启动") }
    func networkChanged(online: Bool, wifi: Bool) {
        let changed = self.online != online || self.wifi != wifi
        self.online = online; self.wifi = wifi
        if transferPolicyRequired && (!online || (cloudConfiguration?.onlyWifiSync == true && !wifi)) { task?.cancel() }
        stopSystemDownloadsForPolicy()
        if changed && online { wake(reason: "网络恢复") }
    }
    func wake(reason: String) {
        guard started, !signOutSuspended, configured, automaticallyDownload || hasPendingRepair else { return }
        if busy { followupNeeded = true; return }
        debounce?.cancel(); let token = operationID
        debounce = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard token == operationID, !signOutSuspended, !busy, online else { return }
            if automaticallyDownload { synchronize(downloadMissing: true, automatic: true) }
            else { readConfiguration() }
        }
    }
    func setAutomatic(_ enabled: Bool) {
        guard let store else { return }
        do { try store.setAutomatic(enabled); automaticallyDownload = enabled; if enabled { wake(reason: "启用自动双向同步") } }
        catch { notice = error.localizedDescription }
        if !enabled { followupNeeded = false; debounce?.cancel(); if automaticOperation { task?.cancel() } }
        stopSystemDownloadsForPolicy()
    }
    func readConfiguration() {
        guard !signOutSuspended, !busy, let service else { return }
        let id = begin(automatic: false)
        task = Task {
            defer { finish(id) }
            do {
                let value = try await service.cloudSyncConfiguration(); try check(id)
                acceptConfiguration(value); configurationReadbackPending = false
                configurationNotice = "已读取官方云同步配置。"; notice = configurationNotice
                OfficialRecordingUploadModel.shared.stopSystemUploadForPolicy()
                OfficialRecordingUploadModel.shared.background.wake(reason: "官方补云策略已读取", wakeCloud: false)
            }
            catch { if operationID == id { notice = error.localizedDescription } }
        }
    }

    var configurationDraftDirty: Bool {
        guard let current = cloudConfiguration else { return false }
        return syncEnabledDraft != current.syncFlag || automaticDownloadDraft != current.autoSync || wifiOnlyDraft != current.onlyWifiSync
    }
    var canSaveConfiguration: Bool {
        configured && cloudConfiguration != nil && configurationDraftDirty && !writingConfiguration && !configurationReadbackPending
    }
    var configurationRequiresDisableConfirmation: Bool { cloudConfiguration?.syncFlag == true && !syncEnabledDraft }

    func resetConfigurationDraft() {
        guard let current = cloudConfiguration, !writingConfiguration else { return }
        syncEnabledDraft = current.syncFlag; automaticDownloadDraft = current.autoSync; wifiOnlyDraft = current.onlyWifiSync
    }

    private func acceptConfiguration(_ value: OfficialCloudSyncConfiguration, resetDraft: Bool = false) {
        let keepDraft = configurationDraftDirty && !resetDraft
        cloudConfiguration = value
        stopSystemDownloadsForPolicy()
        if !keepDraft {
            syncEnabledDraft = value.syncFlag; automaticDownloadDraft = value.autoSync; wifiOnlyDraft = value.onlyWifiSync
        }
    }

    /// Writes once. A failed confirmation read never replays the POST.
    func saveConfiguration() {
        guard canSaveConfiguration, let service, let old = cloudConfiguration else { return }
        let request = OfficialCloudSyncSettingsRequest(syncFlag: syncEnabledDraft,
            autoSync: automaticDownloadDraft, onlyWifiSync: wifiOnlyDraft)
        let previous = task
        previous?.cancel(); debounce?.cancel(); followupNeeded = false
        if let activeTaskID, let store, var record = store.records[activeTaskID], record.state != "ready" {
            record.state = "paused"; record.lastError = nil
            do { try store.save(record); records = store.records }
            catch { configurationNotice = "当前下载已停止，但状态未能保存：" + error.localizedDescription }
        }
        let proposed = OfficialCloudSyncConfiguration(json: ["syncFlag": request.syncFlag,
            "autoSync": request.autoSync, "onlyWifiSync": request.onlyWifiSync,
            "capacity": old.capacity as Any? ?? NSNull(), "usedCapacity": old.usedCapacity as Any? ?? NSNull()])
        let id = begin(automatic: false)
        activeTaskID = nil; writingConfiguration = true
        cloudConfiguration = proposed; configurationReadbackPending = true
        stopSystemDownloadsForPolicy()
        configurationNotice = "正在保存官方云同步配置…"
        OfficialRecordingUploadModel.shared.stopSystemUploadForPolicy()
        task = Task {
            defer {
                if operationID == id { writingConfiguration = false }
                finish(id)
            }
            if let previous { await previous.value }
            do {
                try check(id)
                _ = try await service.editCloudSyncConfiguration(request)
                try check(id)
            } catch {
                guard operationID == id else { return }
                cloudConfiguration = old; configurationReadbackPending = true
                configurationNotice = "设置保存未确认，已还原本地显示。请重新读取官方配置：" + error.localizedDescription
                notice = configurationNotice
                OfficialRecordingUploadModel.shared.stopSystemUploadForPolicy()
                return
            }
            do {
                let confirmed = try await service.cloudSyncConfiguration(); try check(id)
                acceptConfiguration(confirmed, resetDraft: true); configurationReadbackPending = false
                let matches = confirmed.syncFlag == request.syncFlag && confirmed.autoSync == request.autoSync
                    && confirmed.onlyWifiSync == request.onlyWifiSync
                configurationNotice = matches ? "官方配置已保存并读回确认。" : "保存请求已受理；读回值与提交值不同，当前显示服务端值。"
                notice = configurationNotice
                OfficialRecordingUploadModel.shared.stopSystemUploadForPolicy()
                OfficialRecordingUploadModel.shared.background.wake(reason: "官方云设置已保存", wakeCloud: false)
                if confirmed.syncFlag && automaticallyDownload { followupNeeded = true }
            } catch {
                guard operationID == id else { return }
                configurationReadbackPending = true
                configurationNotice = "保存已受理，读回暂未确认；未重复提交：" + error.localizedDescription
                notice = configurationNotice
            }
        }
    }

    private var hasPendingRepair: Bool {
        let upload = OfficialRecordingUploadModel.shared
        return upload.ownerScope == ownerScope && upload.records.values.contains {
            $0.officialPolicyRequired == true && $0.canAutomaticallyContinue && $0.needsUpload
        }
    }

    func permitsRepair(ownerScope: String?, wifi: Bool) -> Bool {
        guard self.ownerScope == ownerScope, !configurationReadbackPending,
              let value = cloudConfiguration else { return false }
        return value.syncFlag && (!value.onlyWifiSync || wifi)
    }

    func synchronize(downloadMissing: Bool, automatic: Bool = false) {
        guard !signOutSuspended, !busy, let service, let store else { return }
        let id = begin(automatic: automatic, transfer: true)
        task = Task {
            defer { finish(id) }
            do {
                let settings = try await service.cloudSyncConfiguration(); try check(id)
                acceptConfiguration(settings); configurationReadbackPending = false
                guard settings.syncFlag else { throw OfficialMemoryFailure(message: "官方云同步总开关未开启，本轮未传输音频。") }
                guard !settings.onlyWifiSync || wifi else { throw OfficialMemoryFailure(message: "官方设置要求 Wi-Fi，当前未满足。") }
                var cycle = OfficialSessionListCycle(taskType: "all")
                var deadline: Int64 = 9_999_999_999_999
                var rows: [OfficialCloudAudioItem] = []
                while true {
                    let value = try await service.sessions(deadline: deadline, taskType: nil, pageSize: 100)
                    try check(id)
                    guard let page = value as? [String: Any], let raw = page["pageList"] as? [[String: Any]] else {
                        throw OfficialMemoryFailure(message: "云音频同步没有取得明确的 Session 分页列表。")
                    }
                    let next = cycle.accept(rows: raw, total: (page["total"] as? NSNumber)?.intValue,
                        deadline: deadline, explicitPage: true)
                    rows.append(contentsOf: raw.compactMap(OfficialCloudAudioItem.init(session:)))
                    if cycle.complete { break }
                    guard cycle.safe, let next else { throw OfficialMemoryFailure(message: "Session 快照未覆盖完整一致的分页，本轮未按缺项执行同步。") }
                    deadline = next
                }
                rows.removeAll { blocked($0.taskID, store: store) }
                cloudItems = rows
                var failures = 0, repaired = 0
                // A completed transfer may have been interrupted during decode or library registration.
                for item in rows {
                    guard let record = store.records[item.taskID], hasLocalAudio(record),
                          record.state != "ready" || cloudEntry(taskID: item.taskID, ownerScope: store.ownerScope) == nil else { continue }
                    try check(id, taskID: item.taskID, store: store); try checkAutomaticPolicy()
                    do { try await receive(item, store: store, service: service, operation: id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failures += 1 }
                }
                try check(id)
                let local = localItems()
                let diff = OfficialCloudAudioDifference.calculate(local: local, cloud: rows.filter { !blocked($0.taskID, store: store) })
                difference = diff
                for item in diff.localOnly {
                    try check(id, taskID: item.taskID, store: store); try checkAutomaticPolicy()
                    guard let entry = localEntry(taskID: item.taskID, ownerScope: store.ownerScope) else { failures += 1; continue }
                    if OfficialRecordingUploadModel.shared.enqueueCloudRepair(item: item, entry: entry,
                        ownerScope: store.ownerScope, automatic: automatic) != nil { repaired += 1 }
                    else { failures += 1 }
                }
                if downloadMissing && settings.autoSync {
                    for item in diff.cloudOnly {
                        try check(id, taskID: item.taskID, store: store); try checkAutomaticPolicy()
                        do { try await receive(item, store: store, service: service, operation: id) }
                        catch is CancellationError { throw CancellationError() }
                        catch { failures += 1; notice = "一条云音频未完成：" + error.localizedDescription }
                    }
                }
                let skipped = downloadMissing && !settings.autoSync ? "；官方自动下载已关闭，仅处理补云" : ""
                let warnings = records.values.filter { $0.state == "ready" && $0.lastError != nil }.count
                notice = "同步批次结束：补云入队 \(repaired) 条，下载候选 \(diff.cloudOnly.count) 条，未完成 \(failures) 条\(skipped)"
                    + (warnings > 0 ? "；\(warnings) 条音频正文暂未读取" : "")
            } catch { if operationID == id { notice = Task.isCancelled ? "云音频同步已停止，已下载文件保留。" : error.localizedDescription } }
        }
    }

    func download(_ item: OfficialCloudAudioItem, configuration reference: OfficialFirmwareConfiguration? = nil) {
        guard !signOutSuspended, !busy, let store, let service else { return }
        if let reference, configuration?.hasSameIdentity(as: reference) != true {
            notice = "账号已变化，请重新选择当前账号的云会话。"; return
        }
        guard !store.cloudDeleted.contains(item.taskID), !deleting.contains(item.taskID) else {
            notice = "此云会话已删除或正在删除，未恢复下载。"; return
        }
        let id = begin(automatic: false, transfer: true)
        task = Task {
            defer { finish(id) }
            do {
                let settings = try await service.cloudSyncConfiguration(); try check(id)
                acceptConfiguration(settings); configurationReadbackPending = false
                guard settings.syncFlag else { throw OfficialMemoryFailure(message: "官方云同步总开关未开启。") }
                guard !settings.onlyWifiSync || wifi else { throw OfficialMemoryFailure(message: "官方设置要求 Wi-Fi，当前未满足。") }
                guard !store.cloudDeleted.contains(item.taskID), !deleting.contains(item.taskID) else { throw CancellationError() }
                if store.suppressed.contains(item.taskID) { try store.allow(taskID: item.taskID) }
                try await receive(item, store: store, service: service, operation: id)
                notice = store.records[item.taskID]?.lastError == nil ? "云音频已保存到当前账号的录音资料库。"
                    : "云音频已保存；转写和摘要正文暂未读取，可稍后重新读取。"
            } catch { if operationID == id { notice = Task.isCancelled ? "下载已取消，完整文件保留。" : error.localizedDescription } }
        }
    }

    private func receive(_ item: OfficialCloudAudioItem, store: OfficialCloudAudioStore,
                         service: OfficialMemoryService, operation: UUID) async throws {
        try check(operation, taskID: item.taskID, store: store)
        guard let library else { throw OfficialMemoryFailure(message: "录音资料库尚未就绪。") }
        activeTaskID = item.taskID; progress = 0
        var record = store.records[item.taskID] ?? OfficialCloudAudioRecord(taskID: item.taskID, title: item.title,
            taskType: item.taskType, createdAtMilliseconds: item.createdAtMilliseconds)
        record.title = item.title.isEmpty ? record.title : item.title
        do {
            if !hasLocalAudio(record) {
                record.state = "downloading"; record.lastError = nil; try store.save(record); records = store.records
                let snapshot = record
                let result = try await fetchObject(item, record: snapshot, store: store, service: service, operation: operation)
                do { try check(operation, taskID: item.taskID, store: store) }
                catch { try? FileManager.default.trashItem(at: result.fileURL, resultingItemURL: nil); throw error }
                record.compressedPath = result.fileURL.path; record.state = "downloaded"
                record.bucketName = result.bucketName; record.objectKey = result.objectKey
                try store.save(record); records = store.records
            }
            try checkAutomaticPolicy(); try check(operation, taskID: item.taskID, store: store)
            if !validFile(record.audioPath), let path = record.compressedPath {
                record.state = "preparing"; try store.save(record); records = store.records
                let audio = try await OfficialCloudAudioImport.prepare(source: URL(fileURLWithPath: path), directory: store.assetDirectory(record)) { value in
                    if self.operationID == operation { self.progress = 0.8 + value * 0.2 }
                }
                try check(operation, taskID: item.taskID, store: store)
                record.audioPath = audio.audioURL.path; record.duration = audio.duration; record.channelCount = audio.channelCount
                try store.save(record); records = store.records
            }
            try check(operation, taskID: item.taskID, store: store)
            var detail: [String: Any]?, detailError: String?
            do {
                let detailValue = try await service.session(taskID: item.taskID)
                try check(operation, taskID: item.taskID, store: store)
                detail = (detailValue as? [[String: Any]])?.first { row in
                    ["aiTask", "recording"].contains { key in OfficialMemoryRow.text((row[key] as? [String: Any])?["taskId"]) == item.taskID }
                }
                if detail == nil { detailError = "音频已保存，但官方尚未返回此任务的正文。" }
            } catch {
                try check(operation, taskID: item.taskID, store: store)
                detailError = "音频已保存，正文读取暂未完成：" + error.localizedDescription
            }
            try check(operation, taskID: item.taskID, store: store)
            try library.registerCloudAudio(record: record, ownerScope: store.ownerScope, detail: detail)
            record.state = "ready"; record.lastError = detailError; try store.save(record); records = store.records; progress = 1
        } catch {
            if operationID == operation {
                record.state = Task.isCancelled ? "paused" : "failed"; record.lastError = error.localizedDescription
                try? store.save(record); records = store.records
            }
            throw error
        }
    }

    private struct ReceivedObject: Sendable { let fileURL: URL; let bucketName: String; let objectKey: String }
    private func fetchObject(_ item: OfficialCloudAudioItem, record: OfficialCloudAudioRecord,
                             store: OfficialCloudAudioStore, service: OfficialMemoryService, operation: UUID) async throws -> ReceivedObject {
        try check(operation, taskID: item.taskID, store: store); try checkAutomaticPolicy()
        let buckets = try await service.getBucketInfo(); try check(operation, taskID: item.taskID, store: store)
        let addresses = candidates(item, buckets: buckets)
        var lastError: Error = OfficialMemoryFailure(message: "云会话没有可下载的音频地址。")
        for (bucket, key) in addresses {
            for attempt in 0...1 {
                let credential = try await service.getTempAk(bucketName: bucket)
                try check(operation, taskID: item.taskID, store: store); try checkAutomaticPolicy()
                guard let endpoint = URL(string: credential.endpoint) else { throw OfficialMemoryFailure(message: "OSS endpoint 无法解析。") }
                let ext = (key as NSString).pathExtension.lowercased()
                let suffix = ["pcm", "wav", "mp3", "opus", "ogg", "m4a", "aac", "flac"].contains(ext) ? ext : "audio"
                let destination = store.assetDirectory(record).appendingPathComponent("source-\(UUID().uuidString).\(suffix)")
                guard let owner = transferOwner else { throw CancellationError() }
                let source: OfficialOSSTransferQueue.Source = automaticOperation ? .systemCloudSync : .userInitiatedSync
                let scopedCredentials = OfficialOSSDownloader.Credentials(accessKeyID: credential.ak, secretAccessKey: credential.sk,
                    securityToken: credential.st, endpoint: endpoint)
                do {
                    let result: OfficialOSSDownloader.Result = try await OfficialOSSTransferQueue.shared.run(owner: owner,
                        taskID: item.taskID, kind: .download, source: source, discardLateResult: { result in
                            try? FileManager.default.trashItem(at: result.fileURL, resultingItemURL: nil)
                        }) { _ in
                        try await OfficialOSSDownloader().download(bucketName: bucket, objectKey: key,
                            credentials: scopedCredentials, destinationFileURL: destination) { value in
                                Task { @MainActor in
                                    if self.operationID == operation { self.progress = (value.fraction ?? 0) * 0.8 }
                                }
                            }
                    }
                    do { try check(operation, taskID: item.taskID, store: store) }
                    catch { try? FileManager.default.trashItem(at: result.fileURL, resultingItemURL: nil); throw error }
                    return ReceivedObject(fileURL: result.fileURL, bucketName: bucket, objectKey: key)
                } catch is CancellationError { throw CancellationError() }
                catch let failure as OfficialOSSDownloader.Failure {
                    lastError = failure
                    if failure.isCredentialRejected && attempt == 0 { continue }
                    if failure.isCredentialRejected { throw failure }
                    break
                }
            }
        }
        throw lastError
    }

    private func candidates(_ item: OfficialCloudAudioItem, buckets: OfficialSessionBucketInfo) -> [(String, String)] {
        var names: [String] = [], keys: [String] = []
        for value in [item.bucketName, buckets.bucket, buckets.tempBucket].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            where !value.isEmpty && !names.contains(value) { names.append(value) }
        let key = item.objectKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ext = (key as NSString).pathExtension.isEmpty ? "pcm" : (key as NSString).pathExtension
        let name = item.taskID + "." + ext
        let parent = (key as NSString).deletingLastPathComponent
        for value in [key, parent.isEmpty ? name : parent + "/" + name, "recording/" + name]
            + ["pcm", "wav", "mp3", "opus"].map({ "recording/" + item.taskID + "." + $0 })
            where !value.isEmpty && !keys.contains(value) { keys.append(value) }
        return names.flatMap { bucket in keys.map { (bucket, $0) } }
    }

    private func localItems() -> [OfficialCloudAudioItem] {
        guard let store else { return [] }
        var local = store.records.values.filter { hasLocalAudio($0) && !blocked($0.taskID, store: store) }
            .map { OfficialCloudAudioItem(taskID: $0.taskID, title: $0.title, bucketName: $0.bucketName, objectKey: $0.objectKey) }
        let uploads = OfficialRecordingUploadModel.shared
        if uploads.ownerScope == store.ownerScope {
            for record in uploads.records.values {
                guard localEntry(taskID: record.taskID, ownerScope: store.ownerScope) != nil,
                      !blocked(record.taskID, store: store) else { continue }
                local.append(.init(taskID: record.taskID, title: record.title, bucketName: record.object?.bucketName, objectKey: record.object?.objectKey))
            }
        }
        for entry in library?.entries ?? [] where entry.cloudOwnerScope == store.ownerScope && entry.finalized {
            guard let taskID = entry.cloudTaskID, !blocked(taskID, store: store),
                  validFile(entry.audioPath) || validFile(entry.cloudCompressedPath) else { continue }
            local.append(.init(taskID: taskID, title: entry.title))
        }
        var seen = Set<String>()
        local = local.filter { seen.insert($0.taskID).inserted }
        return local
    }
    private func cloudEntry(taskID: String, ownerScope: String) -> RecordingLibraryEntry? {
        library?.entries.first { $0.cloudOwnerScope == ownerScope && $0.cloudTaskID == taskID }
    }
    private func localEntry(taskID: String, ownerScope: String) -> RecordingLibraryEntry? {
        let uploads = OfficialRecordingUploadModel.shared
        if uploads.ownerScope == ownerScope, let record = uploads.records.values.first(where: { $0.taskID == taskID }) {
            if let entry = library?.entries.first(where: { $0.id == record.entryID || ($0.nativeIdentity != nil && $0.nativeIdentity == record.nativeIdentity) }),
               entry.finalized, validFile(entry.audioPath) { return entry }
            if let path = record.stagedFilePath, validFile(path) {
                return RecordingLibraryEntry(id: record.entryID, audioPath: path, title: record.title,
                    createdAt: record.recordingStart, source: "upload_staging")
            }
        }
        if var entry = cloudEntry(taskID: taskID, ownerScope: ownerScope), entry.finalized {
            if validFile(entry.audioPath) { return entry }
            if validFile(entry.cloudCompressedPath) { entry.audioPath = entry.cloudCompressedPath; return entry }
        }
        if let record = store?.records[taskID], self.ownerScope == ownerScope, hasLocalAudio(record) {
            return RecordingLibraryEntry(id: record.id, audioPath: validFile(record.audioPath) ? record.audioPath : record.compressedPath,
                title: record.title, createdAt: Date(timeIntervalSince1970: Double(record.createdAtMilliseconds ?? 0) / 1000), source: "official_cloud")
        }
        return nil
    }
    private func validFile(_ path: String?) -> Bool {
        guard let path, !path.hasSuffix(".downloading"), !path.hasSuffix(".download"),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
    private func hasLocalAudio(_ record: OfficialCloudAudioRecord) -> Bool {
        validFile(record.compressedPath) || validFile(record.audioPath)
    }
    private func blocked(_ taskID: String, store: OfficialCloudAudioStore) -> Bool {
        store.suppressed.contains(taskID) || store.cloudDeleted.contains(taskID)
            || (ownerScope == store.ownerScope && deleting.contains(taskID))
    }
    func isSuppressed(taskID: String, ownerScope: String?) -> Bool {
        guard let store, store.ownerScope == ownerScope else { return false }
        return blocked(taskID, store: store)
    }

    struct DeletionTicket {
        fileprivate let id: UUID
        let taskID: String
        let ownerScope: String
        fileprivate let store: OfficialCloudAudioStore
    }
    func beginCloudDeletion(taskID: String, configuration reference: OfficialFirmwareConfiguration) -> DeletionTicket? {
        guard let store, configuration?.hasSameIdentity(as: reference) == true, !deleting.contains(taskID) else { return nil }
        let id = UUID(); deletionTickets[taskID] = id; deleting.insert(taskID)
        if activeTaskID == taskID { task?.cancel() }
        OfficialRecordingUploadModel.shared.suspendForCloudDeletion(taskID: taskID, ownerScope: store.ownerScope)
        return DeletionTicket(id: id, taskID: taskID, ownerScope: store.ownerScope, store: store)
    }
    func finishCloudDeletion(ticket: DeletionTicket, success: Bool) {
        let destination = ownerScope == ticket.ownerScope ? (store ?? ticket.store) : ticket.store
        if success {
            do { try destination.suppressCloud(taskID: ticket.taskID) }
            catch { if ownerScope == ticket.ownerScope { notice = "云会话已删除，但本机删除记录未保存：" + error.localizedDescription } }
        }
        guard ownerScope == ticket.ownerScope else { return }
        if deletionTickets[ticket.taskID] == ticket.id {
            deleting.remove(ticket.taskID); deletionTickets.removeValue(forKey: ticket.taskID)
        }
        if success {
            records = destination.records; cloudItems.removeAll { $0.taskID == ticket.taskID }
            difference = nil
            OfficialRecordingUploadModel.shared.pauseForCloudDeletion(taskID: ticket.taskID, ownerScope: ticket.ownerScope)
        }
    }
    func canDownload(taskID: String) -> Bool {
        configured && store?.cloudDeleted.contains(taskID) != true && !deleting.contains(taskID)
    }
    func suppressLocal(taskID: String, ownerScope: String) throws {
        guard let store, store.ownerScope == ownerScope else {
            throw OfficialMemoryFailure(message: "官方账号已变化，未删除其他账号的本地音频。")
        }
        if activeTaskID == taskID { task?.cancel() }
        try store.suppress(taskID: taskID); records = store.records
    }
    func cancel() { if !writingConfiguration { task?.cancel() } }
    func suspendForTermination() async {
        started = false; followupNeeded = false; debounce?.cancel(); task?.cancel()
        if let owner = transferOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: owner) }
        if let task { await task.value }
    }
    func suspendForSignOut() async {
        signOutSuspended = true
        followupNeeded = false; debounce?.cancel(); task?.cancel()
        if let owner = transferOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: owner) }
        if let task { await task.value }
    }
    private func checkAutomaticPolicy() throws {
        if automaticOperation && !automaticallyDownload { throw CancellationError() }
        if transferPolicyRequired && (!online || cloudConfiguration?.syncFlag == false
            || (cloudConfiguration?.onlyWifiSync == true && !wifi)) { throw CancellationError() }
    }
    private func stopSystemDownloadsForPolicy() {
        guard let owner = transferOwner,
              !online || !automaticallyDownload || configurationReadbackPending || cloudConfiguration?.syncFlag != true
                || cloudConfiguration?.autoSync != true || (cloudConfiguration?.onlyWifiSync == true && !wifi) else { return }
        let upload = OfficialRecordingUploadModel.shared
        let manualTaskIDs = upload.ownerScope == owner.scope ? upload.userRequestedUploadTaskIDs : []
        Task {
            for taskID in manualTaskIDs { await OfficialOSSTransferQueue.shared.promoteToUserInitiated(taskID: taskID, owner: owner) }
            await OfficialOSSTransferQueue.shared.cancel(owner: owner, source: .systemCloudSync)
        }
    }
    private func check(_ id: UUID, taskID: String? = nil, store: OfficialCloudAudioStore? = nil) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
        if let store {
            guard ownerScope == store.ownerScope else { throw CancellationError() }
            if let taskID, blocked(taskID, store: store) { throw CancellationError() }
        }
    }
    private func begin(automatic: Bool, transfer: Bool = false) -> UUID {
        let id = UUID(); operationID = id; busy = true; progress = 0; automaticOperation = automatic
        transferPolicyRequired = transfer; return id
    }
    private func finish(_ id: UUID) {
        if operationID == id {
            operationID = UUID(); busy = false; task = nil; activeTaskID = nil; automaticOperation = false; transferPolicyRequired = false
            if followupNeeded { followupNeeded = false; wake(reason: "处理期间收到的同步触发") }
        }
    }
}
