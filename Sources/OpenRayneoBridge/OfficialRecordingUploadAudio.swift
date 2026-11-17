// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

@MainActor
enum OfficialRecordingUploadAudio {
    struct Result {
        let fileURL: URL
        let durationMilliseconds: Int64
        let channelCount: Int
    }

    /// Freezes one completed library entry into a task-owned staging directory.
    static func prepare(entry: RecordingLibraryEntry, destinationDirectory: URL,
                        progress: @escaping (Double) -> Void) async throws -> Result {
        guard entry.finalized else { throw failure("录音尚未完成保存，请完成收音或恢复后再上传。") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let source = try sourceURL(entry)
        let input = try FileHandle(forReadingFrom: source)
        let signature = try input.read(upToCount: 4)
        try input.close()
        let nativeRaw = entry.source == "native" && source.path == entry.rawAudioPath
        let ogg = signature == Data("OggS".utf8)
        let destination = destinationDirectory.appendingPathComponent(destinationDirectory.lastPathComponent)
            .appendingPathExtension(ogg || nativeRaw ? "opus" : "wav")
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw failure("上传暂存目录不能覆盖原始录音。")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let result: Result
            if ogg || nativeRaw { result = try await oggResult(destination) }
            else { result = try audioResult(destination) }
            progress(1)
            return result
        }
        let temporary = destinationDirectory.appendingPathComponent(".preparing-" + UUID().uuidString)
            .appendingPathExtension(ogg || nativeRaw ? "opus" : "wav")
        do {
            let result: Result
            if ogg {
                try await copy(source, to: temporary, progress: progress)
                result = try await oggResult(temporary)
            } else if nativeRaw {
                result = try await packageNative(source, to: temporary, progress: progress)
            } else {
                result = try await freezeWAV(source, to: temporary, progress: progress)
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress(1)
            return Result(fileURL: destination, durationMilliseconds: result.durationMilliseconds,
                          channelCount: result.channelCount)
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil)
            }
            throw error
        }
    }

    private static func sourceURL(_ entry: RecordingLibraryEntry) throws -> URL {
        if entry.source == "native" {
            guard let metadata = entry.nativeMetadataPath,
                  let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: metadata))) as? [String: Any],
                  record["finalized"] as? Bool == true, record["completed"] as? Bool == true else {
                throw failure("原生录音缺少已完成接收和收尾的元数据，不能作为完整录音上传。")
            }
            if let path = entry.rawAudioPath, FileManager.default.fileExists(atPath: path) {
                guard record["rawPath"] as? String == path,
                      let ranges = record["ranges"] as? [[String: Any]], ranges.count == 1,
                      (ranges[0]["offset"] as? NSNumber)?.intValue == 0,
                      let length = (ranges[0]["length"] as? NSNumber)?.int64Value, length > 0 else {
                    throw failure("原生录音的原始音频覆盖范围不完整。")
                }
                let url = URL(fileURLWithPath: path)
                let size = try fileSize(url)
                guard size == UInt64(length),
                      (record["expectedBytes"] as? NSNumber).map({ length >= $0.int64Value }) ?? true else {
                    throw failure("原生录音大小与完成接收的覆盖范围不一致，请先刷新录音。")
                }
                return url
            }
        }
        guard let url = entry.audioURL, FileManager.default.fileExists(atPath: url.path) else {
            throw failure("已完成的录音文件不存在。")
        }
        return url
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw failure("无法读取录音文件大小。") }
        return size.uint64Value
    }

    private static func copy(_ source: URL, to destination: URL,
                             progress: (Double) -> Void) async throws {
        let size = try fileSize(source)
        guard size > 0 else { throw failure("录音文件为空。") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw failure("无法创建上传音频副本。")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while copied < size {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Int(min(1_048_576, size - copied))), !data.isEmpty else {
                throw failure("原始录音在复制完成前结束。")
            }
            try output.write(contentsOf: data)
            copied += UInt64(data.count)
            progress(Double(copied) / Double(size))
            await Task.yield()
        }
        try output.synchronize()
        try output.close()
    }

    private static func packageNative(_ source: URL, to destination: URL,
                                      progress: (Double) -> Void) async throws -> Result {
        let bytes = try fileSize(source)
        guard bytes > 0, bytes % 240 == 0 else {
            throw failure("原生音频未按完整的 240 字节 Opus 包对齐，不能上传不完整尾部。")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw failure("无法创建上传音频副本。")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let decoder = try OpusDecoder(sampleRate: 48_000, channels: 2)
        var writer = OggWriter(output: output)
        try writer.begin()
        var consumed: UInt64 = 0
        while consumed < bytes {
            try Task.checkCancellation()
            var packets: [Data] = []
            for _ in 0..<50 where consumed < bytes {
                guard let packet = try input.read(upToCount: 240), packet.count == 240 else {
                    throw failure("原生音频在完整包结束前被截断。")
                }
                guard try decoder.decode(packet).frameLength == 960 else {
                    throw failure("原生音频包不是当前支持的 20 毫秒 Opus 格式。")
                }
                packets.append(packet)
                consumed += 240
            }
            try writer.audio(packets, final: consumed == bytes)
            progress(Double(consumed) / Double(bytes))
            await Task.yield()
        }
        try output.synchronize()
        try output.close()
        return Result(fileURL: destination, durationMilliseconds: Int64(bytes / 240) * 20, channelCount: 2)
    }

    private static func freezeWAV(_ source: URL, to destination: URL,
                                  progress: (Double) -> Void) async throws -> Result {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate > 0, format.channelCount > 0,
              Double(input.length) * Double(format.channelCount) * 2 <= Double(UInt32.max) - 36 else {
            throw failure("录音为空或超过标准 WAV 的容量限制。")
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings,
                                                 commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output = nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw failure("无法分配上传音频转换缓冲区。")
        }
        let frames = input.length
        var written: AVAudioFramePosition = 0
        while written < frames {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, frames - written)))
            guard buffer.frameLength > 0 else { throw failure("录音文件在转换完成前结束。") }
            try output?.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
            progress(Double(written) / Double(frames))
            await Task.yield()
        }
        output = nil
        return try audioResult(destination)
    }

    private static func audioResult(_ url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate > 0, file.processingFormat.channelCount > 0 else {
            throw failure("上传音频没有可读取的完整采样。")
        }
        return Result(fileURL: url, durationMilliseconds: Int64((Double(file.length) / rate * 1000).rounded()),
                      channelCount: Int(file.processingFormat.channelCount))
    }

    private static func oggResult(_ url: URL) async throws -> Result {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var channels: Int?
        var preSkip: UInt64 = 0
        var serial: UInt64?
        var finalGranule: UInt64?
        var pageCount = 0
        while let header = try file.read(upToCount: 27), !header.isEmpty {
            try Task.checkCancellation()
            guard header.count == 27, header.prefix(4) == Data("OggS".utf8), header[4] == 0 else {
                throw failure("Ogg 音频页不完整。")
            }
            let laceCount = Int(header[26])
            let laces = laceCount == 0 ? Data() : try file.read(upToCount: laceCount) ?? Data()
            guard laces.count == laceCount else { throw failure("Ogg 音频页不完整。") }
            let payloadSize = laces.reduce(0) { $0 + Int($1) }
            let payload = payloadSize == 0 ? Data() : try file.read(upToCount: payloadSize) ?? Data()
            guard payload.count == payloadSize else {
                throw failure("Ogg 音频页不完整。")
            }
            let pageSerial = littleEndian(header, offset: 14, count: 4)
            if let serial, serial != pageSerial { throw failure("暂不支持包含多个逻辑音轨的 Ogg 文件。") }
            serial = pageSerial
            if channels == nil {
                guard payload.count >= 19, payload.prefix(8) == Data("OpusHead".utf8),
                      payload[9] > 0, payload[18] == 0, payload[9] <= 2 else {
                    throw failure("暂不支持这个 Ogg 音频编码或声道映射。")
                }
                channels = Int(payload[9])
                preSkip = littleEndian(payload, offset: 10, count: 2)
            }
            if header[5] & 4 != 0 { finalGranule = littleEndian(header, offset: 6, count: 8) }
            pageCount += 1
            if pageCount % 50 == 0 { await Task.yield() }
        }
        guard let channels, let frames = finalGranule, frames > preSkip,
              frames != UInt64.max, frames / 48 < UInt64(Int64.max) else {
            throw failure("Ogg 录音缺少完成页或有效时长。")
        }
        return Result(fileURL: url, durationMilliseconds: Int64(((Double(frames - preSkip) / 48).rounded())),
                      channelCount: channels)
    }

    private static func littleEndian(_ data: Data, offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    private static func failure(_ message: String) -> OfficialMemoryFailure {
        OfficialMemoryFailure(message: message)
    }

    private struct OggWriter {
        let output: FileHandle
        private var sequence: UInt32 = 0
        private let serial = UInt32.random(in: 1...UInt32.max)
        private var granule: UInt64 = 0

        init(output: FileHandle) { self.output = output }

        mutating func begin() throws {
            var head = Data("OpusHead".utf8)
            head.append(contentsOf: [1, 2])
            head.uploadAppend(UInt16(312)) // Official AudioConvertUtil identification header and granule origin.
            head.uploadAppend(UInt32(16_000))
            head.uploadAppend(UInt16(0))
            head.append(0)
            try page([head], flags: 2)
            let vendor = Data("OpenRayneo".utf8)
            var tags = Data("OpusTags".utf8)
            tags.uploadAppend(UInt32(vendor.count)); tags.append(vendor); tags.uploadAppend(UInt32(0))
            try page([tags], flags: 0)
            granule = 312
        }

        mutating func audio(_ packets: [Data], final: Bool) throws {
            granule += UInt64(packets.count) * 960
            try page(packets, flags: final ? 4 : 0)
        }

        private mutating func page(_ packets: [Data], flags: UInt8) throws {
            var data = Data("OggS".utf8)
            data.append(contentsOf: [0, flags])
            data.uploadAppend(granule); data.uploadAppend(serial); data.uploadAppend(sequence)
            data.uploadAppend(UInt32(0))
            // Our identification/comment packets and fixed 240-byte audio packets each fit one lace.
            data.append(UInt8(packets.count))
            for packet in packets { data.append(UInt8(packet.count)) }
            for packet in packets { data.append(packet) }
            var crc: UInt32 = 0
            for byte in data {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = crc & 0x8000_0000 == 0 ? crc << 1 : (crc << 1) ^ 0x04c1_1db7 }
            }
            for index in 0..<4 { data[22 + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
            try output.write(contentsOf: data)
            sequence &+= 1
        }
    }
}

private extension Data {
    mutating func uploadAppend<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
