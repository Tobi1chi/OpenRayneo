// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class CapabilityController {
    private let transport: RFCOMMTransport
    private let operationLock: NSRecursiveLock
    private let queue = DispatchQueue(label: "openrayneo.capabilities")
    private var sequence: UInt16 = 0xa000
    private var peer: [[String]] = []
    private var local: [[String]] = []
    private var lastResult = "unknown"

    init(transport: RFCOMMTransport, lock: NSRecursiveLock) { self.transport = transport; operationLock = lock }

    func handle(_ message: RemoteMessage) {
        queue.async { [weak self] in
            guard let self, let json = message.json else { return }
            switch json["type"] as? Int {
            case 1:
                try? self.send(["type": 2, "ret": "OK", "capabilities": self.local])
            case 2, 3:
                self.lastResult = json["ret"] as? String ?? "OK"
                if let items = json["capabilities"] as? [[String]] { self.peer = items }
            default: break
            }
        }
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/capabilities" else { return nil }
        if method == "GET" { return (200, queue.sync { status() }) }
        guard method == "POST" else { return nil }
        operationLock.lock(); defer { operationLock.unlock() }
        try transport.ensureConnected()
        if let items = body["capabilities"] as? [[String]] {
            try queue.sync { local = items; try send(["type": 3, "capabilities": local]) }
        } else {
            let started = Date()
            try queue.sync { try send(["type": 1]) }
            _ = transport.waitForMessage(timeout: 5) { $0.protocolID == 6 && $0.messageType == 2 && $0.receivedAt >= started }
        }
        return (200, queue.sync { status() })
    }

    private func send(_ body: [String: Any]) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.rawBusinessFrame(protocolID: 6, sequence: sequence, payload: JSONSerialization.data(withJSONObject: body)))
    }
    private func status() -> [String: Any] { ["peer": peer, "local": local, "result": lastResult] }
}
