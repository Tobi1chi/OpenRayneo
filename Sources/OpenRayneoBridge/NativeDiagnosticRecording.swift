// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Automatically retains the most recent native capture, independently of ASR acknowledgement.
final class NativeDiagnosticRecording {
    private final class Capture {
        let id: String
        var state = "capturing"
        var accepting = true
        var receivedBytes = 0
        var writtenBytes = 0
        var incomplete = false
        var reason = "capture_end"
        var error: String?
        var path: String?
        // Accessed only on the serial writer queue.
        var writer: WAVRecording?
        var stagingURL: URL?
        init(id: String) { self.id = id }
    }
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "openrayneo.native-recent-writer")
    private let directory: URL
    private var current: Capture?
    private var latest: [String: Any]?
    private var storageError: String?
    private var cleanupError: String?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenRayneo/NativeDiagnostics", isDirectory: true)) {
        self.directory = directory
        let index = directory.appendingPathComponent("latest.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do {
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
                if let saved, let path = saved["path"] as? String, FileManager.default.fileExists(atPath: path) { latest = saved }
                else { storageError = "最近一轮录音文件不存在。" }
            } catch { storageError = error.localizedDescription }
        }
    }

    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Any]
        if let current { result = snapshot(current) }
        else { result = latest ?? ["state": "idle", "captureID": NSNull(), "path": NSNull(), "complete": false] }
        result["mode"] = "automatic_latest"
        result["armRequired"] = false
        result["latest"] = latest as Any? ?? NSNull()
        result["cleanupError"] = cleanupError as Any? ?? NSNull()
        if current == nil, let storageError { result["error"] = storageError }
        return result
    }

    func begin(captureID: String) {
        lock.lock(); defer { lock.unlock() }
        if let old = current, old.accepting { finishLocked(old, reason: "superseded_by_capture", incomplete: true) }
        let capture = Capture(id: captureID)
        current = capture
        writerQueue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let writer = try WAVRecording(sampleRate: 16000, channels: 1, directory: directory, namePrefix: "native-recent")
                capture.writer = writer; capture.stagingURL = writer.url
            } catch { fail(capture, error) }
        }
    }

    func append(_ data: Data, captureID: String) {
        lock.lock(); defer { lock.unlock() }
        guard let capture = current, capture.id == captureID, capture.accepting else { return }
        capture.receivedBytes += data.count
        guard capture.error == nil else { return }
        writerQueue.async { [self] in
            guard let writer = capture.writer else { return }
            do {
                try writer.appendPCM16(data)
                lock.lock(); capture.writtenBytes += data.count; lock.unlock()
            } catch { fail(capture, error) }
        }
    }

    func finish(captureID: String, reason: String, incomplete: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard let capture = current, capture.id == captureID, capture.accepting else { return }
        finishLocked(capture, reason: reason, incomplete: incomplete)
    }

    private func finishLocked(_ capture: Capture, reason: String, incomplete: Bool) {
        capture.accepting = false; capture.state = "finalizing"
        capture.reason = reason; capture.incomplete = capture.incomplete || incomplete
        writerQueue.async { [self] in finalize(capture) }
    }

    private func fail(_ capture: Capture, _ error: Error) {
        capture.writer = nil
        lock.lock(); capture.error = error.localizedDescription; capture.incomplete = true; capture.state = "failed"; lock.unlock()
    }

    private func finalize(_ capture: Capture) {
        do {
            if let writer = capture.writer { try writer.finish() }
            capture.writer = nil
            lock.lock()
            capture.incomplete = capture.incomplete || capture.receivedBytes != capture.writtenBytes ||
                capture.error != nil || capture.writtenBytes == 0
            let failed = capture.incomplete
            if capture.writtenBytes == 0, capture.error == nil { capture.error = "本轮未收到可保存的PCM。" }
            var saved = snapshot(capture)
            lock.unlock()
            guard !failed, let output = capture.stagingURL else { discardFailed(capture); return }
            saved["state"] = "ready"; saved["path"] = output.path
            saved["finalized"] = true
            saved["complete"] = !(saved["incomplete"] as? Bool ?? true)
            saved["wavBytes"] = capture.writtenBytes + 44
            // Publish only after closing the WAV. Atomic index replacement preserves
            // the previous valid capture if serialization or the index write fails.
            try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
            lock.lock()
            latest = saved; storageError = nil; cleanupError = nil
            lock.unlock()
            do {
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where url.lastPathComponent.hasPrefix("native-recent-") && url.pathExtension == "wav" &&
                        url.lastPathComponent != output.lastPathComponent {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch { lock.lock(); cleanupError = error.localizedDescription; lock.unlock() }
            lock.lock(); capture.state = "ready"; capture.path = output.path; lock.unlock()
        } catch {
            fail(capture, error)
            discardFailed(capture)
        }
    }

    private func discardFailed(_ capture: Capture) {
        if let url = capture.stagingURL {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch {
                lock.lock(); capture.path = url.path; cleanupError = error.localizedDescription; lock.unlock()
            }
        }
        lock.lock(); capture.state = "failed"; capture.incomplete = true; lock.unlock()
    }

    private func snapshot(_ capture: Capture) -> [String: Any] {
        ["state": capture.state, "captureID": capture.id, "path": capture.path as Any? ?? NSNull(),
         "sampleRate": 16000, "channels": 1, "bitsPerSample": 16,
         "frames": capture.writtenBytes / 2, "receivedFrames": capture.receivedBytes / 2,
         "pcmBytes": capture.writtenBytes, "wavBytes": capture.state == "ready" ? capture.writtenBytes + 44 : 0,
         "durationSeconds": Double(capture.writtenBytes) / 32000,
         "finalized": capture.state == "ready", "complete": capture.state == "ready" && !capture.incomplete,
         "incomplete": capture.incomplete, "reason": capture.reason, "error": capture.error as Any? ?? NSNull()]
    }
}
