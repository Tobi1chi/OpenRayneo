// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One instance per audio round. Takes 16 kHz mono signed little-endian PCM16.
public actor QwenASR {
    private let configuration: AssistantConfiguration
    private let roundID: String
    private let inputMode: ASRAudioInputMode
    private let settings: ASRPromptSettings
    private let finalSentence: @Sendable (Sentence) async -> Void
    private let diagnostic: @Sendable (String) async -> Void
    private let completed: @Sendable () async -> Void
    private let statistics: @Sendable (ASRAudioStatistics) async -> Void
    private let taskID = UUID().uuidString
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var completionDelivered = false
    private var finishRequested = false
    private var pending = Data()
    private var pump: Task<Void, Never>?
    private var finishSent = false
    private var receivedPCMBytes = 0
    private var sentPCMBytes = 0
    private var peakPendingPCMBytes = 0
    private let session = URLSession(configuration: .ephemeral)
    public init(configuration: AssistantConfiguration, roundID: String, inputMode: ASRAudioInputMode = .realtime, settings: ASRPromptSettings = .init(),
                finalSentence: @escaping @Sendable (Sentence) async -> Void,
                diagnostic: @escaping @Sendable (String) async -> Void,
                completed: @escaping @Sendable () async -> Void = {},
                statistics: @escaping @Sendable (ASRAudioStatistics) async -> Void = { _ in }) {
        self.configuration = configuration; self.roundID = roundID; self.inputMode = inputMode; self.settings = settings
        self.finalSentence = finalSentence; self.diagnostic = diagnostic
        self.completed = completed; self.statistics = statistics
    }

    public func start() async throws {
        guard socket == nil, !finished else { return }
        guard !configuration.bailianKey.isEmpty else { throw AssistantFailure("缺少 BAILIAN_API_KEY / DASHSCOPE_API_KEY") }
        guard let address = configuration.asrURL, address.scheme == "wss", address.host != nil else {
            throw AssistantFailure("百炼 ASR 地址必须是有效 wss 地址")
        }
        var request = URLRequest(url: address); request.timeoutInterval = configuration.runtime.asrConnectionTimeoutSeconds
        request.setValue("Bearer \(configuration.bailianKey)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); self.socket = socket; socket.resume()
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16000, "intermediate_result_enabled": false,
            "disfluency_removal_enabled": false, "heartbeat": true, "vad_model": settings.nearField ? "near_meeting_16k" : "far_field_meeting_16k"]
        let languages = settings.languageHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !languages.isEmpty { parameters["language_hints"] = languages }
        var vocabulary: [String: Int] = [:]
        for word in settings.hotwords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { vocabulary[trimmed] = 3 }
        }
        if !vocabulary.isEmpty { parameters["vocabulary"] = vocabulary }
        var input: [String: Any] = [:]
        if !settings.context.isEmpty {
            input["context"] = [["role": "user", "content": [["type": "input_text", "text": settings.context]]]]
        }
        try await sendJSON(["header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": configuration.asrModel,
                        "parameters": parameters, "input": input]])
        receiveTask = Task { await self.receive() }
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { await self.checkStartTimeout() }
        }
    }

    public func appendPCM(_ bytes: Data) async throws {
        guard !finished, !finishRequested else { throw AssistantFailure("ASR 轮次已经结束") }
        guard bytes.count <= inputMode.bufferLimitBytes - pending.count else {
            throw AssistantFailure("云端 ASR 待发送音频超过\(inputMode.bufferLimitSeconds)秒缓存上限，本轮音频不完整")
        }
        pending.append(bytes)
        receivedPCMBytes += bytes.count; peakPendingPCMBytes = max(peakPendingPCMBytes, pending.count)
        schedulePump()
    }

    public func finish() async {
        guard !finished, !finishRequested else { return }
        if socket == nil { close(); return }
        finishRequested = true
        schedulePump()
        timeoutTask?.cancel()
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(inputMode.drainTimeoutSeconds) * 1_000_000_000)
            if !Task.isCancelled { await self.fail("ASR 音频发送排空超时，剩余音频未完整送出") }
        }
    }

    public func cancel() { close() }
    public func isFinished() -> Bool { finished && completionDelivered }
    public var maximumFinishWaitSeconds: Int { inputMode.maximumFinishWaitSeconds }

    private func receive() async {
        do {
            while !finished, let socket {
                let message = try await socket.receive()
                let bytes: Data
                switch message { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: continue }
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let header = object["header"] as? [String: Any], header["task_id"] as? String == taskID else { continue }
                switch header["event"] as? String {
                case "task-started":
                    started = true
                    if !finishRequested { timeoutTask?.cancel() }
                    schedulePump()
                case "result-generated":
                    let payload = object["payload"] as? [String: Any] ?? [:]
                    if let output = payload["output"] as? [String: Any], let sentence = output["sentence"] as? [String: Any],
                       sentence["sentence_end"] as? Bool == true, sentence["heartbeat"] as? Bool != true,
                       let text = sentence["text"] as? String, let id = sentence["sentence_id"] as? Int {
                        await finalSentence(Sentence(id: "\(roundID):\(id)", text: text, roundID: roundID,
                            beginMS: sentence["begin_time"] as? Int, endMS: sentence["end_time"] as? Int))
                    }
                case "task-finished": close()
                case "task-failed": await fail("百炼 ASR task-failed：\(header["error_code"] as? String ?? "unknown")")
                default: break
                }
            }
        } catch { if !finished { await fail("百炼 ASR 连接失败或提前断开；本轮音频未完整识别") } }
    }

    private func schedulePump() {
        guard started, !finished, pump == nil else { return }
        pump = Task { await self.sendPending() }
    }
    private func sendPending() async {
        defer { pump = nil }
        do {
            let chunk = 6400 // 200 ms at 16 kHz PCM16; only this task sends audio and finish.
            while !finished, let socket {
                if pending.count >= chunk || (finishRequested && !pending.isEmpty) {
                    let count = min(chunk, pending.count), data = Data(pending.prefix(count))
                    pending.removeFirst(count)
                    try await socket.send(.data(data))
                    if !finished { sentPCMBytes += count }
                } else if finishRequested && !finishSent {
                    finishSent = true
                    try await sendJSON(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": ["input": [:]]])
                    guard !finished else { return }
                    timeoutTask?.cancel()
                    timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        if !Task.isCancelled { await self.finishTimeout() }
                    }
                    return
                } else { return }
            }
        } catch { if !finished { await fail("ASR 音频或收尾发送失败") } }
    }
    private func sendJSON(_ value: [String: Any]) async throws {
        guard let socket else { throw AssistantFailure("ASR 未连接") }
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)))
    }
    private func checkStartTimeout() async { if !started && !finished { await fail("百炼 ASR 启动超时") } }
    private func finishTimeout() async { if !finished { await fail("百炼 ASR 收尾超时，剩余文字可能不完整") } }
    private func fail(_ message: String) async { close(error: message) }
    private func close(error: String? = nil) {
        guard !finished else { return }
        finished = true; timeoutTask?.cancel(); receiveTask?.cancel(); pump?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel(); pending = Data()
        let stats = ASRAudioStatistics(roundID: roundID, receivedPCMBytes: receivedPCMBytes, sentPCMBytes: sentPCMBytes,
            peakPendingPCMBytes: peakPendingPCMBytes, bufferLimitSeconds: inputMode.bufferLimitSeconds, finishSent: finishSent)
        Task {
            if let error { await diagnostic(error) }
            await statistics(stats)
            await completed()
            self.completionDelivered = true
        }
    }
}
