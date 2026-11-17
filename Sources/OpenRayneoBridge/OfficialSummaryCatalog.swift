// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialSummaryTemplate: Decodable, Identifiable {
    let templateId: String
    let sort: Int
    let emoji: String
    let name: [String: String]
    let description: [String: String]
    var id: String { templateId }
    var displayName: String { Self.localized(name) }
    var displayDescription: String { Self.localized(description) }

    private static func localized(_ values: [String: String]) -> String {
        let preferred = Locale.preferredLanguages
        let language = Locale(identifier: preferred.first ?? "zh-CN").language.languageCode?.identifier ?? "zh"
        for key in preferred + [language, "zh-CN", "en-US", "en"] {
            if let value = values[key], !value.isEmpty { return value }
        }
        if let key = values.keys.sorted().first(where: { $0.hasPrefix(language) }) { return values[key] ?? "" }
        return values.keys.sorted().first.flatMap { values[$0] } ?? ""
    }
}

struct OfficialSummaryModel: Decodable, Identifiable {
    let modelCode: String
    let displayName: String
    let deepThinking: Bool
    let webSearch: Bool
    let selected: Bool
    let icon: String
    let isDefaultModel: Bool
    let isFreeModel: Bool
    let canAccess: Bool
    let status: String
    var id: String { modelCode }
    var usable: Bool { status == "ONLINE" && canAccess }

    private enum CodingKeys: String, CodingKey {
        case modelCode, displayName, deepThinking, webSearch, selected, icon, isDefaultModel, isFreeModel, canAccess, status
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        modelCode = try value.decode(String.self, forKey: .modelCode)
        displayName = try value.decode(String.self, forKey: .displayName)
        icon = try value.decode(String.self, forKey: .icon)
        deepThinking = try value.decode(Bool.self, forKey: .deepThinking)
        selected = try value.decode(Bool.self, forKey: .selected)
        isDefaultModel = try value.decode(Bool.self, forKey: .isDefaultModel)
        isFreeModel = try value.decode(Bool.self, forKey: .isFreeModel)
        webSearch = try value.decodeIfPresent(Bool.self, forKey: .webSearch) ?? true
        canAccess = try value.decodeIfPresent(Bool.self, forKey: .canAccess) ?? true
        status = try value.decodeIfPresent(String.self, forKey: .status) ?? "ONLINE"
    }
}

enum OfficialSummarySource {
    static func make(detail: [String: Any]) throws -> [String: Any] {
        let task = detail["aiTask"] as? [String: Any] ?? [:]
        let recording = detail["recording"] as? [String: Any] ?? [:]
        let caption = detail["cc"] as? [String: Any] ?? [:]
        func first(_ values: [Any?]) -> Any? { values.compactMap { $0 }.first { !($0 is NSNull) } }
        guard let start = OfficialMemoryRow.milliseconds(first([task["createTime"], recording["createTime"], caption["startTime"]])),
              let end = OfficialMemoryRow.milliseconds(first([task["endTime"], recording["endTime"], caption["endTime"]])) else {
            throw OfficialMemoryFailure(message: "会话缺少生成摘要所需的开始或结束时间，请先刷新详情。")
        }
        let clipKeys = ["clipId", "clipType", "speakerType", "speakerName", "speakerId", "startTime", "endTime",
            "languageCode", "translateLanguageCode", "content", "translateContent"]
        var captionClips = caption["clips"]
        if captionClips == nil, let clips = detail["cc"] as? [[String: Any]] { captionClips = clips }
        let rawClips = first([recording["clips"], captionClips])
        let clips = try array(rawClips, name: "clips")?.map { clip -> [String: Any] in
            var result = project(clip, keys: clipKeys)
            for key in ["startTime", "endTime"] { result[key] = OfficialMemoryRow.milliseconds(clip[key]) as Any? ?? NSNull() }
            return result
        }
        let marks = try array(recording["marks"], name: "marks")?.map { mark -> [String: Any] in
            var result = project(mark, keys: ["markId", "markTime", "remarks"])
            result["markTime"] = OfficialMemoryRow.milliseconds(mark["markTime"]) as Any? ?? NSNull()
            result["remarks"] = try array(mark["remarks"], name: "remarks")?.map { project($0, keys: ["hashtag", "remark"]) } as Any? ?? NSNull()
            return result
        }
        return ["startTime": start, "endTime": end, "clips": clips as Any? ?? NSNull(), "marks": marks as Any? ?? NSNull()]
    }

    private static func project(_ value: [String: Any], keys: [String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, value[$0] ?? NSNull()) })
    }

    private static func array(_ value: Any?, name: String) throws -> [[String: Any]]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rows = value as? [[String: Any]] else {
            throw OfficialMemoryFailure(message: "会话的 \(name) 格式无法用于生成摘要，请刷新详情。")
        }
        return rows
    }
}
