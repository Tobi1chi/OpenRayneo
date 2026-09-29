// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Darwin
import Foundation
import Speech

/// Optional runtime dependency: the normal display bridge works without libopus.
private final class OpusDecoder {
    private typealias Create = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    private typealias Decode = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<Int16>?, Int32, Int32) -> Int32
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias PacketChannels = @convention(c) (UnsafePointer<UInt8>?) -> Int32
    private let library: UnsafeMutableRawPointer
    private let decoder: OpaquePointer
    private let decodePacket: Decode
    private let destroy: Destroy
    private let packetChannels: PacketChannels
    private let maxFrames: Int
    let format: AVAudioFormat

    init(sampleRate: Int = 16_000, channels: Int = 1) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels), interleaved: false)!
        maxFrames = sampleRate * 120 / 1000
        let paths = [ProcessInfo.processInfo.environment["OPENRAYNEO_OPUS_LIBRARY"],
                     "/opt/homebrew/opt/opus/lib/libopus.dylib", "/usr/local/opt/opus/lib/libopus.dylib"].compactMap { $0 }
        var loadedLibrary: UnsafeMutableRawPointer?
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) { loadedLibrary = handle; break }
        }
        guard let library = loadedLibrary else {
            throw BridgeError(status: 503, message: "ASR requires libopus: brew install opus, or set OPENRAYNEO_OPUS_LIBRARY")
        }
        guard let createSymbol = dlsym(library, "opus_decoder_create"),
              let decodeSymbol = dlsym(library, "opus_decode"),
              let destroySymbol = dlsym(library, "opus_decoder_destroy"),
              let channelSymbol = dlsym(library, "opus_packet_get_nb_channels") else {
            dlclose(library)
            throw BridgeError(status: 503, message: "libopus is missing decoder functions")
        }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        var error: Int32 = 0
        guard let decoder = create(Int32(sampleRate), Int32(channels), &error), error == 0 else {
            dlclose(library)
            throw BridgeError(status: 503, message: "Could not initialize the Opus decoder: \(error)")
        }
        self.library = library
        self.decoder = decoder
        decodePacket = unsafeBitCast(decodeSymbol, to: Decode.self)
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        packetChannels = unsafeBitCast(channelSymbol, to: PacketChannels.self)
    }

    deinit { destroy(decoder); dlclose(library) }

    func encodedChannels(_ data: Data) -> Int {
        data.withUnsafeBytes { Int(packetChannels($0.bindMemory(to: UInt8.self).baseAddress)) }
    }

    func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        // Opus can carry up to 120 ms. A mono decoder downmixes stereo packets.
        let channels = Int(format.channelCount)
        var samples = [Int16](repeating: 0, count: maxFrames * channels)
        let count = data.withUnsafeBytes { bytes in
            decodePacket(decoder, bytes.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &samples, Int32(maxFrames), 0)
        }
        guard count > 0 else { throw BridgeError(status: 503, message: "Opus decode failed: \(count)") }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<Int(count) {
            for channel in 0..<channels {
                buffer.floatChannelData![channel][frame] = Float(samples[frame * channels + channel]) / 32768
            }
        }
        return buffer
    }
}

/// A bounded, local-only glasses audio -> speech -> display pipeline.
final class SpeechController {
    private let transport: RFCOMMTransport
    private let displays: DisplayController
    private let queue = DispatchQueue(label: "openrayneo.speech")
    private let pendingLock = NSLock()
    private var pendingPackets = 0
    private var overflowPackets = 0
    private var running = false
    private var sid: String?
    private var decoder: OpusDecoder?
    private var recordingDecoder: OpusDecoder?
    private var recording: WAVRecording?
    private var recognitionEnabled = false
    private var encodedChannelCounts: [String: Int] = [:]
    private var lastAudioSequence: Int?
    private var missingAudioPackets = 0
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskID = UUID()
    private var timer: DispatchSourceTimer?
    private var deadline = Date.distantPast
    private var taskStarted = Date.distantPast
    private var lastAudioAt = Date.distantPast
    private var lastDisplayAt = Date.distantPast
    private var audioPackets = 0
    private var decodedSeconds = 0.0
    private var decodeErrors = 0
    private var consecutiveDecodeErrors = 0
    private var level: Float = 0
    private var transcript = ""
    private var displayedText = ""
    private var error: String?
    private var locale = "zh-CN"

    init(transport: RFCOMMTransport, displays: DisplayController) {
        self.transport = transport
        self.displays = displays
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/asr" || path.hasPrefix("/v1/asr/") || path == "/v1/recording" || path.hasPrefix("/v1/recording/") else { return nil }
        if method == "POST", path == "/v1/asr/authorize" {
            let completed = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { _ in completed.signal() }
            guard completed.wait(timeout: .now() + 60) == .success else {
                throw BridgeError(status: 504, message: "Speech authorization is still pending; complete the macOS prompt and check GET /v1/asr")
            }
            return (200, queue.sync { status() })
        }
        return try queue.sync {
            switch (method, path) {
            case ("GET", "/v1/asr"), ("GET", "/v1/recording"):
                return (200, status())
            case ("POST", "/v1/asr/start"):
                try start(locale: body["locale"] as? String ?? "zh-CN", duration: body["duration"] as? Int ?? 120, recognize: true, record: body["record"] as? Bool ?? false)
                return (200, status())
            case ("POST", "/v1/recording/start"):
                try start(locale: "zh-CN", duration: body["duration"] as? Int ?? 300, recognize: false, record: true)
                return (200, status())
            case ("POST", "/v1/asr/stop"), ("POST", "/v1/recording/stop"):
                stop()
                return (200, status())
            default:
                return nil
            }
        }
    }

    private func status() -> [String: Any] {
        pendingLock.lock()
        let dropped = overflowPackets
        pendingLock.unlock()
        return ["running": running, "source": "glasses", "engine": recognitionEnabled ? "apple-on-device" : "recording-only",
                "locale": locale, "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
                "sid": sid as Any? ?? NSNull(), "audioPackets": audioPackets,
                "decodedSeconds": decodedSeconds, "decodeErrors": decodeErrors,
                "encodedChannelCounts": encodedChannelCounts, "missingAudioPackets": missingAudioPackets,
                "recording": recording?.status as Any? ?? NSNull(),
                "droppedAudioPackets": dropped, "audioRMS": level,
                "transcript": transcript, "displayedText": displayedText,
                "error": error as Any? ?? NSNull()]
    }

    private func start(locale: String, duration: Int, recognize: Bool, record: Bool) throws {
        guard !running else { throw BridgeError(status: 409, message: "An audio session is already running") }
        let limit = recognize ? 600 : 21_600
        guard (10...limit).contains(duration) else { throw BridgeError(status: 400, message: "duration must be between 10 and \(limit) seconds") }
        var recognizer: SFSpeechRecognizer?
        if recognize {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw BridgeError(status: 403, message: "Authorize speech recognition with POST /v1/asr/authorize first")
            }
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            guard recognizer?.isAvailable == true, recognizer?.supportsOnDeviceRecognition == true else {
                throw BridgeError(status: 503, message: "On-device speech recognition is unavailable for \(locale); cloud fallback is disabled")
            }
        }
        let decoder = recognize ? try OpusDecoder() : nil
        let recordingDecoder = record ? try OpusDecoder(sampleRate: 48_000, channels: 2) : nil
        let sid = try displays.startSpeechDisplay()
        let recording: WAVRecording?
        do { recording = record ? try WAVRecording() : nil }
        catch { try? displays.stopSpeechDisplay(); throw error }
        self.recognizer = recognizer
        self.decoder = decoder
        self.recordingDecoder = recordingDecoder
        self.recording = recording
        recognitionEnabled = recognize
        self.sid = sid
        self.locale = locale
        error = nil
        transcript = ""
        displayedText = ""
        audioPackets = 0
        decodedSeconds = 0
        encodedChannelCounts = [:]
        lastAudioSequence = nil
        missingAudioPackets = 0
        decodeErrors = 0
        consecutiveDecodeErrors = 0
        level = 0
        pendingLock.lock()
        overflowPackets = 0
        pendingLock.unlock()
        running = true
        deadline = Date().addingTimeInterval(Double(duration))
        lastAudioAt = Date()
        if recognize { beginRecognition() }
        transport.setAudioHandler { [weak self] message in self?.enqueue(message) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func beginRecognition() {
        taskID = UUID()
        let id = taskID
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        taskStarted = Date()
        task = recognizer?.recognitionTask(with: request) { [weak self] result, failure in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.taskID == id else { return }
                if let result {
                    self.transcript = String(result.bestTranscription.formattedString.suffix(400))
                    if result.isFinal { self.beginRecognition() }
                } else if let failure {
                    self.error = "Speech recognition failed: \(failure.localizedDescription)"
                    self.stop()
                }
            }
        }
    }

    private func enqueue(_ message: RemoteMessage) {
        pendingLock.lock()
        guard pendingPackets < 64 else {
            overflowPackets += 1
            pendingLock.unlock()
            return
        }
        pendingPackets += 1
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pendingPackets -= 1
                self.pendingLock.unlock()
            }
            self.consume(message)
        }
    }

    private func consume(_ message: RemoteMessage) {
        guard running, message.protocolID == 0x17, message.json?["sid"] as? String == sid,
              let audio = message.audioData, !audio.isEmpty else { return }
        audioPackets += 1
        lastAudioAt = Date()
        if let sequence = (message.json?["seq"] as? NSNumber)?.intValue {
            if let previous = lastAudioSequence, sequence > previous + 1 { missingAudioPackets += sequence - previous - 1 }
            lastAudioSequence = sequence
        }
        let mono: AVAudioPCMBuffer?
        let stereo: AVAudioPCMBuffer?
        do {
            mono = try decoder?.decode(audio)
            stereo = try recordingDecoder?.decode(audio)
            guard let buffer = mono ?? stereo else { return }
            if let channels = (recordingDecoder ?? decoder)?.encodedChannels(audio) {
                encodedChannelCounts[String(channels), default: 0] += 1
            }
            consecutiveDecodeErrors = 0
            decodedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            let samples = buffer.floatChannelData![0]
            var squareSum: Float = 0
            for i in 0..<Int(buffer.frameLength) { squareSum += samples[i] * samples[i] }
            level = sqrt(squareSum / Float(buffer.frameLength))
        } catch {
            decodeErrors += 1
            consecutiveDecodeErrors += 1
            if consecutiveDecodeErrors >= 5 {
                self.error = "Repeated Opus decoding failures"
                stop()
            }
            return
        }
        if let stereo {
            do { try recording?.append(stereo) }
            catch {
                self.error = "WAV write failed: \((error as? BridgeError)?.message ?? error.localizedDescription)"
                stop()
                return
            }
        }
        if let mono { request?.append(mono) }
    }

    private func tick() {
        guard running else { return }
        if Date() >= deadline { stop(); return }
        if Date().timeIntervalSince(lastAudioAt) > 10 {
            error = "No glasses audio received for 10 seconds"
            stop()
            return
        }
        let text = String(transcript.suffix(96))
        if !text.isEmpty, text != displayedText, Date().timeIntervalSince(lastDisplayAt) >= 0.25 {
            do {
                try displays.updateSpeechText(text)
                displayedText = text
                lastDisplayAt = Date()
            } catch {
                self.error = "Could not update the glasses display"
                stop()
                return
            }
        }
        // Apple recognition tasks are finite; renew before a long-running limit.
        if recognitionEnabled, Date().timeIntervalSince(taskStarted) > 45 { beginRecognition() }
    }

    private func stop() {
        guard running else { return }
        running = false
        transport.setAudioHandler(nil)
        timer?.cancel()
        timer = nil
        taskID = UUID()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        decoder = nil
        recordingDecoder = nil
        recognizer = nil
        do { try recording?.finish() }
        catch { self.error = (self.error.map { $0 + "; " } ?? "") + "WAV finalization failed: \(error.localizedDescription)" }
        do { try displays.stopSpeechDisplay() }
        catch { self.error = (self.error.map { $0 + "; " } ?? "") + "Could not confirm sending the glasses stop command; exit the page manually" }
    }
}
