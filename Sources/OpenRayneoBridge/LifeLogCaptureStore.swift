// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

enum LifeLogAudioPayload {
    static func isBatched(metadata: [String: Any]) -> Bool {
        ["frameCount", "mode", "vpuMask", "vadMask"].contains { metadata.keys.contains($0) }
    }

    static func frames(audio: Data, metadata: [String: Any]) -> [Data] {
        guard isBatched(metadata: metadata) else { return [audio] }
        let available = audio.count / 240
        let declared = (metadata["frameCount"] as? NSNumber)?.intValue ?? available
        let count = min(31, available, max(0, declared))
        return (0..<count).map { audio.subdata(in: ($0 * 240)..<(($0 + 1) * 240)) }
    }

    static func warnings(audio: Data, metadata: [String: Any]) -> [String] {
        if !isBatched(metadata: metadata) { return audio.isEmpty ? ["旧格式 A3 音频为空。"] : [] }
        let available = audio.count / 240
        let declared = (metadata["frameCount"] as? NSNumber)?.intValue ?? available
        let count = min(31, available, max(0, declared))
        var notes: [String] = []
        if audio.count % 240 != 0 { notes.append("A3 批次含不足 240 字节的尾部，恢复时不解码该尾部。") }
        if available == 0 { notes.append("A3 批次没有完整的 240 字节帧。") }
        if declared != count { notes.append("A3 声明帧数 \(declared) 已收敛为 \(count)。") }
        if available > count { notes.append("A3 批次有 \(available - count) 个完整帧未被声明帧数或 31 帧上限选中。") }
        if let value = metadata["frameCount"], !(value is NSNull), !(value is NSNumber) {
            notes.append("A3 frameCount 不是数值，按可用帧数恢复。")
        }
        return notes
    }
}

struct LifeLogCaptureManifest: Codable, Identifiable {
    let id: String
    let taskID: String
    let observationID: String
    let startedAt: Date
    var endedAt: Date?
    var closed = false
    var receivedCount = 0
    /// Received audio bytes, excluding the local record headers and metadata.
    var bytes = 0
    var notes: [String] = []
    let rawPath: String
}

/// Called serially by the LifeLog receiver. This is a local capture format, not a glasses file format.
final class LifeLogCaptureStore {
    struct RecoveryResult {
        let seconds: Double
        /// Number of successfully decoded Opus packets, not PCM sample frames.
        let frames: Int
        let note: String
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/LifeLogCaptures", isDirectory: true)
    }

    private let observationID: String
    private let directory: URL
    private var manifest: LifeLogCaptureManifest?
    private var manifestURL: URL?
    private var writer: FileHandle?

    init(observationID: String, directory: URL? = nil) throws {
        self.observationID = observationID
        self.directory = directory ?? Self.defaultDirectory
    }

    func beginRound(taskID: String) throws {
        try endRound(reason: "下一轮开始")
        let id = UUID().uuidString.lowercased()
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = folder.appendingPathComponent("audio.a3capture")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LifeLogCaptureFailure("无法创建 LifeLog 原始采集文件。")
        }
        let metadata = folder.appendingPathComponent("manifest.json")
        let entry = LifeLogCaptureManifest(id: id, taskID: taskID, observationID: observationID, startedAt: Date(), rawPath: raw.path)
        let handle = try FileHandle(forWritingTo: raw)
        do { try Self.checkpoint(entry, at: metadata) }
        catch { try? handle.close(); throw error }
        manifest = entry; manifestURL = metadata; writer = handle
    }

    func append(message: RemoteMessage, taskID: String, attribution: String) throws {
        guard var entry = manifest, let metadataURL = manifestURL, let writer else {
            throw LifeLogCaptureFailure("LifeLog 采集没有活动轮次。")
        }
        guard entry.taskID == taskID else { throw LifeLogCaptureFailure("LifeLog 采集轮次不匹配，未将音频写入其他任务。") }
        let audio = message.audioData ?? Data()
        let original = message.json ?? [:]
        let metadata: [String: Any] = ["receivedAt": message.receivedAt.timeIntervalSince1970,
            "sequence": Int(message.sequence), "json": message.json as Any? ?? NSNull(), "attribution": attribution, "taskID": taskID]
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        // Each source message fits the shared 16-bit transport frame. Larger records indicate a corrupt local file.
        guard json.count <= 1_048_576, audio.count <= 1_048_576 else {
            throw LifeLogCaptureFailure("LifeLog 单条采集记录超过本地格式上限。")
        }
        var header = Data()
        for length in [json.count, audio.count] {
            let value = UInt32(length)
            header.append(contentsOf: [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        do {
            try writer.write(contentsOf: header); try writer.write(contentsOf: json); try writer.write(contentsOf: audio)
            entry.receivedCount += 1; entry.bytes += audio.count
            for note in LifeLogAudioPayload.warnings(audio: audio, metadata: original) where !entry.notes.contains(note) {
                entry.notes.append(note)
            }
            if attribution == "active_round_fallback", !entry.notes.contains(Self.fallbackNote) { entry.notes.append(Self.fallbackNote) }
            manifest = entry
            try Self.checkpoint(entry, at: metadataURL)
        } catch {
            entry.notes.append("原始记录写入或清单更新中断；仅可恢复磁盘上的完整记录。")
            manifest = nil; self.writer = nil; manifestURL = nil
            try? writer.close(); try? Self.checkpoint(entry, at: metadataURL)
            throw error
        }
    }

    func endRound(reason: String) throws {
        guard var entry = manifest, let metadataURL = manifestURL, let writer else { return }
        manifest = nil; manifestURL = nil; self.writer = nil
        var closingError: Error?
        do { try writer.synchronize() } catch { closingError = error }
        do { try writer.close() } catch { closingError = closingError ?? error }
        entry.endedAt = Date(); entry.closed = closingError == nil
        entry.notes.append("本地收尾：\(reason)。收尾不证明设备原始音频完整。")
        if closingError != nil { entry.notes.append("文件收尾失败；仅可恢复磁盘上的完整记录。") }
        try Self.checkpoint(entry, at: metadataURL)
        if let closingError { throw closingError }
    }

    func finish() throws { try endRound(reason: "采集结束") }

    static func readManifest(at url: URL) throws -> LifeLogCaptureManifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LifeLogCaptureManifest.self, from: Data(contentsOf: url))
    }

    @MainActor
    static func recover(manifestURL: URL, destination: URL, progress: (Double) -> Void) async throws -> RecoveryResult {
        let entry = try readManifest(at: manifestURL)
        let sourceURL = URL(fileURLWithPath: entry.rawPath)
        guard sourceURL.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw LifeLogCaptureFailure("请选择尚不存在的新 WAV 位置；原始采集文件不会覆盖。")
        }
        let source = try FileHandle(forReadingFrom: sourceURL); defer { try? source.close() }
        let size = try source.seekToEnd(); try source.seek(toOffset: 0)
        let decoder = try OpusDecoder(sampleRate: 16_000, channels: 1)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output = nil }
        var position: UInt64 = 0, pcmFrames: AVAudioFramePosition = 0
        var decoded = 0, records = 0, corrupt = 0
        var notes = entry.notes
        if !entry.closed { notes.append("上次采集未完成本地收尾。") }
        while position < size {
            try Task.checkCancellation()
            guard size - position >= 8 else { notes.append("文件末尾记录头不完整，恢复已停止。"); break }
            guard let header = try source.read(upToCount: 8), header.count == 8 else {
                notes.append("文件末尾记录头不完整，恢复已停止。"); break
            }
            position += 8
            let jsonLength = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let audioLength = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let recordBytes = UInt64(jsonLength) + UInt64(audioLength)
            guard recordBytes <= size - position else { notes.append("文件末尾记录未写完，恢复已停止。"); break }
            guard jsonLength <= 1_048_576, audioLength <= 1_048_576 else {
                corrupt += 1; position += recordBytes; try source.seek(toOffset: position); continue
            }
            let json = try source.read(upToCount: Int(jsonLength)) ?? Data()
            let audio = try source.read(upToCount: Int(audioLength)) ?? Data()
            position += recordBytes
            guard json.count == Int(jsonLength), audio.count == Int(audioLength) else {
                notes.append("文件在读取过程中变短，恢复已停止。"); break
            }
            guard let record = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
                corrupt += 1; continue
            }
            let metadata = record["json"] as? [String: Any] ?? [:]
            for note in LifeLogAudioPayload.warnings(audio: audio, metadata: metadata) where !notes.contains(note) { notes.append(note) }
            records += 1
            for packet in LifeLogAudioPayload.frames(audio: audio, metadata: metadata) {
                try Task.checkCancellation()
                // An empty packet asks libopus to synthesize lost audio; recovery must not insert that audio.
                guard !packet.isEmpty else { corrupt += 1; continue }
                let pcm: AVAudioPCMBuffer
                do { pcm = try decoder.decode(packet) }
                catch { corrupt += 1; continue }
                try output?.write(from: pcm)
                decoded += 1; pcmFrames += AVAudioFramePosition(pcm.frameLength)
            }
            progress(size == 0 ? 1 : Double(position) / Double(size))
            if records % 25 == 0 { await Task.yield() }
        }
        try Task.checkCancellation()
        guard decoded > 0 else { throw LifeLogCaptureFailure("采集中没有可解码的完整 Opus 音频；原文件保留，未生成可用恢复录音。") }
        output = nil
        progress(1)
        let seconds = Double(pcmFrames) / 16_000
        if corrupt > 0 { notes.append("跳过 \(corrupt) 条损坏记录或无法解码的音频帧。") }
        let note = "LifeLog 本地恢复：从 \(records) 条采集记录解码 \(decoded) 个 Opus 帧；只包含实际收到并解码的音频，不补静音，不证明原始录音完整。"
            + (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
        return RecoveryResult(seconds: seconds, frames: decoded, note: note)
    }

    private static let fallbackNote = "部分音频没有 taskId，按当前活动轮次归属；无法证明跨轮迟到匿名包的来源。"

    private static func checkpoint(_ entry: LifeLogCaptureManifest, at url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { try? writer?.close() }
}

private struct LifeLogCaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
