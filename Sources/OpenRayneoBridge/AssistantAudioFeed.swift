// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AssistantCore

/// Bounded, acknowledged local PCM handoff to the desktop assistant; audio is never written to disk.
final class AssistantAudioFeed {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var sequence = 0
    private var bytes = 0
    private var overflow = false
    private var drained = false
    private var peakBytes = 0
    private var overflowBytes = 0
    private let inputMode: ASRAudioInputMode
    private let channels: Int
    private let sampleRate: Int
    init(inputMode: ASRAudioInputMode = .realtime, channels: Int = 1, sampleRate: Int = 16000) {
        self.inputMode = inputMode; self.channels = channels; self.sampleRate = sampleRate
    }
    func finish() { lock.lock(); drained = true; lock.unlock() }
    func append(_ kind: String, round: String, pcm: Data? = nil, metadata: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { return }
        sequence += 1
        var event: [String: Any] = ["sequence": sequence, "kind": kind, "round": round,
                                    "receivedAt": Date().timeIntervalSince1970, "channels": channels,
                                    "sampleRate": sampleRate, "format": "pcm_s16le_interleaved"]
        event.merge(metadata) { existing, _ in existing }
        if let pcm {
            guard pcm.count <= sampleRate * channels * 2 * inputMode.bufferLimitSeconds - bytes else {
                overflow = true; overflowBytes = bytes + pcm.count; return
            }
            event["pcm"] = pcm.base64EncodedString(); event["pcmByteCount"] = pcm.count; bytes += pcm.count
            peakBytes = max(peakBytes, bytes)
        }
        events.append(event)
    }
    func read(after: Int) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        events.removeAll { ($0["sequence"] as? Int ?? 0) <= after }
        bytes = events.reduce(0) { $0 + ($1["pcmByteCount"] as? Int ?? 0) }
        return ["events": events, "overflow": overflow, "drained": drained,
                "bufferedPCMBytes": bytes, "peakBufferedPCMBytes": peakBytes, "overflowPCMBytes": overflowBytes,
                "bufferLimitSeconds": inputMode.bufferLimitSeconds]
    }
}
