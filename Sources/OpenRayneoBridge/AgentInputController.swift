// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A cursor feed for host-local workflows. Semantic decisions live in the consuming Agent.
final class AgentInputController {
    private let lock = NSLock()
    private var sequence = 0
    private var events: [[String: Any]] = []
    private let epoch = UUID().uuidString

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/agent/events" else { return nil }
        lock.lock(); defer { lock.unlock() }
        if method == "POST" {
            guard let text = body["text"] as? String, !text.isEmpty,
                  let sessionID = body["sessionID"] as? String, let roundID = body["roundID"] as? String else {
                throw BridgeError(status: 400, message: "提供 text、sessionID 和 roundID")
            }
            sequence += 1
            var event = body
            event["sequence"] = sequence; event["receivedAt"] = Date().timeIntervalSince1970 * 1000
            event["sessionID"] = sessionID; event["roundID"] = roundID
            events.append(event)
            if events.count > 512 { events.removeFirst(events.count - 512) }
            return (202, ["sequence": sequence, "epoch": epoch])
        }
        guard method == "GET" else { return nil }
        let after = body["after"] as? Int ?? 0
        return (200, ["epoch": epoch, "cursor": sequence, "oldestCursor": events.first?["sequence"] as? Int ?? sequence,
            "overflow": after > 0 && after < (events.first?["sequence"] as? Int ?? sequence) - 1,
            "events": events.filter { ($0["sequence"] as? Int ?? 0) > after },
            "policy": "external-agent", "nativeInput": "/v1/assistant/native", "nativePCM": "/v1/assistant/native/audio",
            "replyRule": "native: POST /v1/assistant/native/reply with wakeID; realtime: POST /v1/prompts/text with sid; manual/import: no implicit glasses reply"])
    }
}
