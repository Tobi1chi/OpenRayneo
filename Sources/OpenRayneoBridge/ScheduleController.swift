// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class ScheduleController {
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private let sync: ScheduleTodoSync
    private var sequence: UInt16 = 0x7000

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, sync: ScheduleTodoSync? = nil) {
        self.transport = transport; self.lock = lock
        self.sync = sync ?? ScheduleTodoSync(transport: transport, lock: lock)
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/schedules" || path.hasPrefix("/v1/schedules/") else { return nil }
        lock.lock(); defer { lock.unlock() }
        if method == "GET", path == "/v1/schedules" { return (200, ["items": try query()]) }
        if method == "POST", path == "/v1/schedules/import" {
            let replacements = Set((body["replaceEventIDs"] as? [String] ?? []).compactMap(Int64.init))
            var existing = try query().filter { !replacements.contains(($0["eventID"] as? NSNumber)?.int64Value ?? -1) }
            for var item in body["items"] as? [[String: Any]] ?? [] {
                try update(&item, body: item)
                item["eventType"] = 0; item["status"] = 0; item["eventSource"] = 0
                existing.append(item)
            }
            try send(type: 5, body: ["scheduleTotal": existing.count, "isLastBatch": true, "eventList": existing])
            return (200, ["items": try query(), "sent": "import"])
        }
        guard method == "POST" || method == "PATCH" || method == "DELETE" else { return nil }
        let id = path == "/v1/schedules" ? nil : Int64(path.dropFirst("/v1/schedules/".count))
        var items = try query()
        var targetID: Int64
        if method == "POST", path == "/v1/schedules" {
            targetID = Int64(Date().timeIntervalSince1970 * 1000)
            let existing = Set(items.compactMap { ($0["eventID"] as? NSNumber)?.int64Value })
            while existing.contains(targetID) { targetID += 1 }
            var item: [String: Any] = ["eventType": 0, "eventID": targetID, "status": 0, "eventSource": 0]
            try update(&item, body: body)
            items.append(item)
        } else {
            guard let id, let index = items.firstIndex(where: { ($0["eventID"] as? NSNumber)?.int64Value == id }) else {
                throw BridgeError(status: 404, message: "Schedule not found")
            }
            targetID = id
            if method == "DELETE" { items.remove(at: index) }
            else { try update(&items[index], body: body) }
        }
        try send(type: 5, body: ["scheduleTotal": items.count, "isLastBatch": true, "eventList": items])
        let readBack = try query()
        return (200, ["eventID": String(targetID), "items": readBack, "sent": method.lowercased()])
    }

    private func update(_ item: inout [String: Any], body: [String: Any]) throws {
        if let title = body["title"] as? String { item["title"] = title }
        if let start = body["startTime"] as? NSNumber { item["startTime"] = start.int64Value }
        if let end = body["endTime"] as? NSNumber { item["endTime"] = end.int64Value }
        guard let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = item["startTime"] as? NSNumber, let end = item["endTime"] as? NSNumber,
              end.int64Value > start.int64Value else {
            throw BridgeError(status: 400, message: "Schedule requires title, startTime and later endTime (Unix seconds)")
        }
        let date = Date(timeIntervalSince1970: start.doubleValue)
        item["localTimeOffset"] = body["localTimeOffset"] as? Int ?? TimeZone.current.secondsFromGMT(for: date)
        item["isTomorrowSchedule"] = Calendar.current.isDateInTomorrow(date)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if item["createTime"] == nil { item["createTime"] = now }
        item["lastModifiedTime"] = now
    }

    private func send(type: UInt64, body: [String: Any]) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: 0x16, sequence: sequence, type: type, body: body))
    }

    private func query() throws -> [[String: Any]] {
        let reply = try sync.query(eventType: 0)
        return reply["dataList"] as? [[String: Any]] ?? []
    }
}
