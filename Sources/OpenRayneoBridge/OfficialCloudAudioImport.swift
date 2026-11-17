// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

@MainActor
enum OfficialCloudAudioImport {
    struct Result {
        let audioURL: URL
        let duration: Double
        let channelCount: Int
        /// Ogg's final granule / 48 kHz; this can differ from the playable PCM duration.
        let containerDuration: Double?
    }

    /// The caller owns the completed download. This creates a separate playable copy without moving it.
    static func prepare(source: URL, directory: URL,
                        progress: @escaping (Double) -> Void) async throws -> Result {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let input = try FileHandle(forReadingFrom: source)
        let signature = try input.read(upToCount: 4)
        try input.close()
        let identifier = UUID().uuidString
        let temporary = directory.appendingPathComponent(".preparing-" + identifier + ".wav")
        let destination = directory.appendingPathComponent("playback-" + identifier + ".wav")
        do {
            let decoded: Decoded
            if signature == Data("OggS".utf8) {
                decoded = try await decodeOgg(source, destination: temporary, progress: progress)
            } else {
                decoded = try await decodeReadable(source, destination: temporary, progress: progress)
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress(1)
            return Result(audioURL: destination, duration: decoded.duration,
                          channelCount: decoded.channels, containerDuration: decoded.containerDuration)
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil)
            }
            throw error
        }
    }

    private struct Decoded {
        let duration: Double
        let channels: Int
        let containerDuration: Double?
    }

    private static func decodeReadable(_ source: URL, destination: URL,
                                       progress: (Double) -> Void) async throws -> Decoded {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard input.length > 0 else { throw failure("下载的音频没有可解码的采样。") }
        let writer = try PCMWriter(url: destination, format: format)
        defer { writer.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw failure("无法分配云音频解码缓冲区。")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, input.length - input.framePosition)))
            guard buffer.frameLength > 0 else { throw failure("下载的音频在完整解码前结束。") }
            try writer.append(buffer)
            progress(Double(input.framePosition) / Double(input.length))
            await Task.yield()
        }
        return try writer.finish(containerDuration: nil)
    }

    private static func decodeOgg(_ source: URL, destination: URL,
                                  progress: (Double) -> Void) async throws -> Decoded {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        var serial: UInt64?
        var nextSequence: UInt32?
        var partial = Data()
        var hasPartialPacket = false
        var packetIndex = 0
        var decoder: OpusDecoder?
        var writer: PCMWriter?
        defer { writer?.close() }
        var preSkip: Int64 = 0
        var gain: Float = 1
        var decodedFrames: Int64 = 0
        var granuleOrigin: Int64?
        var finalGranule: Int64?
        var ended = false
        var pages = 0

        while let header = try input.read(upToCount: 27), !header.isEmpty {
            try Task.checkCancellation()
            guard !ended, header.count == 27, header.prefix(4) == Data("OggS".utf8), header[4] == 0 else {
                throw failure("下载的 Ogg 音频页不完整，或包含暂不支持的多段音轨。")
            }
            let flags = header[5]
            let pageSerial = littleEndian(header, offset: 14, count: 4)
            let sequence = UInt32(littleEndian(header, offset: 18, count: 4))
            if let serial {
                guard serial == pageSerial, nextSequence == sequence, flags & 2 == 0 else {
                    throw failure("Ogg 音轨不连续，或包含多个逻辑音轨。")
                }
            } else {
                guard flags & 2 != 0 else { throw failure("Ogg 音频缺少起始页。") }
                serial = pageSerial
            }
            nextSequence = sequence &+ 1
            guard (flags & 1 != 0) == hasPartialPacket else {
                throw failure("Ogg 跨页音频包不连续。")
            }
            let segmentCount = Int(header[26])
            let laces = segmentCount == 0 ? Data() : try read(input, count: segmentCount)
            let payloadSize = laces.reduce(0) { $0 + Int($1) }
            let payload = payloadSize == 0 ? Data() : try read(input, count: payloadSize)
            var offset = 0
            var audio: [AVAudioPCMBuffer] = []
            let pageStart = decodedFrames
            for lace in laces {
                let count = Int(lace)
                partial.append(payload.subdata(in: offset..<(offset + count)))
                offset += count
                hasPartialPacket = count == 255
                if hasPartialPacket { continue }
                let packet = partial
                partial = Data()
                if packetIndex == 0 {
                    guard packet.count >= 19, packet.prefix(8) == Data("OpusHead".utf8),
                          packet[8] > 0, packet[8] < 16, (1...2).contains(packet[9]), packet[18] == 0 else {
                        throw failure("仅支持单音轨、单／双声道的 Ogg-Opus 音频。")
                    }
                    preSkip = Int64(littleEndian(packet, offset: 10, count: 2))
                    let decibels = Double(Int16(bitPattern: UInt16(littleEndian(packet, offset: 16, count: 2)))) / 256
                    gain = Float(pow(10, decibels / 20))
                    let opus = try OpusDecoder(sampleRate: 48_000, channels: Int(packet[9]))
                    decoder = opus
                    writer = try PCMWriter(url: destination, format: opus.format)
                } else if packetIndex == 1 {
                    guard packet.count >= 8, packet.prefix(8) == Data("OpusTags".utf8) else {
                        throw failure("Ogg-Opus 音频缺少注释头。")
                    }
                } else {
                    guard !packet.isEmpty, let decoder else { throw failure("Ogg-Opus 音频包为空。") }
                    let buffer = try decoder.decode(packet)
                    audio.append(buffer)
                    decodedFrames += Int64(buffer.frameLength)
                }
                packetIndex += 1
            }
            let rawGranule = littleEndian(header, offset: 6, count: 8)
            let granule = rawGranule <= UInt64(Int64.max) ? Int64(rawGranule) : nil
            if !audio.isEmpty, let granule, granuleOrigin == nil {
                // Official native files begin at granule 312 even though no corresponding PCM was added.
                granuleOrigin = max(0, granule - decodedFrames)
            }
            var rawFrameLimit = decodedFrames
            if flags & 4 != 0 {
                guard !hasPartialPacket, let granule, let origin = granuleOrigin,
                      granule >= origin + preSkip else {
                    throw failure("Ogg-Opus 完成页缺少有效的最终采样位置。")
                }
                finalGranule = granule
                rawFrameLimit = min(decodedFrames, granule - origin)
                guard let writer, writer.frames <= max(0, rawFrameLimit - preSkip) else {
                    throw failure("Ogg-Opus 完成页的结束位置早于已完成的音频页。")
                }
                ended = true
            }
            var position = pageStart
            for buffer in audio {
                let end = position + Int64(buffer.frameLength)
                let lower = max(position, preSkip)
                let upper = min(end, rawFrameLimit)
                if upper > lower, let writer {
                    try writer.append(buffer, start: Int(lower - position), count: Int(upper - lower), gain: gain)
                }
                position = end
            }
            pages += 1
            progress(size == 0 ? 0 : Double(try input.offset()) / Double(size))
            if pages % 20 == 0 { await Task.yield() }
        }
        guard ended, !hasPartialPacket, packetIndex > 2, let finalGranule, let writer else {
            throw failure("下载的 Ogg-Opus 音频缺少完整的结束页或音频包。")
        }
        return try writer.finish(containerDuration: Double(finalGranule) / 48_000)
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw failure("下载的 Ogg 音频页被截断。")
        }
        return data
    }

    private static func littleEndian(_ data: Data, offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    private static func failure(_ message: String) -> OfficialMemoryFailure { OfficialMemoryFailure(message: message) }

    @MainActor
    private final class PCMWriter {
        private var file: AVAudioFile?
        private let format: AVAudioFormat
        private(set) var frames: Int64 = 0

        init(url: URL, format: AVAudioFormat) throws {
            self.format = format
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        func append(_ buffer: AVAudioPCMBuffer) throws {
            try append(buffer, start: 0, count: Int(buffer.frameLength), gain: 1)
        }

        func append(_ buffer: AVAudioPCMBuffer, start: Int, count: Int, gain: Float) throws {
            guard (UInt64(frames) + UInt64(count)) * UInt64(format.channelCount) * 2 <= UInt64(UInt32.max) - 36 else {
                throw failure("云音频超过标准 WAV 的容量限制。")
            }
            guard let file else { throw failure("云音频输出文件已关闭。") }
            if start == 0, count == Int(buffer.frameLength), gain == 1 {
                try file.write(from: buffer)
            } else {
                guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let source = buffer.floatChannelData, let destination = trimmed.floatChannelData else {
                    throw failure("无法分配云音频裁剪缓冲区。")
                }
                trimmed.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<count { destination[channel][frame] = source[channel][start + frame] * gain }
                }
                try file.write(from: trimmed)
            }
            frames += Int64(count)
        }

        func close() { file = nil }

        func finish(containerDuration: Double?) throws -> Decoded {
            close()
            guard frames > 0 else { throw failure("云音频去除编码前导采样后没有可播放内容。") }
            return Decoded(duration: Double(frames) / format.sampleRate,
                           channels: Int(format.channelCount), containerDuration: containerDuration)
        }
    }
}
