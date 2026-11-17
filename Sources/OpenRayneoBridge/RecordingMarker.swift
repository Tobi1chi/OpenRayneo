// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct RecordingMarker: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var positionSeconds: Double
    var content = ""
    var source: String
    var timeBasis: String
    var createdAt = Date()

    var json: [String: Any] {
        ["id": id, "positionSeconds": positionSeconds, "content": content,
         "source": source, "timeBasis": timeBasis, "createdAt": ISO8601DateFormatter().string(from: createdAt)]
    }

    init(positionSeconds: Double, content: String = "", source: String, timeBasis: String) {
        self.positionSeconds = positionSeconds; self.content = content
        self.source = source; self.timeBasis = timeBasis
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let position = json["positionSeconds"] as? Double else { return nil }
        self.id = id; positionSeconds = position; content = json["content"] as? String ?? ""
        source = json["source"] as? String ?? "local"; timeBasis = json["timeBasis"] as? String ?? "local_audio"
        if let date = json["createdAt"] as? String, let parsed = ISO8601DateFormatter().date(from: date) { createdAt = parsed }
    }
}
