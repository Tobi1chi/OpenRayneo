// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import IOBluetooth

public final class BridgeController {
    private let transport: RFCOMMTransport
    let displays: DisplayController
    let speech: SpeechController
    private let operationLock: NSRecursiveLock
    private var nextSequence: UInt16 = 0
    private var activeDocumentID: String?
    private var customScriptCount = 0

    public init(address: String) {
        let transport = RFCOMMTransport(address: address)
        let operationLock = NSRecursiveLock()
        self.operationLock = operationLock
        self.transport = transport
        let displays = DisplayController(transport: transport, lock: operationLock)
        self.displays = displays
        speech = SpeechController(transport: transport, displays: displays)
    }

    public static func resolveRayneoAddress() -> String? {
        if let configured = ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"], !configured.isEmpty {
            return configured
        }
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let matches = devices.filter { ($0.nameOrAddress ?? "").localizedCaseInsensitiveContains("RayNeo iO") }
        return matches.count == 1 ? matches[0].addressString : nil
    }

    var isConnected: Bool { transport.isConnected }
    var isBLEReady: Bool { transport.isBLEReady }
    var diagnostics: [String: Any] { transport.diagnostics }

    public func connect() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try transport.ensureConnected()
    }

    func postNotification(title: String, body: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "notificationUID": String(timestamp),
            "appId": "com.openrayneo.bridge",
            "appName": "OpenRayneo Bridge",
            "title": title,
            "subtitle": NSNull(),
            "content": body,
            "timestamp": String(timestamp),
            "category": 0,
            "reply": false,
            "type": 1
        ]
        try sendNotification(payload)
    }

    func startTeleprompter(title: String, text: String, speed: Int) throws -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !text.isEmpty else { throw BridgeError(status: 400, message: "text must not be empty") }

        let documentID = Self.uuidV7()
        let content = Data(text.utf8)
        let characterCount = text.utf16.count
        let timestamp = Int64(Date().timeIntervalSince1970)
        let timezone = TimeZone.current.secondsFromGMT()
        let settings: [String: Any] = [
            "countdown": 3,
            "scroll": 1,
            "speed": speed,
            "gear": 1,
            "depth": 1,
            "size": 18,
            "width": 492,
            "leading": 4
        ]

        var startBody: [String: Any] = settings
        startBody["action"] = 1
        startBody["total"] = characterCount
        startBody["did"] = documentID
        startBody["pageOffset"] = 0
        startBody["highLightOffset"] = 0
        try sendTeleprompter(type: 2, action: 1, body: startBody)

        let taskID = "task_2_\(Int64(Date().timeIntervalSince1970 * 1000))"
        try sendScriptTransfer(taskID: taskID, documentID: documentID, content: content)
        _ = transport.waitForMessage(timeout: 1.0) {
            $0.protocolID == 0x14 && $0.messageType == 2 && $0.action == 2
        }

        var item: [String: Any] = [
            "did": documentID,
            "pin": false,
            "title": title,
            "offset": 0,
            "scroll": 1,
            "total": characterCount,
            "timestamp": timestamp,
            "preview": String(text.prefix(80)),
            "timezone": timezone
        ]
        if title.isEmpty { item["title"] = "Untitled" }
        let listBody: [String: Any] = [
            "action": 2,
            "type": 3,
            "total": customScriptCount + 2,
            "chunkinfo": ["chunkid": 1, "total_items": 1, "islast": true],
            "items": [item]
        ]
        try sendTeleprompter(type: 1, action: 2, body: listBody)
        _ = transport.waitForMessage(timeout: 1.0) {
            $0.protocolID == 0x14 && $0.messageType == 1 && $0.action == 2
        }

        var transferBody: [String: Any] = settings
        transferBody["action"] = 1
        transferBody["did"] = documentID
        transferBody["total"] = characterCount
        transferBody["pageOffset"] = 0
        transferBody["highLightOffset"] = 0
        transferBody["code"] = 1
        transferBody["checksum"] = ProtocolCodec.fnv1a32(content)
        try sendTeleprompter(type: 3, action: 1, body: transferBody)
        _ = transport.waitForMessage(timeout: 1.0) {
            $0.protocolID == 0x14 && $0.messageType == 3 && $0.action == 2
        }

        customScriptCount += 1
        activeDocumentID = documentID
        return documentID
    }

    func controlTeleprompter(_ action: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let documentID = activeDocumentID else {
            throw BridgeError(status: 409, message: "No teleprompter script is active")
        }
        switch action {
        case "pause":
            try sendTeleprompter(type: 4, action: 1, body: [
                "action": 1,
                "did": documentID,
                "offset": 0,
                "code": 1,
                "isCompleted": false
            ])
        case "resume":
            try sendTeleprompter(type: 5, action: 1, body: ["action": 1, "did": documentID])
        case "stop":
            try sendTeleprompter(type: 6, action: 1, body: ["action": 1, "did": documentID])
            activeDocumentID = nil
        default:
            throw BridgeError(status: 404, message: "Unknown teleprompter action")
        }
    }

    private func sendNotification(_ body: [String: Any]) throws {
        let frame = try ProtocolCodec.notificationFrame(sequence: takeSequence(), body: body)
        try transport.send(frame)
    }

    private func sendTeleprompter(type: UInt64, action: UInt64, body: [String: Any]) throws {
        let frame = try ProtocolCodec.teleprompterFrame(sequence: takeSequence(), type: type, action: action, body: body)
        try transport.send(frame)
        usleep(25_000)
    }

    private func sendScriptTransfer(taskID: String, documentID: String, content: Data) throws {
        var info = ProtocolCodec.field(1, string: taskID)
        info.append(ProtocolCodec.field(2, string: documentID))
        info.append(ProtocolCodec.field(3, varint: UInt64(content.count)))
        info.append(ProtocolCodec.field(4, string: ProtocolCodec.md5(content)))
        info.append(ProtocolCodec.field(5, varint: 17))
        try transport.send(ProtocolCodec.fileTransferFrame(protobuf: ProtocolCodec.field(1, bytes: info)))

        var nextOffset = 0
        while nextOffset < content.count {
            let requestedChunk = transport.waitForMessage(timeout: 5.0) {
                guard $0.protocolID == 0x11,
                      ProtocolCodec.firstFieldNumber($0.protobuf) == 3,
                      let request = ProtocolCodec.nestedBytes($0.protobuf, field: 3) else { return false }
                return ProtocolCodec.stringValue(request, field: 1) == taskID
            }
            guard let requestedChunk,
                  let request = ProtocolCodec.nestedBytes(requestedChunk.protobuf, field: 3),
                  let requestedSize = ProtocolCodec.varintValue(request, field: 4) else {
                throw BridgeError(status: 504, message: "Glasses did not request the script data chunk")
            }

            let offsetValue = ProtocolCodec.varintValue(request, field: 3) ?? 0
            guard offsetValue <= UInt64(content.count) else {
                throw BridgeError(status: 502, message: "Glasses requested a script chunk outside the file")
            }
            let offset = Int(offsetValue)
            let size = Int(min(requestedSize, UInt64(content.count) - offsetValue))
            guard size > 0 else {
                throw BridgeError(status: 502, message: "Glasses requested an empty script chunk")
            }
            let end = offset + size
            let chunk = content.subdata(in: offset..<end)
            var entry = ProtocolCodec.field(1, string: taskID)
            entry.append(ProtocolCodec.field(2, varint: ProtocolCodec.varintValue(request, field: 2) ?? 0))
            entry.append(ProtocolCodec.field(3, varint: UInt64(offset)))
            entry.append(ProtocolCodec.field(4, varint: UInt64(chunk.count)))
            entry.append(ProtocolCodec.field(5, bytes: chunk))
            try transport.send(ProtocolCodec.fileTransferFrame(protobuf: ProtocolCodec.field(4, bytes: entry)))
            fputs("[RayNeo iO transfer] Sent bytes \(offset)..<\(end) of \(content.count)\n", stderr)
            nextOffset = max(nextOffset, end)
        }

        let received = transport.waitForMessage(timeout: 5.0) {
            $0.protocolID == 0x11 &&
            ProtocolCodec.firstFieldNumber($0.protobuf) == 5 &&
            ProtocolCodec.nestedBytes($0.protobuf, field: 5).flatMap { state in
                ProtocolCodec.stringValue(state, field: 1)
            } == taskID
        }
        guard let received,
              let state = ProtocolCodec.nestedBytes(received.protobuf, field: 5),
              (ProtocolCodec.varintValue(state, field: 2) ?? 0) == 0 else {
            throw BridgeError(status: 504, message: "Glasses did not confirm script transfer")
        }
        fputs("[RayNeo iO transfer] Glasses confirmed \(content.count) bytes\n", stderr)
    }

    private func takeSequence() -> UInt16 {
        nextSequence &+= 1
        return nextSequence
    }

    private static func uuidV7() -> String {
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> UInt64((5 - index) * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let value = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return value.uuidString.lowercased()
    }
}
