// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import AssistantCore
import Foundation

/// Cloud streaming with a bounded PCM replay buffer, or VAD-driven offline Whisper.
/// Already delivered cloud text forms a timestamp watermark when switching locally.
protocol DesktopVoiceRound: Actor {
    func start() async throws
    func appendPCM(_ bytes: Data) async throws
    func finish() async
    func cancel() async
    func isFinished() -> Bool
    var maximumFinishWaitSeconds: Int { get }
}

actor DesktopASRRound: DesktopVoiceRound {
    private let id: String
    private let policy: DesktopASRPolicy
    private let configuration: AssistantConfiguration
    private let mode: ASRAudioInputMode
    private let settings: ASRPromptSettings
    private let sentence: @Sendable (Sentence) async -> Void
    private let diagnostic: @Sendable (String) async -> Void
    private let completed: @Sendable () async -> Void
    private let statistics: @Sendable (ASRAudioStatistics) async -> Void
    private let backendChanged: @Sendable (String) async -> Void
    private var cloud: QwenASR?
    private var local = false
    private var vad: LocalASRVAD?
    private var replay = Data()
    private var replayOffset = 0
    private var receivedSamples = 0
    private var committedEnd = 0
    private var localOffset = 0
    private var queue: [LocalASRVAD.Utterance] = []
    private var pump: Task<Void, Never>?
    private var finishing = false
    private var finished = false
    private var completionDelivered = false
    private var sequence = 0

    init(configuration: AssistantConfiguration, roundID: String, inputMode: ASRAudioInputMode,
         settings: ASRPromptSettings, policy: DesktopASRPolicy,
         finalSentence: @escaping @Sendable (Sentence) async -> Void,
         diagnostic: @escaping @Sendable (String) async -> Void,
         completed: @escaping @Sendable () async -> Void,
         statistics: @escaping @Sendable (ASRAudioStatistics) async -> Void,
         backendChanged: @escaping @Sendable (String) async -> Void) {
        self.configuration = configuration; id = roundID; mode = inputMode; self.settings = settings; self.policy = policy
        sentence = finalSentence; self.diagnostic = diagnostic; self.completed = completed; self.statistics = statistics; self.backendChanged = backendChanged
    }
    func start() async throws {
        if policy == .local { try await enableLocal(reason: "使用本地 ASR"); return }
        let cloud = QwenASR(configuration: configuration, roundID: id, inputMode: mode, settings: settings,
            finalSentence: { [weak self] in await self?.cloudSentence($0) },
            diagnostic: { [weak self] in await self?.cloudFailed($0) },
            completed: { [weak self] in await self?.cloudCompleted() }, statistics: statistics)
        self.cloud = cloud
        do { try await cloud.start() }
        catch {
            if policy == .cloud { throw error }
            try await enableLocal(reason: error.localizedDescription)
        }
    }
    func appendPCM(_ bytes: Data) async throws {
        guard !finished, !finishing else { throw AssistantFailure("ASR 轮次已经结束") }
        receivedSamples += bytes.count / 2
        if local {
            guard let vad else { throw AssistantFailure("本地 ASR 未准备") }
            queue.append(contentsOf: vad.accept(LocalVoiceAudioReader.decodePCM16(bytes)))
            try checkBacklog(); schedulePump(); return
        }
        if policy == .fallback {
            replay.append(bytes)
            // Keep only uncommitted audio. A missing response never grows this buffer forever.
            if replay.count > 16000 * 2 * 30 {
                try await enableLocal(reason: "云端30秒未提交完整识别，切换本地")
                return
            }
        }
        do { try await cloud?.appendPCM(bytes) }
        catch {
            if policy == .cloud { throw error }
            try await enableLocal(reason: error.localizedDescription)
        }
    }
    private func cloudSentence(_ value: Sentence) async {
        guard !local, !finished else { return }
        if let end = value.endMS { committedEnd = max(committedEnd, end * 16) }
        let remove = min(replay.count / 2, max(0, committedEnd - replayOffset))
        if remove > 0 { replay.removeFirst(remove * 2); replayOffset += remove }
        await sentence(value)
    }
    private func cloudFailed(_ message: String) async {
        guard !local, !finished else { return }
        if policy == .cloud { await diagnostic(message); return }
        do { try await enableLocal(reason: message) }
        catch { await fail(error) }
    }
    private func cloudCompleted() async {
        guard !local, !finished else { return }
        await complete()
    }
    private func enableLocal(reason: String) async throws {
        guard !local, !finished else { return }
        guard LocalASRService.installed else { throw AssistantFailure("\(reason)；本地 ASR 尚未准备，未能兜底") }
        let detector = try LocalASRVAD()
        local = true; vad = detector; localOffset = replayOffset
        queue.append(contentsOf: detector.accept(LocalVoiceAudioReader.decodePCM16(replay)))
        replay = Data()
        await cloud?.cancel(); cloud = nil
        await backendChanged("已切换本地 Whisper tiny（ANE 优先）：\(reason)")
        if finishing { queue.append(contentsOf: detector.flush()) }
        try checkBacklog(); schedulePump()
    }
    private func checkBacklog() throws {
        if queue.reduce(0, { $0 + $1.samples.count }) > 16000 * 30 {
            throw AssistantFailure("本地 ASR 积压超过30秒，已停止本轮，避免无限缓存")
        }
    }
    private func schedulePump() {
        guard pump == nil, !finished else { return }
        pump = Task { await self.process() }
    }
    private func process() async {
        do {
            while !queue.isEmpty, !finished, !Task.isCancelled {
                var utterance = queue.removeFirst()
                let absolute = localOffset + utterance.begin
                let trim = min(utterance.samples.count, max(0, committedEnd - absolute))
                if trim > 0 { utterance.samples.removeFirst(trim) }
                guard utterance.samples.count >= 8000 else { continue }
                let result = try await LocalASRService.shared.transcribe(utterance.samples, language: settings.languageHints.first ?? "zh")
                guard !finished, !Task.isCancelled else { break }
                for segment in result {
                    let begin = absolute + trim + Int(segment.start * 16000)
                    let end = min(absolute + trim + utterance.samples.count, absolute + trim + Int(segment.end * 16000))
                    guard end > committedEnd else { continue }
                    sequence += 1; committedEnd = max(committedEnd, end)
                    await sentence(Sentence(id: "\(id):local:\(sequence)", text: segment.text, roundID: id,
                        beginMS: begin / 16, endMS: end / 16))
                }
            }
            pump = nil
            if finishing, !finished { await complete() }
        } catch { pump = nil; await fail(error) }
    }
    func finish() async {
        guard !finished, !finishing else { return }; finishing = true
        if local {
            if let vad { queue.append(contentsOf: vad.flush()) }
            schedulePump()
        } else { await cloud?.finish() }
    }
    func cancel() async {
        finished = true; pump?.cancel(); pump = nil; queue = []; replay = Data(); vad = nil
        await cloud?.cancel(); cloud = nil
        if !completionDelivered { await completed(); completionDelivered = true }
    }
    private func fail(_ error: Error) async {
        await diagnostic(error.localizedDescription); await cancel()
    }
    private func complete() async {
        guard !finished else { return }; finished = true; queue = []; replay = Data(); vad = nil
        await completed(); completionDelivered = true
    }
    func isFinished() -> Bool { finished && completionDelivered }
    var maximumFinishWaitSeconds: Int { local ? 90 : mode.maximumFinishWaitSeconds }
}
