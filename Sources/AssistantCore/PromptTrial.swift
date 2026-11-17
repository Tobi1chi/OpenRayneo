// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct PromptTrialResult: Codable, Sendable {
    public let createdAt: Date
    public let profile: PromptProfile
    public let thresholds: AssistantThresholds
    public let input: DecisionInput
    public let completeness: ChoiceResult
    public let routing: ChoiceResult?
    public let reply: GeneratedReply?
    public let toolEvents: [AssistantToolEvent]
    public let modelRequests: [AssistantModelRequest]
    public let status: String
}

public enum PromptTrial {
    public static func run(input: DecisionInput, profile: PromptProfile, thresholds: AssistantThresholds,
                           cloud: CloudModels) async throws -> PromptTrialResult {
        try profile.validate()
        let complete = try await cloud.completeness(input, prompts: profile)
        var routing: ChoiceResult?, reply: GeneratedReply?, status = "完整性未通过门槛，未继续路由"
        let events = TrialEvents()
        if complete.choice == "complete", (complete.probabilities["complete"] ?? 0) >= thresholds.completeProbability,
           complete.confidence >= thresholds.completeConfidence {
            let value = try await cloud.route(input, prompts: profile); routing = value
            status = "分支未通过门槛，未生成回复"
            if let route = AssistantRoute(rawValue: value.choice), (value.probabilities[value.choice] ?? 0) >= thresholds.routeProbability,
               value.confidence >= thresholds.routeConfidence {
                status = route == .ignore ? "本次表达将被忽略" : "试运行已完成，未修改眼镜或执行工具"
                if route != .ignore {
                    reply = try await cloud.reply(to: input, route: route, context: .init(prompts: profile, dryRun: true,
                        onToolEvent: { await events.append($0) }, onModelRequest: { await events.appendRequest($0) }))
                }
            }
        }
        return PromptTrialResult(createdAt: Date(), profile: profile, thresholds: thresholds, input: input, completeness: complete, routing: routing,
            reply: reply, toolEvents: await events.values, modelRequests: await events.requests, status: status)
    }
}

private actor TrialEvents {
    var values: [AssistantToolEvent] = []
    var requests: [AssistantModelRequest] = []
    func append(_ value: AssistantToolEvent) { values.append(value) }
    func appendRequest(_ value: AssistantModelRequest) { requests.append(value) }
}
