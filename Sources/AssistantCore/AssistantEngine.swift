// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns text and decision state. No Bluetooth, UI, microphone or audio-format dependency.
public actor AssistantEngine {
    private let decisions: (any DecisionProvider)?
    private let replies: (any ReplyProvider)?
    private let thresholds: AssistantThresholds
    private let configuredRuntime: AssistantRuntimeSettings
    private var prompts: PromptProfile
    private var journal: DatasetJournal?
    private var state = AssistantState()
    private var generation = UUID()
    private var revision = 0
    private var seen = Set<String>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var consumed: [String] = []

    public init(decisions: (any DecisionProvider)? = nil, replies: (any ReplyProvider)? = nil, thresholds: AssistantThresholds = .init(), prompts: PromptProfile = .defaultProfile) {
        self.decisions = decisions; self.replies = replies; self.thresholds = thresholds; self.prompts = prompts
        configuredRuntime = prompts.runtimeSettings
    }

    public func start(logURL: URL) throws {
        stop()
        journal = try DatasetJournal(url: logURL)
        state = AssistantState(); state.running = true; state.logPath = logURL.path; state.phase = "等待最终整句"
        seen = []; consumed = []; revision = 0
        state.promptVersion = prompts.versionLabel
        try journal?.write("session_started", data: SessionConfiguration(schema: "asr-arrays-v2", questionVersion: prompts.versionLabel,
            decisionModel: configuredRuntime.decisionModel, asrModel: configuredRuntime.asrModel,
            agentModel: configuredRuntime.agentModel, thresholds: thresholds, prompts: prompts))
    }

    public func updatePrompts(_ value: PromptProfile) throws {
        try value.validate()
        if state.running { try journal?.write("prompt_configuration", data: value) }
        prompts = value; state.promptVersion = value.versionLabel
    }

    public func suspendDispatch() {
        generation = UUID(); revision += 1
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        state.pendingRequests = 0; state.replyPending = false; state.running = false; state.phase = "已停止"
    }

    public func stop() {
        suspendDispatch()
        if let journal { do { try journal.write("session_stopped", data: state.current) } catch { state.error = error.localizedDescription } }
        journal = nil
    }

    public func snapshot() -> AssistantState { state }

    public func recordASR(_ event: String, data: String) {
        record(event, data)
    }

    public func accept(_ sentence: Sentence) {
        guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              seen.insert(sentence.id).inserted else { return }
        guard record("asr_final", sentence) else { return }
        guard state.running else { return }
        state.current.append(sentence.text); revision += 1
        guard decisions != nil, replies != nil else {
            state.phase = "整句已交付本机 Agent"; state.error = nil
            return
        }
        state.error = nil; state.phase = "判定是否描述完整"
        let input = DecisionInput(previous: state.previous, current: state.current)
        let version = revision, session = generation, requestID = UUID()
        let settings = prompts
        guard record("decision_input", DecisionSnapshot(id: requestID, generation: session, revision: version, input: input, promptVersion: settings.versionLabel)) else { return }
        let task = Task { await self.evaluate(input, version: version, session: session, id: requestID, roundID: sentence.roundID, prompts: settings) }
        tasks[requestID] = task; state.pendingRequests = tasks.count
    }

    private func evaluate(_ input: DecisionInput, version: Int, session: UUID, id: UUID, roundID: String, prompts: PromptProfile) async {
        guard let decisions else { return }
        defer { tasks[id] = nil; state.pendingRequests = tasks.count }
        do {
            let complete = try await decisions.completeness(input, prompts: prompts)
            guard session == generation else { return }
            guard record("completeness", Evaluation(id: id, revision: version, result: complete)) else { return }
            guard version == revision, state.running else { record("stale_completeness", id); return }
            state.completeness = complete; state.routing = nil
            guard complete.choice == "complete", (complete.probabilities["complete"] ?? 0) >= thresholds.completeProbability,
                  complete.confidence >= thresholds.completeConfidence else {
                state.phase = "继续收集整句"; return
            }
            state.phase = "判定处理分支"
            let routing = try await decisions.route(input, prompts: prompts)
            guard session == generation else { return }
            guard record("routing", Evaluation(id: id, revision: version, result: routing)) else { return }
            guard version == revision, state.running else { record("stale_routing", id); return }
            state.routing = routing
            guard let route = AssistantRoute(rawValue: routing.choice) else { throw AssistantFailure("模型返回未知分支") }
            guard (routing.probabilities[routing.choice] ?? 0) >= thresholds.routeProbability,
                  routing.confidence >= thresholds.routeConfidence else { state.phase = "分支不确定，等待补充"; return }
            guard record("consumed", Consumption(id: id, route: route, input: input)) else { return }
            state.current = []; revision += 1
            if route == .ignore { state.phase = "已忽略，等待下一句"; return }
            state.previous = input.currentSentences
            consumed.append(id.uuidString)
            try await generateReply(input, route: route, id: id, roundID: roundID, prompts: prompts, session: session)
        } catch {
            guard session == generation else { return }
            record("request_error", RequestFailure(id: id, revision: version, message: error.localizedDescription))
            if consumed.last == id.uuidString {
                state.replyPending = false; state.replyError = error.localizedDescription
            }
            if version == revision || consumed.last == id.uuidString {
                state.error = error.localizedDescription; state.phase = "请求失败，内容已保留在记录中"
            }
        }
    }

    /// Explicit text entry is addressed to the assistant and bypasses the ambient intent gate.
    public func ask(_ text: String) {
        guard state.running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard replies != nil else {
            accept(Sentence(id: UUID().uuidString, text: text, roundID: "manual")); return
        }
        let input = DecisionInput(previous: state.previous, current: [text])
        let id = UUID(), session = generation, profile = prompts
        guard record("manual_input", DecisionSnapshot(id: id, generation: session, revision: revision, input: input, promptVersion: profile.versionLabel)) else { return }
        state.previous = [text]; consumed.append(id.uuidString)
        state.replyPending = true; state.replyError = nil; state.error = nil
        tasks[id] = Task {
            defer { tasks[id] = nil; state.pendingRequests = tasks.count }
            do { try await generateReply(input, route: .agentTask, id: id, roundID: "manual", prompts: profile, session: session) }
            catch {
                guard session == generation else { return }
                record("manual_request_error", error.localizedDescription)
                if consumed.last == id.uuidString {
                    state.replyPending = false; state.replyError = error.localizedDescription
                    state.error = error.localizedDescription; state.phase = "请求失败"
                }
            }
        }
        state.pendingRequests = tasks.count
    }

    private func generateReply(_ input: DecisionInput, route: AssistantRoute, id: UUID, roundID: String,
                               prompts: PromptProfile, session: UUID) async throws {
        guard let replies else { return }
        state.replyPending = true; state.replyError = nil
        state.phase = route == .glassesHint ? "正在生成眼镜短提示" : "正在处理模型任务"
        let context = AssistantRequestContext(id: id, prompts: prompts, onToolEvent: { event in
            try await self.acceptToolEvent(event, session: session)
        }, onModelRequest: { request in
            try await self.acceptModelRequest(request, session: session)
        })
        let reply = try await replies.reply(to: input, route: route, context: context)
        guard session == generation, state.running else { return }
        guard record("reply", ReplyRecord(id: id, route: route, reply: reply)) else { return }
        // Earlier tasks remain in the dataset, but cannot replace a newer task's visible result.
        guard consumed.last == id.uuidString else { return }
        state.output = reply.text; state.outputID = id; state.outputRoute = route
        state.outputRoundID = roundID
        state.outputPromptVersion = prompts.versionLabel
        state.replyPending = false; state.phase = "结果已返回"
    }

    private func acceptToolEvent(_ event: AssistantToolEvent, session: UUID) throws {
        guard session == generation, state.running else { throw CancellationError() }
        guard record("tool_event", event) else { throw AssistantFailure("工具执行日志写入失败，停止派发") }
        state.toolEvents.append(event)
        if state.toolEvents.count > 50 { state.toolEvents.removeFirst(state.toolEvents.count - 50) }
    }

    private func acceptModelRequest(_ request: AssistantModelRequest, session: UUID) throws {
        guard session == generation, state.running else { throw CancellationError() }
        guard record("model_request", request) else { throw AssistantFailure("模型请求日志写入失败，已停止调用") }
    }

    @discardableResult private func record<T: Encodable>(_ event: String, _ value: T) -> Bool {
        do { try journal?.write(event, data: value); return true }
        catch {
            state.error = "数据集写入失败：\(error.localizedDescription)"; state.phase = "记录失败，已停止派发"
            state.running = false; state.replyPending = false; return false
        }
    }
}

private struct DecisionSnapshot: Encodable { let id: UUID; let generation: UUID; let revision: Int; let input: DecisionInput; let promptVersion: String }
private struct Evaluation: Encodable { let id: UUID; let revision: Int; let result: ChoiceResult }
private struct Consumption: Encodable { let id: UUID; let route: AssistantRoute; let input: DecisionInput }
private struct ReplyRecord: Encodable { let id: UUID; let route: AssistantRoute; let reply: GeneratedReply }
private struct RequestFailure: Encodable { let id: UUID; let revision: Int; let message: String }
private struct SessionConfiguration: Encodable {
    let schema: String; let questionVersion: String; let decisionModel: String; let asrModel: String; let agentModel: String
    let thresholds: AssistantThresholds
    let prompts: PromptProfile
}

/// Only used inside AssistantEngine's actor, making each JSONL append atomic with respect to other events.
private final class DatasetJournal {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AssistantFailure("无法创建数据集文件")
        }
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    }
    func write<T: Encodable>(_ event: String, data: T) throws {
        var bytes = try encoder.encode(JournalEntry(timestamp: Date(), event: event, data: data))
        bytes.append(0x0a); try handle.write(contentsOf: bytes)
    }
    deinit { try? handle.close() }
}
private struct JournalEntry<T: Encodable>: Encodable { let timestamp: Date; let event: String; let data: T }
