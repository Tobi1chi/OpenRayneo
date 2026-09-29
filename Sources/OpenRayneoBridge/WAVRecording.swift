// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Darwin
import Foundation

/// Appends PCM frames to one WAV file; memory use does not grow with duration.
final class WAVRecording {
    let url: URL
    let sampleRate: Int
    let channels: Int
    private let file: FileHandle
    private var dataBytes: UInt32 = 0
    private var lastCheckpoint = Date()
    private(set) var finalized = false

    init(sampleRate: Int = 48_000, channels: Int = 2) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        let directory: URL
        if let configured = ProcessInfo.processInfo.environment["OPENRAYNEO_RECORDINGS_DIR"] {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            directory = music.appendingPathComponent("OpenRayneo/Recordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyyMMdd-HHmmss"
        url = directory.appendingPathComponent("rayneo-\(date.string(from: Date()))-\(UUID().uuidString.prefix(8)).wav")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BridgeError(status: 503, message: "Could not create the WAV recording") }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: header())
    }

    var status: [String: Any] {
        ["path": url.path, "sampleRate": sampleRate, "channels": channels, "bitsPerSample": 16,
         "bytes": UInt64(dataBytes) + 44, "seconds": Double(dataBytes) / Double(sampleRate * channels * 2),
         "finalized": finalized]
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        let frameCount = Int(buffer.frameLength)
        let byteCount = frameCount * channels * 2
        guard !finalized, buffer.format.channelCount == channels,
              buffer.format.sampleRate == Double(sampleRate), let samples = buffer.floatChannelData else {
            throw BridgeError(status: 503, message: "Unexpected WAV audio format")
        }
        guard UInt64(dataBytes) + UInt64(byteCount) <= UInt64(UInt32.max) - 36 else {
            throw BridgeError(status: 413, message: "Recording reached the classic WAV 4 GiB limit")
        }
        var pcm = Data(capacity: byteCount)
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let sample = Int16(max(-32768, min(32767, Int((samples[channel][frame] * 32768).rounded()))))
                pcm.appendLittleEndian(UInt16(bitPattern: sample))
            }
        }
        try file.write(contentsOf: pcm)
        dataBytes += UInt32(byteCount)
        if Date().timeIntervalSince(lastCheckpoint) >= 1 {
            try checkpoint()
            lastCheckpoint = Date()
        }
    }

    private func header() -> Data {
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataBytes)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // Linear PCM
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * channels * 2))
        data.appendLittleEndian(UInt16(channels * 2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(dataBytes)
        return data
    }

    private func checkpoint() throws {
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header())
        try file.seek(toOffset: UInt64(dataBytes) + 44)
        try file.synchronize()
    }

    func finish() throws {
        guard !finalized else { return }
        try checkpoint()
        try file.close()
        finalized = true
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
