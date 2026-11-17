// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Business 0x16 has no query transaction ID. Every caller uses this collector.
final class ScheduleTodoSync {
    private static let queryLock = NSRecursiveLock()
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private let todoStore: TodoOwnershipStore?
    private let events = DispatchQueue(label: "openrayneo.todo-events")
    private var sequence: UInt16 = 0x7400
    private var generation = 0
    private let generationLock = NSLock()

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, todoStore: TodoOwnershipStore? = nil) {
        self.transport = transport
        self.lock = lock
        self.todoStore = todoStore
    }

    /// Safe on the receive callback: never waits for the operation/query lock.
    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 0x16, let type = message.messageType,
              type == 4 || type == 10, let body = message.json else { return }
        events.async { [weak self] in
            do { try self?.todoStore?.applyGlassesStatus(type: type, body: body, receivedAt: message.receivedAt) }
            catch { fputs("ToDo status persistence failed: \(error)\n", stderr) }
        }
    }

    /// Includes locally observed completions that the pending-only device list omits.
    /// This is a display/history view, never the source of an outbound full list.
    func localTodoItems() -> [[String: Any]] {
        events.sync { todoStore?.localItems() ?? [] }
    }

    func query(eventType: Int, needFullData: Bool = true) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        Self.queryLock.lock(); defer { Self.queryLock.unlock() }
        try transport.ensureConnected()
        let started = Date()
        try send(type: 15, body: ["queryType": 0, "eventType": eventType,
            "lastSyncTime": 0, "eventIDList": [], "needFullData": needFullData])
        var deadline = Date().addingTimeInterval(5)
        var first = true
        var last: [String: Any] = [:]
        var items: [[String: Any]] = []
        repeat {
            guard let response = transport.waitForMessage(timeout: max(0, deadline.timeIntervalSinceNow), matching: {
                $0.protocolID == 0x16 && $0.messageType == 16 && $0.receivedAt >= started
            })?.json, let list = response["dataList"] as? [[String: Any]] else {
                throw BridgeError(status: 504, message: "Glasses did not return the complete event list")
            }
            if first { deadline = Date().addingTimeInterval(5); first = false }
            last = response
            items.append(contentsOf: list.filter { ($0["eventType"] as? NSNumber)?.intValue == eventType })
        } while last["isLastBatch"] as? Bool != true
        let countKey = eventType == 1 ? "todoTotal" : "scheduleTotal"
        let ids = items.compactMap { ($0["eventID"] as? NSNumber)?.int64Value }
        guard let expected = (last[countKey] as? NSNumber)?.intValue, expected == items.count,
              Set(ids).count == items.count, !needFullData || last["needFullData"] as? Bool == true else {
            throw BridgeError(status: 409, message: "Glasses event snapshot is incomplete")
        }
        last["dataList"] = items
        if eventType == 1, needFullData {
            try events.sync { try todoStore?.recordSnapshot(items, startedAt: started) }
        }
        return last
    }

    /// `total` is the current pending total, including items outside an incremental batch.
    /// No absence/deletion semantics are inferred from this payload.
    func sendTodos(_ items: [[String: Any]], total: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try transport.ensureConnected()
        generationLock.lock(); generation += 1; let current = generation; generationLock.unlock()
        if items.count <= 30 {
            try send(type: 6, body: ["total": total, "isLastBatch": true, "eventList": items])
            return
        }
        for offset in stride(from: 0, to: items.count, by: 30) {
            generationLock.lock(); let valid = generation == current; generationLock.unlock()
            guard valid else { throw BridgeError(status: 409, message: "ToDo synchronization was cancelled") }
            let batch = Array(items[offset..<min(offset + 30, items.count)])
            let number = offset / 30 + 1
            let last = offset + batch.count == items.count
            try send(type: 6, body: ["total": total, "batchNo": number, "isLastBatch": last,
                "chunkInfo": ["chunkId": current, "batchNo": number, "isLastBatch": last,
                    "currentItems": batch.count], "eventList": batch])
        }
    }

    func cancelTodoSync() {
        generationLock.lock(); generation += 1; generationLock.unlock()
    }

    private func send(type: UInt64, body: [String: Any]) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: 0x16, sequence: sequence, type: type, body: body))
    }
}
