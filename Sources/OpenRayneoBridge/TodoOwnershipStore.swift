// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// IDs and observed state are scoped to the paired glasses.
final class TodoOwnershipStore {
    struct Owned: Codable { let createdMilliseconds: Int64 }
    struct Mutation: Codable {
        let action: String
        let arguments: String
        let eventID: Int64
        var result: String?
        var wasVisibleBeforeMutation: Bool?
        var item: Data?
        var preparedAt: Date?
        var sentAt: Date?
    }
    private struct Device: Codable {
        var owned: [String: Owned] = [:]
        var mutations: [String: Mutation] = [:]
        // Optional so pre-sync ownership files continue to decode unchanged.
        var todos: [String: StoredTodo]?
    }
    private struct StoredTodo: Codable {
        var json: Data
        var observedAt: Date
        var fromGlasses: Bool
        var syncState: String?
        var provenance: String?
        var requestID: String?
        var pendingAction: String?
    }
    private let lock = NSRecursiveLock()
    private let url: URL
    private let deviceID: String
    private var devices: [String: Device]
    private var loadError: String?

    init(deviceID: String = ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? "", url: URL? = nil) {
        self.deviceID = deviceID.uppercased().replacingOccurrences(of: ":", with: "-")
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/HomeContent/todo-ownership.json")
        devices = [:]
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { devices = try JSONDecoder().decode([String: Device].self, from: Data(contentsOf: self.url)) }
            catch { loadError = "Todo ownership records could not be read; writes are disabled" }
        }
        recoverMissingOwnedItems()
    }

    func owns(_ item: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !deviceID.isEmpty, let id = (item["eventID"] as? NSNumber)?.int64Value,
              let created = (item["createTime"] as? NSNumber)?.int64Value else { return false }
        return devices[deviceID]?.owned[String(id)]?.createdMilliseconds == created
    }

    func claim(id: Int64, createdMilliseconds: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try requireDevice()
        devices[deviceID, default: Device()].owned[String(id)] = Owned(createdMilliseconds: createdMilliseconds)
        try save()
    }

    func release(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        devices[deviceID]?.owned[String(id)] = nil
        devices[deviceID]?.todos?[String(id)] = nil
        try save()
    }

    func mutation(_ requestID: String) -> Mutation? {
        lock.lock(); defer { lock.unlock() }
        return devices[deviceID]?.mutations[requestID]
    }

    func begin(_ requestID: String, action: String, arguments: String, id: Int64,
               wasVisibleBeforeMutation: Bool? = nil, item: [String: Any]? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try requireDevice()
        let data = try item.map { try JSONSerialization.data(withJSONObject: $0) }
        let now = Date()
        devices[deviceID, default: Device()].mutations[requestID] = Mutation(action: action,
            arguments: arguments, eventID: id, wasVisibleBeforeMutation: wasVisibleBeforeMutation,
            item: data, preparedAt: now)
        if let data {
            var todos = devices[deviceID]?.todos ?? [:]
            todos[String(id)] = StoredTodo(json: data, observedAt: now, fromGlasses: false,
                syncState: "outcome_unknown", provenance: "local_intent", requestID: requestID, pendingAction: action)
            devices[deviceID]?.todos = todos
        }
        try save()
    }

    func markSent(_ requestID: String) throws {
        lock.lock(); defer { lock.unlock() }
        devices[deviceID]?.mutations[requestID]?.sentAt = Date()
        try save()
    }

    func complete(_ requestID: String, result: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        devices[deviceID]?.mutations[requestID]?.result = String(decoding: data, as: UTF8.self)
        if let mutation = devices[deviceID]?.mutations[requestID],
           var cached = devices[deviceID]?.todos?[String(mutation.eventID)], cached.requestID == requestID {
            if result["readBack"] as? Bool == true {
                cached.syncState = "confirmed_by_readback"
                cached.provenance = "query_readback"
                cached.pendingAction = nil
            }
            devices[deviceID]?.todos?[String(mutation.eventID)] = cached
        }
        try save()
    }

    /// Called only after a complete device query. Local history never becomes a wire snapshot.
    func recordSnapshot(_ items: [[String: Any]], startedAt: Date) throws {
        lock.lock(); defer { lock.unlock() }
        try requireDevice()
        let previous = devices[deviceID]?.todos ?? [:]
        var next: [String: StoredTodo] = [:]
        for item in items {
            guard let id = (item["eventID"] as? NSNumber)?.stringValue else { continue }
            if let cached = previous[id], cached.syncState == "outcome_unknown", let wanted = desiredItem(cached),
               (wanted["createTime"] as? NSNumber) == (item["createTime"] as? NSNumber) {
                if cached.pendingAction != "delete", matchesDesired(item, wanted: wanted) {
                    next[id] = StoredTodo(json: try JSONSerialization.data(withJSONObject: item),
                        observedAt: startedAt, fromGlasses: false, syncState: "confirmed_by_readback",
                        provenance: "query_readback", requestID: cached.requestID)
                } else { next[id] = cached }
            } else if let cached = previous[id], cached.fromGlasses, let old = decode(cached),
               (old["createTime"] as? NSNumber) == (item["createTime"] as? NSNumber),
               cached.observedAt >= startedAt || modificationTime(old) > modificationTime(item) {
                var merged = item
                for key in ["status", "isImportant", "lastModifiedTime"] {
                    if let value = old[key] { merged[key] = value }
                }
                next[id] = StoredTodo(json: try JSONSerialization.data(withJSONObject: merged),
                    observedAt: cached.observedAt, fromGlasses: true,
                    syncState: "confirmed_by_glasses", provenance: "glasses_status")
            } else {
                next[id] = StoredTodo(json: try JSONSerialization.data(withJSONObject: item),
                    observedAt: startedAt, fromGlasses: false,
                    syncState: "confirmed_by_readback", provenance: "query_snapshot")
            }
        }
        // The firmware may omit completed tasks from its pending list.
        for (id, cached) in previous where next[id] == nil {
            if let item = decode(cached), cached.syncState == "outcome_unknown"
                || (item["status"] as? NSNumber)?.intValue == 1
                || (cached.fromGlasses && cached.observedAt >= startedAt) {
                next[id] = cached
            }
        }
        devices[deviceID, default: Device()].todos = next
        try save()
    }

    /// Stores status only for known tasks. Receiving an event never sends a command.
    func applyGlassesStatus(type: UInt64, body: [String: Any], receivedAt: Date) throws {
        lock.lock(); defer { lock.unlock() }
        try requireDevice()
        let updates: [[String: Any]]
        if type == 4 { updates = [body] }
        else if type == 10 {
            updates = (body["eventList"] as? [[String: Any]] ?? []).filter {
                ($0["eventType"] as? NSNumber)?.intValue == 1
            }
        } else { return }
        var todos = devices[deviceID]?.todos ?? [:]
        var changed = false
        for update in updates {
            guard let id = (update["eventID"] as? NSNumber)?.stringValue,
                  var cached = todos[id], cached.observedAt <= receivedAt,
                  var item = decode(cached) else { continue }
            // Keep showing real eye-originated changes while retaining the full
            // desired write in the journal; a partial event cannot confirm it.
            let hasPendingIntent = cached.syncState == "outcome_unknown" && cached.pendingAction != nil
            if let status = (update["status"] as? NSNumber)?.intValue, status == 0 || status == 1 {
                item["status"] = status
            }
            if let important = update["isImportant"] as? Bool { item["isImportant"] = important }
            if let rawTime = (update["lastModifiedTime"] as? NSNumber)?.int64Value {
                item["glassesLastModifiedTime"] = rawTime
                item["lastModifiedTime"] = unixSeconds(rawTime)
            } else { item["lastModifiedTime"] = Int64(receivedAt.timeIntervalSince1970) }
            cached.json = try JSONSerialization.data(withJSONObject: item)
            cached.observedAt = receivedAt
            cached.fromGlasses = true
            cached.syncState = hasPendingIntent ? "outcome_unknown" : "confirmed_by_glasses"
            cached.provenance = hasPendingIntent ? "local_intent_with_glasses_status" : "glasses_status"
            todos[id] = cached
            changed = true
        }
        if changed {
            devices[deviceID, default: Device()].todos = todos
            try save()
        }
    }

    func localItems() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return (devices[deviceID]?.todos ?? [:]).values.compactMap { cached -> [String: Any]? in
            guard var item = decode(cached) else { return nil }
            item["syncState"] = cached.syncState ?? (cached.fromGlasses ? "confirmed_by_glasses" : "confirmed_by_readback")
            item["provenance"] = cached.provenance ?? (cached.fromGlasses ? "glasses_status" : "query_snapshot")
            if let action = cached.pendingAction { item["pendingAction"] = action }
            if let requestID = cached.requestID {
                item["requestID"] = requestID
                let mutation = devices[deviceID]?.mutations[requestID]
                item["deliveryState"] = cached.provenance == "recovered_local_intent"
                    ? "historical_unknown" : (mutation?.sentAt == nil ? "prepared" : "sent")
                if let result = mutation?.result, let bytes = result.data(using: .utf8),
                   let json = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                   let removed = json["pendingRemoved"] as? Bool { item["pendingRemoved"] = removed }
            }
            return item
        }.sorted {
            (($0["eventID"] as? NSNumber)?.int64Value ?? 0) < (($1["eventID"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func matchesDesired(_ item: [String: Any], wanted: [String: Any]) -> Bool {
        item["title"] as? String == wanted["title"] as? String
            && (item["status"] as? NSNumber)?.intValue == (wanted["status"] as? NSNumber)?.intValue
            && (item["isImportant"] as? Bool ?? false) == (wanted["isImportant"] as? Bool ?? false)
    }

    private func desiredItem(_ cached: StoredTodo) -> [String: Any]? {
        if let requestID = cached.requestID, let data = devices[deviceID]?.mutations[requestID]?.item,
           let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return item }
        return decode(cached)
    }

    /// Earlier builds could drop a phone-completed item from the cache. Recover
    /// only an owned ID with one unambiguous, previously confirmed add journal.
    private func recoverMissingOwnedItems() {
        guard var device = devices[deviceID], loadError == nil else { return }
        var todos = device.todos ?? [:]
        for (id, owned) in device.owned where todos[id] == nil {
            let adds = device.mutations.filter { String($0.value.eventID) == id && $0.value.action == "add" }
            guard adds.count == 1, let (requestID, mutation) = adds.first,
                  let result = mutation.result?.data(using: .utf8),
                  let confirmation = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
                  confirmation["readBack"] as? Bool == true,
                  let args = mutation.arguments.data(using: .utf8),
                  let body = (try? JSONSerialization.jsonObject(with: args)) as? [String: Any],
                  let title = body["title"] as? String, let eventID = Int64(id) else { continue }
            let item: [String: Any] = ["eventType": 1, "eventID": eventID,
                "createTime": owned.createdMilliseconds, "title": title,
                "isImportant": body["important"] as? Bool ?? false, "status": 0,
                "lastModifiedTime": owned.createdMilliseconds / 1000, "eventSource": 0]
            guard let json = try? JSONSerialization.data(withJSONObject: item) else { continue }
            todos[id] = StoredTodo(json: json, observedAt: .distantPast, fromGlasses: false,
                syncState: "outcome_unknown", provenance: "recovered_local_intent",
                requestID: requestID, pendingAction: "recovered")
        }
        device.todos = todos
        devices[deviceID] = device
    }

    private func decode(_ stored: StoredTodo) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: stored.json)) as? [String: Any]
    }

    private func modificationTime(_ item: [String: Any]) -> Int64 {
        max(unixSeconds((item["lastModifiedTime"] as? NSNumber)?.int64Value ?? 0),
            unixSeconds((item["offlineCompletedModifiedTime"] as? NSNumber)?.int64Value ?? 0))
    }

    private func unixSeconds(_ timestamp: Int64) -> Int64 {
        // Firmware 1.0.5.12 emits millisecond status events; App items use seconds.
        timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp
    }

    private func requireDevice() throws {
        if let loadError { throw BridgeError(status: 409, message: loadError) }
        guard !deviceID.isEmpty else {
            throw BridgeError(status: 409, message: "Persistent todo ownership requires the connected glasses address")
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(devices).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
