// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import AssistantCore
import CoreML
import CSherpaOnnx
import Foundation
import WhisperKit

enum DesktopASRPolicy: String, CaseIterable, Identifiable {
    case cloud = "百炼 ASR", fallback = "百炼优先，本地兜底", local = "仅本地 ASR"
    var id: String { rawValue }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "desktopASRPolicy") ?? "") ?? .fallback }
}

actor LocalASRService {
    static let shared = LocalASRService()
    static let variant = "openai_whisper-tiny"
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/LocalASR", isDirectory: true)
    }
    static var installed: Bool {
        guard let path = UserDefaults.standard.string(forKey: "localASRModelFolder") else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("AudioEncoder.mlmodelc").path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path)
    }
    struct Transcript: Sendable { var start: Float; var end: Float; var text: String }
    private var pipeline: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var tail: Task<[Transcript], Error>?

    func prepare(download: Bool, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if pipeline != nil { return }
        if let loading { pipeline = try await loading.value; return }
        if !download, !Self.installed { throw AssistantFailure("本地 ASR 模型尚未就绪，请在“声音与说话人”下载并准备模型") }
        let task = Task<WhisperKit, Error> {
            let path: String
            if Self.installed, let saved = UserDefaults.standard.string(forKey: "localASRModelFolder") { path = saved }
            else if FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(Self.variant + "/AudioEncoder.mlmodelc").path) {
                path = Self.folder.appendingPathComponent(Self.variant).path
            }
            else {
                path = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.folder,
                    progressCallback: { progress?($0.fractionCompleted) }).path
            }
            let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: path, tokenizerFolder: Self.folder,
                computeOptions: compute, verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
            UserDefaults.standard.set(path, forKey: "localASRModelFolder")
            try Data("{\"model\":\"openai_whisper-tiny\",\"compute\":\"cpuAndNeuralEngine\"}".utf8)
                .write(to: Self.folder.appendingPathComponent("ready.json"), options: .atomic)
            return kit
        }
        loading = task
        defer { loading = nil }
        pipeline = try await task.value
    }
    func transcribe(_ samples: [Float], language: String) async throws -> [Transcript] {
        let prior = tail
        let task = Task<[Transcript], Error> {
            if let prior { _ = await prior.result }
            try Task.checkCancellation()
            try await self.prepare(download: false)
            return try await self.decode(samples, language: language)
        }
        tail = task
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func decode(_ samples: [Float], language: String) async throws -> [Transcript] {
        guard let pipeline, !samples.isEmpty else { return [] }
        let options = DecodingOptions(language: language, temperatureFallbackCount: 1, sampleLength: 224,
            skipSpecialTokens: true, withoutTimestamps: false, concurrentWorkerCount: 1)
        let result = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return result.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Transcript(start: segment.start, end: segment.end, text: text)
        }
    }
    func unload() async {
        let prior = tail
        let release = Task<[Transcript], Error> {
            if let prior { _ = await prior.result }
            await self.releasePipeline()
            return []
        }
        tail = release
        _ = await release.result
    }
    private func releasePipeline() async {
        await pipeline?.unloadModels(); pipeline = nil
    }
}

/// A VAD-only stream for local ASR. Models run after speech boundaries, not on each packet.
final class LocalASRVAD {
    struct Utterance { var begin: Int; var samples: [Float] }
    private let vad: OpaquePointer
    private var pending: [Float] = []
    init() throws {
        let path = LocalSpeakerEngine.modelsFolder.appendingPathComponent("silero-vad.onnx").path
        let detector = path.withCString { path in "cpu".withCString { cpu in
            var config = SherpaOnnxVadModelConfig()
            config.silero_vad.model = path; config.silero_vad.threshold = 0.5
            config.silero_vad.min_silence_duration = 0.4; config.silero_vad.min_speech_duration = 0.25
            config.silero_vad.window_size = 512; config.silero_vad.max_speech_duration = 8
            config.sample_rate = 16000; config.num_threads = 1; config.provider = cpu
            return SherpaOnnxCreateVoiceActivityDetector(&config, 60)
        } }
        guard let detector else { throw AssistantFailure("本地 ASR 的 VAD 加载失败") }; vad = detector
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    func accept(_ samples: [Float]) -> [Utterance] {
        pending.append(contentsOf: samples)
        let count = pending.count / 512 * 512
        var result: [Utterance] = []
        pending.withUnsafeBufferPointer { buffer in
            for first in stride(from: 0, to: count, by: 512) {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buffer.baseAddress! + first, 512)
                result.append(contentsOf: drain())
            }
        }
        if count > 0 { pending.removeFirst(count) }; return result
    }
    func flush() -> [Utterance] { SherpaOnnxVoiceActivityDetectorFlush(vad); return drain() }
    private func drain() -> [Utterance] {
        var values: [Utterance] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let speech = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            values.append(Utterance(begin: Int(speech.pointee.start), samples: Array(UnsafeBufferPointer(start: speech.pointee.samples, count: Int(speech.pointee.n)))))
            SherpaOnnxDestroySpeechSegment(speech); SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        return values
    }
}

@MainActor
final class LocalASRSettings: ObservableObject {
    static let shared = LocalASRSettings()
    @Published var policy = DesktopASRPolicy.current { didSet { UserDefaults.standard.set(policy.rawValue, forKey: "desktopASRPolicy") } }
    @Published private(set) var ready = LocalASRService.installed
    @Published private(set) var preparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Whisper tiny 多语言 · Core ML · ANE 优先"
    func prepare() {
        guard !preparing else { return }; preparing = true
        Task {
            defer { preparing = false; ready = LocalASRService.installed }
            do {
                status = "正在下载或准备本地模型，首次编译可能需要几分钟…"
                try await LocalASRService.shared.prepare(download: true, progress: { value in Task { @MainActor in self.progress = value } })
                status = "本地模型已就绪，转写时无需网络；编码器与解码器优先使用 ANE"
            } catch { status = error.localizedDescription }
        }
    }
    func unload() {
        guard !preparing else { return }; preparing = true
        Task {
            await LocalASRService.shared.unload()
            status = "已释放推理模型内存，文件保留，下次按需加载"; preparing = false
        }
    }
}
