// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Foundation
import Network

@MainActor
final class OfficialRecordingUploadBackground: ObservableObject {
    struct Policy: Codable {
        var resumeQueued = true
        var newNativeRecordings = false
        var transcribeNewRecordings = false
        var wifiOnly = false
        var region = "CN"
        var sourceLanguage = "auto"
        var separateSpeakers = true
        var summaryModel: String?
        var includeGlassesStarts: Bool?
        var claimedNativeIdentities: Set<String>?
        var enabledAtMilliseconds: Int64?
        var baseline = Set<String>()
    }

    @Published private(set) var policy = Policy()
    @Published private(set) var notice = "后台同步尚未启动。"
    @Published private(set) var online = false
    @Published private(set) var wifi = false
    private weak var model: OfficialRecordingUploadModel?
    private weak var library: RecordingLibraryModel?
    private var scope: String?
    private var directory: URL?
    private var monitor: NWPathMonitor?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var scanner: Task<Void, Never>?
    private var generation = UUID()
    private var attempted = Set<UUID>()
    private var draining = false
    private var forceAll = false
    private var forcedEntryIDs = Set<UUID>()
    private var pendingForceAll = false
    private var pendingForcedEntryIDs = Set<UUID>()
    private var preemptedEntryID: UUID?
    private var modificationDates: [String: Date] = [:]
    private var activatedAtMilliseconds: Int64 = 0

    init(model: OfficialRecordingUploadModel) { self.model = model }
    private var isCurrentOwner: Bool { scope != nil && scope == model?.ownerScope }
    var permitsSystemWork: Bool {
        let forced = forceAll || model?.activeEntryID.map { forcedEntryIDs.contains($0) } == true
        return isCurrentOwner && online && (forced || (policy.resumeQueued && (!policy.wifiOnly || wifi)))
    }

    func start(library: RecordingLibraryModel) {
        guard OfficialCloudPolicy.enabled else { notice = OfficialCloudPolicy.explanation; return }
        self.library = library
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied, wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self, self.monitor != nil else { return }
                let changed = self.online != available || self.wifi != wifi
                self.online = available; self.wifi = wifi
                OfficialCloudAudioModel.shared.networkChanged(online: available, wifi: wifi)
                self.model?.stopSystemUploadForPolicy()
                if available && changed { self.wake(reason: "网络恢复") }
                if !available { self.notice = "等待网络恢复；已入队任务保留。" }
            }
        }
        monitor.start(queue: DispatchQueue(label: "OpenRayneo.upload-network"))
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.wake(reason: "回到前台") } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.wake(reason: "系统唤醒") } })
        model?.$busy.removeDuplicates().sink { [weak self] busy in
            if !busy { Task { @MainActor [weak self] in self?.next() } }
        }.store(in: &subscriptions)
        accountChanged()
    }

    func stop() {
        try? scanNewNative()
        generation = UUID(); debounce?.cancel(); scanner?.cancel()
        debounce = nil; scanner = nil; draining = false
        forceAll = false; forcedEntryIDs = []; pendingForceAll = false; pendingForcedEntryIDs = []
        monitor?.cancel(); monitor = nil; subscriptions = []
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    func accountChanged() {
        generation = UUID(); debounce?.cancel(); scanner?.cancel()
        debounce = nil; scanner = nil; attempted = []; draining = false; preemptedEntryID = nil
        forceAll = false; forcedEntryIDs = []; pendingForceAll = false; pendingForcedEntryIDs = []
        modificationDates = [:]; policy = Policy()
        activatedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        scope = model?.ownerScope; directory = model?.uploadDirectory
        if let directory {
            let file = directory.appendingPathComponent("background-policy.json")
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: file))
                }
                notice = "已载入当前账号的后台同步策略。"
            } catch {
                policy.resumeQueued = false; policy.newNativeRecordings = false
                notice = "后台同步配置读取失败，已保留原文件：" + error.localizedDescription
            }
        } else { notice = "登录官方账号后可管理后台同步。" }
        startScanner()
        if monitor != nil { wake(reason: "账号／应用就绪") }
    }

    func suspendForAccountChange() {
        try? scanNewNative()
        generation = UUID(); debounce?.cancel(); scanner?.cancel()
        debounce = nil; scanner = nil; draining = false
        forceAll = false; forcedEntryIDs = []; pendingForceAll = false; pendingForcedEntryIDs = []
        scope = nil; directory = nil; modificationDates = [:]
    }

    func updatePolicy(resume: Bool? = nil, autoNative: Bool? = nil, transcribe: Bool? = nil,
                      wifiOnly: Bool? = nil, includeGlassesStarts: Bool? = nil) {
        guard let model, scope != nil else { return }
        var updated = policy
        if let resume { updated.resumeQueued = resume }
        if let wifiOnly { updated.wifiOnly = wifiOnly }
        if let includeGlassesStarts { updated.includeGlassesStarts = includeGlassesStarts; modificationDates = [:] }
        if let transcribe {
            if transcribe, model.usableModel == nil { notice = "请先读取并选择账号可用的官方模型。"; return }
            updated.transcribeNewRecordings = transcribe
            updated.summaryModel = transcribe ? model.usableModel?.id : nil
        }
        if let autoNative, autoNative != updated.newNativeRecordings {
            if autoNative {
                guard !model.regionCode.isEmpty else { notice = "请先填写官方录音的国家／地区代码。"; return }
                do { updated.baseline = Set(try nativeFiles().map { $0.standardizedFileURL.path }) }
                catch { notice = "无法建立已有原生录音基线，未开启自动备份：" + error.localizedDescription; return }
                updated.enabledAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
                updated.region = model.regionCode; updated.sourceLanguage = model.sourceLanguage
                updated.separateSpeakers = model.separateSpeakers
                modificationDates = [:]
            }
            updated.newNativeRecordings = autoNative
        }
        do {
            try save(updated); policy = updated; notice = "当前账号后台同步策略已保存。"
            if !updated.resumeQueued {
                draining = false; forceAll = false; forcedEntryIDs = []
                pendingForceAll = false; pendingForcedEntryIDs = []
            }
            if !permitsSystemWork { model.stopSystemUploadForPolicy() }
            startScanner(); wake(reason: "同步策略变化")
        } catch { notice = "后台同步策略未保存：" + error.localizedDescription }
    }

    func wake(reason: String, force: Bool = false, entryID: UUID? = nil, wakeCloud: Bool = true) {
        if wakeCloud { OfficialCloudAudioModel.shared.wake(reason: reason) }
        guard monitor != nil, isCurrentOwner else { return }
        if force {
            if let entryID { pendingForcedEntryIDs.insert(entryID) }
            else { pendingForceAll = true }
        }
        debounce?.cancel()
        let token = generation
        debounce = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard token == generation else { return }
            debounce = nil
            let requestedAll = pendingForceAll, requestedIDs = pendingForcedEntryIDs
            let requested = requestedAll || !requestedIDs.isEmpty
            pendingForceAll = false; pendingForcedEntryIDs = []
            guard model?.configured == true else { notice = "等待官方账号会话。"; return }
            guard online else { notice = "等待网络恢复；队列保持原样。"; return }
            guard policy.resumeQueued || requested else { notice = "自动继续已暂停，可手动处理队列。"; return }
            attempted = []; draining = true
            forceAll = requestedAll; forcedEntryIDs = requestedIDs
            notice = "处理后台队列：" + reason
            next()
        }
    }

    func prioritize(entryID: UUID) {
        if let interrupted = model?.preemptBackgroundUpload() { preemptedEntryID = interrupted }
        wake(reason: "用户优先处理", force: true, entryID: entryID)
    }

    private func next() {
        guard draining, isCurrentOwner, let model, !model.busy, model.configured, online else { return }
        if let preemptedEntryID {
            self.preemptedEntryID = nil
            if model.requeueInterruptedUpload(entryID: preemptedEntryID) { attempted.remove(preemptedEntryID) }
            else { attempted.insert(preemptedEntryID) }
        }
        let jobs = model.records.values.filter { $0.canAutomaticallyContinue }.sorted {
            let left = $0.priority ?? 0, right = $1.priority ?? 0
            if left != right { return left > right }
            let leftOrder = (left > 0 ? $0.prioritySequence ?? $0.queueSequence : $0.queueSequence) ?? Int64.min
            let rightOrder = (right > 0 ? $1.prioritySequence ?? $1.queueSequence : $1.queueSequence) ?? Int64.min
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            let leftTime = $0.queuedAtMilliseconds ?? 0, rightTime = $1.queuedAtMilliseconds ?? 0
            if leftTime != rightTime { return leftTime < rightTime }
            return $0.taskID < $1.taskID
        }
        for job in jobs where !attempted.contains(job.entryID) {
            if job.queueSource == "systemCloudSync", job.officialPolicyRequired == true && job.needsUpload
                && !OfficialCloudAudioModel.shared.permitsRepair(ownerScope: model.ownerScope, wifi: wifi) {
                if OfficialCloudAudioModel.shared.cloudConfiguration == nil,
                   forceAll || forcedEntryIDs.contains(job.entryID) { pendingForcedEntryIDs.insert(job.entryID) }
                continue
            }
            let forced = forceAll || forcedEntryIDs.contains(job.entryID)
            if !policy.resumeQueued && !forced { continue }
            if !forced && policy.wifiOnly && !wifi && job.queueSource == "systemCloudSync" { continue }
            if model.pollingEntryIDs.contains(job.entryID) { continue }
            attempted.insert(job.entryID)
            let entry = library?.entries.first { $0.id == job.entryID || ($0.nativeIdentity != nil && $0.nativeIdentity == job.nativeIdentity) }
            if model.resumeQueued(entryID: job.entryID, entry: entry) { return }
        }
        draining = false; forceAll = false; forcedEntryIDs = []
        notice = jobs.isEmpty ? "当前账号没有待自动继续的任务。" : "本轮队列处理结束；暂停、网络受限或未确认任务保持原状态。"
    }

    private func startScanner() {
        scanner?.cancel(); scanner = nil
        guard monitor != nil, policy.newNativeRecordings, scope != nil else { return }
        let token = generation
        scanner = Task {
            while !Task.isCancelled, token == generation {
                do { try scanNewNative() }
                catch { if token == generation { notice = "原生录音自动发现暂未完成：" + error.localizedDescription } }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func scanNewNative() throws {
        guard policy.newNativeRecordings, isCurrentOwner, let model, let library, !library.busy,
              let enabledAt = policy.enabledAtMilliseconds else { return }
        var completed = Set<String>()
        var claimed = policy.claimedNativeIdentities ?? []
        let originalClaims = claimed
        for url in try nativeFiles() {
            let identity = url.standardizedFileURL.path
            guard !policy.baseline.contains(identity), !model.records.values.contains(where: { $0.nativeIdentity == identity }) else { continue }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modificationDates[identity] == modified { continue }
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            modificationDates[identity] = modified
            guard value["origin"] as? String == "live",
                  let started = (value["recordingStartedAtMilliseconds"] as? NSNumber)?.int64Value, started >= enabledAt else { continue }
            guard claimed.contains(identity) || started >= activatedAtMilliseconds else { continue }
            let timeSource = value["recordingStartTimeSource"] as? String
            guard timeSource == "host_requested_start" || timeSource == "live_sid_milliseconds"
                || policy.includeGlassesStarts == true else { continue }
            claimed.insert(identity)
            guard value["completed"] as? Bool == true, value["finalized"] as? Bool == true else { continue }
            completed.insert(identity)
        }
        if claimed != originalClaims {
            var updated = policy; updated.claimedNativeIdentities = claimed
            do { try save(updated); policy = updated }
            catch {
                for identity in claimed.subtracting(originalClaims) { modificationDates.removeValue(forKey: identity) }
                throw error
            }
        }
        guard !completed.isEmpty else { return }
        library.refresh()
        var queued = false
        var enrolled = Set<String>()
        for entry in library.entries where entry.nativeIdentity.map({ completed.contains($0) }) == true {
            guard entry.source == "native", entry.origin == "live", entry.nativeCompleted == true, entry.finalized else { continue }
            if model.enqueueNative(entry: entry, transcribe: policy.transcribeNewRecordings, summaryModel: policy.summaryModel,
                sourceLanguage: policy.sourceLanguage, separateSpeakers: policy.separateSpeakers, region: policy.region) {
                queued = true
                if let identity = entry.nativeIdentity { enrolled.insert(identity) }
            }
        }
        for identity in completed.subtracting(enrolled) { modificationDates.removeValue(forKey: identity) }
        if queued { wake(reason: "新原生录音完成") }
    }

    private func nativeFiles() throws -> [URL] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/NativeRecordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var failure: Error?
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
        if let failure { throw failure }
        return files
    }

    private func save(_ policy: Policy) throws {
        guard let directory else { throw OfficialMemoryFailure(message: "尚无可保存的官方账号范围。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("background-policy.json")
        try JSONEncoder().encode(policy).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
