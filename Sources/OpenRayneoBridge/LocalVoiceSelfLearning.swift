// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// One automatically learned self reference window (<=3 s, production enrollment chunking).
struct LocalVoiceAutoSample: Codable {
    var vector: [Float]
    var seconds: Float
    var at: Date
}

/// Native wake rounds are the wearer's by user policy, so their speech refreshes the self profile.
/// Mirrors Android SelfVoiceLearning: bootstrap needs an enrollment-grade consistent group; afterwards a
/// window must already match the profile, which keeps occasional bystander speech out.
enum LocalVoiceSelfLearning {
    static let enabledKey = "selfVoiceAutoLearn"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let maxAuto = 10, maxPending = 30

    struct Outcome { var accepted = 0; var bootstrapped = false; var pendingSeconds: Float = 0; var changed = true; var windows = 0; var stale = false }
    static let updated = Notification.Name("LocalVoiceSelfLearning.updated")
    /// A native session usually stops with its round, closing the ASR journal before learning ends; the last result is kept here too.
    static let lastResultKey = "selfVoiceLastLearn"
    private static let log = Logger(subsystem: "com.openrayneo.bridge", category: "self-voice-learning")

    static func apply(_ person: inout LocalVoicePerson, windows: [(vector: [Float], seconds: Float)], now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        guard person.model == LocalSpeakerEngine.modelID, !windows.isEmpty else { outcome.changed = false; return outcome }
        let fresh = windows.map { LocalVoiceAutoSample(vector: $0.vector, seconds: $0.seconds, at: now) }
        let references = person.references
        if !references.isEmpty {
            let accepted = fresh.filter { top3($0.vector, references) >= LocalSpeakerEngine.defaultThreshold }
            if accepted.isEmpty && (person.autoPending ?? []).isEmpty { outcome.changed = false; return outcome }
            person.autoSamples = Array(((person.autoSamples ?? []) + accepted).suffix(maxAuto))
            person.autoPending = nil
            outcome.accepted = accepted.count
            return outcome
        }
        let pending = Array(((person.autoPending ?? []) + fresh).suffix(maxPending))
        let total = pending.reduce(Float(0)) { $0 + $1.seconds }
        var best: [LocalVoiceAutoSample] = [], bestSeconds: Float = -1
        for seed in pending.indices {
            let order = pending.indices.sorted { LocalSpeakerEngine.cosine(pending[seed].vector, pending[$0].vector) > LocalSpeakerEngine.cosine(pending[seed].vector, pending[$1].vector) }
            var group = [seed]
            for index in order where index != seed {
                if group.allSatisfy({ LocalSpeakerEngine.cosine(pending[$0].vector, pending[index].vector) >= 0.5 }) { group.append(index) }
            }
            let seconds = group.reduce(Float(0)) { $0 + pending[$1].seconds }
            if seconds > bestSeconds { bestSeconds = seconds; best = group.sorted().map { pending[$0] } }
        }
        // Same 10 s / 3 window bar as manual enrollment; the wearer must be the majority of the pooled wake speech.
        if bestSeconds >= 10, best.count >= 3, bestSeconds >= total * 0.5 {
            // Keep the longest windows but in capture order, so later FIFO eviction drops the oldest first.
            let keep = Set(best.indices.sorted { best[$0].seconds > best[$1].seconds }.prefix(maxAuto))
            person.autoSamples = best.indices.filter(keep.contains).map { best[$0] }
            person.autoPending = nil
            outcome.accepted = person.autoSamples!.count; outcome.bootstrapped = true
        } else {
            person.autoPending = pending; outcome.pendingSeconds = total
        }
        return outcome
    }

    private static func top3(_ vector: [Float], _ references: [[Float]]) -> Float {
        let scores = references.map { LocalSpeakerEngine.cosine(vector, $0) }.sorted(by: >).prefix(3)
        return Float(scores.reduce(0.0) { $0 + Double($1) } / Double(scores.count))
    }

    /// Extracts enrollment windows from one finished native round, then updates the Keychain profile on the main actor
    /// so it serializes with the voice lab's own profile writes.
    /// Rounds learn one after another: each pass loads its own models, and back-to-back wake rounds must not stack them.
    @MainActor private static var last: Task<Void, Never>?
    /// Bumped by every manual profile change (enroll, bind, remove, clear); a round captured before it must not write.
    @MainActor private(set) static var generation = 0
    @MainActor static func invalidate() { generation += 1 }
    @MainActor static func enqueue(_ audio: [Float], generation: Int, report: @escaping @Sendable (String) async -> Void) {
        let previous = last
        last = Task.detached(priority: .utility) {
            await previous?.value
            do {
                let outcome = try await learn(from: audio, generation: generation)
                let summary = outcome.stale ? "skipped=profile_changed_or_disabled"
                    : "audioSeconds=\(audio.count / 16000); windows=\(outcome.windows); accepted=\(outcome.accepted); bootstrapped=\(outcome.bootstrapped); pendingSeconds=\(Int(outcome.pendingSeconds)); saved=\(outcome.changed)"
                await finished(summary, at: Date(), report: report)
            } catch { await finished("failed=\(error.localizedDescription)", at: Date(), report: report) }
        }
    }
    private static func finished(_ summary: String, at: Date, report: @Sendable (String) async -> Void) async {
        log.notice("\(summary, privacy: .public)")
        await MainActor.run {
            UserDefaults.standard.set(["at": at, "summary": summary], forKey: lastResultKey)
            NotificationCenter.default.post(name: updated, object: nil)
        }
        await report(summary)
    }
    static func learn(from audio: [Float], generation: Int) async throws -> Outcome {
        let engine = try LocalSpeakerEngine(enrolling: true, people: [], threshold: LocalSpeakerEngine.defaultThreshold)
        // Enrollment mode keeps a bounded rolling window, so collect windows as they appear.
        var collected: [UUID: LocalSpeakerTurn] = [:]
        for first in stride(from: 0, to: audio.count, by: 16000) {
            for turn in await engine.accept(Array(audio[first..<min(first + 16000, audio.count)])) { collected[turn.id] = turn }
        }
        for turn in await engine.flush() { collected[turn.id] = turn }
        let windows = collected.values.sorted { $0.beginMS < $1.beginMS }.compactMap { turn in turn.embedding.map { (vector: $0, seconds: Float(turn.endMS - turn.beginMS) / 1000) } }
        guard !windows.isEmpty else { return Outcome(changed: false) }
        return try await MainActor.run {
            guard enabled, generation == Self.generation else { return Outcome(changed: false, stale: true) }
            var people = try LocalVoiceStore.load()
            let index: Int
            if let existing = people.firstIndex(where: \.isSelf) { index = existing }
            else { people.append(LocalVoicePerson(name: "我", isSelf: true)); index = people.count - 1 }
            var outcome = apply(&people[index], windows: windows)
            if outcome.changed { try LocalVoiceStore.save(people) }
            outcome.windows = windows.count
            return outcome
        }
    }
}
