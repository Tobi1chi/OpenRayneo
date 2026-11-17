// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keys follow retained 0x0D captures, including the ASR DTO's serialized-name annotation.
enum NativeAssistantPayload {
    static func asr(text: String, final: Bool) -> [String: Any] {
        ["text": text, "final": final]
    }

    static func reply(text: String, query: String, sid: String, clientID: String,
                      timestamp: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        ["sub": "workflow", "vendor": "OpenRayneo", "uuid": clientID,
         "sid": sid, "round": -1, "timestamp": Int(timestamp), "query": query,
         "domain": "chat", "intent": "chat", "offline": false,
         "answer": ["text": text, "isFinal": true]]
    }
}
