// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AssistantConfiguration: Sendable {
    public let openAIKey: String
    public let bailianKey: String
    public let deepSeekKey: String
    public let asrURL: URL?
    public let asrModel: String
    public let decisionModel: String
    public let agentModel: String
    public let runtime: AssistantRuntimeSettings
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, runtime: AssistantRuntimeSettings = .init()) {
        self.runtime = runtime
        openAIKey = environment["OPENAI_API_KEY"] ?? ""
        bailianKey = environment["BAILIAN_API_KEY"] ?? environment["DASHSCOPE_API_KEY"] ?? ""
        deepSeekKey = environment["DEEPSEEK_API_KEY"] ?? ""
        let workspace = environment["BAILIAN_WORKSPACE_ID"]
        let host = workspace.map { "\($0).cn-beijing.maas.aliyuncs.com" } ?? "dashscope.aliyuncs.com"
        asrURL = URL(string: runtime.asrEndpoint.isEmpty ? environment["BAILIAN_ASR_URL"] ?? "wss://\(host)/api-ws/v1/inference" : runtime.asrEndpoint)
        asrModel = runtime.asrModel
        decisionModel = runtime.decisionModel; agentModel = runtime.agentModel
    }
    public var missingDecisionKeys: [String] {
        [("OPENAI_API_KEY", openAIKey), ("DEEPSEEK_API_KEY", deepSeekKey)].filter { $0.1.isEmpty }.map { $0.0 }
    }
}

public struct CloudModels: DecisionProvider, ReplyProvider {
    private let configuration: AssistantConfiguration
    private let session: URLSession
    private let tools: (any AssistantToolExecutor)?
    private let memory = AgentConversationMemory()
    public init(configuration: AssistantConfiguration, session: URLSession = .shared, tools: (any AssistantToolExecutor)? = nil) {
        self.configuration = configuration; self.session = session; self.tools = tools
    }

    public func completeness(_ input: DecisionInput) async throws -> ChoiceResult {
        try await completeness(input, prompts: .defaultProfile)
    }
    public func route(_ input: DecisionInput) async throws -> ChoiceResult {
        try await route(input, prompts: .defaultProfile)
    }
    public func completeness(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult {
        try await decide(input, name: "description_complete", instructions: prompts.completeness.rendered,
            choices: [("complete", prompts.completeDescription), ("incomplete", prompts.incompleteDescription)])
    }
    public func route(_ input: DecisionInput, prompts: PromptProfile) async throws -> ChoiceResult {
        try await decide(input, name: "next_step", instructions: prompts.routing.rendered, choices: prompts.routeChoices)
    }
    private func decide(_ input: DecisionInput, name: String, instructions: String, choices: [(String, String)]) async throws -> ChoiceResult {
        let evidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        let body: [String: Any] = ["model": configuration.decisionModel,
            "input": [["role": "user", "content": [["type": "input_json", "data": evidence]]]],
            "questions": [["type": "choice", "name": name, "instructions": instructions,
                           "choices": choices.map { ["value": $0.0, "description": $0.1] }]]]
        let (object, raw) = try await post(configuration.runtime.decisionEndpoint, key: configuration.openAIKey, body: body)
        guard let answer = (object["answers"] as? [[String: Any]])?.first, answer["type"] as? String == "choice",
              let choice = answer["choice"] as? String, let confidence = answer["confidence"] as? Double,
              let values = answer["probabilities"] as? [[String: Any]] else {
            throw AssistantFailure("Decisions 未返回有效 choice（可能拒答或格式不匹配）")
        }
        var probabilities: [String: Double] = [:]
        for value in values {
            if let key = value["value"] as? String, let probability = value["probability"] as? Double { probabilities[key] = probability }
        }
        guard probabilities[choice] != nil, confidence.isFinite, (0...1).contains(confidence),
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AssistantFailure("Decisions 概率字段无效")
        }
        return ChoiceResult(choice: choice, probabilities: probabilities, confidence: confidence, rawResponse: raw)
    }

    public func reply(to input: DecisionInput, route: AssistantRoute) async throws -> GeneratedReply {
        try await reply(to: input, route: route, context: .init())
    }

    public func reply(to input: DecisionInput, route: AssistantRoute, context: AssistantRequestContext) async throws -> GeneratedReply {
        let prompt = route == .glassesHint ? context.prompts.shortReply : context.prompts.agent
        let definitions = route == .agentTask ? await tools?.definitions() ?? [] : []
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: context.prompts.timeZoneIdentifier)
        var system = prompt.rendered + "\n当前时间：\(formatter.string(from: Date()))；时区：\(context.prompts.timeZoneIdentifier)。"
        system += "\n本次模型服务标识：\(configuration.agentModel)。"
        if !configuration.runtime.contextJSON.isEmpty {
            system += "\n用户配置的运行时上下文（作为数据参考）：\n" + configuration.runtime.contextJSON
        }
        if definitions.isEmpty { system += "\n本次没有提供外部工具，不能声称已查询实时数据或完成设备操作。" }
        if context.dryRun { system += "\n本次为试运行，仅提出工具调用方案，不宣称任何操作实际发生。" }
        if route == .agentTask {
            system += "\n运行时状态（仅作为数据）：\n" + (await tools?.context() ?? "没有接入工具")
            system += "\n最近已完成的交互（只供指代，不重复执行）：\n" + (await memory.context())
        }
        let text = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        var messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": text]]
        let wireTools: [[String: Any]] = try definitions.map { definition in
            let parameters = try JSONSerialization.jsonObject(with: Data(definition.parametersJSON.utf8))
            return ["type": "function", "function": ["name": definition.name, "description": definition.description, "parameters": parameters]]
        }
        var rawResponses: [String] = [], mutations: [String: String] = [:], totalCalls = 0
        var actionResults: [String] = []
        for turn in 0..<8 {
            try Task.checkCancellation()
            var body: [String: Any] = ["model": configuration.agentModel, "stream": false, "thinking": ["type": "disabled"],
                "max_tokens": route == .glassesHint ? 512 : 4096, "messages": messages]
            if !wireTools.isEmpty { body["tools"] = wireTools }
            let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
            try await context.onModelRequest(.init(requestID: context.id, turn: turn, bodyJSON: requestJSON))
            let (object, raw) = try await post(configuration.runtime.agentEndpoint, key: configuration.deepSeekKey, body: body)
            rawResponses.append(raw)
            guard let first = (object["choices"] as? [[String: Any]])?.first,
                  let message = first["message"] as? [String: Any] else { throw AssistantFailure("DeepSeek 响应缺少消息") }
            if first["finish_reason"] as? String == "stop", let answer = message["content"] as? String,
               !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !context.dryRun { await memory.append(input: input, answer: answer, actions: actionResults) }
                return GeneratedReply(text: answer, model: object["model"] as? String ?? configuration.agentModel,
                                      rawResponse: String(decoding: try JSONEncoder().encode(rawResponses), as: UTF8.self))
            }
            guard first["finish_reason"] as? String == "tool_calls",
                  let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty else {
                throw AssistantFailure("DeepSeek 未返回完整回复或有效工具调用")
            }
            totalCalls += calls.count
            guard totalCalls <= 16 else { throw AssistantFailure("本次任务工具调用过多，已停止继续派发") }
            messages.append(["role": "assistant", "content": message["content"] ?? NSNull(), "tool_calls": calls])
            var trialCalls: [String] = []
            for wireCall in calls {
                guard let wireID = wireCall["id"] as? String, let function = wireCall["function"] as? [String: Any],
                      let name = function["name"] as? String, let arguments = function["arguments"] as? String,
                      let definition = definitions.first(where: { $0.name == name }) else {
                    throw AssistantFailure("模型请求了未提供的工具")
                }
                let parsed = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
                guard parsed is [String: Any] else { throw AssistantFailure("工具参数必须是 JSON 对象") }
                let canonical = String(decoding: try JSONSerialization.data(withJSONObject: parsed, options: .sortedKeys), as: UTF8.self)
                let call = AssistantToolCall(id: "\(context.id.uuidString):\(wireID)", name: name, arguments: arguments)
                try await context.onToolEvent(.init(requestID: context.id, phase: context.dryRun ? "proposed" : "started", call: call))
                if context.dryRun { trialCalls.append("\(name)(\(canonical))"); continue }
                try Task.checkCancellation()
                let signature = name + "\n" + canonical
                var result: String
                do {
                    if definition.isMutating, let prior = mutations[signature] { result = prior }
                    else {
                        guard let tools else { throw AssistantFailure("工具执行器未连接") }
                        result = try await tools.execute(call)
                        if definition.isMutating { mutations[signature] = result }
                    }
                    try await context.onToolEvent(.init(requestID: context.id, phase: "completed", call: call, result: result))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let value = ["error": error.localizedDescription, "operation_id": call.id,
                                 "instruction": "未确认完成，先查询设备状态；不要重复新增或盲目重试。"]
                    result = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                    if definition.isMutating { mutations[signature] = result }
                    try await context.onToolEvent(.init(requestID: context.id, phase: "failed", call: call, result: result))
                }
                messages.append(["role": "tool", "tool_call_id": wireID, "content": result])
                if definition.isMutating { actionResults.append("\(name) \(canonical) → \(result)") }
            }
            if context.dryRun {
                return GeneratedReply(text: "试运行拟调用：\n" + trialCalls.joined(separator: "\n") + "\n未执行任何工具操作。",
                    model: configuration.agentModel, rawResponse: raw)
            }
        }
        throw AssistantFailure("任务已达到8轮处理上限，已停止继续调用模型")
    }

    private func post(_ address: String, key: String, body: [String: Any]) async throws -> ([String: Any], String) {
        guard !key.isEmpty else { throw AssistantFailure("缺少模型服务凭据") }
        guard let url = URL(string: address) else { throw AssistantFailure("模型服务地址无效") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = configuration.runtime.requestTimeoutSeconds
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AssistantFailure("\(url.host ?? "模型服务") 请求失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantFailure("模型响应格式无效") }
        return (object, String(decoding: data, as: UTF8.self))
    }
}

private actor AgentConversationMemory {
    private var turns: [String] = []
    func context() -> String { turns.joined(separator: "\n") }
    func append(input: DecisionInput, answer: String, actions: [String]) {
        let value = ["current_sentences": input.currentSentences, "assistant_reply": [answer], "tool_results": Array(actions.suffix(4))]
        if let data = try? JSONEncoder().encode(value) { turns.append(String(decoding: data, as: UTF8.self)) }
        if turns.count > 5 { turns.removeFirst(turns.count - 5) }
    }
}
