// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class MaintenanceController {
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private var sequence: UInt16 = 0xb000
    private let queue = DispatchQueue(label: "openrayneo.maintenance")
    private var firmware: [String: Any] = [:]
    private var logStatus: [String: Any] = [:]
    init(transport: RFCOMMTransport, lock: NSRecursiveLock) { self.transport = transport; self.lock = lock }

    func handle(_ message: RemoteMessage) {
        queue.async { [weak self] in
            guard let self, let json = message.json else { return }
            if message.protocolID == 9, message.messageType == 1 { self.firmware = json }
            if message.protocolID == 11, message.messageType == 17 { self.logStatus = json }
        }
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        if path == "/v1/maintenance", method == "GET" { return (200, queue.sync { ["firmware": firmware, "logs": logStatus] }) }
        guard path == "/v1/firmware" || path == "/v1/logs/request" || path == "/v1/glasses/factory-reset" || path == "/v1/glasses/unbind-reset" else { return nil }
        lock.lock(); defer { lock.unlock() }
        try transport.ensureConnected()
        let started = Date(); sequence &+= 1
        if ["/v1/glasses/factory-reset", "/v1/glasses/unbind-reset"].contains(path), method == "POST" {
            let resetType = path == "/v1/glasses/unbind-reset" ? 2 : 1
            try transport.send(ProtocolCodec.displayFrame(protocolID: 15, sequence: sequence, type: 14,
                body: ["cmd": "factory_reset", "payload": ["value": resetType, "mode": 1, "data": ""]]))
            guard let json = transport.waitForMessage(timeout: 3, matching: {
                $0.protocolID == 15 && $0.receivedAt >= started && $0.json?["cmd"] as? String == "factory_reset_ack"
            })?.json else { throw BridgeError(status: 504, message: "未收到恢复出厂确认；请检查眼镜状态，不要重复发送") }
            guard let payload = json["payload"] as? [String: Any], let code = payload["value"] as? Int else {
                throw BridgeError(status: 503, message: "眼镜的恢复出厂回复缺少结果码")
            }
            guard code == 0 else { throw BridgeError(status: 503, message: "眼镜拒绝恢复出厂，结果码 \(code)") }
            return (200, ["accepted": true, "resetType": resetType, "requiresReconnect": true, "reply": json])
        }
        if path == "/v1/firmware", method == "GET" {
            try transport.send(ProtocolCodec.transportFrame(protocolID: 9, sequence: sequence, type: 1))
            guard let json = transport.waitForMessage(timeout: 5, matching: {
                $0.protocolID == 9 && $0.messageType == 1 && $0.receivedAt >= started
            })?.json else { throw BridgeError(status: 504, message: "Glasses firmware query timed out") }
            return (200, json)
        }
        if path == "/v1/logs/request", method == "POST" {
            try transport.send(ProtocolCodec.displayFrame(protocolID: 11, sequence: sequence, type: 16,
                body: ["cmd": "start_log_task", "payload": ["value": 0, "mode": 0, "data": ""]]))
            guard let json = transport.waitForMessage(timeout: 15, matching: {
                $0.protocolID == 11 && $0.messageType == 17 && $0.receivedAt >= started
            })?.json else { throw BridgeError(status: 504, message: "Glasses log request timed out") }
            return (202, ["reply": json, "message": "日志压缩与文件传输状态可在文件传输页查看"])
        }
        return nil
    }
}
