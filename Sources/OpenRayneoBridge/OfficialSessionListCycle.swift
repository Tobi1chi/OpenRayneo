// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A complete, consistent chain is required before removing older cloud rows.
struct OfficialSessionListCycle {
    let taskType: String
    private(set) var seenIDs = Set<String>()
    private(set) var expectedDeadline: Int64 = 9_999_999_999_999
    private(set) var serverTotal: Int?
    private(set) var safe = true
    private(set) var reachedEnd = false
    private(set) var paginationBlocked = false

    mutating func accept(rows: [[String: Any]], total: Int?, deadline: Int64, explicitPage: Bool) -> Int64? {
        if expectedDeadline != deadline || !explicitPage { safe = false }
        if let total, total >= 0 {
            if let previous = serverTotal, previous != total { safe = false }
            serverTotal = total
        } else { safe = false }
        var lastTime = deadline
        for row in rows {
            guard let id = OfficialMemoryRow.text(row["taskId"]),
                  let time = OfficialMemoryRow.milliseconds(row["createTime"]) else { safe = false; continue }
            if !seenIDs.insert(id).inserted { safe = false }
            if time >= deadline || time > lastTime { safe = false }
            lastTime = time
            let kind = row["taskType"] as? String
            if taskType == "all" {
                if kind != "recording" && kind != "cc" { safe = false }
            } else if kind != taskType { safe = false }
        }
        if let total = serverTotal, seenIDs.count > total { safe = false }
        reachedEnd = explicitPage && (rows.isEmpty || serverTotal.map { seenIDs.count >= $0 } == true)
        let cursor = rows.compactMap { OfficialMemoryRow.milliseconds($0["createTime"]) }.min()
        let next = cursor.flatMap { $0 < deadline ? $0 : nil }
        paginationBlocked = !reachedEnd && next == nil
        if paginationBlocked { safe = false }
        if let next { expectedDeadline = next }
        return reachedEnd ? nil : next
    }

    var complete: Bool { safe && reachedEnd && serverTotal == seenIDs.count }

    func includes(_ row: [String: Any]) -> Bool {
        let kind = row["taskType"] as? String
        return taskType == "all" ? kind == "recording" || kind == "cc" : kind == taskType
    }
}
