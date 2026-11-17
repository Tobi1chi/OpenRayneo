// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AssistantCore
import Foundation

struct RecordingAudioRange: Codable, Equatable {
    var start: Double
    var end: Double

    var label: String { "\(Self.timeLabel(start)) – \(Self.timeLabel(end))" }

    static func timeLabel(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

enum RecordingLibraryAudioTrim {
    static func remap(markers: [RecordingMarker], ranges: [RecordingAudioRange]) -> [RecordingMarker] {
        var result: [RecordingMarker] = []
        var outputStart = 0.0
        for range in ranges {
            for marker in markers where marker.positionSeconds >= range.start && marker.positionSeconds < range.end {
                result.append(RecordingMarker(positionSeconds: outputStart + marker.positionSeconds - range.start,
                    content: marker.content, source: "trimmed", timeBasis: "edited_audio"))
            }
            outputStart += range.end - range.start
        }
        return result
    }

    struct Result {
        let duration: Double
        let ranges: [RecordingAudioRange]
    }

    struct FrameRange {
        let start: AVAudioFramePosition
        let end: AVAudioFramePosition
    }

    static func frameRanges(_ ranges: [RecordingAudioRange], file: AVAudioFile) throws -> [FrameRange] {
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        guard !ranges.isEmpty else { throw AssistantFailure("没有保留的音频片段。") }
        var previousEnd = 0.0
        return try ranges.map { range in
            guard range.start.isFinite, range.end.isFinite, range.start >= previousEnd,
                  range.end > range.start, range.end <= duration else {
                throw AssistantFailure("剪辑区间超出音频范围，请刷新录音后重新选择。")
            }
            previousEnd = range.end
            let start = AVAudioFramePosition((range.start * rate).rounded())
            let end = min(file.length, AVAudioFramePosition((range.end * rate).rounded()))
            guard end > start else { throw AssistantFailure("所选片段短于一个音频采样，请扩大选区。") }
            return FrameRange(start: start, end: end)
        }
    }

    @MainActor
    static func export(source: URL, ranges: [RecordingAudioRange], destination: URL,
                       progress: (Double) -> Void) async throws -> Result {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let selected = try frameRanges(ranges, file: file)
        let format = file.processingFormat
        let total = selected.reduce(AVAudioFramePosition(0)) { $0 + $1.end - $1.start }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings,
                                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { writer = nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw AssistantFailure("无法分配音频剪辑缓冲区。")
        }
        var written: AVAudioFramePosition = 0
        for range in selected {
            file.framePosition = range.start
            while file.framePosition < range.end {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), range.end - file.framePosition))
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw AssistantFailure("音频在所选片段结束前已到达文件尾部。") }
                try writer?.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
                progress(Double(written) / Double(total))
                await Task.yield()
            }
        }
        writer = nil
        return Result(duration: Double(written) / format.sampleRate,
                      ranges: selected.map { RecordingAudioRange(start: Double($0.start) / format.sampleRate,
                                                                 end: Double($0.end) / format.sampleRate) })
    }
}

@MainActor
final class RecordingLibraryTrimPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let file: AVAudioFile
    private let ranges: [RecordingLibraryAudioTrim.FrameRange]
    private let rate: Double

    init(source: URL, ranges: [RecordingAudioRange], finished: @escaping () -> Void) throws {
        file = try AVAudioFile(forReading: source)
        self.ranges = try RecordingLibraryAudioTrim.frameRanges(ranges, file: file)
        rate = file.processingFormat.sampleRate
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        for (index, range) in self.ranges.enumerated() {
            var start = range.start
            while start < range.end {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(UInt32.max), range.end - start))
                let isLast = index == self.ranges.count - 1 && start + AVAudioFramePosition(count) == range.end
                node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil,
                                     completionCallbackType: .dataPlayedBack) { _ in
                    if isLast { Task { @MainActor in finished() } }
                }
                start += AVAudioFramePosition(count)
            }
        }
        try engine.start()
        node.play()
    }

    var sourcePosition: Double {
        guard let time = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: time) else {
            return Double(ranges[0].start) / rate
        }
        var remaining = playerTime.sampleTime
        for range in ranges {
            let length = range.end - range.start
            if remaining < length { return Double(range.start + remaining) / rate }
            remaining -= length
        }
        return Double(ranges.last!.end) / rate
    }

    func stop() { node.stop(); engine.stop() }
}
