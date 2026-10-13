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

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        count = 0
        primed = false
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

    private(set) var device: VirtualAudioDevice
    let channel: Int
    private var graph: AUGraph?
    private var outputUnit: AudioUnit?
    private let pcm = MicrophonePCMQueue()
    private var active = false
    private var lastRecoveryAt = -Double.infinity
    private var recoveryCount = 0
    private var outputError: String?
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
        stopOutput()
        guard let target = try Self.availableDevices().first(where: { $0.id == device.id }) else {
            throw BridgeError(status: 503, message: "Virtual microphone is unavailable: \(device.name)")
        }
        device = target
        pcm.clear()
        var created: AUGraph?
        try check(NewAUGraph(&created), "create audio graph")
        guard let graph = created else { throw BridgeError(status: 503, message: "Could not create audio graph") }
        self.graph = graph
        do {
            var outputDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            var mixerDescription = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
                componentSubType: kAudioUnitSubType_MultiChannelMixer, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            var outputNode: AUNode = 0
            var mixerNode: AUNode = 0
            try check(AUGraphAddNode(graph, &outputDescription, &outputNode), "add HAL output")
            try check(AUGraphAddNode(graph, &mixerDescription, &mixerNode), "add PCM mixer")
            try check(AUGraphOpen(graph), "open audio graph")
            var output: AudioUnit?
            var mixer: AudioUnit?
            try check(AUGraphNodeInfo(graph, outputNode, nil, &output), "get HAL output")
            try check(AUGraphNodeInfo(graph, mixerNode, nil, &mixer), "get PCM mixer")
            guard let output, let mixer else { throw BridgeError(status: 503, message: "Audio graph units are unavailable") }
            outputUnit = output
            var enabled: UInt32 = 1
            try set(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled)
            enabled = 0
            try set(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            var deviceID = target.deviceID
            try set(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID)
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                0, &stream, &size), "read device format")
            guard let hardware = AVAudioFormat(standardFormatWithSampleRate: stream.mSampleRate,
                                               channels: stream.mChannelsPerFrame) else {
                throw BridgeError(status: 503, message: "Virtual microphone format is unavailable")
            }
            outputSampleRate = hardware.sampleRate
            var sourceFormat = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                mBitsPerChannel: 32, mReserved: 0)
            var hardwareFormat = hardware.streamDescription.pointee
            try set(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &sourceFormat, "set mixer source format")
            try set(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardwareFormat, "set mixer output format")
            try set(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &hardwareFormat, "set HAL client format")
            try check(AudioUnitSetParameter(mixer, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, 0, 1, 0), "enable mixer input")
            try check(AudioUnitSetParameter(mixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0), "set mixer input gain")
            try check(AudioUnitSetParameter(mixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 1, 0), "set mixer output gain")
            var callback = AURenderCallbackStruct(inputProc: { context, flags, _, _, frames, buffers in
                guard let buffers else { return kAudio_ParamError }
                let pcm = Unmanaged<MicrophonePCMQueue>.fromOpaque(context).takeUnretainedValue()
                let output = UnsafeMutableAudioBufferListPointer(buffers)[0].mData!.assumingMemoryBound(to: Float.self)
                if pcm.render(into: output, frames: Int(frames)) {
                    flags.pointee.remove(.unitRenderAction_OutputIsSilence)
                } else {
                    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                }
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(pcm).toOpaque())
            try set(mixer, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback)
            try check(AUGraphConnectNodeInput(graph, mixerNode, 0, outputNode, 0), "connect HAL output")
            try check(AUGraphInitialize(graph), "initialize audio graph")
            try check(AUGraphStart(graph), "start HAL output")
            active = true
            outputError = nil
        } catch {
            stopOutput()
            throw error
        }
    }

    func startWithRecovery() {
        active = true
        lastRecoveryAt = ProcessInfo.processInfo.systemUptime
        do { try start() }
        catch { outputError = (error as? BridgeError)?.message ?? error.localizedDescription }
    }

    func retryOutput() {
        guard active else { return }
        lastRecoveryAt = -Double.infinity
        maintainOutput()
    }

    func append(_ stereo: AVAudioPCMBuffer) {
        pcm.append(stereo, channel: channel - 1)
    }

    private var healthy: Bool {
        guard let outputUnit, Self.uintProperty(device.deviceID, kAudioDevicePropertyDeviceIsAlive) == 1 else { return false }
        var current: AudioDeviceID = 0
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &current, &size) == noErr, current == device.deviceID else { return false }
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global,
                                    0, &running, &size) == noErr && running == 1
    }

    // Called on the speech queue, never from an audio callback. Keep the glasses
    // session alive while resolving the same UID after a Core Audio reconfiguration.
    func maintainOutput() {
        guard active, !healthy else { return }
        stopOutput()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecoveryAt >= 1 else { return }
        lastRecoveryAt = now
        recoveryCount += 1
        do { try start() }
        catch { outputError = (error as? BridgeError)?.message ?? error.localizedDescription }
    }

    var status: [String: Any] {
        let running = healthy
        var data = pcm.status
        data["deviceUID"] = device.id
        data["deviceName"] = device.name
        data["channel"] = channel
        data["sampleRate"] = 48_000
        data["outputSampleRate"] = outputSampleRate
        data["running"] = running
        data["recovering"] = active && !running
        data["recoveryCount"] = recoveryCount
        data["error"] = outputError as Any? ?? NSNull()
        return data
    }

    func stop() {
        active = false
        stopOutput()
        pcm.clear()
    }

    private func stopOutput() {
        if let graph {
            AUGraphStop(graph)
            AUGraphUninitialize(graph)
            DisposeAUGraph(graph)
        }
        graph = nil
        outputUnit = nil
    }

    private func check(_ result: OSStatus, _ operation: String) throws {
        guard result == noErr else { throw BridgeError(status: 503, message: "Could not \(operation): \(result)") }
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T, _ operation: String = "configure virtual audio output") throws {
        let result = withUnsafeBytes(of: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0.baseAddress!, UInt32($0.count))
        }
        try check(result, operation)
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
