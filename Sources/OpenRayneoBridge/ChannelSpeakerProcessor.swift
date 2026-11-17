// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AssistantCore

/// Lanes share a PCM-frame clock, but never a VAD, speaker cache or completion cursor.
actor ChannelSpeakerProcessor {
    let channels: Int
    let channelPolicy: String
    private let engines: [LocalSpeakerEngine]

    init(channels: Int, people: [LocalVoicePerson], threshold: Float, enrolling: Bool = false,
         selfPerson: LocalVoicePerson? = nil, selectedChannel: Int? = nil, offlineDiarization: Bool = false) throws {
        self.channels = channels
        let dual = channels == 2 && !enrolling && selectedChannel == nil
        guard !dual || selfPerson != nil else { throw AssistantFailure("双路策略需要稳定的本人身份") }
        channelPolicy = dual ? "dual_channel1_self" : selectedChannel != nil ? "legacy_selected_mono" : "full_speaker"
        engines = try (0..<channels).map { lane in
            try LocalSpeakerEngine(enrolling: enrolling, people: people, threshold: threshold,
                sourceChannel: selectedChannel ?? lane + 1, defaultSelfID: dual && lane == 0 ? selfPerson?.id : nil,
                offlineDiarization: offlineDiarization)
        }
    }
    func accept(_ lanes: [[Float]]) async -> [LocalSpeakerTurn] {
        var turns: [LocalSpeakerTurn] = []
        for lane in engines.indices { turns += await engines[lane].accept(lanes[lane]) }
        return Self.ordered(turns)
    }
    func flush() async -> [LocalSpeakerTurn] {
        var turns: [LocalSpeakerTurn] = []
        for engine in engines { turns += await engine.flush() }
        return Self.ordered(turns)
    }
    func beginRound() async { for engine in engines { await engine.beginRound() } }
    func analyzedThroughMS() async -> [Int64] {
        var result: [Int64] = []
        for engine in engines { result.append(await engine.analyzedThroughMS()) }
        return result
    }
    private static func ordered(_ turns: [LocalSpeakerTurn]) -> [LocalSpeakerTurn] {
        turns.sorted { $0.beginMS == $1.beginMS ? $0.sourceChannel < $1.sourceChannel : $0.beginMS < $1.beginMS }
    }
}
