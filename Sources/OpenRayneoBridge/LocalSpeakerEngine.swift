// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CSherpaOnnx
import AssistantCore

struct LocalVoicePerson: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var isSelf = false
    var model = LocalSpeakerEngine.modelID
    var samples: [[Float]] = []
}

struct LocalSpeakerTurn: Identifiable, Codable {
    var id = UUID()
    var beginMS: Int64
    var endMS: Int64
    var speaker: String
    var personID: String?
    var score: Float?
    var mixed = false
    var text: String?
    var sourceChannel = 1
    var identityBasis = "unknown"
    // Kept in memory for explicitly confirmed enrollment/binding; never in result exports.
    var embedding: [Float]?
    enum CodingKeys: String, CodingKey { case id, beginMS, endMS, speaker, personID, score, mixed, text, sourceChannel, identityBasis }
}

extension LocalSpeakerTurn {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        beginMS = try values.decode(Int64.self, forKey: .beginMS)
        endMS = try values.decode(Int64.self, forKey: .endMS)
        speaker = try values.decode(String.self, forKey: .speaker)
        personID = try values.decodeIfPresent(String.self, forKey: .personID)
        score = try values.decodeIfPresent(Float.self, forKey: .score)
        mixed = try values.decodeIfPresent(Bool.self, forKey: .mixed) ?? false
        text = try values.decodeIfPresent(String.self, forKey: .text)
        sourceChannel = try values.decodeIfPresent(Int.self, forKey: .sourceChannel) ?? 1
        identityBasis = try values.decodeIfPresent(String.self, forKey: .identityBasis) ?? (mixed ? "mixed" : "unknown")
        embedding = nil
    }
}

struct LocalVoiceAssessment {
    var seconds: Float = 0
    var totalSeconds: Float = 0
    var vectors: [[Float]] = []
    var confirmationVectors: [[Float]] = []
    var ready = false
    var message = "尚未提取到清晰人声；请确认音量有变化，再自然说几句话"

    // Port of Android VoiceEnrollment.assess, including its non-overlap duration gate.
    static func assess(_ samples: [LocalSpeakerTurn]) -> Self {
        let samples = samples.filter { !$0.mixed && $0.embedding != nil }
        guard !samples.isEmpty else { return Self() }
        func duration(_ items: [LocalSpeakerTurn]) -> Int64 {
            var end = Int64.min, total: Int64 = 0
            for item in items.sorted(by: { $0.beginMS < $1.beginMS }) {
                total += max(0, item.endMS - max(item.beginMS, end)); end = max(end, item.endMS)
            }
            return total
        }
        var selected: [LocalSpeakerTurn] = [], best: Int64 = -1
        for seed in samples {
            let compatible = samples.sorted { LocalSpeakerEngine.cosine(seed.embedding!, $0.embedding!) > LocalSpeakerEngine.cosine(seed.embedding!, $1.embedding!) }
            var group = [seed]
            for sample in compatible where sample.id != seed.id {
                if group.allSatisfy({ LocalSpeakerEngine.cosine($0.embedding!, sample.embedding!) >= 0.5 }) { group.append(sample) }
            }
            let value = duration(group)
            if value > best { selected = group; best = value }
        }
        let total = Float(duration(samples)) / 1000, seconds = Float(duration(selected)) / 1000
        let consistent = seconds >= total * 0.8
        let ready = seconds >= 10 && selected.count >= 3 && consistent
        let message: String
        if ready { message = "已取得\(Int(seconds))秒一致人声，可以保存声音" }
        else if !consistent && total >= 10 { message = "人声一致性不足：一致\(Int(seconds))秒／共\(Int(total))秒。请只由本人说话，或重新登记" }
        else if seconds < 10 { message = "已取得\(Int(seconds))／10秒一致人声；请继续说话，每句话后稍作停顿" }
        else { message = "请再说一句，登记需要至少三段可对照的人声" }
        func vectors(_ turns: [LocalSpeakerTurn]) -> [[Float]] {
            turns.sorted { $0.endMS - $0.beginMS > $1.endMS - $1.beginMS }.prefix(10).compactMap(\.embedding)
        }
        return Self(seconds: seconds, totalSeconds: total, vectors: vectors(selected),
                    confirmationVectors: total >= 10 && samples.count >= 3 ? vectors(samples) : [], ready: ready, message: message)
    }
}

/// Serial actor using the shared models. File analysis keeps continuous context;
/// live capture retains its bounded VAD scheduling. Neither path changes thresholds.
actor LocalSpeakerEngine {
    static let modelID = "campplus-zh-16k-common/sherpa-2.0.1"
    private let extractor: OpaquePointer?
    private let vad: OpaquePointer
    private let diarizer: OpaquePointer?
    private let dimension: Int
    private let enrolling: Bool
    private let people: [LocalVoicePerson]
    private let threshold: Float
    private let defaultSelfID: String?
    private let sourceChannel: Int
    private let offlineDiarization: Bool
    private var continuousAudio: [Float] = []
    private var offsetSamples: Int64 = 0
    private var totalSamples: Int64 = 0
    private var analyzedThrough: Int64 = 0
    private var turns: [LocalSpeakerTurn] = []
    private var vadPending: [Float] = []
    private struct Cluster { var label: String; var samples: [[Float]] }
    private var clusters: [Cluster] = []

    init(enrolling: Bool, people: [LocalVoicePerson], threshold: Float, sourceChannel: Int = 1, defaultSelfID: String? = nil,
         offlineDiarization: Bool = false) throws {
        self.enrolling = enrolling; self.people = people; self.threshold = threshold
        self.sourceChannel = sourceChannel; self.defaultSelfID = enrolling ? nil : defaultSelfID
        self.offlineDiarization = offlineDiarization && !enrolling && defaultSelfID == nil
        if let _ = self.defaultSelfID {
            // Channel 1 needs speech boundaries, but never loads embedding/diarization models.
            extractor = nil; diarizer = nil; dimension = 0
            let path = Self.modelsFolder.appendingPathComponent("silero-vad.onnx").path
            let detector = path.withCString { path in "cpu".withCString { cpu in
                var config = SherpaOnnxVadModelConfig()
                config.silero_vad.model = path; config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = 0.4; config.silero_vad.min_speech_duration = 0.25
                config.silero_vad.window_size = 512; config.silero_vad.max_speech_duration = 8
                config.sample_rate = 16000; config.num_threads = 1; config.provider = cpu
                return SherpaOnnxCreateVoiceActivityDetector(&config, 60)
            } }
            guard let detector else { throw AssistantFailure("本人通道 VAD 加载失败") }
            vad = detector; return
        }
        let models = Self.modelsFolder
        let names = [models.appendingPathComponent("campplus-zh-16k.onnx").path,
                     models.appendingPathComponent("silero-vad.onnx").path,
                     models.appendingPathComponent("segmentation.int8.onnx").path, "cpu"]
        let paths: [UnsafeMutablePointer<CChar>] = names.map { name in name.withCString { Darwin.strdup($0)! } }
        defer { paths.forEach { free($0) } }
        var embedding = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        embedding.model = UnsafePointer(paths[0]); embedding.num_threads = 1; embedding.provider = UnsafePointer(paths[3])
        guard let extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&embedding) else { throw AssistantFailure("CAM++ 模型加载失败") }
        var vadConfig = SherpaOnnxVadModelConfig()
        vadConfig.silero_vad.model = UnsafePointer(paths[1]); vadConfig.silero_vad.threshold = 0.5
        vadConfig.silero_vad.min_silence_duration = 0.4; vadConfig.silero_vad.min_speech_duration = 0.25
        vadConfig.silero_vad.window_size = 512; vadConfig.silero_vad.max_speech_duration = 8
        vadConfig.sample_rate = 16000; vadConfig.num_threads = 1; vadConfig.provider = UnsafePointer(paths[3])
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 60) else {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor); throw AssistantFailure("Silero VAD 加载失败")
        }
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = UnsafePointer(paths[2]); config.segmentation.num_threads = 1
        config.segmentation.provider = UnsafePointer(paths[3]); config.embedding = embedding
        config.clustering.threshold = 0.65; config.min_duration_on = 0.25; config.min_duration_off = 0.3
        guard let diarizer = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor); SherpaOnnxDestroyVoiceActivityDetector(vad)
            throw AssistantFailure("pyannote 说话人分段模型加载失败")
        }
        self.extractor = extractor; self.vad = vad; self.diarizer = diarizer
        dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
    }

    deinit {
        if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        if let diarizer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) }
    }

    static var modelsFolder: URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("VoiceModels"), FileManager.default.fileExists(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("android/app/src/main/assets/voice-models")
    }

    func accept(_ samples: [Float]) -> [LocalSpeakerTurn] {
        totalSamples += Int64(samples.count)
        if offlineDiarization {
            continuousAudio.append(contentsOf: samples)
            return turns
        }
        vadPending.append(contentsOf: samples)
        let count = vadPending.count / 512 * 512
        vadPending.withUnsafeBufferPointer { buffer in
            for first in stride(from: 0, to: count, by: 512) {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buffer.baseAddress! + first, 512)
                drain()
            }
        }
        if count > 0 { vadPending.removeFirst(count) }
        if SherpaOnnxVoiceActivityDetectorDetected(vad) == 0 {
            analyzedThrough = max(analyzedThrough, (totalSamples - Int64(vadPending.count)) * 1000 / 16000)
        }
        return turns
    }
    func flush() -> [LocalSpeakerTurn] {
        if offlineDiarization {
            if !continuousAudio.isEmpty {
                diarize(continuousAudio, firstSample: totalSamples - Int64(continuousAudio.count), globalLabels: true)
                continuousAudio.removeAll(keepingCapacity: false)
            }
            analyzedThrough = totalSamples * 1000 / 16000
            return turns
        }
        if !vadPending.isEmpty {
            var tail = vadPending
            tail.append(contentsOf: repeatElement(0, count: 512 - tail.count))
            tail.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, 512) }
            vadPending.removeAll()
            drain()
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad); drain()
        analyzedThrough = totalSamples * 1000 / 16000
        return turns
    }
    func beginRound() {
        _ = flush(); SherpaOnnxVoiceActivityDetectorReset(vad)
        offsetSamples = totalSamples
    }
    func analyzedThroughMS() -> Int64 { analyzedThrough }

    private func embedding(_ samples: [Float]) -> [Float]? {
        guard let extractor else { return nil }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: dimension))
    }

    private func drain() {
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let speech = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let firstSample = offsetSamples + speech.pointee.start
            let realSampleCount = min(Int(speech.pointee.n), Int(max(0, totalSamples - firstSample)))
            let begin = firstSample * 1000 / 16000
            let samples = Array(UnsafeBufferPointer(start: speech.pointee.samples, count: realSampleCount))
            SherpaOnnxDestroySpeechSegment(speech); SherpaOnnxVoiceActivityDetectorPop(vad)
            guard !samples.isEmpty else { continue }
            let end = (firstSample + Int64(samples.count)) * 1000 / 16000
            analyzedThrough = end
            if let defaultSelfID {
                turns.append(LocalSpeakerTurn(beginMS: begin, endMS: end, speaker: "我", personID: defaultSelfID,
                    sourceChannel: sourceChannel, identityBasis: "channel1_default_self"))
                continue
            }
            if enrolling {
                if samples.count < 12800 {
                    turns.append(LocalSpeakerTurn(beginMS: begin, endMS: end, speaker: "未知", sourceChannel: sourceChannel)); continue
                }
                for first in stride(from: 0, to: samples.count, by: 48000) {
                    let last = min(first + 48000, samples.count)
                    guard last - first >= 12800, let vector = embedding(Array(samples[first..<last])) else { continue }
                    turns.append(LocalSpeakerTurn(beginMS: begin + Int64(first) * 1000 / 16000,
                        endMS: begin + Int64(last) * 1000 / 16000, speaker: "登记", sourceChannel: sourceChannel, embedding: vector))
                }
                turns.removeAll { $0.endMS < end - 60000 }
                if turns.count > 30 { turns.removeFirst(turns.count - 30) }
                continue
            }
            diarize(samples, firstSample: firstSample, globalLabels: false)
        }
    }

    private func diarize(_ samples: [Float], firstSample: Int64, globalLabels: Bool) {
        guard let diarizer, let result = samples.withUnsafeBufferPointer({
            SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, $0.baseAddress, Int32($0.count))
        }) else { return }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        let raw = segments.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
        if let segments { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }
        SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)

        struct Region { var first: Int; var last: Int; let speakers: Set<Int32> }
        let intervals = raw.compactMap { segment -> (Int, Int, Int32)? in
            let first = max(0, min(samples.count, Int(segment.start * 16000)))
            let last = max(first, min(samples.count, Int(segment.end * 16000)))
            return last > first ? (first, last, segment.speaker) : nil
        }
        let edges = Set(intervals.flatMap { [$0.0, $0.1] }).sorted()
        var regions: [Region] = []
        for (first, last) in zip(edges, edges.dropFirst()) {
            let speakers = Set(intervals.filter { $0.0 < last && $0.1 > first }.map { $0.2 })
            guard !speakers.isEmpty else { continue }
            if let previous = regions.last, previous.last == first && previous.speakers == speakers {
                regions[regions.count - 1].last = last
            } else { regions.append(Region(first: first, last: last, speakers: speakers)) }
        }
        let speakers = Set(intervals.map { $0.2 }).sorted()
        var labels: [Int32: String] = [:], vectors: [Int32: [Float]] = [:]
        var matches: [Int32: (String?, Float)] = [:]
        for (index, speaker) in speakers.enumerated() {
            // SDK membership is retained: all clean regions of this speaker share
            // one reference, including turns too short to embed on their own.
            let clean = regions.filter { $0.speakers == [speaker] }
            let audio = clean.flatMap { Array(samples[$0.first..<$0.last]) }
            let vector = audio.count >= 12800 ? embedding(audio) : nil
            if let vector { vectors[speaker] = vector; matches[speaker] = person(vector) }
            if globalLabels { labels[speaker] = index < 26 ? String(UnicodeScalar(65 + index)!) : "S\(index + 1)" }
            else { labels[speaker] = vector.map(cluster) ?? "短段\(firstSample / 16)-\(speaker)" }
        }
        for region in regions {
            let mixed = region.speakers.count > 1
            let speaker = region.speakers.first!
            let match = mixed ? nil : matches[speaker]
            turns.append(LocalSpeakerTurn(beginMS: (firstSample + Int64(region.first)) / 16,
                endMS: (firstSample + Int64(region.last)) / 16, speaker: mixed ? "未知" : labels[speaker]!,
                personID: match?.0, score: match?.1, mixed: mixed, sourceChannel: sourceChannel,
                identityBasis: mixed ? "mixed" : match?.0 != nil ? "voiceprint" : "unknown",
                embedding: mixed ? nil : vectors[speaker]))
        }
    }

    private func cluster(_ vector: [Float]) -> String {
        var nearest: (Int, Float)?
        for index in clusters.indices {
            let score = clusters[index].samples.map { Self.cosine(vector, $0) }.max()!
            if nearest == nil || score > nearest!.1 { nearest = (index, score) }
        }
        if let nearest, nearest.1 >= 0.6 {
            if clusters[nearest.0].samples.count < 5 { clusters[nearest.0].samples.append(vector) }
            return clusters[nearest.0].label
        }
        let count = clusters.count
        let label = count < 26 ? String(UnicodeScalar(65 + count)!) : "S\(count + 1)"
        clusters.append(Cluster(label: label, samples: [vector])); return label
    }
    private func person(_ vector: [Float]) -> (String?, Float)? {
        let candidates = people.filter { $0.model == Self.modelID && !$0.samples.isEmpty }.map { person -> (String, Float) in
            let scores = person.samples.map { Self.cosine(vector, $0) }.sorted(by: >).prefix(3)
            return (person.id, Float(scores.reduce(0.0) { $0 + Double($1) } / Double(scores.count)))
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first else { return nil }
        if best.1 < threshold || candidates.count > 1 && best.1 - candidates[1].1 < 0.08 { return (nil, best.1) }
        return (best.0, best.1)
    }
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { dot += Double(a[i] * b[i]); aa += Double(a[i] * a[i]); bb += Double(b[i] * b[i]) }
        return Float(dot / max(sqrt(aa * bb), 1e-12))
    }
}

/// Android ConversationAudio's 63-tap filter and stateful 48k→16k decimator.
struct LocalVoiceResampler {
    private let taps: [Float] = {
        let values: [Float] = (0..<63).map { index in
            let x = Double(index - 31)
            let ideal = x == 0 ? 0.3 : sin(0.3 * Double.pi * x) / (Double.pi * x)
            return Float(ideal * (0.54 - 0.46 * cos(2 * Double.pi * Double(index) / 62)))
        }
        let sum = values.reduce(Float(0), +); return values.map { $0 / sum }
    }()
    private var history = [Float](repeating: 0, count: 63)
    private var cursor = 0, phase = 0
    mutating func convert(_ samples: [Float]) -> [Float] {
        var result: [Float] = []; result.reserveCapacity((samples.count + 2) / 3)
        for sample in samples {
            history[cursor] = sample
            phase += 1
            if phase == 3 {
                phase = 0; var sum: Float = 0
                for tap in taps.indices { sum += taps[tap] * history[(cursor - tap + 63) % 63] }
                result.append(sum)
            }
            cursor = (cursor + 1) % 63
        }
        return result
    }
}

/// Scalar diagnostics for the already analysed query and its original reference snapshot.
/// This type deliberately contains no person names, transcripts or embedding arrays.
struct LocalVoiceMatchingDiagnostics: Encodable {
    struct Reference: Encodable {
        let alias: String
        let modelID: String
        let dimension: Int
        let l2Norm: Double?
        let durationSeconds: Double? = nil // Not stored in the voice profile.
    }
    struct Query: Encodable {
        let alias: String
        let sourceChannel: Int
        let turnIndices: [Int]
        let cleanSeconds: Double
        let dimension: Int
        let l2Norm: Double?
        let referenceCosines: [Float?]
        let maxScore: Float?
        let top3Mean: Float?
        let displayedScore: Float?
    }
    let modelID: String
    let selfAlias: String?
    let referenceModelID: String?
    let referencesEligible: Bool
    let referenceSecondsStored = false
    let references: [Reference]
    let referenceCosines: [[Float?]]
    let queries: [Query]

    static func make(people: [LocalVoicePerson], turns: [LocalSpeakerTurn]) -> Self {
        let person = people.first { $0.isSelf }
        let samples = person?.samples ?? []
        // Same model/nonempty gate as the production person matcher.
        let eligible = person?.model == LocalSpeakerEngine.modelID && !samples.isEmpty
        let references = samples.enumerated().map { index, vector in
            Reference(alias: "ref\(index + 1)", modelID: person!.model,
                dimension: vector.count, l2Norm: norm(vector))
        }
        let matrix = samples.map { left in samples.map { finite(LocalSpeakerEngine.cosine(left, $0)) } }
        var groups: [(channel: Int, speaker: String, vector: [Float], indices: [Int])] = []
        for (index, turn) in turns.enumerated() {
            guard !turn.mixed, let vector = turn.embedding else { continue }
            if let group = groups.firstIndex(where: { $0.channel == turn.sourceChannel && $0.speaker == turn.speaker && $0.vector == vector }) {
                groups[group].indices.append(index)
            } else { groups.append((turn.sourceChannel, turn.speaker, vector, [index])) }
        }
        let queries = groups.enumerated().map { index, group in
            let scores = eligible ? samples.map { LocalSpeakerEngine.cosine(group.vector, $0) } : []
            let best = scores.sorted(by: >).prefix(3)
            // Identical top-three arithmetic to person(_:); do not average all references.
            let mean = best.isEmpty ? nil : finite(Float(best.reduce(0.0) { $0 + Double($1) } / Double(best.count)))
            return Query(alias: "query\(index + 1)", sourceChannel: group.channel, turnIndices: group.indices,
                cleanSeconds: Double(group.indices.reduce(Int64(0)) { $0 + max(0, turns[$1].endMS - turns[$1].beginMS) }) / 1000,
                dimension: group.vector.count, l2Norm: norm(group.vector), referenceCosines: scores.map(finite),
                maxScore: scores.max().flatMap(finite), top3Mean: mean,
                displayedScore: turns[group.indices[0]].score.flatMap(finite))
        }
        return Self(modelID: LocalSpeakerEngine.modelID, selfAlias: person == nil ? nil : "self1",
            referenceModelID: person?.model, referencesEligible: eligible, references: references,
            referenceCosines: matrix, queries: queries)
    }

    private static func finite(_ value: Float) -> Float? { value.isFinite ? value : nil }
    private static func norm(_ vector: [Float]) -> Double? {
        let value = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        return value.isFinite ? value : nil
    }
}
