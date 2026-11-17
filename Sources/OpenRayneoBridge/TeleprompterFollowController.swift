// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AVFoundation
import CoreText
import Foundation
import Speech

/// Matches the current utterance near the reading cursor. Offsets on the wire are UTF-8 bytes.
struct TeleprompterSpeechMatcher {
    private let characters: [Unicode.Scalar]
    private let ends: [Int]
    private(set) var cursor = 0

    init(text: String) {
        var characters: [Unicode.Scalar] = []
        var ends: [Int] = []
        var bytes = 0
        for scalar in text.unicodeScalars {
            bytes += scalar.utf8.count
            for normalized in Self.normalize(String(scalar)) {
                characters.append(normalized); ends.append(bytes)
            }
        }
        self.characters = characters; self.ends = ends
    }

    mutating func seek(byteOffset: Int) {
        cursor = ends.firstIndex(where: { $0 > byteOffset }) ?? characters.count
    }

    mutating func match(_ text: String) -> (byteOffset: Int, confidence: Double)? {
        let query = Array(Self.normalize(text).suffix(72))
        guard query.count >= 4, !characters.isEmpty else { return nil }
        let lower = max(0, cursor - max(90, query.count + 12))
        let upper = min(characters.count, cursor + 100)
        let document = Array(characters[lower..<upper])
        guard !document.isEmpty else { return nil }
        // Semi-global edit distance: the utterance may start anywhere in the local window.
        var previous = [Int](repeating: 0, count: document.count + 1)
        var starts = Array(0...document.count)
        for row in query.indices {
            var current = [Int](repeating: 0, count: document.count + 1)
            var nextStarts = [Int](repeating: 0, count: document.count + 1)
            current[0] = row + 1
            for column in document.indices {
                let substitution = previous[column] + (query[row] == document[column] ? 0 : 1)
                let deletion = previous[column + 1] + 1
                let insertion = current[column] + 1
                if substitution <= deletion && substitution <= insertion {
                    current[column + 1] = substitution; nextStarts[column + 1] = starts[column]
                } else if deletion <= insertion {
                    current[column + 1] = deletion; nextStarts[column + 1] = starts[column + 1]
                } else {
                    current[column + 1] = insertion; nextStarts[column + 1] = nextStarts[column]
                }
            }
            previous = current; starts = nextStarts
        }
        // Prefer the nearest equally good occurrence, preventing repeats from skipping paragraphs.
        let ranked = (1...document.count).filter { lower + $0 >= cursor }.sorted {
            if previous[$0] != previous[$1] { return previous[$0] < previous[$1] }
            return abs(lower + $0 - cursor) < abs(lower + $1 - cursor)
        }
        guard let end = ranked.first else { return nil }
        let confidence = 1 - Double(previous[end]) / Double(query.count)
        let matchedLength = end - starts[end]
        let advance = lower + end - cursor
        guard confidence >= 0.72, matchedLength >= max(3, query.count * 2 / 3), advance > 0,
              advance <= max(24, query.count * 2), lower + starts[end] <= cursor + 36 else { return nil }
        cursor = lower + end
        return (ends[cursor - 1], confidence)
    }

    private static func normalize(_ text: String) -> [Unicode.Scalar] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    }
}

/// Receives the original teleprompter type 9 Opus packets and sends type 8 matched progress.
final class TeleprompterFollowController {
    private let transport: RFCOMMTransport
    private let sendLock: NSRecursiveLock
    private let queue = DispatchQueue(label: "openrayneo.teleprompter-follow")
    private let senderQueue = DispatchQueue(label: "openrayneo.teleprompter-follow-send")
    // Sender takes sendLock → sessionLock. The recognition queue never takes sendLock or waits for senderQueue.
    private let sessionLock = NSLock()
    private var generation: UInt64 = 0
    private let ingressLock = NSLock()
    private var pendingPackets = 0
    private var droppedPackets = 0
    private var sequence: UInt16 = 0xa000
    private var decoder: OpusDecoder?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskID = UUID()
    private var taskStarted = Date()
    private var timer: DispatchSourceTimer?
    private var did: String?
    private var paused = false
    private var matcher = TeleprompterSpeechMatcher(text: "")
    private var lineStarts = [0]
    private var byteCount = 0
    private var highLightOffset = 0
    private var pageOffset = 0
    private var packets = 0
    private var decodedSeconds = 0.0
    private var decodeErrors = 0
    private var lastSequence: UInt16?
    private var transcript = ""
    private var confidence = 0.0
    private var error: String?
    private var lastAudioAt: Date?
    private var lastProgressAt = Date.distantPast
    private var progressPending = false
    private var progressInFlight = false

    init(transport: RFCOMMTransport, lock: NSRecursiveLock) {
        self.transport = transport; self.sendLock = lock
    }

    var status: [String: Any] {
        queue.sync {
            ingressLock.lock(); let dropped = droppedPackets; ingressLock.unlock()
            return ["running": did != nil, "paused": paused, "did": did ?? NSNull(),
                    "engine": "apple_on_device", "locale": recognizer?.locale.identifier ?? "",
                    "packets": packets, "decodedSeconds": decodedSeconds, "decodeErrors": decodeErrors,
                    "droppedPackets": dropped, "lastSequence": lastSequence.map { Int($0) } as Any? ?? NSNull(),
                    "transcript": transcript, "matchConfidence": confidence,
                    "pageOffset": pageOffset, "highLightOffset": highLightOffset, "totalBytes": byteCount,
                    "offsetUnit": "utf8_bytes", "error": error ?? NSNull()]
        }
    }

    func start(did: String, text: String, settings: [String: Any] = [:]) throws {
        try queue.sync {
            stopOnQueue()
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw BridgeError(status: 403, message: "智能跟读需要语音识别授权，请先在实时语音页面授权")
            }
            let locale = text.unicodeScalars.contains(where: { (0x3400...0x9fff).contains(Int($0.value)) }) ? "zh-CN" : "en-US"
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            guard recognizer?.isAvailable == true, recognizer?.supportsOnDeviceRecognition == true else {
                throw BridgeError(status: 503, message: "本机缺少 \(locale) 离线语音识别资源")
            }
            decoder = try OpusDecoder(sampleRate: 16_000, channels: 1)
            self.recognizer = recognizer; self.did = did; paused = false
            matcher = TeleprompterSpeechMatcher(text: text)
            lineStarts = Self.layoutLineStarts(text: text, settings: settings)
            byteCount = text.utf8.count; highLightOffset = 0; pageOffset = 0
            packets = 0; decodedSeconds = 0; decodeErrors = 0; lastSequence = nil
            transcript = ""; confidence = 0; error = nil; lastAudioAt = nil
            ingressLock.lock(); droppedPackets = 0; ingressLock.unlock()
            beginRecognition()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }

    func stop() { queue.sync { stopOnQueue() } }

    /// Bluetooth callbacks must return immediately; teardown belongs to the recognition queue.
    func connectionClosed() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func setPaused(_ value: Bool) {
        queue.sync { setPausedOnQueue(value) }
    }

    func seek(byteOffset: Int) {
        queue.sync {
            invalidateOutbound()
            highLightOffset = max(0, min(byteCount, byteOffset))
            matcher.seek(byteOffset: highLightOffset)
            pageOffset = pageStart(at: highLightOffset)
            if did != nil, !paused { beginRecognition() }
        }
    }

    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 0x14, let type = message.messageType else { return }
        if [UInt64(4), 5, 6].contains(type) {
            queue.async { [weak self] in self?.handleControlOnQueue(message) }
            return
        }
        guard type == 9, let data = message.audioData, !data.isEmpty else { return }
        ingressLock.lock()
        guard pendingPackets < 64 else { droppedPackets += 1; ingressLock.unlock(); return }
        pendingPackets += 1; ingressLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.ingressLock.lock(); self.pendingPackets -= 1; self.ingressLock.unlock() }
            guard self.did != nil, !self.paused, let decoder = self.decoder else { return }
            do {
                // Original Android ingress forwards field 4 directly to one Opus decode; no 240-byte slicing.
                let pcm = try decoder.decode(data)
                self.packets += 1; self.lastSequence = message.sequence; self.lastAudioAt = Date()
                self.decodedSeconds += Double(pcm.frameLength) / pcm.format.sampleRate
                self.request?.append(pcm)
            } catch {
                self.decodeErrors += 1
                self.error = (error as? BridgeError)?.message ?? error.localizedDescription
            }
        }
    }

    private func beginRecognition() {
        cancelRecognition()
        guard did != nil, !paused else { return }
        let id = UUID(); taskID = id; taskStarted = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.addsPunctuation = false
        self.request = request
        task = recognizer?.recognitionTask(with: request) { [weak self] result, failure in
            guard let self else { return }
            self.queue.async {
                guard self.did != nil, !self.paused, self.taskID == id else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if let match = self.matcher.match(self.transcript) {
                        self.confidence = match.confidence
                        self.highLightOffset = match.byteOffset
                        self.pageOffset = self.pageStart(at: match.byteOffset)
                        self.progressPending = true
                        self.error = nil
                    }
                    if result.isFinal { self.beginRecognition() }
                } else if let failure {
                    self.error = "智能跟读识别：\(failure.localizedDescription)"
                    // Retry on the next audio packet instead of spinning on an unavailable service.
                    self.cancelRecognition()
                }
            }
        }
    }

    private func tick() {
        guard did != nil, !paused else { return }
        if request == nil, let lastAudioAt, Date().timeIntervalSince(lastAudioAt) < 1,
           Date().timeIntervalSince(taskStarted) > 2 { beginRecognition() }
        if request != nil, Date().timeIntervalSince(taskStarted) > 45 {
            // Rotate streaming requests before Apple's task-duration limit.
            beginRecognition()
        }
        guard progressPending, !progressInFlight,
              Date().timeIntervalSince(lastProgressAt) >= 0.12, let did else { return }
        let currentGeneration = generation
        progressPending = false; progressInFlight = true; lastProgressAt = Date()
        enqueueFrame(type: 8, action: 1,
            body: ["action": 1, "did": did, "pageOffset": pageOffset, "highLightOffset": highLightOffset],
            generation: currentGeneration) { [weak self] failure in
                guard let self, self.generation == currentGeneration else { return }
                self.progressInFlight = false
                if let failure { self.error = failure; self.progressPending = true }
            }
    }

    private func handleControlOnQueue(_ message: RemoteMessage) {
        guard let type = message.messageType, let activeDid = did,
              message.json?["did"] as? String == activeDid else { return }
        // Field 1 of the recording/display envelope is version; control direction lives in JSON.
        let action = (message.json?["action"] as? NSNumber)?.uint64Value
        guard action == 1 || action == 2 else { return }
        if action == 2, let code = message.json?["code"] as? Int, code != 1 {
            error = "眼镜拒绝提词控制 type=\(type), code=\(code)"
            return
        }
        switch type {
        case 4:
            setPausedOnQueue(true)
            if let offset = message.json?["offset"] as? Int {
                highLightOffset = max(0, min(byteCount, offset))
                matcher.seek(byteOffset: highLightOffset); pageOffset = pageStart(at: highLightOffset)
            }
            if message.json?["isCompleted"] as? Bool == true {
                highLightOffset = byteCount; matcher.seek(byteOffset: byteCount)
                pageOffset = pageStart(at: byteCount)
            }
        case 5: setPausedOnQueue(false)
        case 6: stopOnQueue()
        default: return
        }
        if action == 1 {
            let currentGeneration = generation
            enqueueFrame(type: type, action: 2, body: ["action": 2, "did": activeDid, "code": 1],
                generation: currentGeneration) { [weak self] failure in
                    guard let self, self.generation == currentGeneration else { return }
                    if let failure { self.error = failure }
                }
        }
    }

    private func setPausedOnQueue(_ value: Bool) {
        guard did != nil, paused != value else { return }
        invalidateOutbound(); paused = value
        if value { cancelRecognition() } else { beginRecognition() }
    }

    private func invalidateOutbound() {
        sessionLock.lock(); generation &+= 1; sessionLock.unlock()
        progressInFlight = false; progressPending = false
    }

    private func enqueueFrame(type: UInt64, action: UInt64, body: [String: Any], generation: UInt64,
                              completion: @escaping (String?) -> Void) {
        senderQueue.async { [weak self] in
            guard let self else { return }
            var failure: String?
            self.sendLock.lock()
            self.sessionLock.lock()
            if self.generation == generation {
                do {
                    guard self.transport.isConnected else {
                        throw BridgeError(status: 503, message: "眼镜连接已断开，智能跟读未发送进度")
                    }
                    self.sequence &+= 1
                    try self.transport.send(ProtocolCodec.teleprompterFrame(sequence: self.sequence,
                        type: type, action: action, body: body))
                } catch { failure = (error as? BridgeError)?.message ?? error.localizedDescription }
            }
            self.sessionLock.unlock()
            self.sendLock.unlock()
            let result = failure
            self.queue.async { completion(result) }
        }
    }

    private func cancelRecognition() {
        taskID = UUID(); request?.endAudio(); task?.cancel(); task = nil; request = nil
    }

    private func stopOnQueue() {
        invalidateOutbound()
        timer?.cancel(); timer = nil; cancelRecognition()
        did = nil; paused = false; decoder = nil; recognizer = nil; progressPending = false
    }

    private func pageStart(at byteOffset: Int) -> Int {
        let line = max(0, (lineStarts.lastIndex(where: { $0 <= byteOffset }) ?? 0) - 1)
        return lineStarts[line]
    }

    private static func layoutLineStarts(text: String, settings: [String: Any]) -> [Int] {
        let size = settings["size"] as? Int ?? 18
        let fontSize = CGFloat([18: 22, 20: 24, 24: 29][size] ?? size)
        let width = CGFloat(max(344, min(492, settings["width"] as? Int ?? 492)))
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var starts = [0]
        let nsText = text as NSString
        var character = 0
        var bytes = 0
        while character < nsText.length {
            let length = max(1, CTTypesetterSuggestLineBreak(typesetter, character, Double(width)))
            bytes += nsText.substring(with: NSRange(location: character, length: length)).utf8.count
            character += length
            if character < nsText.length { starts.append(bytes) }
        }
        return starts
    }
}
