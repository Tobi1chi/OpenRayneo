// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import CoreBluetooth
import Darwin
import Foundation
import IOBluetooth

struct BridgeError: Error {
    let status: Int
    let message: String
}

struct RemoteMessage {
    let protocolID: UInt8
    let sequence: UInt16
    let receivedAt: Date
    let protobuf: Data
    let action: UInt64?
    let messageType: UInt64?
    let json: [String: Any]?
    let audioData: Data?
}

enum ProtocolCodec {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        while value >= 0x80 {
            result.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data {
        var result = varint((number << 3) | 0)
        result.append(varint(value))
        return result
    }

    static func field(_ number: UInt64, bytes value: Data) -> Data {
        var result = varint((number << 3) | 2)
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    static func field(_ number: UInt64, string value: String) -> Data {
        field(number, bytes: Data(value.utf8))
    }

    static func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func teleprompterFrame(sequence: UInt16, type: UInt64, action: UInt64, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: action)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: try jsonData(body)))
        protobuf.append(field(4, bytes: Data()))
        return try frame(protocolID: 0x14, sequence: sequence, protobuf: protobuf)
    }

    static func notificationFrame(sequence: UInt16, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: 2))
        protobuf.append(field(3, bytes: try jsonData(body)))
        protobuf.append(field(4, bytes: Data()))
        return try frame(protocolID: 0x15, sequence: sequence, protobuf: protobuf)
    }

    static func displayFrame(protocolID: UInt8, sequence: UInt16, type: UInt64, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: try jsonData(body)))
        return try frame(protocolID: protocolID, sequence: sequence, protobuf: protobuf)
    }

    static func fileTransferFrame(protobuf: Data) throws -> Data {
        try frame(protocolID: 0x11, sequence: 0, protobuf: protobuf)
    }

    static func pairingFrame(sequence: UInt16, command: UInt8, fields: [(UInt8, Data)]) throws -> Data {
        var tlvs = Data()
        for (tag, value) in fields {
            tlvs.append(tag)
            tlvs.appendBE(UInt16(value.count))
            tlvs.append(value)
        }
        var payload = Data([command])
        payload.appendBE(UInt16(tlvs.count))
        payload.append(tlvs)
        return try frame(protocolID: 0x10, sequence: sequence, protobuf: payload)
    }

    static func pairingCommand(_ payload: Data) -> (UInt8, Data, [UInt8: Data])? {
        guard payload.count >= 3 else { return nil }
        let command = payload[0]
        let length = Int(payload[1]) << 8 | Int(payload[2])
        guard length == payload.count - 3 else { return nil }
        let body = payload.subdata(in: 3..<payload.count)
        // Device info and authentication use TLVs; status commands carry raw bytes.
        guard [17, 24, 25].contains(command) else { return (command, body, [:]) }
        var tlvs: [UInt8: Data] = [:]
        var offset = 0
        while offset < body.count {
            guard offset + 3 <= body.count else { return nil }
            let tag = body[offset]
            let size = Int(body[offset + 1]) << 8 | Int(body[offset + 2])
            offset += 3
            guard offset + size <= body.count else { return nil }
            tlvs[tag] = body.subdata(in: offset..<(offset + size))
            offset += size
        }
        return (command, body, tlvs)
    }

    private static func frame(protocolID: UInt8, sequence: UInt16, protobuf: Data) throws -> Data {
        guard protobuf.count <= Int(UInt16.max) - 4 else {
            throw BridgeError(status: 413, message: "Protocol payload exceeds 65531 bytes")
        }
        var body = Data()
        body.appendBE(sequence)
        body.append(0)
        body.append(protocolID)
        body.append(protobuf)

        var result = Data([0xaa, 0x55])
        result.appendBE(UInt16(body.count))
        result.append(body)
        result.appendBE(crc16XModem(body))
        return result
    }

    static func crc16XModem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) == 0 ? crc << 1 : (crc << 1) ^ 0x1021
            }
        }
        return crc
    }

    static func fnv1a32(_ data: Data) -> String {
        var value: UInt32 = 0x811c9dc5
        for byte in data {
            value = (value ^ UInt32(byte)) &* 0x01000193
        }
        return String(format: "%08x", value)
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeVarint(_ data: Data, at start: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while start < data.count && shift < 64 {
            let byte = data[start]
            start += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func fields(_ data: Data) -> [(UInt64, UInt8, UInt64?, Data?)] {
        var result: [(UInt64, UInt8, UInt64?, Data?)] = []
        var offset = 0
        while offset < data.count {
            guard let tag = decodeVarint(data, at: &offset) else { break }
            let number = tag >> 3
            let wire = UInt8(tag & 7)
            if wire == 0 {
                guard let value = decodeVarint(data, at: &offset) else { break }
                result.append((number, wire, value, nil))
            } else if wire == 2 {
                guard let length = decodeVarint(data, at: &offset), length <= UInt64(data.count - offset) else { break }
                let end = offset + Int(length)
                result.append((number, wire, nil, data.subdata(in: offset..<end)))
                offset = end
            } else if wire == 1 {
                guard offset + 8 <= data.count else { break }
                offset += 8
            } else if wire == 5 {
                guard offset + 4 <= data.count else { break }
                offset += 4
            } else {
                break
            }
        }
        return result
    }

    static func decodeRemoteFrame(_ frame: Data) -> RemoteMessage? {
        guard frame.count >= 10, frame[0] == 0xaa, frame[1] == 0x55 else { return nil }
        let length = Int(frame[2]) << 8 | Int(frame[3])
        guard frame.count == 4 + length + 2 else { return nil }
        let body = frame.subdata(in: 4..<(4 + length))
        let storedChecksum = (UInt16(frame[4 + length]) << 8) | UInt16(frame[5 + length])
        guard crc16XModem(body) == storedChecksum, body.count >= 4 else { return nil }
        let protocolID = body[3]
        let protobuf = body.subdata(in: 4..<body.count)
        let parsed = fields(protobuf)
        let action = parsed.first(where: { $0.0 == 1 && $0.1 == 0 })?.2
        let messageType = parsed.first(where: { $0.0 == 2 && $0.1 == 0 })?.2
        let jsonData = parsed.first(where: { $0.0 == 3 && $0.1 == 2 })?.3
        let json = jsonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let audioData = parsed.first(where: { $0.0 == 4 && $0.1 == 2 })?.3
        return RemoteMessage(protocolID: protocolID, sequence: UInt16(body[0]) << 8 | UInt16(body[1]), receivedAt: Date(), protobuf: protobuf, action: action, messageType: messageType, json: json, audioData: audioData)
    }

    static func firstFieldNumber(_ protobuf: Data) -> UInt64? {
        var offset = 0
        return decodeVarint(protobuf, at: &offset).map { $0 >> 3 }
    }

    static func nestedBytes(_ protobuf: Data, field number: UInt64) -> Data? {
        fields(protobuf).first(where: { $0.0 == number && $0.1 == 2 })?.3
    }

    static func varintValue(_ protobuf: Data, field number: UInt64) -> UInt64? {
        fields(protobuf).first(where: { $0.0 == number && $0.1 == 0 })?.2
    }

    static func stringValue(_ protobuf: Data, field number: UInt64) -> String? {
        nestedBytes(protobuf, field: number).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

}

private final class BLEReadinessSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceID = CBUUID(string: "0000B81D-0000-1000-8000-00805F9B34FB")
    private static let sendID = CBUUID(string: "EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9")
    private static let receiveID = CBUUID(string: "7DB3E235-3608-41F3-A03C-955FCBD2EA4B")
    private static let pairInfoID = CBUUID(string: "EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9")
    private static let authConstant = Data([0x07, 0x12, 0xC8, 0xAD, 0x27, 0x74, 0x41, 0x95, 0xDE, 0x5F, 0xA1, 0xEA, 0x6D, 0x02, 0x5F, 0xB8])

    private let expectedClassicAddress: String
    private let condition = NSCondition()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var sendCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var classicAddressBytes = Data()
    private var localDeviceID = Data()
    private var pairingSequence: UInt16 = 0
    private var receiveBuffer = Data()
    private var deviceInfoSent = false
    private var authResponseValidated = false
    private var ready = false
    private var scanRequested = false
    private var scanStarted = false
    private var failure: String?
    private var phase = "idle"
    private var bluetoothState = CBManagerState.unknown.rawValue
    private var observedPeripherals = Set<UUID>()
    private var rejectedPeripherals = Set<UUID>()
    private var pairingState: UInt8?

    init(address: String) {
        expectedClassicAddress = Self.normalize(address)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    var isReady: Bool {
        condition.lock()
        defer { condition.unlock() }
        return ready
    }

    var diagnostics: [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        return [
            "phase": phase, "ready": ready, "bluetoothState": bluetoothState,
            "scanning": scanStarted, "discoveredPeripheralCount": observedPeripherals.count,
            "pairingState": pairingState.map { Int($0) } as Any? ?? NSNull(),
            "lastError": failure as Any? ?? NSNull()
        ]
    }

    func waitUntilReady(timeout: TimeInterval) throws {
        DispatchQueue.main.sync {
            guard !self.isReady else { return }
            self.clearConnection()
            self.condition.lock()
            self.failure = nil
            self.scanRequested = true
            self.observedPeripherals.removeAll()
            self.rejectedPeripherals.removeAll()
            self.phase = "waitingForBluetooth"
            self.condition.unlock()
            self.centralManagerDidUpdateState(self.central)
        }

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !ready && failure == nil {
            if !condition.wait(until: deadline), !ready, failure == nil {
                failure = "RayNeo iO BLE timed out at \(phase); observed \(observedPeripherals.count) BLE peripherals"
            }
        }
        let failure = self.failure
        condition.unlock()
        if let failure {
            DispatchQueue.main.sync {
                self.clearConnection()
                self.setPhase("failed")
            }
            throw BridgeError(status: 503, message: failure)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        condition.lock()
        bluetoothState = central.state.rawValue
        condition.unlock()
        trace("CoreBluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            startScanIfNeeded()
        } else if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
            clearConnection()
            setFailure("Mac Bluetooth is unavailable for the RayNeo iO BLE session")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        condition.lock()
        let firstObservation = observedPeripherals.insert(peripheral.identifier).inserted
        condition.unlock()
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if firstObservation, ProcessInfo.processInfo.environment["OPENRAYNEO_BLE_TRACE"] == "1" {
            trace("Advertisement name=\(name.isEmpty ? "<unnamed>" : name), services=\(services.map(\.uuidString).joined(separator: ",")), connectable=\(advertisementData[CBAdvertisementDataIsConnectable] ?? "unknown"), RSSI=\(rssi)")
        }
        guard name.localizedCaseInsensitiveContains("RayNeo iO") || services.contains(Self.serviceID) else { return }
        connectCandidate(peripheral)
    }

    private func connectCandidate(_ peripheral: CBPeripheral) {
        condition.lock()
        guard scanRequested, self.peripheral == nil, !rejectedPeripherals.contains(peripheral.identifier) else {
            condition.unlock()
            return
        }
        self.peripheral = peripheral
        scanStarted = false
        phase = "connecting"
        condition.unlock()
        central.stopScan()
        trace("Connecting BLE candidate; verifying B81D and classic identity next")
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        setPhase("discoveringServices")
        peripheral.discoverServices([Self.serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        setFailure("Could not connect to the RayNeo iO BLE service")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else {
            setFailure("RayNeo iO BLE service discovery failed")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            rejectCandidate(peripheral)
            return
        }
        setPhase("discoveringCharacteristics")
        peripheral.discoverCharacteristics([Self.sendID, Self.receiveID, Self.pairInfoID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil,
              let send = service.characteristics?.first(where: { $0.uuid == Self.sendID }),
              let receive = service.characteristics?.first(where: { $0.uuid == Self.receiveID }),
              let pairInfo = service.characteristics?.first(where: { $0.uuid == Self.pairInfoID }) else {
            setFailure("RayNeo iO BLE connection characteristics were incomplete")
            return
        }
        condition.lock()
        sendCharacteristic = send
        receiveCharacteristic = receive
        phase = "readingIdentity"
        condition.unlock()
        peripheral.readValue(for: pairInfo)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let value = characteristic.value else {
            setFailure("RayNeo iO BLE data could not be read")
            return
        }
        if characteristic.uuid == Self.pairInfoID {
            guard value.count >= 13 else {
                setFailure("RayNeo iO pairing information could not be read over BLE")
                return
            }
            let addressBytes = Data(value.prefix(6))
            let discoveredAddress = Self.normalize(addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":"))
            guard discoveredAddress == expectedClassicAddress else {
                rejectCandidate(peripheral)
                return
            }
            let boundDeviceID = Data(value[7..<13])
            let identity = boundDeviceID.allSatisfy { $0 == 0 } ? Self.hostBluetoothAddressBytes() : boundDeviceID
            guard let identity, identity.count == 6 else {
                setFailure("Mac Bluetooth identity is unavailable for RayNeo iO authentication")
                return
            }
            classicAddressBytes = addressBytes
            localDeviceID = identity
            let receive = receiveCharacteristic
            guard let receive else {
                setFailure("RayNeo iO BLE receive characteristic was not found")
                return
            }
            setPhase("subscribing")
            peripheral.setNotifyValue(true, for: receive)
            return
        }
        if characteristic.uuid == Self.receiveID {
            receiveBuffer.append(value)
            processPairingFrames(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard characteristic.uuid == Self.receiveID else { return }
        guard error == nil, characteristic.isNotifying else {
            setFailure("RayNeo iO BLE receive notifications could not be enabled")
            return
        }
        sendDeviceInfoExchange(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .disconnected else { return }
        clearConnection()
        setFailure("RayNeo iO BLE disconnected; retry the request to reconnect")
    }

    private func startScanIfNeeded() {
        condition.lock()
        guard scanRequested, !scanStarted, peripheral == nil, !ready, failure == nil, central.state == .poweredOn else {
            condition.unlock()
            return
        }
        scanStarted = true
        phase = "scanning"
        condition.unlock()
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceID])
            .first(where: { !rejectedPeripherals.contains($0.identifier) }) {
            connectCandidate(connected)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        trace("Scanning BLE advertisements for RayNeo iO name or B81D service")
    }

    private func clearConnection() {
        central.stopScan()
        let previous = peripheral
        previous?.delegate = nil
        condition.lock()
        peripheral = nil
        sendCharacteristic = nil
        receiveCharacteristic = nil
        ready = false
        scanRequested = false
        scanStarted = false
        receiveBuffer = Data()
        deviceInfoSent = false
        authResponseValidated = false
        pairingState = nil
        condition.unlock()
        if let previous { central.cancelPeripheralConnection(previous) }
    }

    private func rejectCandidate(_ peripheral: CBPeripheral) {
        rejectedPeripherals.insert(peripheral.identifier)
        trace("BLE candidate does not match the paired RayNeo iO; continuing scan")
        clearConnection()
        condition.lock()
        scanRequested = true
        condition.unlock()
        startScanIfNeeded()
    }

    private func setPhase(_ value: String) {
        condition.lock()
        phase = value
        condition.unlock()
    }

    private func setFailure(_ message: String) {
        condition.lock()
        failure = message
        phase = "failed"
        ready = false
        condition.broadcast()
        condition.unlock()
    }

    private static func normalize(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    private func sendDeviceInfoExchange(_ peripheral: CBPeripheral) {
        guard !deviceInfoSent else { return }
        let host = IOBluetoothHostController.default()
        let name = host?.nameAsString() ?? ProcessInfo.processInfo.hostName
        let model = ProcessInfo.processInfo.hostName
        deviceInfoSent = true
        setPhase("exchangingDeviceInfo")
        sendPairingCommand(peripheral, command: 17, fields: [
            (16, Data([1])),
            (17, localDeviceID),
            (18, Data(name.utf8)),
            (19, Data([2])),
            (22, Data("Apple".utf8)),
            (23, Data(model.utf8)),
            (27, Data([1]))
        ])
        trace("Sent connection-pairing device info")
    }

    private func processPairingFrames(_ peripheral: CBPeripheral) {
        let magic = Data([0xaa, 0x55])
        while receiveBuffer.count >= 4 {
            guard let start = receiveBuffer.range(of: magic) else {
                receiveBuffer = Data(receiveBuffer.suffix(1))
                return
            }
            if start.lowerBound > receiveBuffer.startIndex {
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<start.lowerBound)
            }
            guard receiveBuffer.count >= 4 else { return }
            let base = receiveBuffer.startIndex
            let length = Int(receiveBuffer[base + 2]) << 8 | Int(receiveBuffer[base + 3])
            let frameLength = 4 + length + 2
            guard receiveBuffer.count >= frameLength else { return }
            let end = base + frameLength
            let frame = receiveBuffer.subdata(in: base..<end)
            receiveBuffer.removeSubrange(base..<end)
            guard let message = ProtocolCodec.decodeRemoteFrame(frame), message.protocolID == 0x10,
                  let (command, body, fields) = ProtocolCodec.pairingCommand(message.protobuf) else { continue }
            trace("Received connection-pairing command \(command)")
            switch command {
            case 17:
                guard fields[25] == nil else {
                    setFailure("RayNeo iO requested account-bound ECDH authentication")
                    return
                }
                sendAuthenticationRequest(peripheral)
            case 25:
                guard let random = fields[16], random.count == 4,
                      let receivedValue = fields[17], receivedValue.count == 32 else {
                    setFailure("RayNeo iO returned invalid authentication data")
                    return
                }
                var input = random
                input.append(localDeviceID)
                input.append(classicAddressBytes)
                input.append(Self.authConstant)
                let expectedValue = Data(SHA256.hash(data: input))
                guard expectedValue == receivedValue else {
                    setFailure("RayNeo iO application authentication was rejected")
                    return
                }
                authResponseValidated = true
                trace("Application authentication accepted")
                markReadyIfAuthenticated()
            case 23:
                condition.lock()
                pairingState = body.first
                condition.unlock()
                trace("Pairing state notification: \(body.first.map { String($0) } ?? "missing")")
            case 22:
                trace("Connection state notification: \(body.first.map { String($0) } ?? "missing")")
            default:
                break
            }
        }
    }

    private func sendAuthenticationRequest(_ peripheral: CBPeripheral) {
        setPhase("authenticating")
        var random = Data()
        for _ in 0..<4 { random.append(UInt8.random(in: 0...255)) }
        var input = random
        input.append(localDeviceID)
        input.append(classicAddressBytes)
        input.append(Self.authConstant)
        let authValue = Data(SHA256.hash(data: input))
        sendPairingCommand(peripheral, command: 24, fields: [(16, random), (17, authValue)])
    }

    private func sendPairingCommand(_ peripheral: CBPeripheral, command: UInt8, fields: [(UInt8, Data)]) {
        guard let sendCharacteristic else {
            setFailure("RayNeo iO BLE send characteristic was not found")
            return
        }
        pairingSequence &+= 1
        do {
            let frame = try ProtocolCodec.pairingFrame(sequence: pairingSequence &- 1, command: command, fields: fields)
            peripheral.writeValue(frame, for: sendCharacteristic, type: .withoutResponse)
        } catch {
            setFailure("RayNeo iO pairing command exceeds the protocol frame size")
            return
        }
        trace("Sent connection-pairing command \(command)")
    }

    private func markReadyIfAuthenticated() {
        guard authResponseValidated else { return }
        condition.lock()
        ready = true
        phase = "authenticated"
        failure = nil
        condition.broadcast()
        condition.unlock()
        trace("BLE session authenticated and ready")
    }

    private func trace(_ message: String) {
        FileHandle.standardError.write(Data("[RayNeo iO BLE] \(message)\n".utf8))
    }

    private static func hostBluetoothAddressBytes() -> Data? {
        guard let address = IOBluetoothHostController.default()?.addressAsString() else { return nil }
        let parts = address.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? Data(bytes) : nil
    }
}

final class RFCOMMTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private let bleReadiness: BLEReadinessSession
    private let writeLock = NSLock()
    private let channelLock = NSLock()
    private let receiveCondition = NSCondition()
    private let openCondition = NSCondition()
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
    private var lifeLogWakeHandler: ((RemoteMessage) -> Void)?
    private var lifeLogEvents: [[String: Any]] = []
    private var lifeLogAudioCounts: [String: Int] = [:]
    private var lifeLogLastAudioMetadata: [String: Any] = [:]

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
        receiveCondition.lock()
        receiveBuffer.append(Data(bytes: dataPointer, count: dataLength))
        extractMessages()
        receiveCondition.broadcast()
        receiveCondition.unlock()
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channelLock.lock()
        if storedChannel === rfcommChannel { storedChannel = nil }
        channelLock.unlock()
    }

    private func extractMessages() {
        let magic = Data([0xaa, 0x55])
        while receiveBuffer.count >= 4 {
            guard let start = receiveBuffer.range(of: magic) else {
                receiveBuffer = Data(receiveBuffer.suffix(1))
                return
            }
            if start.lowerBound > receiveBuffer.startIndex {
                receiveBuffer = receiveBuffer.subdata(in: start.lowerBound..<receiveBuffer.endIndex)
            }
            guard receiveBuffer.count >= 4 else { return }
            let length = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
            let frameLength = 4 + length + 2
            guard receiveBuffer.count >= frameLength else { return }
            let frame = receiveBuffer.subdata(in: 0..<frameLength)
            receiveBuffer = receiveBuffer.subdata(in: frameLength..<receiveBuffer.count)
            if let message = ProtocolCodec.decodeRemoteFrame(frame) {
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
                        // The wake experiment counts audio; it does not retain packet payloads.
                        continue
                    }
                    lifeLogEvents.append(["type": type, "receivedAt": message.receivedAt.timeIntervalSince1970,
                                          "body": message.json as Any? ?? NSNull()])
                    if lifeLogEvents.count > 128 { lifeLogEvents.removeFirst() }
                    if type == 161 || type == 165 { lifeLogWakeHandler?(message) }
                }
                if [0x13, 0x17].contains(message.protocolID), message.messageType == 4 {
                    if let audioHandler { audioHandler(message) }
                    else { droppedDisplayAudioPackets += 1 }
                    continue
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
    }
}

private final class BridgeController {
    private let transport: RFCOMMTransport
    let displays: DisplayController
    let speech: SpeechController
    private let operationLock: NSRecursiveLock
    private var nextSequence: UInt16 = 0
    private var activeDocumentID: String?
    private var customScriptCount = 0

    init(address: String) {
        let transport = RFCOMMTransport(address: address)
        let operationLock = NSRecursiveLock()
        self.operationLock = operationLock
        self.transport = transport
        let displays = DisplayController(transport: transport, lock: operationLock)
        self.displays = displays
        speech = SpeechController(transport: transport, displays: displays)
    }

    var isConnected: Bool { transport.isConnected }
    var isBLEReady: Bool { transport.isBLEReady }
    var diagnostics: [String: Any] { transport.diagnostics }

    func connect() throws {
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

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private final class LocalHTTPServer {
    private let port: UInt16
    private let token: String
    private let controller: BridgeController

    init(port: UInt16, token: String, controller: BridgeController) {
        self.port = port
        self.token = token
        self.controller = controller
    }

    func run() throws -> Never {
        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw BridgeError(status: 500, message: "Could not create HTTP socket") }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(serverFD, 16) == 0 else {
            Darwin.close(serverFD)
            throw BridgeError(status: 500, message: "Could not bind HTTP API to 127.0.0.1:\(port)")
        }

        print("OpenRayneo Bridge listening at http://127.0.0.1:\(port)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { continue }
                DispatchQueue.global().async { [weak self] in
                    guard let self else { Darwin.close(clientFD); return }
                    self.handle(clientFD)
                }
            }
        }
        while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)) }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        do {
            let request = try readRequest(clientFD)
            let (status, response) = route(request)
            let body = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
            let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : status == 413 ? "Payload Too Large" : status == 503 ? "Service Unavailable" : status == 504 ? "Gateway Timeout" : "Internal Server Error"
            var headers = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            headers.append(body)
            headers.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                _ = Darwin.send(clientFD, base, rawBuffer.count, 0)
            }
        } catch let error as BridgeError {
            writeError(clientFD, status: error.status, message: error.message)
        } catch {
            writeError(clientFD, status: 400, message: error.localizedDescription)
        }
    }

    private func route(_ request: HTTPRequest) -> (Int, [String: Any]) {
        if request.method == "GET", request.path == "/health" {
            return (200, ["ok": true, "bleReady": controller.isBLEReady, "rfcommConnected": controller.isConnected])
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return (401, ["error": "missing or invalid bearer token"])
        }
        if request.method == "GET", request.path == "/v1/device" {
            return (200, controller.diagnostics)
        }
        do {
            let object = request.body.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:])
            if let response = try controller.speech.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if request.method == "POST", request.path.hasPrefix("/v1/teleprompter"), controller.displays.isSpeechReserved {
                throw BridgeError(status: 409, message: "Stop the audio session before using the teleprompter")
            }
            if let response = try controller.displays.route(method: request.method, path: request.path, body: object) {
                return response
            }
            switch (request.method, request.path) {
            case ("POST", "/v1/device/connect"):
                try controller.connect()
                return (200, controller.diagnostics)
            case ("POST", "/v1/notifications"):
                guard let title = object["title"] as? String, let body = object["body"] as? String else {
                    throw BridgeError(status: 400, message: "title and body are required")
                }
                try controller.postNotification(title: title, body: body)
                return (202, ["ok": true, "sent": "notification"])
            case ("POST", "/v1/teleprompter"):
                guard let text = object["text"] as? String else {
                    throw BridgeError(status: 400, message: "text is required")
                }
                let title = object["title"] as? String ?? "OpenRayneo"
                let speed = object["speed"] as? Int ?? 120
                let documentID = try controller.startTeleprompter(title: title, text: text, speed: speed)
                return (202, ["ok": true, "sent": "teleprompter", "did": documentID])
            case ("POST", "/v1/teleprompter/pause"), ("POST", "/v1/teleprompter/resume"), ("POST", "/v1/teleprompter/stop"):
                let action = String(request.path.split(separator: "/").last ?? "")
                try controller.controlTeleprompter(action)
                return (202, ["ok": true, "sent": action])
            default:
                return (404, ["error": "route not found"])
            }
        } catch let error as BridgeError {
            return (error.status, ["error": error.message])
        } catch {
            return (400, ["error": error.localizedDescription])
        }
    }

    private func readRequest(_ fd: Int32) throws -> HTTPRequest {
        var data = Data()
        var boundary: Range<Data.Index>?
        var contentLength = 0
        while data.count <= 1_048_576 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard received > 0 else { throw BridgeError(status: 400, message: "empty request") }
            data.append(contentsOf: buffer.prefix(received))
            if boundary == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                boundary = range
                let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                contentLength = headerText.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    return parts.count == 2 && parts[0] == "content-length" ? Int(parts[1]) : nil
                }.first ?? 0
                guard contentLength >= 0 else { throw BridgeError(status: 400, message: "invalid content-length") }
                guard contentLength <= 1_000_000 else { throw BridgeError(status: 413, message: "request body too large") }
            }
            if let boundary, data.count >= boundary.upperBound + contentLength { break }
        }
        guard let boundary else { throw BridgeError(status: 400, message: "malformed HTTP request") }
        let headerText = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { throw BridgeError(status: 400, message: "malformed request line") }
        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count >= 2 else { throw BridgeError(status: 400, message: "malformed request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        let bodyStart = boundary.upperBound
        let bodyEnd = bodyStart + contentLength
        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<bodyEnd)
        )
    }

    private func writeError(_ fd: Int32, status: Int, message: String) {
        let response = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
        let reason = status == 503 ? "Service Unavailable" : status == 413 ? "Payload Too Large" : "Bad Request"
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(response.count)\r\n\r\n".utf8)
        bytes.append(response)
        bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.send(fd, base, rawBuffer.count, 0)
        }
    }
}

func resolveRayneoAddress() -> String? {
    if let configured = ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"], !configured.isEmpty {
        return configured
    }
    let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    let matches = devices.filter { ($0.nameOrAddress ?? "").localizedCaseInsensitiveContains("RayNeo iO") }
    return matches.count == 1 ? matches[0].addressString : nil
}

guard let address = resolveRayneoAddress() else {
    fputs("Pair one RayNeo iO with this Mac, or set RAYNEO_ADDRESS if several are paired.\n", stderr)
    exit(1)
}
let token = ProcessInfo.processInfo.environment["OPENRAYNEO_API_TOKEN"] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
let port = UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765
private let controller = BridgeController(address: address)
private let server = LocalHTTPServer(port: port, token: token, controller: controller)
print("API token: \(token)")
do {
    try server.run()
} catch {
    fputs("OpenRayneo Bridge failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
