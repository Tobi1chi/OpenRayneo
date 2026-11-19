// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import AppKit
import AssistantCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LocalVoiceLab: ObservableObject {
    @Published private(set) var people: [LocalVoicePerson] = []
    @Published private(set) var turns: [LocalSpeakerTurn] = []
    @Published private(set) var running = false
    @Published private(set) var live = false
    @Published private(set) var stopping = false
    @Published private(set) var receivedSeconds = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var status = "导入音频或手动开始眼镜收音。处理在本机完成。"
    @Published var error: String?
    @Published var sourceURL: URL?
    @Published var channel = 3
    @Published private(set) var audioChannels = 1
    @Published private(set) var channelPolicy = "full_speaker"
    @Published var enrolling = false
    @Published var transcribe = false
    @Published var threshold = Double(LocalSpeakerEngine.defaultThreshold)
    @Published var duration = 120
    @Published var name = "我"
    @Published var isSelf = true
    @Published var confirmed = false
    @Published var selectedPerson = ""
    @Published var bindingSpeaker = ""
    @Published var bindingName = ""
    @Published var bindingPerson = ""
    @Published var rememberVoice = false
    private var audio: [[Float]] = []
    private var matchingPeople: [LocalVoicePerson] = []
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var generation = UUID()
    private var player: LocalVoicePlayer?
    private weak var bridge: DesktopBridge?
    private var captureSID: String?
    private var profilesLoaded = false
    private var startedAt = Date()

    var assessment: LocalVoiceAssessment { LocalVoiceAssessment.assess(turns) }
    var speakers: [String] { Array(Set(turns.map(\.speaker).filter { $0 != "未知" && $0 != "登记" })).sorted() }
    var canSave: Bool { !running && !turns.isEmpty && (assessment.ready || confirmed && !assessment.confirmationVectors.isEmpty) }

    /// Reloads on every panel appearance: native wake rounds may have refreshed the self profile meanwhile.
    func loadPeople() {
        guard !running else { return }
        do { people = try LocalVoiceStore.load(); profilesLoaded = true }
        catch { self.error = error.localizedDescription }
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        if panel.runModal() == .OK { sourceURL = panel.url }
    }
    private func begin(live: Bool) -> UUID {
        player?.stop(); task?.cancel(); generation = UUID(); stopRequested = false
        turns = []; audio = []; receivedSeconds = 0; progress = 0; elapsed = 0; error = nil; confirmed = false
        // Wake rounds may have refreshed the self profile since the panel loaded it.
        do { people = try LocalVoiceStore.load() } catch { self.error = error.localizedDescription }
        matchingPeople = people
        running = true; self.live = live; stopping = false; status = "正在加载与 Android 相同的模型…"
        startedAt = Date()
        return generation
    }
    func analyzeFile() {
        guard !running, let url = sourceURL, profilesLoaded else { return }
        let id = begin(live: false), people = people, channel = channel, enrolling = enrolling, threshold = Float(threshold)
        task = Task.detached(priority: .userInitiated) { [self] in
            let started = Date()
            do {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let selected = enrolling && channel == 3 ? 1 : channel
                let reader = try LocalVoiceAudioReader(url: url, channel: selected)
                guard reader.duration <= 1800 else { throw AssistantFailure("测试台每次最多处理30分钟录音，请先在录音资料库剪辑选段。") }
                let selfPerson = reader.outputChannels == 2 && !enrolling ? try await MainActor.run { try LocalVoiceStore.ensureSelf() } : nil
                let engine = try ChannelSpeakerProcessor(channels: reader.outputChannels, people: people, threshold: threshold,
                    enrolling: enrolling, selfPerson: selfPerson, selectedChannel: selected == 3 ? nil : max(1, selected), offlineDiarization: true)
                await configure(channels: reader.outputChannels, policy: engine.channelPolicy, selfPerson: selfPerson, id: id)
                while let samples = try reader.nextChannels() {
                    try Task.checkCancellation()
                    let turns = await engine.accept(samples)
                    await receive(samples, turns: turns, progress: reader.progress, elapsed: Date().timeIntervalSince(started), id: id)
                }
                let final = await engine.flush()
                await receive([], turns: final, progress: 1, elapsed: Date().timeIntervalSince(started), id: id)
                try await finishTranscription(id: id)
                await complete(id: id)
            } catch is CancellationError { await cancelled(id: id) }
            catch { await failed(error, id: id) }
        }
    }
    func startLive(bridge: DesktopBridge) {
        guard !running, profilesLoaded, bridge.connected, bridge.activeSession == nil, !bridge.assistant.active else { return }
        let id = begin(live: true), people = people, enrolling = enrolling, threshold = Float(threshold), channel = channel, duration = duration
        self.bridge = bridge
        task = Task {
            let started = Date()
            do {
                let dual = channel == 3 && !enrolling
                let selfPerson = dual ? try LocalVoiceStore.ensureSelf() : nil
                let engine = try await Task.detached { try ChannelSpeakerProcessor(channels: dual ? 2 : 1, people: people,
                    threshold: threshold, enrolling: enrolling, selfPerson: selfPerson, selectedChannel: dual ? nil : max(1, channel == 3 ? 1 : channel)) }.value
                configure(channels: dual ? 2 : 1, policy: engine.channelPolicy, selfPerson: selfPerson, id: id)
                try Task.checkCancellation()
                captureSID = try await bridge.startAssistantRealtime(duration: duration, channel: channel == 3 ? 1 : channel, sampleRate: 48000, stereo: dual)
                var cursor = 0, resamplers = [LocalVoiceResampler(), LocalVoiceResampler()]
                status = enrolling ? "请本人独自自然说话，每句后停顿；结束后评估登记" : "正在本地识别说话人；结束后可回听、绑定人物"
                while !stopRequested {
                    try Task.checkCancellation()
                    guard bridge.activeSession == .assistantAudio else { throw AssistantFailure("眼镜收音已被其他功能切换，本轮已停止") }
                    let reply = try await bridge.assistantAudioEvents(after: cursor, source: .realtime)
                    if let status = reply["audioStatus"] as? [String: Any], status["sid"] as? String != captureSID {
                        throw AssistantFailure("收音会话已变化，已保留新会话")
                    }
                    if reply["overflow"] as? Bool == true { throw AssistantFailure("本地处理未跟上收音，音频已积压；本轮不完整，请停止后用录音导入对照") }
                    let events = reply["events"] as? [[String: Any]] ?? []
                    for event in events {
                        guard let sequence = event["sequence"] as? Int, sequence > cursor else { continue }
                        cursor = sequence
                        switch event["kind"] as? String {
                        case "begin": await engine.beginRound()
                        case "pcm":
                            guard let encoded = event["pcm"] as? String, let data = Data(base64Encoded: encoded) else { throw AssistantFailure("收音 PCM 缺失") }
                            let lanes = LocalVoiceAudioReader.decodePCM16Channels(data, channels: dual ? 2 : 1)
                            let samples = lanes.indices.map { resamplers[$0].convert(lanes[$0]) }
                            let turns = await engine.accept(samples)
                            receive(samples, turns: turns, progress: min(1, receivedSeconds / Double(duration)), elapsed: Date().timeIntervalSince(started), id: id)
                        case "gap": throw AssistantFailure("眼镜音频存在丢包，本轮不连续")
                        default: break
                        }
                    }
                    if reply["drained"] as? Bool == true { break }
                    if Date().timeIntervalSince(started) > Double(duration + 10) { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                // Stop the owned capture, then read its final PCM before flushing the VAD.
                if bridge.activeSession == .assistantAudio { try await bridge.stopAssistantCapture(source: .realtime, expectedSID: captureSID) }
                let tail = try await bridge.assistantAudioEvents(after: cursor, source: .realtime)
                for event in tail["events"] as? [[String: Any]] ?? [] where event["kind"] as? String == "pcm" {
                    if let encoded = event["pcm"] as? String, let data = Data(base64Encoded: encoded) {
                        let lanes = LocalVoiceAudioReader.decodePCM16Channels(data, channels: dual ? 2 : 1)
                        let samples = lanes.indices.map { resamplers[$0].convert(lanes[$0]) }
                        let turns = await engine.accept(samples)
                        receive(samples, turns: turns, progress: 1, elapsed: Date().timeIntervalSince(started), id: id)
                    }
                }
                captureSID = nil
                let final = await engine.flush()
                receive([], turns: final, progress: 1, elapsed: Date().timeIntervalSince(started), id: id)
                try await finishTranscription(id: id); complete(id: id)
            } catch is CancellationError { await stopOwnedCapture(); cancelled(id: id) }
            catch { await stopOwnedCapture(); failed(error, id: id) }
        }
    }
    func stop() {
        guard running else { return }
        if live { stopping = true; stopRequested = true; status = "正在停止并补齐尾段…" }
        else { task?.cancel() }
    }
    func suspend() async {
        task?.cancel(); await task?.value; player?.stop()
    }
    private func stopOwnedCapture() async {
        guard captureSID != nil, let bridge, bridge.activeSession == .assistantAudio else { captureSID = nil; return }
        do { try await bridge.stopAssistantCapture(source: .realtime, expectedSID: captureSID) }
        catch { self.error = error.localizedDescription }
        captureSID = nil
    }
    private func configure(channels: Int, policy: String, selfPerson: LocalVoicePerson?, id: UUID) {
        guard id == generation else { return }
        audioChannels = channels; channelPolicy = policy; audio = Array(repeating: [], count: channels)
        if let selfPerson, !people.contains(where: { $0.id == selfPerson.id }) { people.append(selfPerson) }
    }
    private func receive(_ samples: [[Float]], turns: [LocalSpeakerTurn], progress: Double, elapsed: Double, id: UUID) {
        guard id == generation else { return }
        for lane in samples.indices { audio[lane].append(contentsOf: samples[lane]) }
        self.turns = turns; receivedSeconds = Double(audio.first?.count ?? 0) / 16000
        self.progress = progress; self.elapsed = elapsed
    }
    private func finishTranscription(id: UUID) async throws {
        guard transcribe, !enrolling, id == generation else { return }
        status = "正在用本地 ASR 转写人声片段…"
        for index in turns.indices where turns[index].endMS > turns[index].beginMS {
            try Task.checkCancellation()
            let lane = audio.count == 2 ? turns[index].sourceChannel - 1 : 0
            let samples = audio[lane]
            let first = max(0, min(samples.count, Int(turns[index].beginMS * 16)))
            let last = max(first, min(samples.count, Int(turns[index].endMS * 16)))
            let result = try await LocalASRService.shared.transcribe(Array(samples[first..<last]), language: "zh")
            guard id == generation else { return }
            turns[index].text = result.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private func complete(id: UUID) {
        guard id == generation else { return }
        running = false; live = false; stopping = false; task = nil
        elapsed = Date().timeIntervalSince(startedAt)
        status = enrolling ? assessment.message : "本地处理完成：\(speakers.count)位临时说话人，\(turns.count)个人声片段"
    }
    private func cancelled(id: UUID) {
        guard id == generation else { return }; running = false; live = false; stopping = false; task = nil; status = "已停止，已完成片段保留供检查"
    }
    private func failed(_ error: Error, id: UUID) {
        guard id == generation else { return }; running = false; live = false; stopping = false; task = nil
        self.error = error.localizedDescription; status = "处理未完成，保留已产生的片段"
    }
    func saveEnrollment() {
        guard canSave else { return }
        do {
            var updated = try LocalVoiceStore.load()
            let vectors = assessment.ready ? assessment.vectors : assessment.confirmationVectors
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AssistantFailure("请填写人物名字") }
            var person = updated.first(where: { $0.id == selectedPerson }) ?? LocalVoicePerson(name: trimmed)
            person.name = trimmed; person.isSelf = isSelf; person.samples = vectors
            // Automatic samples are the wearer's voice and only live on the current self; manual references end bootstrap pending.
            person.autoPending = nil
            if !isSelf { person.autoSamples = nil }
            if isSelf {
                // Automatic samples belong to whoever is self; a different self must not inherit or keep them.
                for i in updated.indices where updated[i].id != person.id { updated[i].isSelf = false; updated[i].autoSamples = nil; updated[i].autoPending = nil }
            }
            updated.removeAll { $0.id == person.id }; updated.append(person)
            try LocalVoiceStore.save(updated); people = updated; LocalVoiceSelfLearning.invalidate(); selectedPerson = person.id
            status = "已保存\(person.name)的\(vectors.count)个声音样本，下次分析生效"
        } catch { self.error = error.localizedDescription }
    }
    func removeVoice(_ id: String) {
        do {
            var updated = try LocalVoiceStore.load()
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].samples = []; updated[index].autoSamples = nil; updated[index].autoPending = nil }
            try LocalVoiceStore.save(updated); people = updated; LocalVoiceSelfLearning.invalidate()
        } catch { self.error = error.localizedDescription }
    }
    func clearAutoSamples(_ id: String) {
        do {
            var updated = try LocalVoiceStore.load()
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].autoSamples = nil; updated[index].autoPending = nil }
            try LocalVoiceStore.save(updated); people = updated; LocalVoiceSelfLearning.invalidate()
        } catch { self.error = error.localizedDescription }
    }
    func bindSpeaker() {
        do {
            var updated = try LocalVoiceStore.load()
            let trimmed = bindingName.trimmingCharacters(in: .whitespacesAndNewlines)
            var person = updated.first(where: { $0.id == bindingPerson }) ?? LocalVoicePerson(name: trimmed)
            guard !person.name.isEmpty else { throw AssistantFailure("请选择人物或填写新名字") }
            if rememberVoice {
                person.samples = turns.filter { $0.speaker == bindingSpeaker && !$0.mixed && $0.embedding != nil }
                    .sorted { $0.endMS - $0.beginMS > $1.endMS - $1.beginMS }.prefix(5).compactMap(\.embedding)
                guard !person.samples.isEmpty else { throw AssistantFailure("该说话人没有可保存的独立声音片段") }
            }
            updated.removeAll { $0.id == person.id }; updated.append(person)
            try LocalVoiceStore.save(updated); people = updated; LocalVoiceSelfLearning.invalidate()
            for i in turns.indices where turns[i].speaker == bindingSpeaker {
                turns[i].personID = person.id; turns[i].identityBasis = "manual"
            }
            status = rememberVoice ? "人物与确认的声音已保存，下次分析可匹配" : "已为本次记录命名；没有学习新声音"
        } catch { self.error = error.localizedDescription }
    }
    func play(_ turn: LocalSpeakerTurn) {
        do {
            if player == nil { player = LocalVoicePlayer() }
            let lane = audio.count == 2 ? turn.sourceChannel - 1 : 0
            try player?.play(audio[lane], from: turn.beginMS, to: turn.endMS)
        }
        catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop() }
    func exportResult() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "OpenRayneo-speakers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            struct Export: Encodable { let model: String; let seconds: Double; let threshold: Double; let audioChannels: Int; let channelPolicy: String; let turns: [LocalSpeakerTurn]; let people: [String: String]; let matchingDiagnostics: LocalVoiceMatchingDiagnostics }
            let export = Export(model: LocalSpeakerEngine.modelID, seconds: receivedSeconds, threshold: threshold,
                audioChannels: audioChannels, channelPolicy: channelPolicy, turns: turns, people: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) }),
                matchingDiagnostics: .make(people: matchingPeople, turns: turns))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: url, options: .atomic); status = "已导出时间、说话人和文字；不包含音频或声纹向量"
        } catch { self.error = error.localizedDescription }
    }
}
