// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialSummaryContentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// SummaryMindMapResponse.toJson projects only title and recursively serialized children.
struct OfficialSummaryMindMap: Sendable {
    let title: String
    let children: [OfficialSummaryMindMap]

    private init(json: [String: Any]) throws {
        guard let title = json["title"] as? String else {
            throw OfficialSummaryContentFailure(message: "现有思维导图的节点缺少文字标题，未发送摘要修改。")
        }
        self.title = title
        if let raw = json["children"], !(raw is NSNull) {
            guard let nodes = raw as? [[String: Any]] else {
                throw OfficialSummaryContentFailure(message: "现有思维导图的子节点格式无法识别，未发送摘要修改。")
            }
            children = try nodes.map(Self.init(json:))
        } else { children = [] }
    }

    fileprivate static func existing(_ value: Any?) throws -> OfficialSummaryMindMap? {
        // The official response helper treats an absent/invalid root or a blank root title as no map.
        guard let root = value as? [String: Any], let title = root["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try Self(json: root)
    }

    fileprivate var jsonBody: [String: Any] {
        ["title": title, "children": children.map(\.jsonBody)]
    }
}

/// Mirrors the official body-editor caller: name=null, outline=null, existing mind map retained.
/// Markdown is sent as text; editor document JSON and displayed speaker names are not substituted for it.
struct OfficialSummaryContentUpdateRequest: Sendable {
    let summaryID: String
    let markdown: String
    let mindMap: OfficialSummaryMindMap?

    init(summaryID: String, markdown: String, existingContent: [String: Any]) throws {
        self.summaryID = summaryID
        self.markdown = markdown
        mindMap = try OfficialSummaryMindMap.existing(existingContent["mindMap"])
    }

    var jsonBody: [String: Any] {
        ["items": [["summaryId": summaryID, "name": NSNull(), "content": [
            "content": markdown, "outline": NSNull(), "mindMap": mindMap?.jsonBody as Any? ?? NSNull()
        ]]]]
    }
}

struct OfficialSummaryUpdateResult: Sendable {
    let successfulSummaryIDs: [String]?

    init(json: [String: Any]) throws {
        guard let value = json["successfulSummaryIds"], !(value is NSNull) else {
            successfulSummaryIDs = nil
            return
        }
        guard let ids = value as? [String] else {
            throw OfficialSummaryContentFailure(message: "官方摘要保存结果的成功 ID 列表无法识别。")
        }
        successfulSummaryIDs = ids
    }
}
