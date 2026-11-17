// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

private struct NativeAudioRange: Codable {
    var offset: Int
    var length: Int
    var end: Int { offset + length }
}

private struct NativeRecordingEntry: Codable {
    var uuid: String
    var sid: String?
    var state: String
    var mode: Int
    var rawPath: String
    var wavPath: String?
    var seconds: Double
    var finalized: Bool
    var completed: Bool
    var expectedBytes: Int?
    var ranges: [NativeAudioRange]
    var receivedBytes: Int
    var updatedAt: Date
    var error: String?
    var markers: [RecordingMarker]?
    var timelineSeconds: Double?
    var timelineUpdatedAt: Date?
    var timelineSource: String?
    var localUUID: String?
    var origin: String?
    var recordingStartedAtMilliseconds: Int64?
    var recordingStartTimeSource: String?
}

private struct NativeOfflineImportBatch {
    let generation: Int
    let uuids: Set<String>
    let importedUUIDs: Set<String>
    var pendingUUIDs: Set<String>
}

private final class NativeRecordingCapture {
    var entry: NativeRecordingEntry
    let metadataURL: URL
    private var source: FileHandle?
    private var wav: WAVRecording?
    private var decoder: OpusDecoder?
    private var decodedOffset = 0
    private var lastCheckpoint = Date.distantPast

    init(entry: NativeRecordingEntry, metadataURL: URL) {
        self.entry = entry; self.metadataURL = metadataURL
    }

    deinit { try? source?.close() }

    func elapsed(at date: Date = Date()) -> Double {
        let base = entry.timelineSeconds ?? entry.seconds
        return base + (entry.state == "recording" ? max(0, date.timeIntervalSince(entry.timelineUpdatedAt ?? date)) : 0)
    }

    func setState(_ state: String, at date: Date = Date()) {
        entry.timelineSeconds = elapsed(at: date); entry.timelineUpdatedAt = date; entry.state = state
    }

    func alignTimeline(seconds: Double, source: String, at date: Date = Date()) {
        entry.timelineSeconds = seconds; entry.timelineUpdatedAt = date; entry.timelineSource = source
    }

    func establishLiveStart(observedAt date: Date? = nil, requestedByMac: Bool = false) {
        guard entry.origin == "live", entry.recordingStartedAtMilliseconds == nil else { return }
        if let date {
            entry.recordingStartedAtMilliseconds = Int64(date.timeIntervalSince1970 * 1000)
            entry.recordingStartTimeSource = requestedByMac ? "host_requested_start" : "host_observed_start"
        } else if let sid = entry.sid, sid.utf8.count == 13,
                  sid.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let milliseconds = Int64(sid),
                  milliseconds >= 946_684_800_000,
                  milliseconds <= Int64((Date().timeIntervalSince1970 + 300) * 1000) {
            // Recover only an explicit millisecond-shaped live SID; never reinterpret older second-based IDs.
            entry.recordingStartedAtMilliseconds = milliseconds
            entry.recordingStartTimeSource = "live_sid_milliseconds"
        }
    }

    func addMarker(source: String, content: String = "", at date: Date = Date()) throws -> Int {
        let position = floor(elapsed(at: date))
        if let last = entry.markers?.last, position - last.positionSeconds < 5 { return 2 }
        let marker = RecordingMarker(positionSeconds: position, content: content, source: source,
                                     timeBasis: entry.timelineSource ?? "host_recording_clock")
        let previous = entry.markers
        entry.markers = (previous ?? []) + [marker]
        do { try save(force: true) }
        catch { entry.markers = previous; throw error }
        return 1
    }

    func save(force: Bool = false) throws {
        guard force || Date().timeIntervalSince(lastCheckpoint) >= 1 else { return }
        entry.updatedAt = Date()
        try source?.synchronize()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: metadataURL, options: .atomic)
        lastCheckpoint = Date()
    }

    private func openAudio(rebuild: Bool = false) throws {
        if source == nil { source = try FileHandle(forUpdating: URL(fileURLWithPath: entry.rawPath)) }
        if wav == nil || rebuild {
            if let old = wav, !old.finalized { try old.finish() }
            let next = try WAVRecording(sampleRate: 48_000, channels: 2)
            wav = next; decoder = try OpusDecoder(sampleRate: 48_000, channels: 2)
            decodedOffset = 0; entry.wavPath = next.url.path; entry.finalized = false
        }
    }

    func append(_ data: Data, offset: Int) throws {
        let end = offset + data.count
        let alreadyCovered = entry.ranges.contains { $0.offset <= offset && $0.end >= end }
        if entry.finalized && alreadyCovered { return }
        let restart = entry.finalized
        try openAudio(rebuild: restart)
        guard let source else { return }
        try source.seek(toOffset: UInt64(offset)); try source.write(contentsOf: data)
        entry.receivedBytes += data.count
        entry.ranges.append(NativeAudioRange(offset: offset, length: data.count))
        entry.ranges.sort { $0.offset < $1.offset }
        var merged: [NativeAudioRange] = []
        for range in entry.ranges {
            if let last = merged.last, range.offset <= last.end {
                merged[merged.count - 1].length = max(last.end, range.end) - last.offset
            } else { merged.append(range) }
        }
        entry.ranges = merged
        if let end = merged.last?.end, !entry.finalized {
            let position = Double(end / 240) * 0.02
            alignTimeline(seconds: max(elapsed(), position), source: "audio_offset_and_host_clock")
        }
        try drain()
        if entry.completed { try finishIfCovered() }
        else if !["paused", "stopping", "pausing", "resuming", "syncing"].contains(entry.state) { entry.state = "recording" }
        try save()
    }

    private func drain() throws {
        guard let first = entry.ranges.first, first.offset == 0, let source, let decoder, let wav, !wav.finalized else { return }
        while decodedOffset + 240 <= first.end {
            try source.seek(toOffset: UInt64(decodedOffset))
            guard let packet = try source.read(upToCount: 240), packet.count == 240 else { break }
            try wav.append(decoder.decode(packet)); decodedOffset += 240
        }
        entry.seconds = Double(decodedOffset / 240) * 0.02
    }

    func finishIfCovered() throws {
        guard entry.completed, entry.ranges.count == 1, let first = entry.ranges.first,
              first.offset == 0, first.end > 0, first.end % 240 == 0,
              entry.expectedBytes.map({ first.end >= $0 }) ?? true else {
            entry.state = "waitingForData"; try save(force: true); return
        }
        if !entry.finalized {
            try openAudio(); try drain(); try wav?.finish()
            entry.finalized = true
        }
        entry.state = "completed"; entry.error = nil
        try save(force: true)
    }

    func export() throws {
        if entry.finalized { return }
        try openAudio(); try drain()
        if entry.completed { try finishIfCovered() }
        try save(force: true)
    }

    var status: [String: Any] {
        var recording: [String: Any] = ["sampleRate": 48_000, "channels": 2, "seconds": entry.seconds, "finalized": entry.finalized]
        if let path = entry.wavPath { recording["path"] = path }
        return ["uuid": entry.uuid, "sid": entry.sid as Any? ?? NSNull(), "state": entry.state,
                "localUUID": entry.localUUID ?? metadataURL.deletingPathExtension().lastPathComponent,
                "origin": entry.origin ?? "unknown",
                "recordingStartedAtMilliseconds": entry.recordingStartedAtMilliseconds as Any? ?? NSNull(),
                "recordingStartTimeSource": entry.recordingStartTimeSource as Any? ?? NSNull(),
                "elapsedSeconds": elapsed(), "markers": (entry.markers ?? []).map(\.json),
                "mode": entry.mode, "recording": recording, "sourcePath": entry.rawPath,
                "receivedBytes": entry.receivedBytes, "decodedBytes": Int(entry.seconds * 48_000 / 960) * 240,
                "coveredRanges": entry.ranges.map { ["offset": $0.offset, "length": $0.length] },
                "expectedBytes": entry.expectedBytes as Any? ?? NSNull(), "error": entry.error as Any? ?? NSNull()]
    }
}

/// Native recording keeps independent byte ranges and decoder state for every UUID.
final class NativeRecordingController {
    private let transport: RFCOMMTransport
    private let operationLock: NSRecursiveLock
    private let sendLock = NSLock()
    private let queue = DispatchQueue(label: "openrayneo.native-recording")
    private let directory: URL
    private var sequence: UInt16 = 0x8000
    private var captures: [String: NativeRecordingCapture] = [:]
    private var selectedUUID: String?
    private var activeUUID: String?
    private var offlineItems: [[String: Any]] = []
    private var lastMessage: [String: Any] = [:]
    private var controlEvents: [[String: Any]] = []
    private var error: String?
    private var requestedMode = 1
    private var lastMarkResult: [String: Any] = [:]
    private var offlineImportBatch: NativeOfflineImportBatch?

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, deviceID: String? = nil) {
        self.transport = transport; operationLock = lock
        let device = (deviceID ?? ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? "default")
            .filter { $0.isLetter || $0.isNumber }.lowercased()
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/NativeRecordings/\(device)", isDirectory: true)
        queue.async { [weak self] in self?.restore() }
        transport.setNativeRecordingHandler { [weak self] message in
            self?.queue.async { [weak self] in self?.receive(message) }
        }
    }

    var isRecording: Bool { queue.sync { activeUUID != nil } }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/native-recording" || path.hasPrefix("/v1/native-recording/") else { return nil }
        if method == "GET", path == "/v1/native-recording" { return (200, queue.sync { status() }) }
        guard method == "POST" else { return nil }
        if path == "/v1/native-recording/select" || path == "/v1/native-recording/export" {
            return try queue.sync {
                guard let id = body["uuid"] as? String, let capture = captures[id] else { throw BridgeError(status: 404, message: "Recording not found") }
                selectedUUID = id
                if path.hasSuffix("export") { try capture.export() }
                return (200, status())
            }
        }
        operationLock.lock(); defer { operationLock.unlock() }
        try transport.ensureConnected()
        queue.sync { reconcileImportConnection() }
        switch path {
        case "/v1/native-recording/foreground":
            try reportForeground(body["isAppForeground"] as? Bool ?? true)
        case "/v1/native-recording/query-status":
            try queryCurrentStatus()
        case "/v1/native-recording/start":
            let newUUID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let newSID = String(Int(Date().timeIntervalSince1970))
            let mode = body["mode"] as? Int ?? 1
            guard mode == 1 || mode == 2 else { throw BridgeError(status: 400, message: "mode must be 1 (wide spectrum) or 2 (voice isolation)") }
            try queue.sync {
                guard activeUUID == nil, offlineImportBatch?.pendingUUIDs.isEmpty != false else { throw BridgeError(status: 409, message: "Native recording or offline import already active") }
                let capture = try capture(uuid: newUUID, sid: newSID, mode: mode)
                capture.entry.origin = "live"
                capture.establishLiveStart(observedAt: Date(), requestedByMac: true)
                capture.entry.state = "starting"; try capture.save(force: true)
                activeUUID = newUUID; selectedUUID = newUUID; requestedMode = mode
            }
            do { try send(type: 1, body: ["uuid": newUUID, "sid": newSID, "type": 1, "mode": mode, "action": 1]) }
            catch { queue.sync { self.error = error.localizedDescription; captures[newUUID]?.entry.state = "failed"; activeUUID = nil }; throw error }
        case "/v1/native-recording/stop":
            guard let id = queue.sync(execute: { activeUUID }) else { throw BridgeError(status: 409, message: "No active native recording") }
            queue.sync { captures[id]?.setState("stopping") }
            try send(type: 4, body: ["uuid": id, "code": 2, "action": 1])
        case "/v1/native-recording/pause", "/v1/native-recording/resume":
            guard let id = queue.sync(execute: { activeUUID }) else { throw BridgeError(status: 409, message: "No active native recording") }
            let paused = path.hasSuffix("pause")
            var command: [String: Any] = ["uuid": id, "action": 1]
            if paused { command["code"] = 1 }
            queue.sync { captures[id]?.setState(paused ? "pausing" : "resuming") }
            try send(type: paused ? 8 : 9, body: command)
        case "/v1/native-recording/mark":
            let result = try queue.sync { () throws -> (String, Int) in
                guard let id = activeUUID, let capture = captures[id], ["recording", "paused"].contains(capture.entry.state) else {
                    throw BridgeError(status: 409, message: "当前没有可标记的原生录音")
                }
                let code = try capture.addMarker(source: "mac", content: body["content"] as? String ?? "")
                lastMarkResult = ["code": code, "uuid": id, "source": "mac"]
                return (id, code)
            }
            try send(type: 11, body: ["uuid": result.0, "code": result.1, "action": 2])
        case "/v1/native-recording/mode":
            guard let mode = body["mode"] as? Int, mode == 1 || mode == 2 else { throw BridgeError(status: 400, message: "mode must be 1 or 2") }
            guard let id = queue.sync(execute: { activeUUID }) else { throw BridgeError(status: 409, message: "No active native recording") }
            try send(type: 10, body: ["uuid": id, "mode": mode, "action": 1])
        case "/v1/native-recording/list": try send(type: 12, body: ["action": 1])
        case "/v1/native-recording/import-unmatched":
            try importUnmatchedRecordings()
        case "/v1/native-recording/sync":
            try queue.sync {
                guard offlineImportBatch?.pendingUUIDs.isEmpty != false else { throw BridgeError(status: 409, message: "请等待当前整批离线导入完成。") }
            }
            let ids = body["uuids"] as? [String] ?? []
            let snapshot = try queryOfflineItems()
            let items = snapshot.filter { ids.contains($0["uuid"] as? String ?? "") }
            guard !items.isEmpty else { throw BridgeError(status: 400, message: "Select offline recordings to synchronize") }
            try queue.sync {
                for item in items {
                    guard let id = item["uuid"] as? String else { continue }
                    let current = try capture(uuid: id, sid: nil, mode: requestedMode)
                    if current.entry.origin == nil { current.entry.origin = "offline_sync" }
                    current.entry.expectedBytes = item["offlineSize"] as? Int
                    current.entry.state = "syncing"; try current.save(force: true)
                    selectedUUID = id
                }
            }
            try send(type: 12, body: ["action": 2, "items": items, "total_items": items.count, "deleteOther": false])
        case "/v1/native-recording/delete-offline":
            let ids = body["uuids"] as? [String] ?? []
            let snapshot = try queryOfflineItems()
            let keep = try queue.sync { () throws -> [[String: Any]] in
                let available = Set(snapshot.compactMap { $0["uuid"] as? String })
                guard !ids.isEmpty, Set(ids).isSubset(of: available) else { throw BridgeError(status: 400, message: "Select existing offline recordings to delete") }
                guard activeUUID == nil, !hasUnfinishedLiveTail, offlineImportBatch?.pendingUUIDs.isEmpty != false, !captures.values.contains(where: {
                    ids.contains($0.entry.uuid) && ["recording", "starting", "stopping", "pausing", "resuming", "syncing"].contains($0.entry.state)
                }) else {
                    throw BridgeError(status: 409, message: "Wait for active recording and audio synchronization to finish before deleting")
                }
                return snapshot.filter { !ids.contains($0["uuid"] as? String ?? "") }
            }
            var reply: [String: Any] = ["action": 2, "total_items": keep.count, "deleteOther": true]
            if !keep.isEmpty { reply["items"] = keep }
            try send(type: 12, body: reply)
            try send(type: 12, body: ["action": 1])
        default: return nil
        }
        return (202, queue.sync { status() })
    }

    func reportForeground(_ foreground: Bool) throws {
        try send(type: 14, body: ["isAppForeground": foreground])
    }

    func queryCurrentStatus() throws {
        _ = try readCurrentStatus()
    }

    private func readCurrentStatus() throws -> [String: Any] {
        let id = queue.sync { activeUUID ?? selectedUUID ?? "" }
        let started = Date()
        try send(type: 5, body: ["uuid": id, "action": 1])
        guard let reply = transport.waitForMessage(timeout: 5, matching: {
            $0.protocolID == 0x0e && $0.messageType == 5 && $0.receivedAt >= started && $0.json?["state"] is Int
        })?.json else { throw BridgeError(status: 504, message: "Glasses did not report the recording state") }
        queue.sync {}
        return reply
    }

    private func queryOfflineItems() throws -> [[String: Any]] {
        let started = Date()
        try send(type: 12, body: ["action": 1])
        guard let response = transport.waitForMessage(timeout: 5, matching: {
            $0.protocolID == 0x0e && $0.messageType == 12 && $0.receivedAt >= started && $0.json?["items"] is [[String: Any]]
        })?.json, let items = response["items"] as? [[String: Any]] else {
            throw BridgeError(status: 504, message: "Glasses did not return the offline recording list")
        }
        queue.sync { offlineItems = items }
        return items
    }

    private var hasUnfinishedLiveTail: Bool {
        captures.values.contains {
            !$0.entry.completed && $0.entry.origin != "offline_import" && $0.entry.origin != "offline_sync" &&
                ["recording", "paused", "starting", "pausing", "resuming", "stopping", "waitingForData"].contains($0.entry.state)
        }
    }

    private func importUnmatchedRecordings() throws {
        let generation = transport.currentConnectionGeneration
        guard try readCurrentStatus()["state"] as? Int == 3 else {
            throw BridgeError(status: 409, message: "请先停止眼镜录音，再导入离线记录。")
        }
        let snapshot = try queryOfflineItems()
        let total = try queue.sync { () throws -> Int in
            guard activeUUID == nil, !hasUnfinishedLiveTail,
                  offlineImportBatch?.pendingUUIDs.isEmpty != false,
                  !captures.values.contains(where: { $0.entry.state == "syncing" }) else {
                throw BridgeError(status: 409, message: "请等待实时尾包或当前离线传输完成；缺失范围可先用所选同步补齐。")
            }
            let unmatched = Set(snapshot.compactMap { item -> String? in
                guard let id = item["uuid"] as? String, !id.isEmpty else { return nil }
                if let entry = captures[id]?.entry {
                    return entry.origin == "offline_import" && !entry.finalized ? id : nil
                }
                return id
            })
            guard !unmatched.isEmpty else { throw BridgeError(status: 409, message: "新鲜离线列表中没有本机未匹配的录音。") }
            let candidates = snapshot.filter { item in
                guard let id = item["uuid"] as? String, !id.isEmpty else { return false }
                return captures[id]?.entry.finalized != true || captures[id]?.entry.completed != true
            }
            for item in candidates {
                guard let size = item["offlineSize"] as? Int, size > 0 else {
                    throw BridgeError(status: 409, message: "眼镜未返回可核对的离线录音字节数，暂不发起整批导入。")
                }
                if let id = item["uuid"] as? String, let target = captures[id],
                   !FileManager.default.fileExists(atPath: target.entry.rawPath) {
                    throw BridgeError(status: 409, message: "本地录音 \(id) 的原始文件缺失，请先恢复该文件。")
                }
            }
            var ids: Set<String> = []
            do {
                for item in candidates {
                    guard let id = item["uuid"] as? String else { continue }
                    let target = try capture(uuid: id, sid: nil, mode: requestedMode,
                                             origin: unmatched.contains(id) ? "offline_import" : nil)
                    if unmatched.contains(id) { target.entry.origin = "offline_import" }
                    target.entry.expectedBytes = item["offlineSize"] as? Int
                    target.entry.state = "syncing"
                    ids.insert(id)
                    try target.save(force: true)
                }
            } catch {
                for id in ids {
                    captures[id]?.entry.state = "interrupted"
                    try? captures[id]?.save(force: true)
                }
                throw error
            }
            offlineImportBatch = NativeOfflineImportBatch(generation: generation, uuids: ids,
                                                          importedUUIDs: unmatched, pendingUUIDs: ids)
            selectedUUID = unmatched.sorted().first
            error = nil
            return ids.count
        }
        do {
            try queue.sync {
                guard transport.isConnected, transport.currentConnectionGeneration == generation,
                      activeUUID == nil, !hasUnfinishedLiveTail else {
                    throw BridgeError(status: 409, message: "导入准备期间连接或实时录音状态已变化，请重新查询。")
                }
                // The official import response deliberately omits items; it cannot select a UUID subset.
                try send(type: 12, body: ["action": 2, "total_items": total, "deleteOther": false])
            }
        } catch {
            queue.sync { interruptOfflineImport(); self.error = error.localizedDescription }
            throw error
        }
    }

    private func interruptOfflineImport() {
        guard let batch = offlineImportBatch, !batch.pendingUUIDs.isEmpty else { return }
        for id in batch.pendingUUIDs where captures[id]?.entry.state == "syncing" {
            captures[id]?.entry.state = "interrupted"
            try? captures[id]?.save(force: true)
        }
        offlineImportBatch = nil
    }

    private func reconcileImportConnection() {
        guard let batch = offlineImportBatch, !batch.pendingUUIDs.isEmpty,
              !transport.isConnected || batch.generation != transport.currentConnectionGeneration else { return }
        interruptOfflineImport()
        error = "离线导入连接已中断，本地已收音频保留；重新连接后可查询并同步未完成记录。"
    }

    private func updateOfflineImport(_ capture: NativeRecordingCapture) {
        if capture.entry.completed && capture.entry.finalized {
            offlineImportBatch?.pendingUUIDs.remove(capture.entry.uuid)
        }
    }

    private func send(type: UInt64, body: [String: Any]) throws {
        sendLock.lock(); defer { sendLock.unlock() }
        sequence &+= 1
        try transport.send(ProtocolCodec.transportFrame(protocolID: 0x0e, sequence: sequence, type: type,
            message: ProtocolCodec.jsonData(body)))
    }

    private func capture(uuid: String, sid: String?, mode: Int, origin: String? = nil) throws -> NativeRecordingCapture {
        if let existing = captures[uuid] { if let sid { existing.entry.sid = sid }; return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let raw = directory.appendingPathComponent(stem + ".opus-packets")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError(status: 503, message: "Could not create native audio file") }
        let entry = NativeRecordingEntry(uuid: uuid, sid: sid, state: "idle", mode: mode, rawPath: raw.path,
            wavPath: nil, seconds: 0, finalized: false, completed: false, expectedBytes: nil, ranges: [], receivedBytes: 0, updatedAt: Date(), error: nil, localUUID: stem, origin: origin)
        let result = NativeRecordingCapture(entry: entry, metadataURL: directory.appendingPathComponent(stem + ".json"))
        try result.save(force: true); captures[uuid] = result
        return result
    }

    private func restore() {
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
                var entry = try decoder.decode(NativeRecordingEntry.self, from: Data(contentsOf: url))
                if !entry.finalized { entry.state = "interrupted" }
                let capture = NativeRecordingCapture(entry: entry, metadataURL: url)
                capture.establishLiveStart()
                if capture.entry.recordingStartedAtMilliseconds != entry.recordingStartedAtMilliseconds {
                    try capture.save(force: true)
                }
                captures[entry.uuid] = capture
            }
            selectedUUID = captures.values.max { $0.entry.updatedAt < $1.entry.updatedAt }?.entry.uuid
        } catch { self.error = "Could not restore native recording: \(error.localizedDescription)" }
    }

    private func receive(_ message: RemoteMessage) {
        reconcileImportConnection()
        let type = message.messageType ?? 0
        lastMessage = ["type": type, "body": message.json as Any? ?? NSNull()]
        if type != 3 {
            var event = lastMessage
            event["receivedAt"] = message.receivedAt.timeIntervalSince1970
            if message.json == nil { event["protobuf"] = message.protobuf.base64EncodedString() }
            controlEvents.append(event)
            if controlEvents.count > 32 { controlEvents.removeFirst() }
        }
        guard let json = message.json else { return }
        do {
            if type == 12, let items = json["items"] as? [[String: Any]] { offlineItems = items }
            let id = json["uuid"] as? String ?? activeUUID
            if type == 3, let id, let data = message.audioData, let offset = json["offset"] as? Int, offset >= 0 {
                let target = try capture(uuid: id, sid: json["sid"] as? String, mode: json["mode"] as? Int ?? requestedMode)
                if !target.entry.finalized, activeUUID != id && (offlineImportBatch?.uuids.contains(id) == true || target.entry.origin == "offline_import") {
                    target.entry.state = "syncing"
                }
                try target.append(data, offset: offset)
                updateOfflineImport(target)
                if selectedUUID == nil { selectedUUID = id }
                return
            }
            if type == 6, let id {
                let target = try capture(uuid: id, sid: json["sid"] as? String, mode: requestedMode)
                if json["completed"] as? Bool == true {
                    target.entry.completed = true; try target.finishIfCovered()
                    updateOfflineImport(target)
                    if activeUUID == id { activeUUID = nil }
                }
            }
            if type == 11, json["action"] as? Int == 1 {
                let supplied = (json["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let markID = supplied ?? activeUUID
                var code = 3
                if let markID, markID == activeUUID, let target = captures[markID],
                   ["recording", "paused"].contains(target.entry.state) {
                    do { code = try target.addMarker(source: "glasses", at: message.receivedAt) }
                    catch { self.error = "标记保存失败：\(error.localizedDescription)" }
                }
                try send(type: 11, body: ["uuid": markID ?? "", "code": code, "action": 2])
                lastMarkResult = ["code": code, "uuid": markID ?? "", "source": "glasses"]
            }
            if type == 5, json["action"] as? Int == 1 {
                try send(type: 5, body: ["uuid": json["uuid"] as? String ?? activeUUID ?? selectedUUID ?? "", "action": 2, "state": 3])
            }
            if type == 5, let state = json["state"] as? Int {
                let reportedID = (json["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let currentID = reportedID ?? activeUUID ?? selectedUUID
                if let currentID {
                    let target = try capture(uuid: currentID, sid: json["sid"] as? String, mode: json["mode"] as? Int ?? requestedMode)
                    switch state {
                    case 1, 2:
                        target.setState(state == 1 ? "recording" : "paused", at: message.receivedAt)
                        if let time = json["time"] as? Double, time >= 0 {
                            target.alignTimeline(seconds: time, source: "glasses_status_time", at: message.receivedAt)
                        }
                        activeUUID = currentID; selectedUUID = currentID
                        if let mode = json["mode"] as? Int { target.entry.mode = mode; requestedMode = mode }
                    case 3:
                        if json["action"] as? Int == 2 {
                            let needsClosing = !target.entry.completed && ["recording", "paused", "pausing", "resuming", "stopping", "starting", "interrupted"].contains(target.entry.state)
                            if activeUUID == currentID { activeUUID = nil }
                            if !target.entry.completed { target.entry.state = "waitingForData" }
                            if needsClosing { try send(type: 4, body: ["code": 1, "action": 2]) }
                        }
                    default: break
                    }
                    try target.save(force: true)
                }
            }
            if [1, 4, 8, 9, 10].contains(type), let id {
                let isNewCapture = captures[id] == nil
                let target = try capture(uuid: id, sid: json["sid"] as? String, mode: requestedMode)
                let action = json["action"] as? Int ?? 0
                let code = json["code"] as? Int
                if type == 1, action == 1 {
                    if code == nil || code == 1 {
                        target.entry.origin = "live"
                        target.establishLiveStart(observedAt: isNewCapture ? message.receivedAt : nil)
                        target.setState("recording", at: message.receivedAt); activeUUID = id; selectedUUID = id
                        var response: [String: Any] = ["uuid": id, "type": 1, "mode": json["mode"] as? Int ?? requestedMode, "code": 1, "action": 2]
                        if let sid = json["sid"] as? String { response["sid"] = sid }
                        try send(type: 1, body: response)
                    }
                }
                if type == 1, action == 2 {
                    if code == nil || code == 1 {
                        if isNewCapture { target.entry.origin = "live" }
                        target.establishLiveStart(observedAt: isNewCapture ? message.receivedAt : nil)
                        target.setState("recording", at: message.receivedAt); activeUUID = id
                    }
                    else { target.entry.state = "failed"; target.entry.error = "Glasses rejected recording start (code \(code!))"; if activeUUID == id { activeUUID = nil } }
                }
                if type == 4 {
                    target.setState("stopping", at: message.receivedAt)
                    if action == 1 { try send(type: 4, body: ["code": code ?? 1, "action": 2]) }
                }
                if type == 8 {
                    if action == 1 { try send(type: 8, body: ["uuid": id, "code": code ?? 1, "action": 2]) }
                    if code == nil || code == 1 { target.setState("paused", at: message.receivedAt) }
                    else { target.entry.error = "Pause was not accepted (code \(code!))" }
                }
                if type == 9 {
                    if action == 1 { try send(type: 9, body: ["uuid": id, "action": 2]) }
                    target.setState("recording", at: message.receivedAt)
                }
                if type == 10, let mode = json["mode"] as? Int {
                    if action == 1 { try send(type: 10, body: ["uuid": id, "mode": mode, "action": 2]) }
                    target.entry.mode = mode; requestedMode = mode
                }
                try target.save(force: true)
            }
        } catch {
            self.error = error.localizedDescription
            if let id = json["uuid"] as? String, let target = captures[id] { target.entry.error = error.localizedDescription; try? target.save(force: true) }
        }
    }

    private func status() -> [String: Any] {
        reconcileImportConnection()
        var result = selectedUUID.flatMap { captures[$0]?.status } ?? ["state": "idle"]
        result["activeUUID"] = activeUUID as Any? ?? NSNull()
        result["activeState"] = activeUUID.flatMap { captures[$0]?.entry.state } as Any? ?? NSNull()
        result["offlineItems"] = offlineItems
        if let batch = offlineImportBatch {
            result["offlineImport"] = ["total": batch.uuids.count, "unmatched": batch.importedUUIDs.count,
                                       "known": batch.uuids.count - batch.importedUUIDs.count,
                                       "pending": batch.pendingUUIDs.count,
                                       "state": batch.pendingUUIDs.isEmpty ? "completed" : "syncing"]
        }
        result["recordings"] = captures.values.sorted { $0.entry.updatedAt > $1.entry.updatedAt }.map(\.status)
        result["error"] = error as Any? ?? (selectedUUID.flatMap { captures[$0]?.entry.error } as Any? ?? NSNull())
        result["lastMessage"] = lastMessage
        result["controlEvents"] = controlEvents
        result["markResult"] = lastMarkResult
        return result
    }
}
