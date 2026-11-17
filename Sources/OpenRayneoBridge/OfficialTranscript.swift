// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialTranscriptClip: Equatable, Sendable {
    let clipID: String?
    let clipType: String?
    var speakerType: String?
    var speakerName: String?
    var speakerID: String?
    let startTime: Int64?
    let endTime: Int64?
    let languageCode: String?
    let translateLanguageCode: String?
    var content: String?
    var translateContent: String?

    init(json: [String: Any]) throws {
        func string(_ key: String) throws -> String? {
            guard let value = json[key], !(value is NSNull) else { return nil }
            guard let result = value as? String else {
                throw OfficialMemoryFailure(message: "转写片段的\(key)不是文字，请刷新会话。")
            }
            return result
        }
        func milliseconds(_ key: String) throws -> Int64? {
            guard let value = json[key], !(value is NSNull) else { return nil }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int64Value }
            if let text = value as? String, let number = Int64(text) { return number }
            throw OfficialMemoryFailure(message: "转写片段的时间无法读取，请刷新会话。")
        }
        clipID = try string("clipId"); clipType = try string("clipType")
        speakerType = try string("speakerType"); speakerName = try string("speakerName"); speakerID = try string("speakerId")
        startTime = try milliseconds("startTime"); endTime = try milliseconds("endTime")
        languageCode = try string("languageCode"); translateLanguageCode = try string("translateLanguageCode")
        content = try string("content"); translateContent = try string("translateContent")
    }

    var jsonBody: [String: Any] {
        ["clipId": clipID as Any? ?? NSNull(), "clipType": clipType as Any? ?? NSNull(),
         "speakerType": speakerType as Any? ?? NSNull(), "speakerName": speakerName as Any? ?? NSNull(),
         "speakerId": speakerID as Any? ?? NSNull(), "startTime": startTime as Any? ?? NSNull(),
         "endTime": endTime as Any? ?? NSNull(), "languageCode": languageCode as Any? ?? NSNull(),
         "translateLanguageCode": translateLanguageCode as Any? ?? NSNull(),
         "content": content as Any? ?? NSNull(), "translateContent": translateContent as Any? ?? NSNull()]
    }

    static func parse(_ value: Any?) throws -> [Self]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rows = value as? [[String: Any]] else {
            throw OfficialMemoryFailure(message: "转写片段不是可识别的列表，请刷新会话。")
        }
        return try rows.map(Self.init(json:))
    }
}

struct OfficialRecordingTranscriptUpdateRequest: Sendable {
    let taskID: String
    let clips: [OfficialTranscriptClip]
    var jsonBody: [String: Any] { ["taskId": taskID, "clips": clips.map(\.jsonBody)] }
}

enum OfficialTranscriptKind: Sendable {
    case recording, caption
    var title: String { self == .recording ? "录音转写" : "字幕转写" }

    static func from(_ detail: [String: Any]) -> Self? {
        switch (detail["aiTask"] as? [String: Any])?["taskType"] as? String {
        case "recording": return .recording
        case "cc": return .caption
        default: return nil
        }
    }

    func rawClips(in detail: [String: Any]) -> Any? {
        if self == .recording { return (detail["recording"] as? [String: Any])?["clips"] }
        if let caption = detail["cc"] as? [String: Any] { return caption["clips"] }
        return detail["cc"]
    }
}

struct OfficialTranscriptEditTarget: Identifiable {
    let id = UUID()
    let taskID: String
    let account: UUID
    let title: String
    let kind: OfficialTranscriptKind
    let clips: [OfficialTranscriptClip]

    var editableIndices: Set<Int> {
        let counts = clips.compactMap(\.clipID).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return Set(clips.indices.filter { index in
            guard let id = clips[index].clipID, !id.isEmpty else { return false }
            if kind == .caption, clips[index].speakerID == nil { return false }
            return counts[id] == 1
        })
    }
}

enum OfficialTranscriptText {
    enum Field: Sendable { case content, translation }
    struct Match {
        let clipIndex: Int
        let field: Field
        let range: NSRange
    }

    // NSString ranges use UTF-16 offsets, as do the official Dart match ranges.
    static func matches(in clips: [OfficialTranscriptClip], query: String, includeTranslation: Bool,
                        editableIndices: Set<Int>) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        for index in clips.indices where editableIndices.contains(index) {
            let fields: [(Field, String?)] = [(.content, clips[index].content)]
                + (includeTranslation ? [(.translation, clips[index].translateContent)] : [])
            for (field, text) in fields {
                guard let text else { continue }
                let value = text as NSString
                var offset = 0
                while offset < value.length {
                    let range = value.range(of: query, options: [.caseInsensitive, .literal],
                        range: NSRange(location: offset, length: value.length - offset))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    result.append(Match(clipIndex: index, field: field, range: range))
                    offset = NSMaxRange(range)
                }
            }
        }
        return result
    }

    static func replace(_ match: Match, with replacement: String, in clips: inout [OfficialTranscriptClip]) {
        switch match.field {
        case .content:
            if let text = clips[match.clipIndex].content {
                clips[match.clipIndex].content = (text as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        case .translation:
            if let text = clips[match.clipIndex].translateContent {
                clips[match.clipIndex].translateContent = (text as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
    }
}
