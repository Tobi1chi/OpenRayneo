// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct VirtualAudioDevice: Identifiable {
    let deviceID: AudioDeviceID
    let id: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var json: [String: Any] {
        ["uid": id, "name": name, "inputChannels": inputChannels, "outputChannels": outputChannels]
    }
}

/// A short FIFO keeps Bluetooth bursts from building up seconds of stale speech.
final class MicrophonePCMQueue {
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: 12_000)
    private var readIndex = 0
    private var count = 0
    private var primed = false
    private var droppedFrames = 0
    private var underrunFrames = 0

    func append(_ buffer: AVAudioPCMBuffer, channel: Int) {
        let source = buffer.floatChannelData![channel]
        let frames = Int(buffer.frameLength)
        lock.lock()
        defer { lock.unlock() }
        let kept = min(frames, samples.count)
        let discarded = max(0, count + kept - samples.count)
        readIndex = (readIndex + discarded) % samples.count
        count -= discarded
        droppedFrames += discarded + frames - kept
        for frame in (frames - kept)..<frames {
            samples[(readIndex + count) % samples.count] = source[frame]
            count += 1
        }
    }

    func render(into output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        // Never wait for the producer on the audio render thread.
        guard lock.try() else {
            output.update(repeating: 0, count: frames)
            return false
        }
        defer { lock.unlock() }
        if !primed, count >= max(1_920, frames) { primed = true } // At least 40 ms and one render block.
        let available = primed ? min(count, frames) : 0
        for frame in 0..<available {
            output[frame] = samples[(readIndex + frame) % samples.count]
        }
        output.advanced(by: available).update(repeating: 0, count: frames - available)
        readIndex = (readIndex + available) % samples.count
        count -= available
        underrunFrames += frames - available
        if count == 0 { primed = false }
        return available > 0
    }

    var status: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["bufferedSeconds": Double(count) / 48_000, "droppedFrames": droppedFrames,
                "underrunFrames": underrunFrames]
    }
}

/// Writes glasses PCM to the output side of an installed loopback audio device.
/// Its input side is the microphone selected by Codex or another receiving app.
final class VirtualMicrophone {
    static let builtInDeviceUIDs = ["com.openrayneo.microphone.channel1", "com.openrayneo.microphone.channel2"]

    static func builtInPair() throws -> [VirtualMicrophone] {
        let installed = try availableDevices()
        guard builtInDeviceUIDs.allSatisfy({ uid in installed.contains { $0.id == uid } }) else {
            throw BridgeError(status: 503, message: "Install the bundled OpenRayneo Audio driver; both Channel 1 and Channel 2 must be available")
        }
        return try builtInDeviceUIDs.enumerated().map { try VirtualMicrophone(deviceUID: $0.element, channel: $0.offset + 1) }
    }

    let device: VirtualAudioDevice
    let channel: Int
    private let engine = AVAudioEngine()
    private let pcm = MicrophonePCMQueue()
    private var source: AVAudioSourceNode?
    private var outputSampleRate = 0.0

    init(deviceUID: String, channel: Int) throws {
        guard (1...2).contains(channel) else {
            throw BridgeError(status: 400, message: "channel must be 1 (wearer) or 2 (forward)")
        }
        guard let device = try Self.availableDevices().first(where: { $0.id == deviceUID }) else {
            throw BridgeError(status: 400, message: "Virtual audio device is unavailable; install the bundled OpenRayneo Audio driver and refresh GET /v1/virtual-mic/devices")
        }
        self.device = device
        self.channel = channel
    }

    func start() throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw BridgeError(status: 503, message: "The audio output unit is unavailable")
        }
        var deviceID = device.deviceID
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &deviceID,
                                         UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else {
            throw BridgeError(status: 503, message: "Could not select the virtual audio device: \(result)")
        }
        // AVAudioEngine's cached node format can still describe the old device.
        var stream = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                   0, &stream, &streamSize) == noErr,
              stream.mSampleRate > 0, stream.mChannelsPerFrame > 0,
              let hardware = AVAudioFormat(standardFormatWithSampleRate: stream.mSampleRate, channels: stream.mChannelsPerFrame) else {
            throw BridgeError(status: 503, message: "The virtual audio device has no usable output format")
        }
        outputSampleRate = stream.mSampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = self.pcm
        let source = AVAudioSourceNode(format: format) { silence, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let output = list[0].mData!.assumingMemoryBound(to: Float.self)
            silence.pointee = ObjCBool(!pcm.render(into: output, frames: Int(frames)))
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // The mixer converts 48 kHz mono to the selected device's rate/channels.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        do { try engine.start() }
        catch {
            stop()
            throw BridgeError(status: 503, message: "Could not start virtual microphone output: \(error.localizedDescription)")
        }
    }

    func append(_ stereo: AVAudioPCMBuffer) {
        pcm.append(stereo, channel: channel - 1)
    }

    var failure: String? {
        if Self.uintProperty(device.deviceID, kAudioDevicePropertyDeviceIsAlive) != 1 || !engine.isRunning {
            return "Virtual audio output stopped or the device was removed"
        }
        var current: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &current, &size) == noErr, current == device.deviceID else {
            return "Virtual audio output device changed; refresh devices and start again"
        }
        return nil
    }

    var status: [String: Any] {
        var data = pcm.status
        data["deviceUID"] = device.id
        data["deviceName"] = device.name
        data["channel"] = channel
        data["sampleRate"] = 48_000
        data["outputSampleRate"] = outputSampleRate
        data["running"] = engine.isRunning
        return data
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }

    deinit { stop() }

    static func availableDevices() throws -> [VirtualAudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw BridgeError(status: 503, message: "Could not enumerate audio devices")
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { throw BridgeError(status: 503, message: "Could not read audio devices: \(result)") }
        return ids.compactMap { id in
            guard uintProperty(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual,
                  uintProperty(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let inputs = channels(id, scope: kAudioDevicePropertyScopeInput)
            let outputs = channels(id, scope: kAudioDevicePropertyScopeOutput)
            guard inputs > 0, outputs > 0 else { return nil }
            return VirtualAudioDevice(deviceID: id, id: uid, name: name, inputChannels: inputs, outputChannels: outputs)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func uintProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
