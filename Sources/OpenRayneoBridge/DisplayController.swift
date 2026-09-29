// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Experimental display messages reconstructed from the official Android APK.
/// A device acknowledgment and a visible result are reported separately.
final class DisplayController {
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private var nextSequence: UInt16 = 0x4000
    private var session: (id: String, protocolID: UInt8, ready: Bool)?
    private var ownedTodoIDs = Set<Int64>()

    init(transport: RFCOMMTransport, lock: NSRecursiveLock) {
        self.transport = transport
        self.lock = lock
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        if method == "GET", path == "/v1/display/events" {
            return (200, ["events": transport.displayEvents, "discardedAudioPackets": transport.displayAudioPacketCount])
        }
        if method == "GET", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            return (200, ["reply": try queryTodos()])
        }
        if method == "POST", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            guard let title = body["title"] as? String, !title.isEmpty else {
                throw BridgeError(status: 400, message: "title must not be empty")
            }
            var items = try todoItems(queryTodos())
            let existing = Set(items.compactMap { ($0["eventID"] as? NSNumber)?.int64Value })
            guard let id = (Int64(90_000)..<100_000).first(where: { !existing.contains($0) }) else {
                throw BridgeError(status: 409, message: "No free local test task ID")
            }
            let now = Date().timeIntervalSince1970
            items.append([
                "eventType": 1, "eventID": id, "createTime": Int64(now * 1000),
                "title": title, "isImportant": body["important"] as? Bool ?? false,
                "status": 0, "lastModifiedTime": Int64(now)
            ])
            try synchronizeTodos(items)
            ownedTodoIDs.insert(id)
            let confirmed = try todoItems(queryTodos())
            let found = confirmed.first { ($0["eventID"] as? NSNumber)?.int64Value == id }
            return (202, ["eventID": id, "sent": "todo", "readBack": found?["title"] as? String == title,
                          "visible": "unverified"])
        }
        if method == "DELETE", path.hasPrefix("/v1/todos/") {
            lock.lock()
            defer { lock.unlock() }
            guard let id = Int64(path.dropFirst("/v1/todos/".count)), ownedTodoIDs.contains(id) else {
                throw BridgeError(status: 409, message: "Only tasks created by this bridge process can be removed")
            }
            var items = try todoItems(queryTodos())
            items.removeAll { ($0["eventID"] as? NSNumber)?.int64Value == id }
            try synchronizeTodos(items)
            let confirmed = try todoItems(queryTodos())
            let removed = !confirmed.contains { ($0["eventID"] as? NSNumber)?.int64Value == id }
            if removed { ownedTodoIDs.remove(id) }
            return (202, ["eventID": id, "sent": "removeTodo", "readBack": removed])
        }
        let prefix: String
        let protocolID: UInt8
        if path.hasPrefix("/v1/captions/") {
            prefix = "/v1/captions/"
            protocolID = 0x13
        } else if path.hasPrefix("/v1/prompts/") {
            prefix = "/v1/prompts/"
            protocolID = 0x17
        } else {
            return nil
        }
        guard method == "POST" else { return nil }
        lock.lock()
        defer { lock.unlock() }
        switch String(path.dropFirst(prefix.count)) {
        case "start":
            guard session == nil else {
                throw BridgeError(status: 409, message: "Stop the current text display session first")
            }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let config: [String: Any] = [
                "font_size": body["font_size"] as? Int ?? 2,
                "content_width": body["content_width"] as? Int ?? 100,
                "max_lines": body["max_lines"] as? Int ?? 5,
                "position": "center", "is_display": true, "straight_view": "original"
            ]
            if protocolID == 0x13 {
                try send(protocolID, type: 7, body: ["sid": id, "force": false, "scope": "temporary", "config": config])
            } else {
                try send(protocolID, type: 1, body: [
                    "sid": id, "trigger": 1, "force": false, "code": 0,
                    "settings": ["mode": "conversation", "source_language": "zh-CN",
                                 "target_language": "zh-CN", "save_audio": false, "direction": "ahead"]
                ])
            }
            session = (id, protocolID, false)
            let replyType: UInt64 = protocolID == 0x13 ? 8 : 2
            let reply = transport.waitForMessage(timeout: 8) {
                $0.protocolID == protocolID && $0.messageType == replyType && $0.json?["sid"] as? String == id
            }
            guard let reply, let json = reply.json else {
                return (202, ["sid": id, "sent": "start", "acknowledged": false, "visible": "unverified"])
            }
            let code = (json["code"] as? NSNumber)?.intValue
            session = (id, protocolID, code == 1)
            return (200, ["sid": id, "sent": "start", "acknowledged": true,
                          "accepted": code == 1, "reply": json, "visible": "unverified"])
        case "text":
            guard let session, session.protocolID == protocolID, session.ready else {
                throw BridgeError(status: 409, message: "A confirmed display session is required")
            }
            guard let text = body["text"] as? String, !text.isEmpty else {
                throw BridgeError(status: 400, message: "text must not be empty")
            }
            var content: [String: Any] = ["source_transcript": text]
            if let translation = body["translation"] as? String { content["target_translation"] = translation }
            if protocolID == 0x17 {
                content["keyword_info"] = NSNull()
                content["label"] = 0
            }
            try send(protocolID, type: 5, body: [
                "sid": session.id, "mode": protocolID == 0x17 ? 4 : 3,
                "status": (body["final"] as? Bool ?? false) ? 1 : 0, "content": content
            ])
            return (202, ["sid": session.id, "sent": "text", "visible": "unverified"])
        case "stop":
            guard let session, session.protocolID == protocolID else {
                throw BridgeError(status: 409, message: "No matching text display session")
            }
            try send(protocolID, type: 3, body: ["sid": session.id, "reason_code": protocolID == 0x13 ? 10 : 2, "text": ""])
            self.session = nil
            return (202, ["sid": session.id, "sent": "stop", "visible": "unverified"])
        default:
            return nil
        }
    }

    private func send(_ protocolID: UInt8, type: UInt64, body: [String: Any]) throws {
        nextSequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: protocolID, sequence: nextSequence, type: type, body: body))
    }

    private func queryTodos() throws -> [String: Any] {
        try transport.ensureConnected()
        let started = Date()
        try send(0x16, type: 15, body: [
            "queryType": 0, "eventType": 1, "lastSyncTime": 0,
            "eventIDList": [], "needFullData": true
        ])
        var last: [String: Any] = [:]
        var records: [[String: Any]] = []
        let deadline = started.addingTimeInterval(5)
        repeat {
            guard let reply = transport.waitForMessage(timeout: max(0, deadline.timeIntervalSinceNow), matching: {
                $0.protocolID == 0x16 && $0.messageType == 16 && $0.receivedAt >= started
            }), let json = reply.json, let data = json["dataList"] as? [[String: Any]] else {
                throw BridgeError(status: 504, message: "Glasses did not answer the complete task query")
            }
            last = json
            records.append(contentsOf: data)
        } while last["isLastBatch"] as? Bool != true
        last["dataList"] = records
        return last
    }

    private func todoItems(_ reply: [String: Any]) throws -> [[String: Any]] {
        guard reply["needFullData"] as? Bool == true,
              let expected = (reply["todoTotal"] as? NSNumber)?.intValue,
              let records = reply["dataList"] as? [[String: Any]] else {
            throw BridgeError(status: 409, message: "A complete task snapshot is required before writing")
        }
        let todos = records.filter { ($0["eventType"] as? NSNumber)?.intValue == 1 }
        guard todos.count == expected, todos.allSatisfy({ $0["eventID"] is NSNumber && $0["title"] is String }) else {
            throw BridgeError(status: 409, message: "Task snapshot is incomplete or uses an unrecognized item format")
        }
        return todos
    }

    private func synchronizeTodos(_ items: [[String: Any]]) throws {
        try send(0x16, type: 6, body: ["total": items.count, "isLastBatch": true, "eventList": items])
    }
}
