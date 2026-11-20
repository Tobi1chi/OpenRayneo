// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOBluetooth

private final class SDPQueryCompletion: NSObject {
    static let queryKind = "allL2CAPServices"
    let completed = DispatchSemaphore(value: 0)
    let generation: Int
    private let lock = NSLock()
    private var result: IOReturn?
    private var startResult: IOReturn?
    private var startedAt: Date?
    private var callbackAt: Date?
    private var timedOutAt: Date?
    var didComplete: ((SDPQueryCompletion) -> Void)?

    init(generation: Int) { self.generation = generation; super.init() }

    func markStarted() { lock.lock(); startedAt = Date(); lock.unlock() }
    func recordStartResult(_ value: IOReturn) { lock.lock(); startResult = value; lock.unlock() }
    func markTimedOut() { lock.lock(); timedOutAt = Date(); lock.unlock() }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        lock.lock(); result = status; callbackAt = Date(); lock.unlock()
        completed.signal(); didComplete?(self)
    }

    var status: IOReturn? { lock.lock(); defer { lock.unlock() }; return result }

    var diagnostics: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["generation": generation, "queryKind": Self.queryKind,
            "startedAt": startedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "callbackAt": callbackAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "elapsedMilliseconds": startedAt.map { (callbackAt ?? Date()).timeIntervalSince($0) * 1_000 } as Any? ?? NSNull(),
            "startStatus": startResult as Any? ?? NSNull(), "callbackStatus": result as Any? ?? NSNull(),
            "timedOutAt": timedOutAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "completedAfterTimeout": callbackAt.map { callback in timedOutAt.map { callback > $0 } ?? false } as Any? ?? NSNull(),
            "pending": callbackAt == nil && (startResult == nil || startResult == kIOReturnSuccess)]
    }
}

private final class DataChannelDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    weak var owner: RFCOMMTransport?
    let generation: Int
    init(owner: RFCOMMTransport, generation: Int) { self.owner = owner; self.generation = generation }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        owner?.channelOpened(channel, status: status, generation: generation)
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        owner?.channelReceived(channel, data: data, length: length, generation: generation)
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        owner?.channelClosed(channel, generation: generation)
    }
}

final class RFCOMMTransport: NSObject {
    private let address: String
    private let bleReadiness: BLEReadinessSession
    private let writeLock = NSLock()
    private var appForeground = ProcessInfo.processInfo.environment["OPENRAYNEO_APP_FOREGROUND"] != "0"
    private var visibilitySequence: UInt16 = 0x7800
    private var connectionGeneration = 0
    private let recoveryCondition = NSCondition()
    private let recoveryQueue = DispatchQueue(label: "openrayneo.link-recovery", qos: .userInitiated)
    private let connectionEvents = DispatchQueue(label: "openrayneo.link-events")
    private var connectionDesired = false
    private var recoverySuspended = false
    private var recoveryRunning = false
    private var recoveryCycle = 0
    private var activeRecoveryEpoch = 0
    private var demandEpoch = 0
    private var everConnected = false
    private var linkPhase = "idle"
    private var recoveryAttempt = 0
    private var linkError: String?
    private var recoveryReason = ""
    private var nextRetryAt: Date?
    private var retryWork: DispatchWorkItem?
    private var selectedChannel: BluetoothRFCOMMChannelID = 26
    private var selectedChannelSource = "fallback26"
    private var sdpError: String?
    private var sdpQueries: [Int: SDPQueryCompletion] = [:]
    private var sdpQueryHistory: [SDPQueryCompletion] = []
    private let maximumPendingSDPQueries = 3
    private var skippedSDPQueries = 0
    private var lastSkippedSDPQueryAt: Date?
    private var readyHandler: ((Int) -> Void)?
    private var lostHandler: ((Bool) -> Void)?
    private var lossNotifiedBLE: Bool?
    private var channelDelegate: DataChannelDelegate?
    private var channelGeneration: Int?
    private var expectedOpenGeneration: Int?
    private var receiveEpoch = 0
    private var visibilitySentGeneration: Int?
    private var visibilitySentForeground: Bool?
    private var visibilitySentAt: Date?
    private var visibilityAttemptAt: Date?
    private var visibilityError: String?
    private let visibilityStateLock = NSLock()
    private var visibilitySnapshot: [String: Any] = [:]
    private let acknowledgementQueue = DispatchQueue(label: "openrayneo.transport-ack", qos: .userInitiated)
    private let acknowledgementLock = NSLock()
    private var acknowledgementsSent = 0
    private var acknowledgementsReceived = 0
    private var acknowledgementError: String?
    private let channelLock = NSLock()
    private let receiveCondition = NSCondition()
    private let openCondition = NSCondition()
    private let closingChannels = DispatchGroup()
    private var device: IOBluetoothDevice?
    private var storedChannel: IOBluetoothRFCOMMChannel?
    private var channel: IOBluetoothRFCOMMChannel? {
        get {
            channelLock.lock()
            defer { channelLock.unlock() }
            return storedChannel
        }
        set {
            channelLock.lock()
            storedChannel = newValue
            channelLock.unlock()
        }
    }
    private var channelOpenResult: IOReturn?
    private var receiveBuffer = Data()
    private var remoteMessages: [RemoteMessage] = []
    private var recentDisplayMessages: [[String: Any]] = []
    private var droppedDisplayAudioPackets = 0
    private var audioHandler: ((RemoteMessage) -> Void)?
    private var displayControlHandler: ((RemoteMessage) -> Void)?
    private var nativeRecordingHandler: ((RemoteMessage) -> Void)?
    private var todoStatusHandler: ((RemoteMessage) -> Void)?
    private var fileTransferHandler: ((RemoteMessage) -> Void)?
    private var corruptFrameHandler: ((Data) -> Void)?
    private var networkRelayHandler: ((RemoteMessage) -> Void)?
    private var capabilityHandler: ((RemoteMessage) -> Void)?
    private var maintenanceHandler: ((RemoteMessage) -> Void)?
    private var otaHandler: ((RemoteMessage) -> Void)?
    private var teleprompterHandler: ((RemoteMessage) -> Void)?
    private var teleprompterDisconnectHandler: (() -> Void)?
    private var lifeLogAudioHandler: ((RemoteMessage) -> Void)?
    private var nativeAssistantHandler: ((RemoteMessage) -> Void)?
    private var lifeLogWakeHandler: ((RemoteMessage) -> Void)?
    private var lifeLogEvents: [[String: Any]] = []
    private var lifeLogAudioCounts: [String: Int] = [:]
    private var lifeLogLastAudioMetadata: [String: Any] = [:]

    func setNativeAssistantHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        nativeAssistantHandler = handler
    }

    func setLifeLogAudioHandler(_ handler: ((RemoteMessage) -> Void)?) {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        lifeLogAudioHandler = handler
    }

    func observeLifeLog(_ wake: ((RemoteMessage) -> Void)?) {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        lifeLogWakeHandler = wake
        if wake != nil {
            lifeLogEvents = []
            lifeLogAudioCounts = [:]
            lifeLogLastAudioMetadata = [:]
        }
    }

    var lifeLogDiagnostics: [String: Any] {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        return ["events": lifeLogEvents, "audio": lifeLogAudioCounts, "lastAudioMetadata": lifeLogLastAudioMetadata]
    }

    func setAudioHandler(_ handler: ((RemoteMessage) -> Void)?) {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        audioHandler = handler
    }

    func setDisplayControlHandler(_ handler: ((RemoteMessage) -> Void)?) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        displayControlHandler = handler
    }

    func setNativeRecordingHandler(_ handler: ((RemoteMessage) -> Void)?) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        nativeRecordingHandler = handler
    }

    func setTodoStatusHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        todoStatusHandler = handler
    }

    func setFileTransferHandlers(message: @escaping (RemoteMessage) -> Void, corrupt: @escaping (Data) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        fileTransferHandler = message; corruptFrameHandler = corrupt
    }

    func setNetworkRelayHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        networkRelayHandler = handler
    }

    func setCapabilityHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        capabilityHandler = handler
    }

    func setMaintenanceHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        maintenanceHandler = handler
    }

    func setOTAHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        otaHandler = handler
    }

    func setTeleprompterHandlers(message: @escaping (RemoteMessage) -> Void, disconnected: @escaping () -> Void) {
        receiveCondition.lock(); defer { receiveCondition.unlock() }
        teleprompterHandler = message
        teleprompterDisconnectHandler = disconnected
    }

    init(address: String) {
        self.address = address.replacingOccurrences(of: "-", with: ":")
        let intent = ConnectionIntent(rawValue: ProcessInfo.processInfo.environment["OPENRAYNEO_CONNECTION_INTENT"] ?? "") ?? .reconnect
        bleReadiness = BLEReadinessSession(address: address, intent: intent)
        super.init()
        refreshVisibilitySnapshot()
        bleReadiness.setReadinessHandlers(changed: { [weak self] ready in
            guard let self, !ready else { return }
            if let connection = self.channel { self.loseChannel(connection, reason: "BLE authentication link lost") }
            else { self.notifyLinkLost(bleDisconnected: true, reason: "BLE authentication link lost") }
        }, poweredOn: { [weak self] in
            _ = self?.requestRecovery(reason: "bluetoothPoweredOn")
        })
        bleReadiness.setBusinessMessageHandler { [weak self] message in
            guard let self else { return }
            guard self.bleReadiness.isReady || (message.protocolID == 0x10 && message.protobuf.first == 0x1e) else { return }
            self.receiveCondition.lock()
            self.dispatch(message)
            self.receiveCondition.broadcast()
            self.receiveCondition.unlock()
        }
    }

    var isConnected: Bool {
        channel?.isOpen() == true
    }

    var isBLEReady: Bool { bleReadiness.isReady }

    func prepareSystemPairing() throws {
        // Register first, then release LE before IOBluetoothDevicePair. Holding LE
        // made the Mac helper stall without a baseband-connected callback.
        try bleReadiness.waitUntilReady(timeout: 20)
        try bleReadiness.releaseForSystemPairing()
    }

    var currentConnectionGeneration: Int {
        recoveryCondition.lock(); defer { recoveryCondition.unlock() }; return connectionGeneration
    }

    func setConnectionStateHandlers(ready: @escaping (Int) -> Void, lost: @escaping (Bool) -> Void) {
        recoveryCondition.lock(); readyHandler = ready; lostHandler = lost; recoveryCondition.unlock()
    }

    func suspendRecovery() {
        recoveryCondition.lock()
        connectionDesired = false; recoverySuspended = true; demandEpoch += 1
        retryWork?.cancel(); retryWork = nil; nextRetryAt = nil
        if !isConnected { linkPhase = "suspended" }
        recoveryCondition.broadcast(); recoveryCondition.unlock()
        openCondition.lock(); openCondition.broadcast(); openCondition.unlock()
    }

    /// Drops only the data socket; existing bonding and BLE authentication are preserved.
    func interruptDataChannel() {
        if let connection = channel { loseChannel(connection, reason: "Data channel interrupted for recovery") }
        else { _ = requestRecovery(reason: "manualDataChannelRecovery") }
    }

    private var linkDiagnostics: [String: Any] {
        recoveryCondition.lock(); defer { recoveryCondition.unlock() }
        return ["phase": linkPhase, "generation": connectionGeneration, "desired": connectionDesired,
            "recovering": recoveryRunning, "recoveryCycle": recoveryCycle, "attempt": recoveryAttempt,
            "maximumAttempts": 3, "burstBudgetSeconds": 45, "reason": recoveryReason,
            "everConnected": everConnected, "nextRetryAt": nextRetryAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "channel": Int(selectedChannel), "channelSource": selectedChannelSource,
            "serviceUUID": "99999999-9999-9999-9999-999999999999",
            "sdpError": sdpError as Any? ?? NSNull(),
            "sdp": ["queryKind": SDPQueryCompletion.queryKind,
                "pendingCount": sdpQueries.count, "maximumPendingQueries": maximumPendingSDPQueries,
                "skippedCount": skippedSDPQueries, "lastSkippedAt": lastSkippedSDPQueryAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                "pending": sdpQueries.keys.sorted().compactMap { sdpQueries[$0]?.diagnostics },
                "recent": sdpQueryHistory.map(\.diagnostics)],
            "error": linkError as Any? ?? NSNull()]
    }

    var diagnostics: [String: Any] {
        acknowledgementLock.lock()
        let receipts: [String: Any] = ["sent": acknowledgementsSent, "received": acknowledgementsReceived,
                                      "error": acknowledgementError as Any? ?? NSNull()]
        acknowledgementLock.unlock()
        return ["ble": bleReadiness.diagnostics, "rfcommConnected": isConnected, "transportAcknowledgements": receipts,
                "appVisibility": appVisibilityStatus, "dataLink": linkDiagnostics]
    }

    var appVisibilityStatus: [String: Any] {
        visibilityStateLock.lock(); var result = visibilitySnapshot; visibilityStateLock.unlock()
        let generation = currentConnectionGeneration
        result["connectionGeneration"] = generation
        if !isConnected || result["lastSentConnectionGeneration"] as? Int != generation { result["pending"] = true }
        return result
    }

    private func refreshVisibilitySnapshot() {
        let result: [String: Any] = ["requestedForeground": appForeground, "connectionGeneration": connectionGeneration,
                "lastSentForeground": visibilitySentForeground as Any? ?? NSNull(),
                "lastSentConnectionGeneration": visibilitySentGeneration as Any? ?? NSNull(),
                "lastSentAt": visibilitySentAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                "lastAttemptAt": visibilityAttemptAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                "lastSendSucceeded": visibilityAttemptAt.map { _ in visibilityError == nil } as Any? ?? NSNull(),
                "pending": !isConnected || visibilitySentGeneration != connectionGeneration || visibilitySentForeground != appForeground,
                "applicationAccepted": NSNull(), "error": visibilityError as Any? ?? NSNull()]
        visibilityStateLock.lock(); visibilitySnapshot = result; visibilityStateLock.unlock()
    }

    func setAppForeground(_ foreground: Bool) throws {
        writeLock.lock(); defer { refreshVisibilitySnapshot(); writeLock.unlock() }
        appForeground = foreground
        // The GUI publishes lifecycle before connecting; keep it pending without opening a channel.
        if isConnected { try sendAppVisibilityIfNeeded() }
    }

    private func sendAppVisibilityIfNeeded() throws {
        guard visibilitySentGeneration != connectionGeneration || visibilitySentForeground != appForeground else { return }
        defer { refreshVisibilitySnapshot() }
        visibilityAttemptAt = Date()
        visibilitySequence &+= 1
        do {
            try writeConnected(ProtocolCodec.appVisibilityFrame(sequence: visibilitySequence, foreground: appForeground))
            visibilitySentForeground = appForeground; visibilitySentGeneration = connectionGeneration
            visibilitySentAt = Date(); visibilityError = nil
        } catch {
            visibilityError = (error as? BridgeError)?.message ?? error.localizedDescription
            throw error
        }
    }

    var displayEvents: [[String: Any]] {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        return recentDisplayMessages
    }

    var displayAudioPacketCount: Int {
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        return droppedDisplayAudioPackets
    }

    func ensureConnected() throws { try awaitConnection(resumeDemand: true) }

    func send(_ bytes: Data) throws {
        try awaitConnection(resumeDemand: false)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isConnected, isBLEReady else { throw BridgeError(status: 503, message: "Data link changed before write; request was not replayed") }
        try writeConnected(bytes)
    }

    /// Called only under writeLock, including the first visibility frame after connect.
    private func writeConnected(_ bytes: Data) throws {
        guard let channel = channel, !bytes.isEmpty else {
            throw BridgeError(status: 503, message: "RFCOMM channel is unavailable")
        }
        guard bytes.count <= Int(UInt16.max) else {
            throw BridgeError(status: 413, message: "Frame is too large")
        }
        let mtu = Int(channel.getMTU())
        guard mtu > 0 else { throw BridgeError(status: 503, message: "RFCOMM channel has no usable MTU") }
        var offset = 0
        while offset < bytes.count {
            let count = min(mtu, bytes.count - offset)
            let result = bytes.withUnsafeBytes { rawBuffer -> IOReturn in
                guard let baseAddress = rawBuffer.baseAddress else { return kIOReturnBadArgument }
                return channel.writeSync(UnsafeMutableRawPointer(mutating: baseAddress.advanced(by: offset)), length: UInt16(count))
            }
            guard result == kIOReturnSuccess else {
                loseChannel(channel, reason: "RFCOMM write failed at byte \(offset): \(result)")
                throw BridgeError(status: 503, message: "RFCOMM write failed at byte \(offset): \(result)")
            }
            offset += count
        }
    }

    func waitForMessage(timeout: TimeInterval, matching predicate: (RemoteMessage) -> Bool) -> RemoteMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        let epoch = receiveEpoch
        while true {
            guard epoch == receiveEpoch else { return nil }
            if let index = remoteMessages.firstIndex(where: predicate) {
                return remoteMessages.remove(at: index)
            }
            if !receiveCondition.wait(until: deadline) { return nil }
        }
    }

    private func awaitConnection(resumeDemand: Bool) throws {
        guard !Thread.isMainThread else { throw BridgeError(status: 503, message: "Connection preparation must run off the main delegate thread") }
        let requested = requestRecovery(reason: resumeDemand ? "explicitConnect" : "send", activate: true, resume: resumeDemand, expedite: resumeDemand)
        if isConnected, isBLEReady { return }
        guard let (cycle, epoch) = requested else { throw BridgeError(status: 503, message: "Connection recovery is suspended") }
        recoveryCondition.lock(); defer { recoveryCondition.unlock() }
        while recoveryRunning, recoveryCycle == cycle, demandEpoch == epoch {
            recoveryCondition.wait()
        }
        guard demandEpoch == epoch, recoveryCycle == cycle, isConnected, isBLEReady else {
            throw BridgeError(status: 503, message: linkError ?? "Connection preparation was cancelled or superseded")
        }
    }

    @discardableResult
    private func requestRecovery(reason: String, activate: Bool = false, resume: Bool = false, expedite: Bool = true) -> (Int, Int)? {
        recoveryCondition.lock(); defer { recoveryCondition.unlock() }
        if resume, recoverySuspended { recoverySuspended = false }
        if activate, !recoverySuspended { connectionDesired = true }
        guard connectionDesired, !recoverySuspended else { return nil }
        if isConnected, isBLEReady { return nil }
        if recoveryRunning, activeRecoveryEpoch == demandEpoch { return (recoveryCycle, demandEpoch) }
        // Polling/business writes must not turn the offline cooldown into continuous reconnect bursts.
        if !expedite, nextRetryAt != nil { return (recoveryCycle, demandEpoch) }
        retryWork?.cancel(); retryWork = nil; nextRetryAt = nil
        recoveryCycle += 1; recoveryRunning = true; recoveryAttempt = 0
        recoveryReason = reason; linkPhase = "recovering"; linkError = nil
        let cycle = recoveryCycle, epoch = demandEpoch
        activeRecoveryEpoch = epoch
        recoveryQueue.async { [weak self] in self?.recover(cycle: cycle, epoch: epoch) }
        return (cycle, epoch)
    }

    private func recoveryIsCurrent(_ cycle: Int, _ epoch: Int) -> Bool {
        recoveryCondition.lock(); defer { recoveryCondition.unlock() }
        return connectionDesired && !recoverySuspended && recoveryCycle == cycle && demandEpoch == epoch
    }

    private func recover(cycle: Int, epoch: Int) {
        let deadline = Date().addingTimeInterval(45)
        var failure: String?
        writeLock.lock()
        for attempt in 1...3 {
            guard recoveryIsCurrent(cycle, epoch), Date() < deadline else { break }
            if attempt > 1 {
                recoveryCondition.lock()
                linkPhase = "backoff"
                _ = recoveryCondition.wait(until: min(deadline, Date().addingTimeInterval(attempt == 2 ? 1 : 3)))
                recoveryCondition.unlock()
                guard recoveryIsCurrent(cycle, epoch), Date() < deadline else { break }
            }
            recoveryCondition.lock(); recoveryAttempt = attempt; linkPhase = "waitingForBLE"; recoveryCondition.unlock()
            do {
                try connect(cycle: cycle, epoch: epoch, deadline: deadline)
                failure = nil; break
            } catch {
                failure = (error as? BridgeError)?.message ?? error.localizedDescription
                recoveryCondition.lock(); linkError = failure; recoveryCondition.unlock()
            }
        }
        writeLock.unlock()
        recoveryCondition.lock()
        guard recoveryCycle == cycle else { recoveryCondition.unlock(); return }
        recoveryRunning = false
        let current = demandEpoch == epoch && connectionDesired && !recoverySuspended
        let ready = current && isConnected && isBLEReady
        let generation = connectionGeneration, handler = readyHandler
        if ready { everConnected = true; linkPhase = "ready"; linkError = nil; lossNotifiedBLE = nil }
        else if current {
            linkError = failure ?? "Connection recovery budget exhausted"
            linkPhase = everConnected ? "waitingToRetry" : "failed"
            if everConnected {
                nextRetryAt = Date().addingTimeInterval(60)
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.recoveryCondition.lock()
                    let valid = self.demandEpoch == epoch && self.recoveryCycle == cycle && self.connectionDesired && !self.recoverySuspended
                    self.recoveryCondition.unlock()
                    if valid { _ = self.requestRecovery(reason: "retryAfterOffline") }
                }
                retryWork = work
                recoveryQueue.asyncAfter(deadline: .now() + 60, execute: work)
            }
        } else { linkPhase = isConnected ? "ready" : "suspended" }
        if ready {
            connectionEvents.async { [weak self] in
                guard let self, self.currentConnectionGeneration == generation, self.isConnected, self.isBLEReady else { return }
                handler?(generation)
            }
        }
        recoveryCondition.broadcast(); recoveryCondition.unlock()
    }

    private func resolveDataChannel(_ device: IOBluetoothDevice, generation: Int, deadline: Date) -> BluetoothRFCOMMChannelID {
        let uuid = IOBluetoothSDPUUID(data: Data(repeating: 0x99, count: 16))
        recoveryCondition.lock()
        guard sdpQueries.count < maximumPendingSDPQueries else {
            skippedSDPQueries += 1; lastSkippedSDPQueryAt = Date()
            selectedChannel = 26; selectedChannelSource = "fallback26"
            sdpError = "SDP query skipped: \(sdpQueries.count) earlier queries still await callbacks"
            recoveryCondition.unlock()
            trace("SDP query skipped at pending limit (generation \(generation)); using channel 26")
            return 26
        }
        let query = SDPQueryCompletion(generation: generation)
        sdpQueries[generation] = query; sdpQueryHistory.append(query)
        if sdpQueryHistory.count > 8 { sdpQueryHistory.removeFirst(sdpQueryHistory.count - 8) }
        linkPhase = "queryingSDP"; recoveryCondition.unlock()
        query.didComplete = { [weak self] query in
            guard let self else { return }
            self.recoveryCondition.lock(); self.sdpQueries[generation] = nil; self.recoveryCondition.unlock()
            self.trace("SDP query callback: \(query.diagnostics)")
        }
        let started = DispatchQueue.main.sync {
            query.markStarted()
            return device.performSDPQuery(query)
        }
        query.recordStartResult(started)
        trace("SDP query started (generation \(generation), result \(started))")
        var reason: String?
        var chosen: BluetoothRFCOMMChannelID = 26
        if started != kIOReturnSuccess { reason = "SDP query could not start: \(started)" }
        else if query.completed.wait(timeout: .now() + max(0, min(3, deadline.timeIntervalSinceNow))) == .timedOut {
            query.markTimedOut(); reason = "SDP query timed out"
            trace("SDP query exceeded 3-second budget (generation \(generation)); delegate retained for late callback")
        }
        else if query.status != kIOReturnSuccess { reason = "SDP query failed: \(query.status ?? kIOReturnError)" }
        else {
            let result: IOReturn = DispatchQueue.main.sync {
                guard let record = device.getServiceRecord(for: uuid) else { return kIOReturnNotFound }
                return record.getRFCOMMChannelID(&chosen)
            }
            if result != kIOReturnSuccess || !(1...30).contains(chosen) { chosen = 26; reason = "SPP UUID has no valid RFCOMM channel: \(result)" }
        }
        recoveryCondition.lock()
        selectedChannel = chosen; selectedChannelSource = reason == nil ? "sdpUUID" : "fallback26"; sdpError = reason
        if started != kIOReturnSuccess { sdpQueries[generation] = nil }
        recoveryCondition.unlock()
        return chosen
    }

    private func connect(cycle: Int, epoch: Int, deadline: Date) throws {
        try bleReadiness.waitUntilReady(timeout: max(0, min(15, deadline.timeIntervalSinceNow)))
        guard recoveryIsCurrent(cycle, epoch) else { throw BridgeError(status: 503, message: "Connection demand was cancelled") }
        let device: IOBluetoothDevice = try DispatchQueue.main.sync {
            guard let device = self.device ?? IOBluetoothDevice(addressString: address) else {
                throw BridgeError(status: 503, message: "RayNeo device address was not found")
            }
            guard device.isPaired() else { throw BridgeError(status: 409, message: "The existing Bluetooth bond is missing; recovery does not re-pair devices") }
            // Keep first device access on the run loop that starts its asynchronous SDP and RFCOMM work.
            self.device = device
            return device
        }
        // requestAuthentication can synchronously initiate pairing according to IOBluetoothDevice.h.
        // Open the secure RFCOMM service using the existing bond instead of invoking a new pairing flow.
        recoveryCondition.lock(); connectionGeneration += 1; let generation = connectionGeneration; recoveryCondition.unlock()
        invalidateReceivedState()
        let selected = resolveDataChannel(device, generation: generation, deadline: deadline)
        guard recoveryIsCurrent(cycle, epoch), Date() < deadline else { throw BridgeError(status: 503, message: "Connection demand was cancelled or timed out") }
        guard closingChannels.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            throw BridgeError(status: 504, message: "Previous data channel is still closing")
        }
        guard recoveryIsCurrent(cycle, epoch), Date() < deadline else {
            throw BridgeError(status: 503, message: "Connection demand was cancelled or timed out")
        }
        let delegate = DataChannelDelegate(owner: self, generation: generation)
        openCondition.lock()
        channelOpenResult = nil
        expectedOpenGeneration = generation
        openCondition.unlock()

        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = DispatchQueue.main.sync { device.openRFCOMMChannelAsync(&openedChannel, withChannelID: selected, delegate: delegate) }
        guard result == kIOReturnSuccess, let openedChannel else {
            openCondition.lock(); expectedOpenGeneration = nil; openCondition.unlock()
            if let openedChannel { _ = openedChannel.setDelegate(nil); _ = openedChannel.close() }
            throw BridgeError(status: 503, message: "Could not start RayNeo RFCOMM channel \(selected): \(result)")
        }
        channelLock.lock(); storedChannel = openedChannel; channelGeneration = generation; channelDelegate = delegate; channelLock.unlock()
        recoveryCondition.lock(); linkPhase = "openingSPP"; recoveryCondition.unlock()
        trace("Opening data channel \(selected) after BLE authentication (generation \(generation))")

        let openDeadline = min(deadline, Date().addingTimeInterval(8))
        openCondition.lock()
        while channelOpenResult == nil, recoveryIsCurrent(cycle, epoch) {
            if !openCondition.wait(until: openDeadline) {
                expectedOpenGeneration = nil
                openCondition.unlock()
                loseChannel(openedChannel, reason: "SPP open timed out")
                throw BridgeError(status: 504, message: "RayNeo iO RFCOMM channel \(selected) did not finish opening")
            }
        }
        let openResult = channelOpenResult ?? kIOReturnError
        expectedOpenGeneration = nil
        openCondition.unlock()
        guard recoveryIsCurrent(cycle, epoch), openResult == kIOReturnSuccess, openedChannel.isOpen(), isBLEReady else {
            loseChannel(openedChannel, reason: "SPP open failed or was cancelled")
            throw BridgeError(status: 503, message: "RayNeo iO RFCOMM channel \(selected) failed to open: \(openResult)")
        }
        do { try sendAppVisibilityIfNeeded() }
        catch { trace("App visibility notification failed: \(visibilityError ?? error.localizedDescription)") }
        guard isConnected else { throw BridgeError(status: 503, message: "SPP link closed during initial visibility send") }
    }

    private func trace(_ message: String) {
        FileHandle.standardError.write(Data("[RayNeo iO RFCOMM] \(message)\n".utf8))
    }

    fileprivate func channelOpened(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn, generation: Int) {
        trace("Data channel open completed: \(error), MTU=\(rfcommChannel?.getMTU() ?? 0)")
        openCondition.lock()
        guard expectedOpenGeneration == generation else { openCondition.unlock(); return }
        channelOpenResult = error
        openCondition.broadcast()
        openCondition.unlock()
    }

    fileprivate func channelReceived(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int, generation: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        receiveCondition.lock()
        channelLock.lock(); let current = storedChannel === rfcommChannel && channelGeneration == generation; channelLock.unlock()
        guard current else { receiveCondition.unlock(); return }
        receiveBuffer.append(Data(bytes: dataPointer, count: dataLength))
        extractMessages()
        receiveCondition.broadcast()
        receiveCondition.unlock()
    }

    fileprivate func channelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!, generation: Int) {
        openCondition.lock()
        if expectedOpenGeneration == generation, channelOpenResult == nil {
            channelOpenResult = kIOReturnNotOpen; openCondition.broadcast()
        }
        openCondition.unlock()
        loseChannel(rfcommChannel, reason: "SPP channel disconnected", generation: generation)
    }

    private func invalidateReceivedState() {
        receiveCondition.lock()
        receiveEpoch += 1; receiveBuffer = Data(); remoteMessages = []; recentDisplayMessages = []
        lifeLogEvents = []; lifeLogLastAudioMetadata = [:]
        receiveCondition.broadcast(); receiveCondition.unlock()
        bleReadiness.discardPartialFrames()
    }

    private func loseChannel(_ connection: IOBluetoothRFCOMMChannel, reason: String, generation: Int? = nil) {
        channelLock.lock()
        let current = storedChannel === connection && (generation == nil || generation == channelGeneration)
        let previousDelegate = channelDelegate
        let lostGeneration = channelGeneration
        if current { storedChannel = nil; channelDelegate = nil; channelGeneration = nil }
        channelLock.unlock()
        guard current else { return }
        closingChannels.enter()
        openCondition.lock()
        if expectedOpenGeneration == lostGeneration, channelOpenResult == nil {
            channelOpenResult = kIOReturnNotOpen; openCondition.broadcast()
        }
        openCondition.unlock()
        let bleDisconnected = !isBLEReady
        invalidateReceivedState()
        notifyLinkLost(bleDisconnected: bleDisconnected, reason: reason)
        receiveCondition.lock(); let teleprompterLost = teleprompterDisconnectHandler; receiveCondition.unlock()
        connectionEvents.async {
            teleprompterLost?()
        }
        DispatchQueue.global(qos: .utility).async { [previousDelegate, closingChannels] in
            defer { closingChannels.leave() }
            _ = previousDelegate
            _ = connection.setDelegate(nil); _ = connection.close()
        }
        _ = requestRecovery(reason: reason)
    }

    private func notifyLinkLost(bleDisconnected: Bool, reason: String) {
        recoveryCondition.lock()
        let notify = everConnected && (lossNotifiedBLE == nil || (bleDisconnected && lossNotifiedBLE == false))
        if notify {
            lossNotifiedBLE = bleDisconnected
            let handler = lostHandler
            connectionEvents.async { handler?(bleDisconnected) }
        }
        linkPhase = "disconnected"; linkError = reason
        recoveryCondition.broadcast(); recoveryCondition.unlock()
        if bleDisconnected { _ = requestRecovery(reason: reason) }
    }

    private func acknowledge(protocolID: UInt8, sequence: UInt16) {
        channelLock.lock(); let connection = storedChannel, generation = channelGeneration; channelLock.unlock()
        guard let connection, let generation else { return }
        acknowledgementQueue.async { [weak self] in
            guard let self else { return }
            do {
                let bytes = try ProtocolCodec.acknowledgement(protocolID: protocolID, sequence: sequence)
                self.writeLock.lock()
                // A delayed receipt belongs only to the connection that received the frame.
                self.channelLock.lock()
                let current = self.storedChannel === connection && self.channelGeneration == generation
                self.channelLock.unlock()
                guard current, connection.isOpen() else { self.writeLock.unlock(); return }
                let result = bytes.withUnsafeBytes { buffer in
                    connection.writeSync(UnsafeMutableRawPointer(mutating: buffer.baseAddress!), length: UInt16(bytes.count))
                }
                self.writeLock.unlock()
                guard result == kIOReturnSuccess else { throw BridgeError(status: 503, message: "Transport acknowledgement write failed: \(result)") }
                self.acknowledgementLock.lock()
                self.acknowledgementsSent += 1
                self.acknowledgementLock.unlock()
            } catch {
                guard self.currentConnectionGeneration == generation else { return }
                self.acknowledgementLock.lock()
                self.acknowledgementError = error.localizedDescription
                self.acknowledgementLock.unlock()
                self.trace("Transport acknowledgement failed: \(error.localizedDescription)")
            }
        }
    }

    private func dispatch(_ message: RemoteMessage) {
        if message.protocolID == 0x10, message.protobuf.first == 0x1e {
            _ = requestRecovery(reason: "peer_spp_connect")
            return
        }
        if message.protocolID == 0x16 { todoStatusHandler?(message) }
        if message.protocolID == 0x11 || message.protocolID == 0x12 { fileTransferHandler?(message) }
        if message.protocolID == 0x19 { networkRelayHandler?(message); return }
        if message.protocolID == 0x06 { capabilityHandler?(message) }
        if message.protocolID == 9 || message.protocolID == 11 { maintenanceHandler?(message) }
        if message.protocolID == 9 { otaHandler?(message) }
        if message.protocolID == 0x14 { teleprompterHandler?(message) }
        if message.protocolID == 0x0e {
            nativeRecordingHandler?(message)
            if message.messageType == 3 { return }
        }
        if message.protocolID == 0x0d {
            nativeAssistantHandler?(message)
            if message.messageType == 3 { return }
        }
        if message.protocolID == 0x0d, let type = message.messageType, (161...168).contains(type) {
            if type == 163 || type == 164 {
                let prefix = type == 163 ? "realtime" : "cached"
                lifeLogAudioCounts[prefix + "Messages", default: 0] += 1
                lifeLogAudioCounts[prefix + "Bytes", default: 0] += message.audioData?.count ?? 0
                lifeLogLastAudioMetadata = message.json ?? [:]
                lifeLogLastAudioMetadata["receivedAt"] = message.receivedAt.timeIntervalSince1970
                if type == 163, let count = message.json?["frameCount"] as? Int {
                    let frames = max(0, min(31, count, (message.audioData?.count ?? 0) / 240))
                    lifeLogAudioCounts["realtimeFrames", default: 0] += frames
                    for key in ["vpuMask", "vadMask"] {
                        if let mask = (message.json?[key] as? NSNumber)?.uint64Value {
                            for index in 0..<frames where mask & (1 << index) != 0 {
                                lifeLogAudioCounts[key + "Frames", default: 0] += 1
                            }
                        }
                    }
                }
                if type == 163 { lifeLogAudioHandler?(message) }
                // Diagnostic observers may inspect PCM; packet payloads are not retained.
                return
            }
            lifeLogEvents.append(["type": type, "receivedAt": message.receivedAt.timeIntervalSince1970,
                                  "body": message.json as Any? ?? NSNull()])
            if lifeLogEvents.count > 128 { lifeLogEvents.removeFirst() }
            if type == 161 || type == 165 { lifeLogWakeHandler?(message) }
        }
        if [0x13, 0x17].contains(message.protocolID), message.messageType == 4 {
            if let audioHandler { audioHandler(message) }
            else { droppedDisplayAudioPackets += 1 }
            return
        }
        if [0x13, 0x17].contains(message.protocolID) || (message.protocolID == 0x0f && message.messageType == 24) {
            displayControlHandler?(message)
        }
        remoteMessages.append(message)
        if remoteMessages.count > 256 { remoteMessages.removeFirst(remoteMessages.count - 256) }
        if [0x13, 0x14, 0x16, 0x17].contains(message.protocolID) ||
            (message.protocolID == 0x0f && message.messageType == 19 &&
             ["dashboard_config", "current_weather_update", "weather_update"].contains(message.json?["cmd"] as? String ?? "")) {
            recentDisplayMessages.append([
                "protocol": Int(message.protocolID), "type": message.messageType as Any? ?? NSNull(),
                "sequence": Int(message.sequence), "receivedAt": message.receivedAt.timeIntervalSince1970,
                "body": message.json as Any? ?? NSNull()
            ])
            if recentDisplayMessages.count > 64 { recentDisplayMessages.removeFirst() }
            trace("Display message protocol=\(message.protocolID) type=\(message.messageType ?? 0)")
        }
    }

    private func extractMessages() {
        let magic = Data([0xaa, 0x55])
        let acknowledgementMagic = Data([0x55, 0xaa])
        let maxFrameBytes = 65_541
        while receiveBuffer.count >= 4 {
            let candidates = [receiveBuffer.range(of: magic), receiveBuffer.range(of: acknowledgementMagic)].compactMap { $0 }
            guard let start = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else {
                receiveBuffer = Data(receiveBuffer.suffix(1))
                return
            }
            if start.lowerBound > receiveBuffer.startIndex {
                receiveBuffer = receiveBuffer.subdata(in: start.lowerBound..<receiveBuffer.endIndex)
            }
            guard receiveBuffer.count >= 4 else { return }
            let length = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
            let headerMin = receiveBuffer.count >= 7
                ? 4 + (receiveBuffer[6] & 2 == 0 ? 0 : 1) + Int(receiveBuffer[6] >> 5)
                : 4
            if length < 4 || (receiveBuffer.count >= 7 && length < headerMin) || (receiveBuffer[0] == 0x55 && length != 4) {
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                continue
            }
            let frameLength = 4 + length + 2
            if receiveBuffer.count < frameLength {
                if receiveBuffer.count > maxFrameBytes || ProtocolCodec.containsCompleteValidFrame(in: receiveBuffer) {
                    receiveBuffer = Data(receiveBuffer.dropFirst(1))
                    continue
                }
                return
            }
            let frame = receiveBuffer.subdata(in: 0..<frameLength)
            if frame[0] == 0x55 {
                if ProtocolCodec.crc16XModem(frame.subdata(in: 4..<8)) == ((UInt16(frame[8]) << 8) | UInt16(frame[9])) {
                    receiveBuffer = receiveBuffer.subdata(in: frameLength..<receiveBuffer.count)
                    acknowledgementLock.lock(); acknowledgementsReceived += 1; acknowledgementLock.unlock()
                } else {
                    receiveBuffer = Data(receiveBuffer.dropFirst(1))
                }
                continue
            }
            if let message = ProtocolCodec.decodeRemoteFrame(frame) {
                receiveBuffer = receiveBuffer.subdata(in: frameLength..<receiveBuffer.count)
                if frame[6] & 1 != 0 { acknowledge(protocolID: message.protocolID, sequence: message.sequence) }
                dispatch(message)
            } else {
                corruptFrameHandler?(frame)
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
            }
        }
        if receiveBuffer.count > maxFrameBytes * 2 {
            receiveBuffer = Data(receiveBuffer.suffix(maxFrameBytes))
        }
    }
}

