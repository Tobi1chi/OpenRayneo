// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import AssistantCore
import Foundation
import SwiftUI

enum AssistantCaptureSource: String, CaseIterable, Identifiable {
    case native = "原生助手唤醒", realtime = "实时提示双麦", lifeLog = "AlwaysOn（对照）"
    var id: String { rawValue }
}

@MainActor
final class DesktopAssistant: ObservableObject {
    @Published private(set) var state = AssistantState()
    @Published private(set) var active = false
    @Published private(set) var live = false
    @Published private(set) var stopping = false
    @Published private(set) var starting = false
    @Published private(set) var startingAudio = false
    @Published private(set) var importing = false
    @Published private(set) var receivedAudioPackets = 0
    @Published private(set) var receivedAudioSeconds = 0.0
    @Published private(set) var asrStatus = "尚未接收音频"
    @Published private(set) var lastUtterance = ""
    @Published private(set) var error: String?
    @Published private(set) var replySending = false
    @Published private(set) var replyDeliveryStatus = "尚无待发送回复"
    @Published var sentenceText = ""
    @Published var sendRepliesToGlasses = true
    @Published var modelExperiment = false
    @Published var replyClearAfterSeconds = UserDefaults.standard.integer(forKey: "assistantReplyClearAfterSeconds") {
        didSet { UserDefaults.standard.set(replyClearAfterSeconds, forKey: "assistantReplyClearAfterSeconds") }
    }
    @Published var captureSource: AssistantCaptureSource = .realtime
    @Published var preserveLifeLogAudio = false
    @Published var lifeLogVADDelay = 2
    @Published var microphoneChannel = 3
    @Published var completeProbability = 0.85
    @Published var completeConfidence = 0.8
    @Published var routeProbability = 0.7
    @Published var routeConfidence = 0.7
    let promptStore = PromptProfileStore()
    @Published private(set) var applyingPrompts = false
    @Published private(set) var promptStatus = ""
    @Published var trialCurrentText = ""
    @Published var trialPreviousText = ""
    @Published private(set) var trialRunning = false
    @Published private(set) var trialResult: PromptTrialResult?
    @Published private(set) var trialError: String?
    @Published private(set) var trialSamples: [DecisionInput] = []
    @Published var trialSampleIndex = 0
    private var trialTask: Task<Void, Never>?
    private var trialGeneration = UUID()
    var configuration: AssistantConfiguration { ProviderCredentials.configuration(runtime: promptStore.saved.runtimeSettings) }
    private var sessionConfiguration: AssistantConfiguration?
    private var engine: AssistantEngine?
    private var sentenceSequence: ASRSentenceSequence?
    private var monitor: Task<Void, Never>?
    private var importer: Task<Void, Never>?
    private var rounds: [String: any DesktopVoiceRound] = [:]
    private var cursor = 0
    private var attemptedReplyID: UUID?
    private var replyDeliveryTask: Task<Void, Never>?
    private weak var conversationBridge: DesktopBridge?
    private var pendingNativeWakeID: String?
    private var realtimeSID: String?
    private var captureRounds = Set<String>()
    private var sessionID = UUID()
    private var pollingAudio = false
    private var activeSource: AssistantCaptureSource = .realtime
    private var startedRounds = Set<String>()

    var environmentStatus: String {
        [("OpenAI", configuration.openAIKey), ("百炼", configuration.bailianKey), ("DeepSeek", configuration.deepSeekKey)]
            .map { "\($0.0)：\($0.1.isEmpty ? "未配置" : "已配置")" }.joined(separator: " · ")
    }

    func answerNativeWake(bridge: DesktopBridge) {
        guard !stopping, !importing, bridge.nativeAssistantActive, let id = bridge.nativeWakeID else { return }
        // A new native round waits for the previous native PCM feed to drain. Other sources keep ownership.
        guard !live || activeSource == .native else { return }
        pendingNativeWakeID = id
        if active { resumePendingNativeWake(bridge: bridge) }
        else { start(bridge: bridge, nativeCapture: true) }
    }

    private func resumePendingNativeWake(bridge: DesktopBridge) {
        guard let id = pendingNativeWakeID else { return }
        guard bridge.nativeAssistantActive, bridge.nativeWakeID == id else { pendingNativeWakeID = nil; return }
        guard active, !live, !starting, !startingAudio, !stopping, !importing else { return }
        pendingNativeWakeID = nil
        captureSource = .native
        startCapture(bridge: bridge, duration: 60)
    }

    func start(bridge: DesktopBridge, nativeCapture: Bool = false) {
        guard !active, !stopping, !starting else { return }
        promptStore.reloadIfUnchanged()
        starting = true
        Task {
            defer { starting = false }
            do {
                let configuration = self.configuration
                guard !modelExperiment || configuration.missingDecisionKeys.isEmpty else {
                    throw AssistantFailure("缺少：" + configuration.missingDecisionKeys.joined(separator: "、") + "。请在模型配置中填写 API 密钥。")
                }
                let thresholds = AssistantThresholds(completeProbability: completeProbability, completeConfidence: completeConfidence,
                    routeProbability: routeProbability, routeConfidence: routeConfidence)
                guard [completeProbability, completeConfidence, routeProbability, routeConfidence].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw AssistantFailure("概率和置信度阈值应在0至1之间")
                }
                let core: AssistantEngine
                if modelExperiment {
                    let cloud = CloudModels(configuration: configuration, tools: bridge.homeContent)
                    core = AssistantEngine(decisions: cloud, replies: cloud, thresholds: thresholds, prompts: promptStore.saved)
                } else {
                    core = AssistantEngine(prompts: promptStore.saved)
                }
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("OpenRayneo/AssistantDatasets")
                try await core.start(logURL: folder.appendingPathComponent("\(UUID().uuidString).jsonl"))
                conversationBridge = bridge; lastUtterance = ""
                engine = core; sessionConfiguration = configuration; sessionID = UUID(); active = true; error = nil; attemptedReplyID = nil
                realtimeSID = nil; replyDeliveryStatus = "尚无待发送回复"
                let generation = sessionID
                sentenceSequence = ASRSentenceSequence { [weak self] sentence in
                    await core.accept(sentence)
                    await self?.receiveTranscript(sentence, generation: generation)
                }
                state = await core.snapshot()
                monitor = Task { [weak self, weak bridge] in
                    while !Task.isCancelled {
                        guard let self, let bridge else { return }
                        await self.refresh(bridge: bridge)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                if nativeCapture {
                    pendingNativeWakeID = nil
                    captureSource = .native
                    startCapture(bridge: bridge, duration: 60)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func savePrompts() async {
        guard !applyingPrompts else { return }
        applyingPrompts = true; defer { applyingPrompts = false }
        do {
            let profile = try promptStore.save()
            try await engine?.updatePrompts(profile)
            promptStatus = "r\(profile.revision) 已保存，提示词从下一条新整句生效；ASR 提示从下一轮生效，模型与运行时设置从下次启动助手生效。"
        } catch { promptStatus = "保存或应用失败：\(error.localizedDescription)" }
    }

    func runPromptTrial(bridge: DesktopBridge) {
        guard !trialRunning else { return }
        let profile = promptStore.draft
        let input = DecisionInput(previous: trialPreviousText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                                  current: trialCurrentText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard !input.currentSentences.isEmpty else { trialError = "请至少输入一个当前整句"; return }
        trialGeneration = UUID(); let generation = trialGeneration
        let thresholds = AssistantThresholds(completeProbability: completeProbability, completeConfidence: completeConfidence,
            routeProbability: routeProbability, routeConfidence: routeConfidence)
        trialRunning = true; trialError = nil; trialResult = nil
        trialTask = Task {
            defer { if generation == trialGeneration { trialRunning = false; trialTask = nil } }
            do {
                let cloud = CloudModels(configuration: ProviderCredentials.configuration(runtime: profile.runtimeSettings), tools: bridge.homeContent)
                let result = try await PromptTrial.run(input: input, profile: profile, thresholds: thresholds, cloud: cloud)
                guard generation == trialGeneration, !Task.isCancelled else { return }
                trialResult = result
            } catch {
                if generation == trialGeneration, !Task.isCancelled { trialError = error.localizedDescription }
            }
        }
    }

    func cancelPromptTrial() {
        trialGeneration = UUID(); trialTask?.cancel(); trialTask = nil; trialRunning = false
    }

    func loadTrialSamples() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            trialSamples = text.components(separatedBy: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["event"] as? String == "decision_input", let data = object["data"] as? [String: Any],
                      let input = data["input"], let bytes = try? JSONSerialization.data(withJSONObject: input) else { return nil }
                return try? JSONDecoder().decode(DecisionInput.self, from: bytes)
            }
            trialSampleIndex = 0
            if let input = trialSamples.first { useTrialSample(input) }
            else { trialError = "文件中没有可识别的 decision_input 样本" }
        } catch { trialError = "读取样本失败：\(error.localizedDescription)" }
    }

    func useTrialSample(_ input: DecisionInput) {
        trialPreviousText = input.previousSuccessfulSentences.joined(separator: "\n")
        trialCurrentText = input.currentSentences.joined(separator: "\n")
    }

    func exportTrialResult() {
        guard let trialResult else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OpenRayneo-prompt-trial.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(trialResult).write(to: url, options: .atomic)
        } catch { trialError = "导出失败：\(error.localizedDescription)" }
    }

    func submitMessage() {
        let text = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !live, !importing, !startingAudio, !stopping, let engine, !text.isEmpty else { return }
        sentenceText = ""; lastUtterance = text
        Task {
            await engine.ask(text)
            if !modelExperiment { await publishAgentInput(text: text, roundID: "manual", kind: "manual") }
        }
    }

    func submitSentence() {
        let text = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !live, !importing, !startingAudio, !stopping, let engine, !text.isEmpty else { return }
        sentenceText = ""
        Task {
            await engine.accept(Sentence(id: UUID().uuidString, text: text, roundID: "manual"))
            if !modelExperiment { await publishAgentInput(text: text, roundID: "manual", kind: "manual") }
        }
    }

    func startCapture(bridge: DesktopBridge, duration: Int) {
        guard active, !live, !stopping, !startingAudio, !importing else { return }
        startingAudio = true
        Task {
            defer { startingAudio = false }
            do {
                if DesktopASRPolicy.current == .cloud, configuration.bailianKey.isEmpty { throw AssistantFailure("缺少 BAILIAN_API_KEY / DASHSCOPE_API_KEY") }
                cursor = 0
                captureRounds = []
                receivedAudioPackets = 0; receivedAudioSeconds = 0
                activeSource = captureSource
                if activeSource == .native {
                    realtimeSID = try await bridge.startAssistantNative(duration: duration)
                } else if activeSource == .realtime {
                    realtimeSID = try await bridge.startAssistantRealtime(duration: duration, channel: microphoneChannel == 3 ? 1 : microphoneChannel, stereo: microphoneChannel == 3)
                } else {
                    realtimeSID = nil
                    try await bridge.startAssistantLifeLog(duration: duration, preserveAudio: preserveLifeLogAudio, vadDelay: lifeLogVADDelay)
                }
                await engine?.recordASR("capture_source", data: "\(activeSource.rawValue); channel=\(microphoneChannel); preserveLifeLogAudio=\(activeSource == .lifeLog && preserveLifeLogAudio)")
                live = true; error = nil
                asrStatus = activeSource == .native ? "正在接收原生助手音频" : activeSource == .realtime ? "实时提示页已打开，等待双麦音频" : "AlwaysOn 待命，等待眼镜语音触发"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func refresh(bridge: DesktopBridge) async {
        guard !stopping, let engine else { return }
        if live {
            let drained: Bool
            do { drained = try await pollAudio(bridge: bridge) }
            catch { self.error = error.localizedDescription; await stop(bridge: bridge); return }
            guard !stopping else { return }
            if drained {
                live = false
                for round in rounds.values { await round.finish() }
                asrStatus = "采集结束，等待剩余识别结果"
            }
        }
        resumePendingNativeWake(bridge: bridge)
        let generation = sessionID
        state = await engine.snapshot()
        guard !stopping, active, generation == sessionID else { return }
        if !state.running, active { await stop(bridge: bridge); return }
        if let id = state.outputID, attemptedReplyID != id, !replySending {
            if !sendRepliesToGlasses || (!live && activeSource != .native) || !captureRounds.contains(state.outputRoundID ?? "") {
                attemptedReplyID = id
                replyDeliveryStatus = !sendRepliesToGlasses ? "自动发送已关闭，回复保留在 Mac" : "回复不属于当前进行中的眼镜采集，保留在 Mac"
                await engine.recordASR("reply_send_skipped", data: "id=\(id); \(replyDeliveryStatus)")
            } else { sendReply(bridge: bridge) }
        }
        for (id, round) in rounds where await round.isFinished() { rounds[id] = nil }
    }

    var canSendReply: Bool {
        active && (live || activeSource == .native) && !stopping && !replySending && state.outputID != nil && !state.output.isEmpty
            && captureRounds.contains(state.outputRoundID ?? "")
    }

    func sendReply(bridge: DesktopBridge) {
        guard canSendReply, let id = state.outputID, let engine else { return }
        let generation = sessionID, source = activeSource, sid = realtimeSID
        let query = state.previous.joined(separator: " ")
        let text = state.output, route = state.outputRoute?.rawValue ?? "unknown"
        let context = "id=\(id); route=\(route); source=\(source.rawValue); sid=\(sid ?? "none")"
        attemptedReplyID = id; replySending = true; replyDeliveryStatus = "正在发送到眼镜…"
        replyDeliveryTask = Task {
            defer { if generation == sessionID { replySending = false; replyDeliveryTask = nil } }
            do {
                try Task.checkCancellation()
                let channel = try await bridge.displayAssistantReply(text, source: source, sid: sid, clearAfterMilliseconds: max(0, min(600, replyClearAfterSeconds)) * 1000, query: query)
                try Task.checkCancellation()
                await engine.recordASR("reply_sent", data: "\(context); channel=\(channel); visible=unverified")
                guard generation == sessionID, !stopping, state.outputID == id else { return }
                replyDeliveryStatus = channel == "native_assistant" ? "已写入原生助手通道，眼镜显示待确认" : channel == "realtime_prompt" ? "已写入实时提示通道，眼镜显示待确认" : "已发送通知，眼镜显示待确认"
            } catch {
                await engine.recordASR(Task.isCancelled ? "reply_send_cancelled" : "reply_send_failed", data: "\(context); \(error.localizedDescription)")
                guard generation == sessionID, !stopping, state.outputID == id else { return }
                replyDeliveryStatus = "发送失败：\(error.localizedDescription)；可点击重新发送"
            }
        }
    }

    @discardableResult private func pollAudio(bridge: DesktopBridge, allowDuringStop: Bool = false) async throws -> Bool {
        guard !pollingAudio else { return false }
        pollingAudio = true; defer { pollingAudio = false }
        let data = try await bridge.assistantAudioEvents(after: cursor, source: activeSource)
        guard !stopping || allowDuringStop else { return false }
        if let audio = data["audioStatus"] as? [String: Any] {
            receivedAudioPackets = audio["audioPackets"] as? Int ?? 0
            receivedAudioSeconds = audio["decodedSeconds"] as? Double ?? 0
            if let failure = audio["error"] as? String { error = failure }
        }
        if data["overflow"] as? Bool == true {
            let limit = data["bufferLimitSeconds"] as? Int ?? 15
            await engine?.recordASR("audio_buffer_overflow", data: "source=\(activeSource.rawValue); limitSeconds=\(limit); overflowPCMBytes=\(data["overflowPCMBytes"] as? Int ?? 0)")
            throw AssistantFailure("本机音频交接超过\(limit)秒缓存上限，采集已停止；本轮不能视为完整")
        }
        let events = data["events"] as? [[String: Any]] ?? []
        let batchBytes = events.reduce(0) { $0 + ($1["pcmByteCount"] as? Int ?? 0) }
        if batchBytes > 0 {
            await engine?.recordASR("audio_batch", data: "source=\(activeSource.rawValue); pcmBytes=\(batchBytes); peakBufferedPCMBytes=\(data["peakBufferedPCMBytes"] as? Int ?? 0); limitSeconds=\(data["bufferLimitSeconds"] as? Int ?? 15)")
        }
        for event in events {
            guard let sequence = event["sequence"] as? Int, sequence > cursor,
                  let kind = event["kind"] as? String, let id = event["round"] as? String else { continue }
            switch kind {
            case "begin":
                captureRounds.insert(id)
                let language = event["language"] as? String
                // Only live native capture is a wake round; file imports keep full speaker analysis.
                let round = try await makeRound(id, language: language, channels: event["channels"] as? Int ?? 1, nativeWake: activeSource == .native)
                rounds[id] = round
                asrStatus = language.map { "ASR \($0) 新流已就绪，等待音频；旧流继续排空" }
                    ?? "音频会话已就绪，等待眼镜音频包"
            case "pcm":
                guard let round = rounds[id], let encoded = event["pcm"] as? String, let pcm = Data(base64Encoded: encoded) else {
                    throw AssistantFailure("音频缺少对应 ASR 轮次")
                }
                if startedRounds.insert(id).inserted { try await round.start() }
                try await round.appendPCM(pcm)
                asrStatus = "正在流式识别眼镜音频"
            case "end":
                await rounds[id]?.finish()
                asrStatus = activeSource == .native ? "原生收音结束，等待最后整句与回复" : activeSource == .realtime ? "实时音频结束，等待最后整句" : "一轮结束，等待最终整句；AlwaysOn 继续待命"
            case "gap": throw AssistantFailure("眼镜音频丢包或解码失败，本轮不能视为连续完整音频")
            default: break
            }
            if let engine, let raw = try? JSONSerialization.data(withJSONObject: event.filter { $0.key != "pcm" }) {
                await engine.recordASR("audio_round", data: String(decoding: raw, as: UTF8.self))
            }
            cursor = sequence
        }
        return data["drained"] as? Bool == true
    }

    private func makeRound(_ id: String, inputMode: ASRAudioInputMode? = nil, language: String? = nil, channels: Int = 1, selectedChannel: Int? = nil,
                           nativeWake: Bool = false) async throws -> any DesktopVoiceRound {
        let core = engine!, generation = sessionID, sequence = sentenceSequence!
        await sequence.begin(id)
        let mode = inputMode ?? (activeSource == .lifeLog ? .buffered : .realtime)
        let profile = promptStore.saved
        var settings = profile.asr
        if let language {
            // Qwen's existing run-task interface accepts language_hints (ISO language codes).
            // Language changes create a new task; there is no invented in-stream update command.
            settings.languageHints = [language.components(separatedBy: "-")[0]]
        }
        if let data = try? JSONEncoder().encode(settings) {
            await core.recordASR("asr_configuration", data: "round=\(id); profile=\(profile.versionLabel); settings=\(String(decoding: data, as: UTF8.self))")
        }
        let people = try LocalVoiceStore.load()
        let selfPerson = channels == 2 || nativeWake ? try LocalVoiceStore.ensureSelf() : nil
        var selfLearned: (@Sendable (String) async -> Void)?
        if nativeWake && LocalVoiceSelfLearning.enabled {
            selfLearned = { @Sendable (message: String) async in await core.recordASR("self_voice_learn", data: "round=\(id); \(message)") }
        }
        return try DesktopChannelRound(configuration: sessionConfiguration ?? configuration, roundID: id, inputMode: mode, settings: settings,
            policy: DesktopASRPolicy.current, channels: channels,
            selectedChannel: selectedChannel ?? (activeSource == .realtime && microphoneChannel != 3 ? max(1, microphoneChannel) : nil),
            people: people, selfPerson: selfPerson, nativeWake: nativeWake,
            selfLearned: selfLearned,
            finalSentence: { sentence in
            await sequence.accept(sentence)
        }, diagnostic: { [weak self] message in
            await core.recordASR("asr_error", data: message)
            await self?.reportASRError(message, generation: generation)
        }, completed: { await sequence.finish(id) }, statistics: { stats in
            if let data = try? JSONEncoder().encode(stats) {
                await core.recordASR("asr_audio_stats", data: String(decoding: data, as: UTF8.self))
            }
        }, backendChanged: { [weak self] message in
            await core.recordASR("asr_backend", data: message)
            await self?.updateASRBackend(message, generation: generation)
        })
    }

    private func receiveTranscript(_ sentence: Sentence, generation: UUID) async {
        guard generation == sessionID, active, !stopping,
              !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if captureRounds.contains(sentence.roundID) { lastUtterance = sentence.text }
        if !modelExperiment { await publishAgentInput(text: sentence.text, roundID: sentence.roundID, kind: "asr_final", sentenceID: sentence.id, sentence: sentence) }
        guard activeSource == .native, realtimeSID == sentence.roundID,
              let bridge = conversationBridge, bridge.nativeAssistantActive,
              bridge.nativeWakeID == sentence.roundID else { return }
        do {
            _ = try await bridge.request("/v1/assistant/native/asr",
                body: ["wakeID": sentence.roundID, "text": sentence.text, "final": true], timeout: 3)
            await engine?.recordASR("native_asr_sent", data: "round=\(sentence.roundID); visible=unverified")
        } catch {
            await engine?.recordASR("native_asr_send_failed", data: "round=\(sentence.roundID); \(error.localizedDescription)")
            if generation == sessionID, realtimeSID == sentence.roundID, bridge.nativeWakeID == sentence.roundID {
                self.error = "原生识别文字回送失败：" + error.localizedDescription
            }
        }
    }

    private func publishAgentInput(text: String, roundID: String, kind: String, sentenceID: String = UUID().uuidString, sentence: Sentence? = nil) async {
        guard let bridge = conversationBridge else { return }
        var event: [String: Any] = ["text": text, "sessionID": sessionID.uuidString, "roundID": roundID,
            "sentenceID": sentenceID, "kind": kind, "source": activeSource == .native ? "NATIVE" : activeSource == .lifeLog ? "ALWAYS_ON_TEST" : "REALTIME"]
        if let sentence {
            event["sourceChannel"] = sentence.sourceChannel; event["identityBasis"] = sentence.identityBasis
            event["personId"] = sentence.personId; event["speaker"] = sentence.speaker
            event["beginMS"] = sentence.beginMS; event["endMS"] = sentence.endMS
            if let turns = sentence.speakerTurns { event["speakerTurns"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(turns)) }
        }
        if captureRounds.contains(roundID) {
            if activeSource == .native {
                event["replyTarget"] = ["path": "/v1/assistant/native/reply", "wakeID": roundID]
            } else if activeSource == .realtime, let sid = realtimeSID {
                event["replyTarget"] = ["path": "/v1/prompts/text", "sid": sid]
            }
        }
        do { _ = try await bridge.request("/v1/agent/events", body: event, timeout: 5) }
        catch { self.error = "本机 Agent 输入交付失败：" + error.localizedDescription }
    }

    private func reportASRError(_ message: String, generation: UUID) {
        if sessionID == generation { error = message }
    }
    private func updateASRBackend(_ message: String, generation: UUID) {
        if sessionID == generation { asrStatus = message }
    }

    func importAudio() {
        guard active, !live, !startingAudio, importer == nil, !stopping else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        importer = Task {
            defer { importer = nil; importing = false }
            var importingRound: (any DesktopVoiceRound)?
            do {
                let reader = try LocalVoiceAudioReader(url: url, channel: microphoneChannel)
                let id = UUID().uuidString, round = try await makeRound(id, inputMode: .realtime,
                    channels: reader.outputChannels, selectedChannel: microphoneChannel == 3 ? nil : max(1, microphoneChannel)); rounds[id] = round
                importingRound = round
                try await round.start(); asrStatus = "正在识别导入音频"
                while let samples = try reader.nextChannels() {
                    try Task.checkCancellation()
                    try await round.appendPCM(LocalVoiceAudioReader.encodePCM16(samples))
                    try await Task.sleep(nanoseconds: UInt64(samples[0].count) * 1_000_000_000 / 16000)
                }
                await round.finish(); asrStatus = "音频已发送，等待最后整句"
                while !(await round.isFinished()) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                asrStatus = "音频识别已完成"
            } catch { await importingRound?.finish(); if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    func stop(bridge: DesktopBridge) async {
        if stopping {
            while stopping { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        stopping = true; pendingNativeWakeID = nil; defer { stopping = false }
        if replySending { replyDeliveryStatus = "发送已中止，回复保留在 Mac" }
        replyDeliveryTask?.cancel()
        await replyDeliveryTask?.value
        // A start already in flight must settle before the stop can own and drain its audio session.
        while starting || startingAudio { try? await Task.sleep(nanoseconds: 50_000_000) }
        importer?.cancel(); importer = nil
        await engine?.suspendDispatch()
        while pollingAudio { try? await Task.sleep(nanoseconds: 50_000_000) }
        if live {
            do {
                try await bridge.stopAssistantCapture(source: activeSource)
                let deadline = Date().addingTimeInterval(4)
                var drained = false
                repeat {
                    drained = try await pollAudio(bridge: bridge, allowDuringStop: true)
                    if !drained { try? await Task.sleep(nanoseconds: 50_000_000) }
                } while !drained && Date() < deadline
                if !drained { throw AssistantFailure("本机音频收尾超时，最后片段可能不完整") }
            } catch {
                self.error = error.localizedDescription
                await engine?.recordASR("audio_drain_error", data: error.localizedDescription)
            }
        }
        live = false; realtimeSID = nil; conversationBridge = nil
        var finishWaitSeconds = 16
        for round in rounds.values {
            await round.finish()
            finishWaitSeconds = max(finishWaitSeconds, await round.maximumFinishWaitSeconds)
        }
        let deadline = Date().addingTimeInterval(Double(finishWaitSeconds))
        while !rounds.isEmpty, Date() < deadline {
            for (id, round) in rounds where await round.isFinished() { rounds[id] = nil }
            if !rounds.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        for round in rounds.values { await round.cancel() }
        rounds = [:]; startedRounds = []; await engine?.stop()
        if let engine { state = await engine.snapshot() }
        active = false; monitor?.cancel(); monitor = nil; asrStatus = "已停止，收尾结果保留在数据集"
    }
}
