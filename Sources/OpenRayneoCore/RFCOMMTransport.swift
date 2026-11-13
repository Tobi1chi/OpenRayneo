// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOBluetooth

final class RFCOMMTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private let bleReadiness: BLEReadinessSession
    private let writeLock = NSLock()
    private let channelLock = NSLock()
    private let receiveCondition = NSCondition()
    private let openCondition = NSCondition()
    private let ackQueue = DispatchQueue(label: "openrayneo.rfcomm.ack")
    private let streamDecoder = ProtocolStreamDecoder()
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
    private var remoteMessages: [RemoteMessage] = []
    private var recentDisplayMessages: [[String: Any]] = []
    private var droppedDisplayAudioPackets = 0
    private var audioHandler: ((RemoteMessage) -> Void)?
    private var lifeLogAudioHandler: ((RemoteMessage) -> Void)?
    private var lifeLogWakeHandler: ((RemoteMessage) -> Void)?
    private var lifeLogEvents: [[String: Any]] = []
    private var lifeLogAudioCounts: [String: Int] = [:]
    private var lifeLogLastAudioMetadata: [String: Any] = [:]

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

    init(address: String) {
        self.address = address.replacingOccurrences(of: "-", with: ":")
        bleReadiness = BLEReadinessSession(address: address)
        super.init()
    }

    var isConnected: Bool {
        channel?.isOpen() == true
    }

    var isBLEReady: Bool { bleReadiness.isReady }

    var diagnostics: [String: Any] {
        ["ble": bleReadiness.diagnostics, "rfcommConnected": isConnected]
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

    func ensureConnected() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !isConnected { try connect() }
    }

    func send(_ bytes: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !isConnected {
            try connect()
        }
        try writeToCurrentChannel(bytes)
    }

    private func sendConnectedOnly(_ bytes: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isConnected else { return }
        try writeToCurrentChannel(bytes)
    }

    private func writeToCurrentChannel(_ bytes: Data) throws {
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
                self.channel = nil
                _ = channel.close()
                throw BridgeError(status: 503, message: "RFCOMM write failed at byte \(offset): \(result)")
            }
            offset += count
        }
    }

    func waitForMessage(timeout: TimeInterval, matching predicate: (RemoteMessage) -> Bool) -> RemoteMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        receiveCondition.lock()
        defer { receiveCondition.unlock() }
        while true {
            if let index = remoteMessages.firstIndex(where: predicate) {
                return remoteMessages.remove(at: index)
            }
            if !receiveCondition.wait(until: deadline) { return nil }
        }
    }

    private func connect() throws {
        try bleReadiness.waitUntilReady(timeout: 15)
        guard let device = self.device ?? IOBluetoothDevice(addressString: address) else {
            throw BridgeError(status: 503, message: "RayNeo device address was not found")
        }
        let authentication = device.requestAuthentication()
        guard authentication == kIOReturnSuccess else {
            throw BridgeError(status: 503, message: "RayNeo iO Bluetooth authentication failed: \(authentication)")
        }
        openCondition.lock()
        channelOpenResult = nil
        openCondition.unlock()
        receiveCondition.lock()
        streamDecoder.reset()
        receiveCondition.unlock()

        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&openedChannel, withChannelID: 26, delegate: self)
        guard result == kIOReturnSuccess, let openedChannel else {
            throw BridgeError(status: 503, message: "Could not start RayNeo RFCOMM channel 26: \(result)")
        }
        self.device = device
        self.channel = openedChannel
        trace("Opening data channel 26 after BLE authentication")

        let deadline = Date().addingTimeInterval(12)
        openCondition.lock()
        while channelOpenResult == nil {
            if !openCondition.wait(until: deadline) {
                openCondition.unlock()
                self.channel = nil
                _ = openedChannel.setDelegate(nil)
                _ = openedChannel.close()
                throw BridgeError(status: 504, message: "RayNeo iO RFCOMM channel 26 did not finish opening")
            }
        }
        let openResult = channelOpenResult ?? kIOReturnError
        openCondition.unlock()
        guard openResult == kIOReturnSuccess, openedChannel.isOpen() else {
            self.channel = nil
            _ = openedChannel.setDelegate(nil)
            _ = openedChannel.close()
            throw BridgeError(status: 503, message: "RayNeo iO RFCOMM channel 26 failed to open: \(openResult)")
        }
    }

    private func trace(_ message: String) {
        FileHandle.standardError.write(Data("[RayNeo iO RFCOMM] \(message)\n".utf8))
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        trace("Data channel open completed: \(error), MTU=\(rfcommChannel?.getMTU() ?? 0)")
        openCondition.lock()
        channelOpenResult = error
        openCondition.broadcast()
        openCondition.unlock()
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        var pendingAcks: [Data] = []
        receiveCondition.lock()
        let frames = streamDecoder.append(Data(bytes: dataPointer, count: dataLength))
        for frame in frames {
            if frame.requiresAcknowledgement {
                pendingAcks.append(ProtocolCodec.acknowledgementFrame(protocolID: frame.protocolID, sequence: frame.sequence))
            }
            guard let message = ProtocolCodec.decodeRemoteMessage(from: frame) else { continue }
            processDecodedMessage(message)
        }
        receiveCondition.broadcast()
        receiveCondition.unlock()
        if !pendingAcks.isEmpty {
            ackQueue.async { [weak self] in
                guard let self else { return }
                for ack in pendingAcks {
                    try? self.sendConnectedOnly(ack)
                }
            }
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channelLock.lock()
        if storedChannel === rfcommChannel { storedChannel = nil }
        channelLock.unlock()
        receiveCondition.lock()
        streamDecoder.reset()
        receiveCondition.unlock()
    }

    private func processDecodedMessage(_ message: RemoteMessage) {
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
        remoteMessages.append(message)
        if remoteMessages.count > 256 { remoteMessages.removeFirst(remoteMessages.count - 256) }
        if [0x13, 0x16, 0x17].contains(message.protocolID) ||
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
}
