// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import AssistantCore
import Foundation
import Security
import LocalAuthentication

enum LocalVoiceStore {
    private static let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.openrayneo.bridge.voice-profiles", kSecAttrAccount as String: "people"]
    static func load() throws -> [LocalVoicePerson] {
        var query = identity; query[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw AssistantFailure("声音档案钥匙串读取失败：\(status)") }
        return try JSONDecoder().decode([LocalVoicePerson].self, from: data)
    }
    static func save(_ people: [LocalVoicePerson]) throws {
        let data = try JSONEncoder().encode(people)
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantFailure("声音档案保存失败：\(status)") }
    }
    static func ensureSelf() throws -> LocalVoicePerson {
        let people = try load()
        if let person = people.first(where: \.isSelf) { return person }
        let person = LocalVoicePerson(name: "我", isSelf: true)
        try save(people + [person])
        return person
    }
}

/// Selects a channel before conversion. Native glasses 48k PCM uses the Android FIR;
/// 16k input is unchanged; other file rates first use AVAudioConverter to reach 48k.
final class LocalVoiceAudioReader {
    private let file: AVAudioFile
    private let input: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private var ended = false
    private var resamplers = [LocalVoiceResampler(), LocalVoiceResampler()]
    private let channel: Int
    var progress: Double { file.length == 0 ? 1 : Double(file.framePosition) / Double(file.length) }
    let duration: Double
    let inputChannels: Int
    let outputChannels: Int
    init(url: URL, channel: Int) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.channel = channel
        inputChannels = Int(file.processingFormat.channelCount)
        guard (1...2).contains(inputChannels), channel != 2 || inputChannels == 2 else {
            throw AssistantFailure("请选择真实单/双声道输入；单声道文件没有第二路")
        }
        outputChannels = channel == 3 ? inputChannels : 1
        duration = Double(file.length) / file.processingFormat.sampleRate
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw AssistantFailure("无法分配音频缓冲") }
        self.input = input
        if [16000, 48000].contains(file.processingFormat.sampleRate) { converter = nil }
        else {
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: file.processingFormat.channelCount, interleaved: false)!
            guard let value = AVAudioConverter(from: file.processingFormat, to: target) else { throw AssistantFailure("无法转换音频采样率") }
            converter = value
        }
    }
    func next() throws -> [Float]? {
        try nextChannels()?.first
    }
    func nextChannels() throws -> [[Float]]? {
        guard !ended else { return nil }
        let buffer: AVAudioPCMBuffer
        if let converter {
            buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 9600)!
            var error: NSError?, readError: Error?
            let result = converter.convert(to: buffer, error: &error) { [self] requested, status in
                do {
                    guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity, AVAudioFrameCount(file.length - file.framePosition)))
                    status.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch { readError = error; status.pointee = .endOfStream; return nil }
            }
            if let error { throw error }; if let readError { throw readError }
            ended = result == .endOfStream
        } else {
            guard file.framePosition < file.length else { ended = true; return nil }
            try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition)))
            buffer = input; ended = input.frameLength == 0
        }
        guard buffer.frameLength > 0 else { return nil }
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![min(1, Int(buffer.format.channelCount) - 1)]
        return (0..<outputChannels).map { lane in
            let samples = (0..<Int(buffer.frameLength)).map { index -> Float in
                let value = channel == 3 ? (lane == 0 ? left[index] : right[index]) : channel == 1 ? left[index] : channel == 2 ? right[index] : (left[index] + right[index]) * 0.5
                return Float(max(-32768, min(32767, Int(value * 32768)))) / 32768
            }
            return buffer.format.sampleRate == 16000 ? samples : resamplers[lane].convert(samples)
        }
    }
    static func decodePCM16(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count - 1, by: 2).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768 }
        }
    }
    static func decodePCM16Channels(_ data: Data, channels: Int) -> [[Float]] {
        let values = decodePCM16(data)
        return (0..<channels).map { channel in stride(from: channel, to: values.count, by: channels).map { values[$0] } }
    }
    static func encodePCM16(_ channels: [[Float]]) -> Data {
        guard let first = channels.first else { return Data() }
        var data = Data(capacity: first.count * channels.count * 2)
        for frame in first.indices {
            for channel in channels {
                var value = Int16(max(-32768, min(32767, Int(channel[frame] * 32768)))).littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
        }
        return data
    }
}

@MainActor
final class LocalVoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!)
    }
    func play(_ samples: [Float], from: Int64, to: Int64) throws {
        stop()
        let first = max(0, min(samples.count, Int(from * 16))), last = max(0, min(samples.count, Int(to * 16)))
        guard last > first else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress! + first, count: last - first) }
        try engine.start(); node.scheduleBuffer(buffer); node.play()
    }
    func stop() { node.stop(); engine.stop() }
}
