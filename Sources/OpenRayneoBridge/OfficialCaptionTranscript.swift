// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Caption updates send only changed slices; sourceText is serialized as "context".
struct OfficialCaptionTranscriptUpdateItem: Sendable {
    let taskID: String
    let clip: OfficialTranscriptClip

    var jsonBody: [String: Any] {
        ["taskId": taskID, "clipId": clip.clipID as Any? ?? NSNull(),
         "speakerType": clip.speakerType ?? "others", "speakerId": clip.speakerID as Any? ?? NSNull(),
         "speakerName": clip.speakerName as Any? ?? NSNull(), "context": clip.content as Any? ?? NSNull(),
         "translationText": clip.translateContent as Any? ?? NSNull()]
    }
}

struct OfficialCaptionTranscriptUpdateResult: Decodable, Sendable {
    let taskId: String?
    let roundId: String?
    let speakerId: String?
    let speakerName: String?
}
