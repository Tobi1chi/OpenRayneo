// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Native 0x0D notifications and opt-in local audio; separate from 0xA1 AlwaysOn.
final class NativeAssistantController {
    private let queue = DispatchQueue(label: "openrayneo.native-assistant")
    private let transport: RFCOMMTransport
    private var events: [[String: Any]] = []
    private var sequence = 0
    private var wireSequence: UInt16 = 0x7000
    private var wakeID: String?
    private var active = false
    private var capturing = false
    private var audioPackets = 0
    private var audioBytes = 0
    private var decodedSeconds = 0.0
    private var wakeBody: [String: Any] = [:]
    private let clientID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var lastReplySID: String?
    private var lastAdvancedReplySID: String?
    private var vadActive = false
    private var decoder: OpusDecoder?
    private var feed: AssistantAudioFeed?
    private var captureID: String?
    private var failure: String?
    private var stopWork: DispatchWorkItem?
    private let pendingLock = NSLock()
    private var pendingAudio = 0
    private var overloadReported = false
    private let diagnosticRecording = NativeDiagnosticRecording()

    init(transport: RFCOMMTransport) { self.transport = transport }

    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 0x0d, let type = message.messageType, type < 161 else { return }
        pendingLock.lock()
        let overloaded = type == 3 && pendingAudio >= 64
        if !overloaded, type == 3 { pendingAudio += 1 }
        let reportOverload = overloaded && !overloadReported
        if reportOverload { overloadReported = true }
        pendingLock.unlock()
        if overloaded {
            if reportOverload { queue.async { [weak self] in
                guard let self else { return }
                self.failCapture("原生助手音频处理积压，已停止本轮收音。")
                self.pendingLock.lock(); self.overloadReported = false; self.pendingLock.unlock()
            } }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if type == 3 {
                defer { self.pendingLock.lock(); self.pendingAudio -= 1; self.pendingLock.unlock() }
                self.receiveAudio(message)
                return
            }
            let kind: String
            switch type {
            case 1:
                self.finishCapture(reason: "next_wake")
                kind = "wake"; self.active = true; self.wakeID = UUID().uuidString
                self.audioPackets = 0; self.audioBytes = 0; self.decodedSeconds = 0
                self.wakeBody = message.json ?? [:]; self.failure = nil
                self.lastReplySID = nil; self.lastAdvancedReplySID = nil; self.vadActive = false
            case 8: kind = "exit"; self.active = false; self.finishCapture()
            case 11:
                guard self.active else { return }
                if let sid = message.json?["sid"] as? String, !sid.isEmpty {
                    guard self.lastReplySID == nil || self.lastReplySID == sid,
                          self.lastAdvancedReplySID != sid else { return }
                    self.lastAdvancedReplySID = sid
                }
                self.finishCapture(); self.vadActive = false; self.wakeID = UUID().uuidString; self.active = true
                kind = "next_round"
            default: return
            }
            self.sequence += 1
            self.events.append(["sequence": self.sequence, "kind": kind, "wakeID": self.wakeID as Any? ?? NSNull(),
                                "receivedAt": message.receivedAt.timeIntervalSince1970,
                                "body": message.json as Any? ?? NSNull()])
            if self.events.count > 64 { self.events.removeFirst(self.events.count - 64) }
        }
    }

    func connectionLost() { queue.async { [weak self] in self?.active = false; self?.finishCapture(reason: "connection_lost", incomplete: true) } }

    var status: [String: Any] { queue.sync { snapshot() } }
    private func snapshot() -> [String: Any] {
        ["active": active, "capturing": capturing, "wakeID": wakeID as Any? ?? NSNull(), "wake": wakeBody,
         "captureID": captureID as Any? ?? NSNull(), "audioPackets": audioPackets, "audioBytes": audioBytes,
         "decodedSeconds": decodedSeconds, "error": failure as Any? ?? NSNull(), "events": events,
         "sequence": sequence, "lastReplySID": lastReplySID as Any? ?? NSNull(), "officialCloudEnabled": OfficialCloudPolicy.enabled]
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/assistant/native" || path.hasPrefix("/v1/assistant/native/") else { return nil }
        return try queue.sync {
            if method == "GET", path == "/v1/assistant/native" { return (200, snapshot()) }
            if method == "GET", path == "/v1/assistant/native/diagnostic" { return (200, diagnosticRecording.status) }
            guard method == "POST" else { return nil }
            switch path {
            case "/v1/assistant/native/start":
                guard active, let id = wakeID, body["wakeID"] as? String == id else {
                    throw BridgeError(status: 409, message: "请先唤醒眼镜，并使用当前 wakeID。")
                }
                guard !capturing else { throw BridgeError(status: 409, message: "原生助手正在收音。") }
                guard (1...6).contains(wakeBody["rc"] as? Int ?? 0) else {
                    throw BridgeError(status: 409, message: "共享音频唤醒由原有功能管理，请结束该功能后再唤醒助手。")
                }
                let duration = body["duration"] as? Int ?? 60
                guard (10...600).contains(duration) else { throw BridgeError(status: 400, message: "duration 应为 10–600 秒。") }
                decoder = try OpusDecoder(sampleRate: 16_000, channels: 1)
                let feed = AssistantAudioFeed(); self.feed = feed; captureID = id
                feed.append("begin", round: id)
                do {
                    try send(type: 2, body: ["rc": 1])
                    try send(type: 9, body: ["rc": 1])
                }
                catch let startupError {
                    failure = startupError.localizedDescription
                    do { try send(type: 2, body: ["rc": 2]) }
                    catch { failure = startupError.localizedDescription + "；停止命令失败：" + error.localizedDescription }
                    feed.append("end", round: id); feed.finish(); decoder = nil
                    throw startupError
                }
                capturing = true; failure = nil
                diagnosticRecording.begin(captureID: id)
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.captureID == id, self.capturing else { return }
                    do { try self.send(type: 2, body: ["rc": 2]) }
                    catch { self.failure = error.localizedDescription }
                    self.finishCapture(reason: "capture_duration_end", incomplete: self.failure != nil)
                }
                stopWork = work; queue.asyncAfter(deadline: .now() + .seconds(duration), execute: work)
                return (202, snapshot())
            case "/v1/assistant/native/audio":
                guard let feed, body["wakeID"] as? String == captureID else {
                    throw BridgeError(status: 409, message: "原生助手音频轮次已变化。")
                }
                var result = feed.read(after: body["after"] as? Int ?? 0)
                result["audioStatus"] = snapshot()
                return (200, result)
            case "/v1/assistant/native/stop":
                guard body["wakeID"] as? String == captureID else {
                    throw BridgeError(status: 409, message: "原生助手音频轮次已变化。")
                }
                if capturing { try send(type: 2, body: ["rc": 2]) }
                finishCapture()
                return (200, snapshot())
            case "/v1/assistant/native/asr":
                guard active, body["wakeID"] as? String == wakeID, let text = body["text"] as? String else {
                    throw BridgeError(status: 409, message: "原生助手轮次已变化或文字缺失。")
                }
                guard !text.isEmpty else { throw BridgeError(status: 400, message: "识别文字不能为空。") }
                if !vadActive { try send(type: 4, body: ["rc": 1]); vadActive = true }
                let final = body["final"] as? Bool ?? true
                try send(type: 5, body: NativeAssistantPayload.asr(text: text, final: final))
                if final {
                    try send(type: 4, body: ["rc": 2]); vadActive = false
                    try send(type: 9, body: ["rc": 3])
                }
                return (202, ["sent": "asr", "wakeID": wakeID!, "visible": "unverified"])
            case "/v1/assistant/native/reply":
                guard active, let id = wakeID, body["wakeID"] as? String == id else {
                    throw BridgeError(status: 409, message: "原生助手轮次已变化，未覆盖新的对话。")
                }
                guard let text = body["text"] as? String, !text.isEmpty else {
                    throw BridgeError(status: 400, message: "回复文字不能为空。")
                }
                if capturing, captureID == id {
                    try send(type: 2, body: ["rc": 2]); finishCapture()
                }
                let sid = id.replacingOccurrences(of: "-", with: "").lowercased()
                let reply = NativeAssistantPayload.reply(text: text, query: body["query"] as? String ?? "", sid: sid, clientID: clientID)
                try send(type: 9, body: ["rc": 3])
                try send(type: 32, body: reply)
                lastReplySID = sid
                try send(type: 12, body: [:])
                return (202, ["sent": "reply", "wakeID": id, "sid": sid, "visible": "unverified"])
            default: return nil
            }
        }
    }

    private func receiveAudio(_ message: RemoteMessage) {
        audioPackets += 1; audioBytes += message.audioData?.count ?? 0
        guard capturing, let decoder, let feed, let id = captureID, let data = message.audioData, !data.isEmpty else { return }
        do {
            let buffer = try decoder.decode(data)
            var pcm = Data(capacity: Int(buffer.frameLength) * 2)
            for index in 0..<Int(buffer.frameLength) {
                var value = Int16(max(-32768, min(32767, Int(buffer.floatChannelData![0][index] * 32768)))).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            decodedSeconds += Double(buffer.frameLength) / 16_000
            diagnosticRecording.append(pcm, captureID: id)
            feed.append("pcm", round: id, pcm: pcm)
        } catch { failCapture(error.localizedDescription) }
    }

    private func failCapture(_ message: String) {
        guard capturing else { return }
        failure = message
        if let id = captureID { feed?.append("gap", round: id) }
        do { try send(type: 2, body: ["rc": 2]) }
        catch { failure = message + "；停止命令失败：" + error.localizedDescription }
        finishCapture(reason: "capture_error", incomplete: true)
    }

    private func finishCapture(reason: String = "capture_end", incomplete: Bool = false) {
        stopWork?.cancel(); stopWork = nil
        if capturing, let id = captureID { diagnosticRecording.finish(captureID: id, reason: reason, incomplete: incomplete) }
        if capturing, let id = captureID { feed?.append("end", round: id); feed?.finish() }
        capturing = false; decoder = nil
    }

    private func send(type: UInt64, body: [String: Any]) throws {
        wireSequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: 0x0d, sequence: wireSequence, type: type, body: body))
    }
}
