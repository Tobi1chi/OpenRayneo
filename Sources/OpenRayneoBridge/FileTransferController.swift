// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The official receiver-driven file protocol, shared by SmallCore and LargeCore.
final class FileTransferController {
    private final class Transfer {
        let id: String
        let direction: String
        let core: UInt8
        let businessID: UInt64
        let url: URL
        let size: UInt64
        let md5: String
        var file: FileHandle?
        var state = "waiting"
        var error: String?
        var ranges: [Range<UInt64>] = []
        var updated = Date()
        var chunkID: UInt64 = 0
        var currentRequest: (offset: UInt64, size: UInt64)?
        var retries = 0
        var cancellationOrigin: String?
        var cancelNotificationSent = false
        var completionNotificationSent: Bool?
        var peerReceiveState: UInt64?

        init(id: String, direction: String, core: UInt8, businessID: UInt64, url: URL, size: UInt64, md5: String) {
            self.id = id; self.direction = direction; self.core = core; self.businessID = businessID
            self.url = url; self.size = size; self.md5 = md5
        }

        var active: Bool { state == "waiting" || state == "transferring" }
        var covered: UInt64 { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
        var status: [String: Any] {
            var result: [String: Any] = ["uuid": id, "direction": direction, "core": core == 0x11 ? "small" : "large",
             "businessID": businessID, "path": url.path, "fileName": url.lastPathComponent,
             "size": size, "transferred": covered, "progress": state == "completed" ? 1.0 : (size == 0 ? 0.0 : Double(covered) / Double(size)),
             "state": state, "error": error as Any? ?? NSNull(), "updatedAt": updated.timeIntervalSince1970]
            if let cancellationOrigin {
                result["cancellationOrigin"] = cancellationOrigin
                if cancellationOrigin == "local" {
                    result["cancelNotificationSent"] = cancelNotificationSent
                    result["remoteCancellationConfirmed"] = false
                }
            }
            if let completionNotificationSent { result["completionNotificationSent"] = completionNotificationSent }
            if let peerReceiveState { result["peerReceiveState"] = peerReceiveState }
            return result
        }

        func include(_ range: Range<UInt64>) {
            ranges.append(range)
            ranges.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<UInt64>] = []
            for next in ranges {
                if let last = merged.last, next.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
                } else { merged.append(next) }
            }
            ranges = merged
            updated = Date()
        }
    }

    private let transport: RFCOMMTransport
    private let operationLock: NSRecursiveLock
    private let queue = DispatchQueue(label: "openrayneo.file-transfer")
    private var transfers: [String: Transfer] = [:]
    private let directory: URL
    private var timer: DispatchSourceTimer?

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, directory: URL? = nil) {
        self.transport = transport; self.operationLock = lock
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/Transfers", isDirectory: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.expire() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        if method == "GET", path == "/v1/files" {
            return (200, queue.sync { ["transfers": transfers.values.sorted { $0.updated > $1.updated }.map(\.status),
                "receiveDirectory": directory.path, "connected": transport.isConnected, "automaticResume": false] })
        }
        guard method == "POST", path == "/v1/files/send" || path == "/v1/files/cancel" else { return nil }
        operationLock.lock(); defer { operationLock.unlock() }
        if path == "/v1/files/send" {
            guard let path = body["path"] as? String else {
                throw BridgeError(status: 400, message: "path is required")
            }
            let core: UInt8
            if let name = body["core"] as? String, name == "small" || name == "large" {
                core = name == "large" ? 0x12 : 0x11
            } else if let number = body["core"] as? NSNumber, number.intValue == 0x11 || number.intValue == 0x12 {
                core = UInt8(number.intValue)
            } else if body["core"] == nil { core = 0x11 }
            else { throw BridgeError(status: 400, message: "core must be small (0x11) or large (0x12)") }
            // SDK K5/l.e derives FileInfoSync.bus_id from SmallCore/LargeCore, not the consuming app.
            let businessID = UInt64(core)
            if let supplied = body["businessID"] {
                guard let number = supplied as? NSNumber, number.uint64Value == businessID else {
                    throw BridgeError(status: 400, message: "businessID must match the selected file core (17 for small, 18 for large)")
                }
            }
            try transport.ensureConnected()
            let url = URL(fileURLWithPath: path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                throw BridgeError(status: 400, message: "path must name a regular file")
            }
            let digest = try Self.digest(url)
            let transfer = Transfer(id: UUID().uuidString.lowercased(), direction: "send", core: core,
                                    businessID: businessID, url: url, size: size, md5: digest)
            transfer.file = try FileHandle(forReadingFrom: url)
            return try queue.sync {
                transfers[transfer.id] = transfer
                do {
                    var info = ProtocolCodec.field(1, string: transfer.id)
                    info.append(ProtocolCodec.field(2, string: body["fileName"] as? String ?? url.lastPathComponent))
                    info.append(ProtocolCodec.field(3, varint: size))
                    info.append(ProtocolCodec.field(4, string: digest))
                    info.append(ProtocolCodec.field(5, varint: businessID))
                    try send(transfer, field: 1, payload: info)
                    return (202, transfer.status)
                } catch { finish(transfer, state: "failed", error: error.localizedDescription); throw error }
            }
        }
        guard let uuid = body["uuid"] as? String else { throw BridgeError(status: 400, message: "uuid is required") }
        let transfer = try queue.sync { () throws -> Transfer in
            guard let transfer = transfers[uuid] else { throw BridgeError(status: 404, message: "Transfer not found") }
            if transfer.active { transfer.cancellationOrigin = "local"; finish(transfer, state: "cancelled") }
            return transfer
        }
        if queue.sync(execute: { transfer.cancellationOrigin == "local" && !transfer.cancelNotificationSent }), transport.isConnected {
            do {
                var cancel = ProtocolCodec.field(1, string: uuid)
                cancel.append(ProtocolCodec.field(2, string: "Cancelled by user"))
                try send(transfer, field: 6, payload: cancel)
                queue.sync { transfer.cancelNotificationSent = true }
            } catch {
                queue.sync { transfer.error = "本地已取消；远端通知未确认：\(error.localizedDescription)" }
            }
        }
        return (200, queue.sync { transfer.status })
    }

    /// Enqueue original TransferMessage bytes. Unknown UUIDs on replies are ignored,
    /// so the existing teleprompter sender can continue consuming its own replies.
    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 0x11 || message.protocolID == 0x12,
              let field = ProtocolCodec.firstFieldNumber(message.protobuf), (1...6).contains(field),
              let payload = ProtocolCodec.nestedBytes(message.protobuf, field: field),
              let id = ProtocolCodec.stringValue(payload, field: 1), !id.isEmpty else { return }
        queue.async { [weak self] in self?.receive(core: message.protocolID, field: field, id: id, payload: payload) }
    }

    /// Called when AA55 framing is complete but its CRC is invalid. Only an
    /// already-owned incoming chunk can ask for a repeat; it is never written.
    func handleCorruptFrame(_ frame: Data) {
        guard frame.count >= 10, frame[0] == 0xaa, frame[1] == 0x55,
              frame[7] == 0x11 || frame[7] == 0x12 else { return }
        let length = Int(frame[2]) << 8 | Int(frame[3])
        guard length >= 4, frame.count == length + 6,
              let payload = ProtocolCodec.nestedBytes(frame.subdata(in: 8..<(frame.count - 2)), field: 4),
              let id = ProtocolCodec.stringValue(payload, field: 1) else { return }
        queue.async { [weak self] in
            guard let self, let transfer = self.transfers[id], transfer.active,
                  transfer.direction == "receive", transfer.core == frame[7] else { return }
            transfer.retries += 1
            do {
                if transfer.retries > 3 {
                    try self.sendState(transfer, success: false, reason: "Chunk CRC retry limit reached")
                    self.finish(transfer, state: "failed", error: "Chunk CRC retry limit reached")
                } else if let range = transfer.currentRequest {
                    var request = ProtocolCodec.field(1, string: transfer.id)
                    request.append(ProtocolCodec.field(2, varint: transfer.chunkID))
                    request.append(ProtocolCodec.field(3, varint: range.offset))
                    request.append(ProtocolCodec.field(4, varint: range.size))
                    try self.send(transfer, field: 3, payload: request)
                    transfer.updated = Date()
                }
            } catch { self.finish(transfer, state: "failed", error: error.localizedDescription) }
        }
    }

    private func receive(core: UInt8, field: UInt64, id: String, payload: Data) {
        var transfer = transfers[id]
        do {
            if field == 1 {
                if let transfer, transfer.active {
                    guard transfer.direction == "receive", transfer.core == core else { return }
                    try send(transfer, field: 2, payload: ProtocolCodec.field(1, string: id))
                    try requestNext(transfer)
                    return
                }
                guard let name = ProtocolCodec.stringValue(payload, field: 2),
                      let md5 = ProtocolCodec.stringValue(payload, field: 4) else { return }
                let size = ProtocolCodec.varintValue(payload, field: 3) ?? 0
                let business = ProtocolCodec.varintValue(payload, field: 5) ?? 0
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let leaf = URL(fileURLWithPath: name).lastPathComponent
                let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(leaf.isEmpty ? "file" : leaf)")
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let incoming = Transfer(id: id, direction: "receive", core: core, businessID: business, url: url, size: size, md5: md5)
                incoming.file = try FileHandle(forUpdating: url)
                transfers[id] = incoming; transfer = incoming
                try send(incoming, field: 2, payload: ProtocolCodec.field(1, string: id))
                try requestNext(incoming)
                return
            }
            guard let transfer, transfer.active, transfer.core == core else { return }
            transfer.updated = Date()
            switch field {
            case 2:
                if transfer.direction == "send" { transfer.state = "transferring" }
            case 3:
                guard transfer.direction == "send", let file = transfer.file else { return }
                let offset = ProtocolCodec.varintValue(payload, field: 3) ?? 0
                let requested = ProtocolCodec.varintValue(payload, field: 4) ?? 0
                guard offset <= transfer.size, requested > 0 else { throw BridgeError(status: 502, message: "Invalid file range requested by glasses") }
                let length = min(requested, transfer.size - offset)
                guard length > 0, length <= UInt64(UInt16.max) else {
                    throw BridgeError(status: 502, message: "Requested chunk cannot fit the bounded file transport frame")
                }
                try file.seek(toOffset: offset)
                let data = try file.read(upToCount: Int(length)) ?? Data()
                var chunk = ProtocolCodec.field(1, string: id)
                chunk.append(ProtocolCodec.field(2, varint: ProtocolCodec.varintValue(payload, field: 2) ?? 0))
                chunk.append(ProtocolCodec.field(3, varint: offset))
                chunk.append(ProtocolCodec.field(4, varint: UInt64(data.count)))
                chunk.append(ProtocolCodec.field(5, bytes: data))
                try send(transfer, field: 4, payload: chunk)
                transfer.include(offset..<(offset + UInt64(data.count)))
                transfer.state = "transferring"
            case 4:
                guard transfer.direction == "receive", let file = transfer.file,
                      let data = ProtocolCodec.nestedBytes(payload, field: 5) else { return }
                let offset = ProtocolCodec.varintValue(payload, field: 3) ?? 0
                let length = UInt64(data.count)
                guard offset <= transfer.size, length <= transfer.size - offset,
                      (ProtocolCodec.varintValue(payload, field: 4) ?? 0) == length else {
                    throw BridgeError(status: 502, message: "Received file chunk is outside the declared file")
                }
                let range = offset..<(offset + length)
                if !transfer.ranges.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }) {
                    try file.seek(toOffset: offset); try file.write(contentsOf: data)
                    transfer.include(range)
                }
                transfer.retries = 0
                try requestNext(transfer)
            case 5:
                if transfer.direction == "send" {
                    let state = ProtocolCodec.varintValue(payload, field: 2) ?? 0
                    transfer.peerReceiveState = state
                    if state == 0 || state == 1 {
                        finish(transfer, state: state == 0 ? "completed" : "failed", error: state == 0 ? nil : ProtocolCodec.stringValue(payload, field: 3))
                    }
                }
            case 6:
                transfer.cancellationOrigin = "peer"
                finish(transfer, state: "cancelled", error: ProtocolCodec.stringValue(payload, field: 2))
            default: break
            }
        } catch {
            if let transfer {
                try? sendState(transfer, success: false, reason: error.localizedDescription)
                finish(transfer, state: "failed", error: error.localizedDescription)
            }
        }
    }

    private func requestNext(_ transfer: Transfer) throws {
        var offset: UInt64 = 0
        for range in transfer.ranges {
            if range.lowerBound > offset { break }
            offset = max(offset, range.upperBound)
        }
        if offset >= transfer.size {
            try transfer.file?.synchronize()
            let matches = try Self.digest(transfer.url).caseInsensitiveCompare(transfer.md5) == .orderedSame
            if matches {
                do {
                    try sendState(transfer, success: true, reason: "")
                    transfer.completionNotificationSent = true
                    finish(transfer, state: "completed")
                } catch {
                    // The file is already complete and verified; losing the final notification must not trash it.
                    transfer.completionNotificationSent = false
                    finish(transfer, state: "completed", error: "文件已完整接收并校验；完成通知未确认：\(error.localizedDescription)")
                }
            } else {
                try? sendState(transfer, success: false, reason: "MD5 mismatch")
                finish(transfer, state: "failed", error: "MD5 mismatch")
            }
            return
        }
        let size = min(UInt64(51_200), transfer.size - offset)
        transfer.chunkID &+= 1
        transfer.currentRequest = (offset, size)
        transfer.state = "transferring"
        var request = ProtocolCodec.field(1, string: transfer.id)
        request.append(ProtocolCodec.field(2, varint: transfer.chunkID))
        request.append(ProtocolCodec.field(3, varint: offset))
        request.append(ProtocolCodec.field(4, varint: size))
        try send(transfer, field: 3, payload: request)
    }

    private func sendState(_ transfer: Transfer, success: Bool, reason: String) throws {
        var state = ProtocolCodec.field(1, string: transfer.id)
        state.append(ProtocolCodec.field(2, varint: success ? 0 : 1))
        state.append(ProtocolCodec.field(3, string: reason))
        try send(transfer, field: 5, payload: state)
    }

    private func send(_ transfer: Transfer, field: UInt64, payload: Data) throws {
        let protobuf = ProtocolCodec.field(field, bytes: payload)
        try transport.send(ProtocolCodec.rawBusinessFrame(protocolID: transfer.core, sequence: 0, payload: protobuf))
    }

    private func finish(_ transfer: Transfer, state: String, error: String? = nil) {
        try? transfer.file?.close(); transfer.file = nil
        transfer.state = state; transfer.error = error; transfer.updated = Date()
        if transfer.direction == "receive", state != "completed", FileManager.default.fileExists(atPath: transfer.url.path) {
            try? FileManager.default.trashItem(at: transfer.url, resultingItemURL: nil)
        }
    }

    private func expire() {
        for transfer in transfers.values where transfer.active && Date().timeIntervalSince(transfer.updated) > 120 {
            finish(transfer, state: "failed", error: "Transfer timed out after 120 seconds without progress")
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var md5 = Insecure.MD5()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { md5.update(data: chunk) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
