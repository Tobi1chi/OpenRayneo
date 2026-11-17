// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Phone-authoritative replica and durable Agent outbox. Never binds a device-control socket to LAN.
final class RecordSyncController {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["OPENRAYNEO_SUPPORT_DIRECTORY"] { return URL(fileURLWithPath: path).appendingPathComponent("MemoryLibrary/PhoneReplica") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/MemoryLibrary/PhoneReplica")
    }
    private let queue = DispatchQueue(label: "openrayneo.record-sync")
    private let folder: URL
    private var state: [String: Any] = ["cursor": 0, "records": [:], "people": [:], "derived": [:], "pending": [:], "audioPaths": [:], "enabled": false]
    private var failure: String?
    private var writable = true
    private var lastSyncedAt: Double?
    private var timer: DispatchSourceTimer?

    init(folder: URL = RecordSyncController.directory) {
        self.folder = folder
        let file = folder.appendingPathComponent("replica.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                    throw BridgeError(status: 500, message: "同步副本格式错误")
                }
                state = saved
            }
            catch { failure = "同步副本读取失败：\(error.localizedDescription)"; writable = false }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 15)
        timer.setEventHandler { [weak self] in self?.attemptSync() }
        timer.resume(); self.timer = timer
    }

    private var records: [String: [String: Any]] { state["records"] as? [String: [String: Any]] ?? [:] }
    private var pending: [String: [String: Any]] { state["pending"] as? [String: [String: Any]] ?? [:] }
    private func persist(_ value: [String: Any]) throws {
        guard writable else { throw BridgeError(status: 500, message: failure ?? "副本不可写") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("replica.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = value
    }
    private func status() -> [String: Any] {
        ["enabled": state["enabled"] as? Bool ?? false, "peerURL": state["peerURL"] as? String ?? "",
         "configured": !(state["token"] as? String ?? "").isEmpty, "cursor": state["cursor"] as? Int ?? 0,
         "recordCount": records.count, "pendingCount": pending.count, "lastSyncedAt": lastSyncedAt as Any? ?? NSNull(),
         "error": failure as Any? ?? NSNull(), "replicaPath": folder.path, "audioPolicy": "on-demand",
         "authority": "phone", "deviceControlBinding": "127.0.0.1"]
    }
    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/records" || path.hasPrefix("/v1/records/") else { return nil }
        return try queue.sync {
            switch (method, path) {
            case ("GET", "/v1/records/sync"): return (200, status())
            case ("PATCH", "/v1/records/sync"):
                var next = state
                if let peer = body["peerURL"] as? String {
                    guard let url = URL(string: peer), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
                          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                        throw BridgeError(status: 400, message: "peerURL 必须是手机 sync 服务的 HTTP 地址")
                    }
                    if peer != state["peerURL"] as? String {
                        guard records.isEmpty || body["resetCursor"] as? Bool == true else {
                            throw BridgeError(status: 409, message: "更换手机地址请显式传 resetCursor:true；已有副本保留")
                        }
                        next["cursor"] = 0
                    }
                    next["peerURL"] = peer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if let token = body["token"] as? String { next["token"] = token }
                if let enabled = body["enabled"] as? Bool { next["enabled"] = enabled }
                if body["resetCursor"] as? Bool == true { next["cursor"] = 0 }
                try persist(next); failure = nil
                queue.async { [weak self] in self?.attemptSync() }
                return (200, status())
            case ("POST", "/v1/records/sync"):
                queue.async { [weak self] in self?.attemptSync() }
                return (202, status())
            case ("GET", "/v1/records"), ("POST", "/v1/records/query"):
                let rows = records.values.filter { row in
                    if let id = body["recordId"] as? String, row["id"] as? String != id { return false }
                    let start = row["createdAt"] as? Double ?? 0
                    let end = row["endedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000
                    if let from = body["from"] as? Double, end <= from { return false }
                    if let to = body["to"] as? Double, start >= to { return false }
                    if let text = body["text"] as? String, !text.isEmpty {
                        let data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data()
                        return String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains(text)
                    }
                    return true
                }.sorted { ($0["createdAt"] as? Double ?? 0) > ($1["createdAt"] as? Double ?? 0) }
                return (200, ["records": rows, "sync": status()])
            case ("GET", "/v1/records/people"):
                return (200, ["people": Array((state["people"] as? [String: [String: Any]] ?? [:]).values)])
            case ("POST", "/v1/records/derived"):
                guard let recordID = body["recordId"] as? String, let record = records[recordID],
                      let sourceRevision = body["sourceRevision"] as? Int,
                      let kind = body["kind"] as? String, ["analysis", "note", "tags"].contains(kind) else {
                    throw BridgeError(status: 400, message: "提供已有 recordId、sourceRevision 和 kind(analysis/note/tags)")
                }
                let id = body["id"] as? String ?? UUID().uuidString
                guard UUID(uuidString: id) != nil else { throw BridgeError(status: 400, message: "派生项 id 必须为 UUID") }
                var next = state
                var all = state["derived"] as? [String: [String: Any]] ?? [:]
                let syncedItems = (record["derived"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == id }
                let previous = (syncedItems + [all[id]].compactMap { $0 }).max { ($0["revision"] as? Int ?? 0) < ($1["revision"] as? Int ?? 0) }
                if let previous, previous["recordId"] as? String != recordID {
                    throw BridgeError(status: 409, message: "派生项 id 已关联其他记录")
                }
                let revision = body["revision"] as? Int ?? ((previous?["revision"] as? Int ?? 0) + 1)
                if let previous, revision <= (previous["revision"] as? Int ?? 0) { return (200, ["derived": previous, "queued": pending[id] != nil]) }
                let item: [String: Any] = ["id": id, "recordId": recordID, "revision": revision, "sourceRevision": sourceRevision,
                    "kind": kind, "text": body["text"] as? String ?? "", "tags": body["tags"] as? [String] ?? [],
                    "agent": body["agent"] as? String ?? "mac-local-agent", "updatedAt": Date().timeIntervalSince1970 * 1000,
                    "stale": sourceRevision != (record["revision"] as? Int ?? 0)]
                all[id] = item; next["derived"] = all
                var outbox = pending; outbox[id] = item; next["pending"] = outbox
                var source = record; var items = record["derived"] as? [[String: Any]] ?? []
                items.removeAll { $0["id"] as? String == id }; items.append(item); source["derived"] = items
                var updatedRecords = records; updatedRecords[recordID] = source; next["records"] = updatedRecords
                try persist(next)
                queue.async { [weak self] in self?.attemptSync() }
                return (202, ["derived": item, "queued": true])
            case ("POST", "/v1/records/audio"):
                guard let id = body["recordId"] as? String, UUID(uuidString: id) != nil, records[id] != nil else {
                    throw BridgeError(status: 404, message: "副本中不存在该记录")
                }
                var paths = state["audioPaths"] as? [String: String] ?? [:]
                if let path = paths[id], FileManager.default.fileExists(atPath: path) { return (200, ["recordId": id, "audioPath": path, "cached": true]) }
                let bytes = try fetch(path: "/v1/sync/audio?recordId=\(id)", body: nil)
                let audioFolder = folder.appendingPathComponent("Audio")
                try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = audioFolder.appendingPathComponent("\(id).wav")
                try bytes.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                paths[id] = file.path; var next = state; next["audioPaths"] = paths; try persist(next)
                return (200, ["recordId": id, "audioPath": file.path, "cached": false])
            default: return nil
            }
        }
    }

    private func fetch(path: String, body: [String: Any]?) throws -> Data {
        guard let peer = state["peerURL"] as? String, let url = URL(string: peer + path),
              let token = state["token"] as? String, !token.isEmpty else { throw BridgeError(status: 409, message: "请先配置手机同步地址和独立凭据") }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let completed = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { completed.signal() }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else { result = .failure(BridgeError(status: status == 404 ? 404 : 502, message: "手机同步服务返回 HTTP \(status)")); return }
            result = .success(data)
        }
        task.resume(); completed.wait()
        return try result.get()
    }
    private func attemptSync() {
        guard writable, state["enabled"] as? Bool == true else { return }
        do {
            var more = true
            // Yield between large histories so Agent queries and disabling sync remain responsive.
            var batches = 0
            while more, batches < 10 {
                let cursor = state["cursor"] as? Int ?? 0
                let previousPendingCount = pending.count
                let sent = Dictionary(uniqueKeysWithValues: pending.sorted { $0.key < $1.key }.prefix(100).map { ($0.key, $0.value) })
                let bytes = try fetch(path: "/v1/sync/exchange", body: ["protocolVersion": 1, "cursor": cursor, "limit": 100, "derived": Array(sent.values)])
                guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      response["protocolVersion"] as? Int == 1, let newCursor = response["cursor"] as? Int, newCursor >= cursor,
                      let incoming = response["records"] as? [[String: Any]], let people = response["people"] as? [[String: Any]] else {
                    throw BridgeError(status: 502, message: "手机同步响应格式错误")
                }
                var next = state, updatedRecords = records
                var allDerived = state["derived"] as? [String: [String: Any]] ?? [:]
                var outbox = pending
                for row in incoming {
                    guard let id = row["id"] as? String else { throw BridgeError(status: 502, message: "记录缺少 id") }
                    if let old = updatedRecords[id], (old["revision"] as? Int ?? 0) > (row["revision"] as? Int ?? 0) { continue }
                    var merged = row
                    var derived = row["derived"] as? [[String: Any]] ?? []
                    for (itemID, var item) in allDerived where item["recordId"] as? String == id {
                        item["stale"] = (item["sourceRevision"] as? Int ?? 0) != (row["revision"] as? Int ?? 0)
                        allDerived[itemID] = item
                        if outbox[itemID] != nil { outbox[itemID] = item }
                        if let position = derived.firstIndex(where: { $0["id"] as? String == itemID }) {
                            if (derived[position]["revision"] as? Int ?? 0) <= (item["revision"] as? Int ?? 0) { derived[position] = item }
                        } else { derived.append(item) }
                    }
                    merged["derived"] = derived; updatedRecords[id] = merged
                }
                var updatedPeople = state["people"] as? [String: [String: Any]] ?? [:]
                for person in people { guard let id = person["id"] as? String else { throw BridgeError(status: 502, message: "人物缺少 id") }; updatedPeople[id] = person }
                for id in response["acceptedDerivedIds"] as? [String] ?? [] where sent[id] != nil { outbox[id] = nil }
                next["records"] = updatedRecords; next["people"] = updatedPeople; next["derived"] = allDerived; next["pending"] = outbox; next["cursor"] = newCursor
                try persist(next); lastSyncedAt = Date().timeIntervalSince1970 * 1000; failure = nil
                let hasMore = response["hasMore"] as? Bool ?? false
                if hasMore, newCursor == cursor { throw BridgeError(status: 502, message: "手机分页游标未推进") }
                more = hasMore || (!outbox.isEmpty && outbox.count < previousPendingCount)
                batches += 1
            }
            if more { queue.async { [weak self] in self?.attemptSync() } }
        } catch { failure = error.localizedDescription }
    }
}
