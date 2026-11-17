// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
final class OfficialMemoryCache {
    struct Snapshot {
        let value: Any
        let savedAt: Date
    }

    private let directory: URL
    private var entries: [String: [String: Any]] = [:]

    init(configuration: OfficialFirmwareConfiguration) throws {
        let scope: UUID
        if let epoch = configuration.identityEpoch { scope = epoch }
        else {
            guard !configuration.accountID.isEmpty else {
                throw OfficialMemoryFailure(message: "需要账号 ID 才能隔离并保存这个环境会话的云内容缓存。")
            }
            let key = [configuration.accountID, configuration.baseURL.absoluteString]
                .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            var scopes = UserDefaults.standard.dictionary(forKey: "officialMemoryCacheScopes") as? [String: String] ?? [:]
            if let stored = scopes[key], let id = UUID(uuidString: stored) { scope = id }
            else {
                scope = UUID(); scopes[key] = scope.uuidString
                UserDefaults.standard.set(scopes, forKey: "officialMemoryCacheScopes")
            }
        }
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OfficialMemoryCache", isDirectory: true)
            .appendingPathComponent(scope.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("cache.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let entries = root["entries"] as? [String: [String: Any]] else {
                throw OfficialMemoryFailure(message: "本地官方内容缓存无法读取，未覆盖已有文件。")
            }
            self.entries = entries
        }
    }

    func snapshot(_ key: String) -> Snapshot? {
        guard let entry = entries[key], let value = entry["value"], let time = entry["savedAt"] as? Double else { return nil }
        return Snapshot(value: value, savedAt: Date(timeIntervalSince1970: time))
    }

    func store(_ value: Any, for key: String) throws {
        var updated = entries
        updated[key] = ["value": value, "savedAt": Date().timeIntervalSince1970]
        try persist(updated)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
        entries = [:]
    }

    var deletedSessionIDs: Set<String> {
        Set(snapshot("deletedSessions")?.value as? [String] ?? [])
    }

    func sessionRows(taskType: String) -> [[String: Any]] {
        var rows: [String: [String: Any]] = [:]
        let lists = entries.filter { $0.key.hasPrefix("sessions:") }.values.sorted {
            ($0["savedAt"] as? Double ?? 0) < ($1["savedAt"] as? Double ?? 0)
        }
        for entry in lists {
            let value = entry["value"] as? [String: Any]
            for row in value?["rows"] as? [[String: Any]] ?? [] {
                if let id = OfficialMemoryRow.text(row["taskId"]), !deletedSessionIDs.contains(id) { rows[id] = row }
            }
        }
        if let canonical = snapshot("sessionRows")?.value as? [String: [String: Any]] {
            rows.merge(canonical) { _, fresh in fresh }
        }
        return rows.values.filter { taskType == "all" || $0["taskType"] as? String == taskType }.sorted {
            (OfficialMemoryRow.milliseconds($0["createTime"]) ?? 0) > (OfficialMemoryRow.milliseconds($1["createTime"]) ?? 0)
        }
    }

    func upsertSessionRows(_ incoming: [[String: Any]]) throws {
        var rows = snapshot("sessionRows")?.value as? [String: [String: Any]] ?? [:]
        for row in incoming {
            if let id = OfficialMemoryRow.text(row["taskId"]), !deletedSessionIDs.contains(id) { rows[id] = row }
        }
        try store(rows, for: "sessionRows")
    }

    func removeSession(taskID: String) throws {
        try removeSessions([taskID], rememberDeletion: true)
    }

    func removeSessions(_ taskIDs: Set<String>, rememberDeletion: Bool = false) throws {
        var updated = entries
        for taskID in taskIDs { updated.removeValue(forKey: "session:" + taskID) }
        if var entry = updated["sessionRows"], var rows = entry["value"] as? [String: [String: Any]] {
            for taskID in taskIDs { rows.removeValue(forKey: taskID) }
            entry["value"] = rows; updated["sessionRows"] = entry
        }
        if rememberDeletion {
            updated["deletedSessions"] = ["value": Array(deletedSessionIDs.union(taskIDs)).sorted(),
                "savedAt": Date().timeIntervalSince1970]
        }
        for key in Array(updated.keys) where key.hasPrefix("sessions:") {
            guard var entry = updated[key], var value = entry["value"] as? [String: Any],
                  let rows = value["rows"] as? [[String: Any]] else { continue }
            value["rows"] = rows.filter { !taskIDs.contains(OfficialMemoryRow.text($0["taskId"]) ?? "") }
            value["total"] = NSNull()
            entry["value"] = value; updated[key] = entry
        }
        try persist(updated)
    }

    private func persist(_ updated: [String: [String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["entries": updated], options: [.sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("cache.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = updated
    }
}
