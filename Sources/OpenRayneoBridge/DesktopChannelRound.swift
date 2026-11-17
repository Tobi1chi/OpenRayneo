// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import Foundation

/// Independent ASR streams share the original PCM clock, then join speaker evidence at delivery.
actor DesktopChannelRound: DesktopVoiceRound {
    private let id: String
    private let channels: Int
    private let selectedChannel: Int?
    private let selfPerson: LocalVoicePerson?
    private let configuration: AssistantConfiguration
    private let mode: ASRAudioInputMode
    private let settings: ASRPromptSettings
    private let policy: DesktopASRPolicy
    private let processor: ChannelSpeakerProcessor
    private let sentence: @Sendable (Sentence) async -> Void
    private let diagnostic: @Sendable (String) async -> Void
    private let completed: @Sendable () async -> Void
    private let statistics: @Sendable (ASRAudioStatistics) async -> Void
    private let backendChanged: @Sendable (String) async -> Void
    private var lanes: [DesktopASRRound] = []
    private var turns: [LocalSpeakerTurn] = []
    private var pending: [Sentence] = []
    private var finishedLanes = Set<Int>()
    private var analysisWatermarks: [Int64] = []
    private var finishing = false
    private var speakersFinished = false
    private var finished = false
    private var delivering = false

    init(configuration: AssistantConfiguration, roundID: String, inputMode: ASRAudioInputMode,
         settings: ASRPromptSettings, policy: DesktopASRPolicy, channels: Int, selectedChannel: Int? = nil,
         people: [LocalVoicePerson], selfPerson: LocalVoicePerson?,
         finalSentence: @escaping @Sendable (Sentence) async -> Void,
         diagnostic: @escaping @Sendable (String) async -> Void, completed: @escaping @Sendable () async -> Void,
         statistics: @escaping @Sendable (ASRAudioStatistics) async -> Void,
         backendChanged: @escaping @Sendable (String) async -> Void) throws {
        self.configuration = configuration; id = roundID; mode = inputMode; self.settings = settings; self.policy = policy
        self.channels = channels; self.selectedChannel = selectedChannel; self.selfPerson = selfPerson
        processor = try ChannelSpeakerProcessor(channels: channels, people: people, threshold: 0.7, selfPerson: selfPerson, selectedChannel: selectedChannel)
        sentence = finalSentence; self.diagnostic = diagnostic; self.completed = completed
        self.statistics = statistics; self.backendChanged = backendChanged
    }
    func start() async throws {
        for lane in 0..<channels {
            let round = DesktopASRRound(configuration: configuration, roundID: "\(id):ch\(selectedChannel ?? lane + 1)", inputMode: mode,
                settings: settings, policy: policy, finalSentence: { [weak self] in await self?.receive($0, lane: lane) },
                diagnostic: diagnostic, completed: { [weak self] in await self?.laneFinished(lane) }, statistics: statistics, backendChanged: backendChanged)
            lanes.append(round)
        }
        do { for lane in lanes { try await lane.start() } }
        catch { await cancel(); throw error }
    }
    func appendPCM(_ bytes: Data) async throws {
        let samples = LocalVoiceAudioReader.decodePCM16Channels(bytes, channels: channels)
        turns = await processor.accept(samples)
        analysisWatermarks = await processor.analyzedThroughMS()
        for lane in lanes.indices { try await lanes[lane].appendPCM(LocalVoiceAudioReader.encodePCM16([samples[lane]])) }
        await deliverReady()
    }
    private func receive(_ value: Sentence, lane: Int) async {
        guard !finished else { return }
        var value = Sentence(id: value.id, text: value.text, roundID: id, beginMS: value.beginMS, endMS: value.endMS)
        value.sourceChannel = selectedChannel ?? lane + 1
        pending.append(value)
        await deliverReady()
    }
    private func laneFinished(_ lane: Int) async { finishedLanes.insert(lane); await deliverReady() }

    private func deliverReady() async {
        guard !delivering, !finished else { return }
        delivering = true; defer { delivering = false }
        while !finished {
            let final = finishing && speakersFinished && finishedLanes.count == channels
            pending.sort {
                ($0.beginMS ?? Int.max) == ($1.beginMS ?? Int.max) ? ($0.sourceChannel ?? 1) < ($1.sourceChannel ?? 1) : ($0.beginMS ?? Int.max) < ($1.beginMS ?? Int.max)
            }
            var blocked = Set<Int>(), ready: [Sentence] = [], waiting: [Sentence] = []
            for value in pending {
                let channel = value.sourceChannel ?? 1
                let lane = selectedChannel != nil ? 0 : channel - 1
                let analyzed = analysisWatermarks.indices.contains(lane) ? analysisWatermarks[lane] : 0
                let defaultSelf = channels == 2 && channel == 1 && selectedChannel == nil
                let complete = final || defaultSelf || (value.endMS.map { Int64($0) <= analyzed } ?? false)
                if blocked.contains(channel) || !complete { waiting.append(value); blocked.insert(channel) }
                else { ready.append(value) }
            }
            pending = waiting
            guard !ready.isEmpty else { break }
            for var value in ready {
                guard !finished else { break }
                let overlap = turns.filter {
                    $0.sourceChannel == value.sourceChannel && (value.beginMS == nil || value.endMS == nil || $0.endMS > Int64(value.beginMS!) && $0.beginMS < Int64(value.endMS!))
                }
                value.speakerTurns = overlap.map { SpeakerAttribution(beginMS: $0.beginMS, endMS: $0.endMS, sourceChannel: $0.sourceChannel,
                    personId: $0.personID, speaker: $0.speaker, identityBasis: $0.identityBasis, mixed: $0.mixed) }
                if channels == 2, value.sourceChannel == 1, selectedChannel == nil {
                    value.personId = selfPerson?.id; value.speaker = "我"; value.identityBasis = "channel1_default_self"
                } else {
                    let people = Set(overlap.compactMap(\.personID))
                    let mixed = overlap.contains(where: \.mixed)
                    value.personId = !mixed && people.count == 1 && overlap.allSatisfy { $0.personID != nil } ? people.first : nil
                    value.identityBasis = mixed ? "mixed" : value.personId != nil ? "voiceprint" : "unknown"
                    let labels = Set(overlap.map(\.speaker))
                    value.speaker = labels.count == 1 ? labels.first : "未知"
                }
                await sentence(value)
            }
        }
        if !finished, finishing, speakersFinished, finishedLanes.count == channels, pending.isEmpty {
            finished = true; await completed()
        }
    }
    func finish() async {
        guard !finishing, !finished else { return }; finishing = true
        if lanes.isEmpty { finished = true; await completed(); return }
        turns = await processor.flush(); speakersFinished = true
        analysisWatermarks = await processor.analyzedThroughMS()
        for lane in lanes { await lane.finish() }
        await deliverReady()
    }
    func cancel() async {
        guard !finished else { return }; finished = true
        for lane in lanes { await lane.cancel() }
        pending = []; await completed()
    }
    func isFinished() -> Bool { finished }
    var maximumFinishWaitSeconds: Int { 180 }
}
