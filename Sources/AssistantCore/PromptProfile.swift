// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct PromptExample: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var previous: [String]
    public var current: [String]
    public var expected: String
    public init(previous: [String] = [], current: [String] = [], expected: String) {
        id = UUID(); self.previous = previous; self.current = current; self.expected = expected
    }
}

public struct ClassifierPrompt: Codable, Equatable, Sendable {
    public var objective: String
    public var rules: [String]
    public var examples: [PromptExample]
    public var rendered: String {
        let encoder = JSONEncoder()
        let samples = examples.compactMap { sample -> String? in
            guard let data = try? encoder.encode(DecisionInput(previous: sample.previous, current: sample.current)) else { return nil }
            return "\(String(decoding: data, as: UTF8.self)) → \(sample.expected)"
        }
        return ([objective] + rules.filter { !$0.isEmpty } + (samples.isEmpty ? [] : ["分类示例："] + samples)).joined(separator: "\n")
    }
}

public struct ResponsePrompt: Codable, Equatable, Sendable {
    public var role: String
    public var objective: String
    public var style: String
    public var maximumCharacters: Int
    public var rules: [String]
    public var rendered: String {
        ([role, objective, "回复风格：\(style)", "尽量在\(maximumCharacters)字以内。"] + rules.filter { !$0.isEmpty }).joined(separator: "\n")
    }
}

public struct ASRPromptSettings: Codable, Equatable, Sendable {
    public var context: String
    public var hotwords: [String]
    public var languageHints: [String]
    public var nearField: Bool
    public init(context: String = "", hotwords: [String] = [], languageHints: [String] = [], nearField: Bool = false) {
        self.context = context; self.hotwords = hotwords; self.languageHints = languageHints; self.nearField = nearField
    }
}

public struct PromptProfile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name: String
    public var revision: Int
    public var savedAt: Date
    public var completeness: ClassifierPrompt
    public var routing: ClassifierPrompt
    public var completeDescription: String
    public var incompleteDescription: String
    public var ignoreDescription: String
    public var hintDescription: String
    public var agentDescription: String
    public var shortReply: ResponsePrompt
    public var agent: ResponsePrompt
    public var asr: ASRPromptSettings
    public var timeZoneIdentifier: String
    public var runtime: AssistantRuntimeSettings? = nil
    public var runtimeSettings: AssistantRuntimeSettings { runtime ?? .init() }
    public var versionLabel: String { "prompts-v\(schemaVersion)-r\(revision)" }

    public var routeChoices: [(String, String)] {
        [("ignore", ignoreDescription), ("glasses_hint", hintDescription), ("agent_task", agentDescription)]
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw AssistantFailure("不支持的提示词配置版本") }
        try runtime?.validate()
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw AssistantFailure("时区标识无效，例如 Asia/Shanghai") }
        guard (20...4000).contains(shortReply.maximumCharacters), (20...8000).contains(agent.maximumCharacters) else {
            throw AssistantFailure("回复长度超出支持范围")
        }
        guard asr.context.count <= 400, asr.hotwords.count <= 2000, asr.languageHints.count <= 4 else {
            throw AssistantFailure("ASR 上下文最多400字，热词最多2000项，语种提示最多4项")
        }
        guard completeness.examples.allSatisfy({ ["complete", "incomplete"].contains($0.expected) }),
              routing.examples.allSatisfy({ ["ignore", "glasses_hint", "agent_task"].contains($0.expected) }) else {
            throw AssistantFailure("示例分类与固定的输出类别不匹配")
        }
    }

    public static var defaultProfile: PromptProfile {
        let completeLines = DecisionPolicy.completeness.components(separatedBy: "\n")
        let routingLines = DecisionPolicy.routing.components(separatedBy: "\n")
        return PromptProfile(name: "默认配置", revision: 1, savedAt: Date(timeIntervalSince1970: 0),
            completeness: .init(objective: completeLines.first ?? "判断是否描述完整", rules: Array(completeLines.dropFirst()).filter { !$0.hasPrefix("示例：") },
                examples: [.init(current: ["助手，帮我查一下"], expected: "incomplete"),
                           .init(previous: ["助手查明天天气"], current: ["我在天津"], expected: "complete")]),
            routing: .init(objective: routingLines.first ?? "选择处理分支", rules: Array(routingLines.dropFirst()).filter { !$0.hasPrefix("示例（") && !$0.contains(" / [") },
                examples: [.init(current: ["助手帮我解释欧姆定律"], expected: "glasses_hint"),
                           .init(previous: ["助手查明天天气"], current: ["我在天津"], expected: "agent_task"),
                           .init(current: ["我是在天津"], expected: "ignore")]),
            completeDescription: "已经能理解本次表达或更新，可以处理或提出明确澄清问题",
            incompleteDescription: "明显半句或请求对象仍无法确定，需要继续收集",
            ignoreDescription: DecisionPolicy.routeChoices[0].1,
            hintDescription: DecisionPolicy.routeChoices[1].1,
            agentDescription: DecisionPolicy.routeChoices[2].1,
            shortReply: .init(role: "你是眼镜助手。", objective: "仅处理当前表达；若当前为补充、纠正或续问，结合上一成功表达理解本次更新，不单独重答历史。",
                style: "中文纯文本、简短直接，适合眼镜阅读", maximumCharacters: 80,
                rules: ["无需外部信息的知识解释可直接回答。", "没有调用工具时，不得虚构实时信息或声称已执行操作。"]),
            agent: .init(role: "你是 OpenRayneo 的任务助手。", objective: "理解当前需求，调用已提供的待办、天气和日程工具，再根据真实工具结果回答。",
                style: "中文纯文本、明确说明结果，眼镜上优先显示结论", maximumCharacters: 600,
                rules: ["当前是补充、纠正或续问时，结合上一成功表达和最近工具结果处理本次更新。",
                        "先查询再修改已有任务；多个同名项目时询问要操作哪一项。",
                        "缺少城市、具体起止时间等必要信息时澄清，不编造参数。",
                        "创建或修改后以工具返回的设备回读结果为准；失败或结果未知时如实说明，不盲目重试新增。",
                        "只有已提供的工具可用；不声称拥有尚未实现的系统日历、网络搜索或设备能力。",
                        "对明确的单项指令直接执行，不重复征求确认；仅在信息不足或对象有歧义时追问。"]),
            asr: .init(), timeZoneIdentifier: "Asia/Shanghai")
    }
}
