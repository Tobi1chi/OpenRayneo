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
    let version: UInt64?
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

    static func teleprompterFrame(sequence: UInt16, type: UInt64, action _: UInt64, body: [String: Any]) throws -> Data {
        // TransportMessage field 1 is the envelope version. Direction is JSON action.
        var protobuf = field(1, varint: 1)
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

    static func rawBusinessFrame(protocolID: UInt8, sequence: UInt16, payload: Data) throws -> Data {
        try frame(protocolID: protocolID, sequence: sequence, protobuf: payload)
    }

    static func acknowledgement(protocolID: UInt8, sequence: UInt16) throws -> Data {
        try frame(protocolID: protocolID, sequence: sequence, protobuf: Data(), magic: 0x55aa)
    }

    static func transportFrame(protocolID: UInt8, sequence: UInt16, type: UInt64, message: Data = Data(), data: Data = Data()) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: message))
        protobuf.append(field(4, bytes: data))
        return try frame(protocolID: protocolID, sequence: sequence, protobuf: protobuf)
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

    static func appVisibilityFrame(sequence: UInt16, foreground: Bool) throws -> Data {
        // GlassesAppVisibilityNotifier 0x271153c: raw command 31, body length 1.
        try frame(protocolID: 0x10, sequence: sequence, protobuf: Data([0x1f, 0, 1, foreground ? 2 : 1]))
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

    private static func frame(protocolID: UInt8, sequence: UInt16, protobuf: Data, magic: UInt16 = 0xaa55) throws -> Data {
        guard protobuf.count <= Int(UInt16.max) - 4 else {
            throw BridgeError(status: 413, message: "Protocol payload exceeds 65531 bytes")
        }
        var body = Data()
        body.appendBE(sequence)
        body.append(0)
        body.append(protocolID)
        body.append(protobuf)

        var result = Data()
        result.appendBE(magic)
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
        let headerLength = 4 + (body[2] & 2 == 0 ? 0 : 1) + Int(body[2] >> 5)
        guard body.count >= headerLength else { return nil }
        let protocolID = body[headerLength - 1]
        let protobuf = body.subdata(in: headerLength..<body.count)
        if [0x06, 0x19].contains(protocolID), let json = try? JSONSerialization.jsonObject(with: protobuf) as? [String: Any] {
            return RemoteMessage(protocolID: protocolID, sequence: UInt16(body[0]) << 8 | UInt16(body[1]), receivedAt: Date(),
                protobuf: protobuf, version: nil, messageType: protocolID == 6 ? (json["type"] as? NSNumber)?.uint64Value : 1, json: json, audioData: nil)
        }
        let parsed = fields(protobuf)
        let version = parsed.first(where: { $0.0 == 1 && $0.1 == 0 })?.2
        let messageType = parsed.first(where: { $0.0 == 2 && $0.1 == 0 })?.2
        let jsonData = parsed.first(where: { $0.0 == 3 && $0.1 == 2 })?.3
        let json = jsonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let audioData = parsed.first(where: { $0.0 == 4 && $0.1 == 2 })?.3
        return RemoteMessage(protocolID: protocolID, sequence: UInt16(body[0]) << 8 | UInt16(body[1]), receivedAt: Date(), protobuf: protobuf, version: version, messageType: messageType, json: json, audioData: audioData)
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
    private var pairInfoCharacteristic: CBCharacteristic?
    private var classicAddressBytes = Data()
    private var localDeviceID = Data()
    private var pairingSequence: UInt16 = 0
    private var receiveBuffer = Data()
    private var connectionIntent: ConnectionIntent
    private var lastSentPairValue: UInt8?
    private var identitySource: String?
    private var reportedBondState: Int?
    private var maximumBLEWrite = 0
    private var lastHandshakeFrameBytes = 0
    private var lastReceivedPairingCommand: Int?
    private var pendingBLEWrites: [Data] = []
    private var deviceInfoSent = false
    private var authResponseValidated = false
    private var ready = false
    private var scanRequested = false
    private var scanStarted = false
    private var failure: String?
    private var phase = "idle"
    private var failedPhase: String?
    private var bluetoothError: [String: Any]?
    private var bluetoothState = CBManagerState.unknown.rawValue
    private var observedPeripherals = Set<UUID>()
    private var rejectedPeripherals = Set<UUID>()
    private var pairingState: UInt8?
    private var businessMessageHandler: ((RemoteMessage) -> Void)?
    private var readinessHandler: ((Bool) -> Void)?
    private var poweredOnHandler: (() -> Void)?

    init(address: String, intent: ConnectionIntent = .reconnect) {
        connectionIntent = intent
        expectedClassicAddress = Self.normalize(address)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    var isReady: Bool {
        condition.lock()
        defer { condition.unlock() }
        return ready
    }

    func setBusinessMessageHandler(_ handler: @escaping (RemoteMessage) -> Void) {
        condition.lock(); businessMessageHandler = handler; condition.unlock()
    }

    func setReadinessHandlers(changed: @escaping (Bool) -> Void, poweredOn: @escaping () -> Void) {
        condition.lock(); readinessHandler = changed; poweredOnHandler = poweredOn; condition.unlock()
    }

    func discardPartialFrames() {
        DispatchQueue.main.async { [weak self] in self?.receiveBuffer = Data() }
    }

    var diagnostics: [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        return [
            "phase": phase, "ready": ready, "bluetoothState": bluetoothState,
            "bluetoothAuthorization": CBManager.authorization.rawValue,
            "scanning": scanStarted, "discoveredPeripheralCount": observedPeripherals.count,
            "pairingState": pairingState.map { Int($0) } as Any? ?? NSNull(),
            "registrationPending": connectionIntent == .register,
            "lastSentPairValue": lastSentPairValue.map { Int($0) } as Any? ?? NSNull(),
            "identitySource": identitySource as Any? ?? NSNull(),
            "reportedBondState": reportedBondState as Any? ?? NSNull(),
            "maximumBLEWrite": maximumBLEWrite, "lastHandshakeFrameBytes": lastHandshakeFrameBytes,
            "lastReceivedPairingCommand": lastReceivedPairingCommand as Any? ?? NSNull(),
            "lastError": failure as Any? ?? NSNull(),
            "failedPhase": failedPhase as Any? ?? NSNull(), "bluetoothError": bluetoothError as Any? ?? NSNull()
        ]
    }

    func waitUntilReady(timeout: TimeInterval) throws {
        DispatchQueue.main.sync {
            guard !self.isReady else { return }
            self.clearConnection()
            self.condition.lock()
            self.failure = nil; self.failedPhase = nil; self.bluetoothError = nil
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

    func releaseForSystemPairing() throws {
        let previous: CBPeripheral? = DispatchQueue.main.sync {
            let previous = self.peripheral
            self.clearConnection()
            self.setPhase("waitingForSystemPairing")
            return previous
        }
        let deadline = Date().addingTimeInterval(5)
        while let previous, DispatchQueue.main.sync(execute: { previous.state != .disconnected }) {
            guard Date() < deadline else {
                throw BridgeError(status: 504, message: "BLE registration finished but its link has not disconnected for system pairing")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        condition.lock()
        bluetoothState = central.state.rawValue
        condition.unlock()
        trace("CoreBluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            startScanIfNeeded()
            condition.lock(); let handler = poweredOnHandler; condition.unlock()
            handler?()
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
        if let advertised = RayneoAdvertisement.classicAddress(advertisementData), Self.normalize(advertised) != expectedClassicAddress { return }
        guard advertisementData[CBAdvertisementDataIsConnectable] as? Bool != false else { return }
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
        guard self.peripheral === peripheral, peripheral.state == .disconnected else { return }
        setBluetoothFailure("Could not connect to the RayNeo iO BLE service", error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else {
            setBluetoothFailure("RayNeo iO BLE service discovery failed", error: error)
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
        guard service === peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else { return }
        guard error == nil,
              let send = service.characteristics?.first(where: { $0.uuid == Self.sendID }),
              let receive = service.characteristics?.first(where: { $0.uuid == Self.receiveID }),
              let pairInfo = service.characteristics?.first(where: { $0.uuid == Self.pairInfoID }) else {
            setBluetoothFailure("RayNeo iO BLE connection characteristics were incomplete", error: error)
            return
        }
        condition.lock()
        sendCharacteristic = send
        receiveCharacteristic = receive
        pairInfoCharacteristic = pairInfo
        phase = "readingIdentity"
        condition.unlock()
        peripheral.readValue(for: pairInfo)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let value = characteristic.value else {
            setBluetoothFailure("RayNeo iO BLE data could not be read", error: error)
            return
        }
        if characteristic.uuid == Self.pairInfoID {
            guard characteristic === pairInfoCharacteristic else { return }
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
            reportedBondState = Int(value[6])
            let useHostIdentity = boundDeviceID.allSatisfy { $0 == 0 }
            let identity = useHostIdentity ? Self.hostBluetoothAddressBytes() : boundDeviceID
            identitySource = useHostIdentity ? "hostBluetoothAddress" : "deviceBoundIdentity"
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
            guard characteristic === receiveCharacteristic else { return }
            receiveBuffer.append(value)
            processPairingFrames(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard characteristic === receiveCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            setBluetoothFailure("RayNeo iO BLE receive notifications could not be enabled", error: error)
            return
        }
        sendDeviceInfoExchange(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .disconnected else { return }
        setBluetoothFailure("RayNeo iO BLE disconnected", error: error)
        clearConnection()
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
        let wasReady = ready, handler = readinessHandler
        peripheral = nil
        sendCharacteristic = nil
        receiveCharacteristic = nil
        pairInfoCharacteristic = nil
        ready = false
        scanRequested = false
        scanStarted = false
        receiveBuffer = Data()
        deviceInfoSent = false
        pendingBLEWrites.removeAll()
        authResponseValidated = false
        pairingState = nil
        condition.unlock()
        if wasReady { handler?(false) }
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

    private func setBluetoothFailure(_ message: String, error: Error?) {
        condition.lock()
        let stage = phase
        if let error = error as NSError? { bluetoothError = ["domain": error.domain, "code": error.code, "message": error.localizedDescription] }
        condition.unlock()
        setFailure("\(message) at \(stage)" + (error.map { "; " + $0.localizedDescription } ?? ""))
    }

    private func setFailure(_ message: String) {
        condition.lock()
        let wasReady = ready, handler = readinessHandler
        failure = message
        failedPhase = phase
        phase = "failed"
        ready = false
        condition.broadcast()
        condition.unlock()
        if wasReady { handler?(false) }
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
        lastSentPairValue = connectionIntent.pairValue
        setPhase("exchangingDeviceInfo")
        sendPairingCommand(peripheral, command: 17, fields: [
            (16, Data([1])),
            (17, localDeviceID),
            (18, Data(name.utf8)),
            (19, Data([2])),
            (22, Data("Apple".utf8)),
            (23, Data(model.utf8)),
            // RNAuthManager keeps the Add/Pair intent after the OS bond completes.
            (27, Data([connectionIntent.pairValue]))
        ])
        trace("Sent connection-pairing device info (\(connectionIntent.rawValue), pairValue=\(connectionIntent.pairValue))")
    }

    private func processPairingFrames(_ peripheral: CBPeripheral) {
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
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<start.lowerBound)
            }
            guard receiveBuffer.count >= 4 else { return }
            let base = receiveBuffer.startIndex
            let length = Int(receiveBuffer[base + 2]) << 8 | Int(receiveBuffer[base + 3])
            let headerMin = receiveBuffer.count >= 7
                ? 4 + (receiveBuffer[base + 6] & 2 == 0 ? 0 : 1) + Int(receiveBuffer[base + 6] >> 5)
                : 4
            if length < 4 || (receiveBuffer.count >= 7 && length < headerMin) || (receiveBuffer[base] == 0x55 && length != 4) {
                receiveBuffer.removeFirst()
                continue
            }
            let frameLength = 4 + length + 2
            if receiveBuffer.count < frameLength {
                if receiveBuffer.count > maxFrameBytes {
                    receiveBuffer.removeFirst()
                    continue
                }
                return
            }
            let end = base + frameLength
            let frame = receiveBuffer.subdata(in: base..<end)
            if frame[0] == 0x55 {
                let expectedCRC = ProtocolCodec.crc16XModem(frame.subdata(in: 4..<8))
                let storedCRC = (UInt16(frame[8]) << 8) | UInt16(frame[9])
                if expectedCRC == storedCRC {
                    receiveBuffer.removeSubrange(base..<end)
                } else {
                    receiveBuffer.removeFirst()
                }
                continue
            }
            guard let message = ProtocolCodec.decodeRemoteFrame(frame) else {
                receiveBuffer.removeFirst()
                continue
            }
            receiveBuffer.removeSubrange(base..<end)
            if frame[6] & 1 != 0, let sendCharacteristic,
               let receipt = try? ProtocolCodec.acknowledgement(protocolID: message.protocolID, sequence: message.sequence) {
                enqueueBLEWrite(receipt, peripheral: peripheral, characteristic: sendCharacteristic)
            }
            if message.protocolID != 0x10 || message.protobuf.first == 0x1e {
                condition.lock(); let handler = businessMessageHandler; condition.unlock()
                handler?(message)
                continue
            }
            guard let (command, body, fields) = ProtocolCodec.pairingCommand(message.protobuf) else { continue }
            lastReceivedPairingCommand = Int(command)
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
            lastHandshakeFrameBytes = frame.count
            enqueueBLEWrite(frame, peripheral: peripheral, characteristic: sendCharacteristic)
        } catch {
            setFailure("RayNeo iO pairing command exceeds the protocol frame size")
            return
        }
        trace("Sent connection-pairing command \(command)")
    }

    private func enqueueBLEWrite(_ bytes: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maximum > 0 else { setFailure("BLE write length is unavailable"); return }
        maximumBLEWrite = maximum
        for offset in stride(from: 0, to: bytes.count, by: maximum) {
            pendingBLEWrites.append(bytes.subdata(in: offset..<min(offset + maximum, bytes.count)))
        }
        drainBLEWrites(peripheral, characteristic: characteristic)
    }

    private func drainBLEWrites(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard self.peripheral === peripheral else { return }
        while !pendingBLEWrites.isEmpty && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(pendingBLEWrites.removeFirst(), for: characteristic, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let sendCharacteristic else { return }
        drainBLEWrites(peripheral, characteristic: sendCharacteristic)
    }

    private func markReadyIfAuthenticated() {
        guard authResponseValidated else { return }
        condition.lock()
        let wasReady = ready, handler = readinessHandler
        ready = true
        connectionIntent = .reconnect
        phase = "authenticated"
        failure = nil
        condition.broadcast()
        condition.unlock()
        if !wasReady { handler?(true) }
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
                if receiveBuffer.count > maxFrameBytes {
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

private final class BridgeController {
    private let transport: RFCOMMTransport
    let displays: DisplayController
    let speech: SpeechController
    let settings: GlassesSettingsController
    let schedules: ScheduleController
    let todoSync: ScheduleTodoSync
    let nativeRecording: NativeRecordingController
    let files: FileTransferController
    let networkRelay: NetworkRelayController
    let capabilities: CapabilityController
    let maintenance: MaintenanceController
    let ota: OTAUpdateController
    let teleprompterFollow: TeleprompterFollowController
    let assistantRuntime = AssistantRuntimeController()
    let nativeAssistant: NativeAssistantController
    private let operationLock: NSRecursiveLock
    private var nextSequence: UInt16 = 0
    private var recordingForeground: Bool?
    private var recordingVisibilityGeneration: Int?
    private var recordingVisibilityError: String?
    private let visibilityStateLock = NSLock()
    private var recordingVisibilitySnapshot: [String: Any] = [:]
    private var activeDocumentID: String?
    private var lastDocumentID: String?
    private var activeDocumentText = ""
    private var activeTeleprompterSettings: [String: Any] = [:]
    private var teleprompterPaused = false
    private var teleprompterPageOffset = 0
    private var teleprompterHighlightOffset = 0
    private var teleprompterError: String?
    private let teleprompterEvents = DispatchQueue(label: "openrayneo.teleprompter-events")
    private let teleprompterRepository = TeleprompterRepository()
    private var pendingDocumentID: String?
    private lazy var stateSynchronization = DeviceStateSynchronization(isCurrent: { [weak self] generation in
        guard let self else { return false }
        return self.transport.isConnected && self.transport.isBLEReady && self.transport.currentConnectionGeneration == generation
    }, steps: { [weak self] in self?.connectionSynchronizationSteps() ?? [] })

    init(address: String) {
        let transport = RFCOMMTransport(address: address)
        let operationLock = NSRecursiveLock()
        self.operationLock = operationLock
        self.transport = transport
        let nativeAssistant = NativeAssistantController(transport: transport)
        self.nativeAssistant = nativeAssistant
        transport.setNativeAssistantHandler { [weak nativeAssistant] in nativeAssistant?.handle($0) }
        let teleprompterFollow = TeleprompterFollowController(transport: transport, lock: operationLock)
        self.teleprompterFollow = teleprompterFollow
        settings = GlassesSettingsController(transport: transport, lock: operationLock)
        let todoStore = TodoOwnershipStore(deviceID: address)
        let todoSync = ScheduleTodoSync(transport: transport, lock: operationLock, todoStore: todoStore)
        self.todoSync = todoSync
        transport.setTodoStatusHandler { [weak todoSync] in todoSync?.handle($0) }
        schedules = ScheduleController(transport: transport, lock: operationLock, sync: todoSync)
        nativeRecording = NativeRecordingController(transport: transport, lock: operationLock, deviceID: address)
        let files = FileTransferController(transport: transport, lock: operationLock)
        self.files = files
        transport.setFileTransferHandlers(message: { [weak files] in files?.handle($0) }, corrupt: { [weak files] in files?.handleCorruptFrame($0) })
        let networkRelay = NetworkRelayController(transport: transport)
        self.networkRelay = networkRelay
        transport.setNetworkRelayHandler { [weak networkRelay] in networkRelay?.handle($0) }
        let capabilities = CapabilityController(transport: transport, lock: operationLock)
        self.capabilities = capabilities
        transport.setCapabilityHandler { [weak capabilities] in capabilities?.handle($0) }
        let maintenance = MaintenanceController(transport: transport, lock: operationLock)
        self.maintenance = maintenance
        transport.setMaintenanceHandler { [weak maintenance] in maintenance?.handle($0) }
        let ota = OTAUpdateController(transport: transport, lock: operationLock, deviceID: address)
        self.ota = ota
        transport.setOTAHandler { [weak ota] in ota?.handle($0) }
        let displays = DisplayController(transport: transport, lock: operationLock, deviceID: address, todoStore: todoStore, todoSync: todoSync)
        self.displays = displays
        transport.setDisplayControlHandler { [weak displays] message in displays?.handle(message) }
        speech = SpeechController(transport: transport, displays: displays)
        let stateSynchronization = self.stateSynchronization
        transport.setConnectionStateHandlers(ready: { [weak self, weak stateSynchronization] generation in
            guard let self else { return }
            self.displays.connectionReady()
            stateSynchronization?.request(generation: generation)
        }, lost: { [weak self, weak stateSynchronization] bleDisconnected in
            guard let self else { return }
            stateSynchronization?.connectionLost()
            self.nativeAssistant.connectionLost()
            self.displays.connectionLost(bleDisconnected: bleDisconnected)
            self.todoSync.cancelTodoSync()
        })
        transport.setTeleprompterHandlers(message: { [weak self] message in
            guard let self else { return }
            if message.messageType == 9 { self.teleprompterFollow.handle(message) }
            else { self.teleprompterEvents.async { [weak self] in self?.receiveTeleprompterControl(message) } }
        }, disconnected: { [weak self] in
            guard let self else { return }
            self.todoSync.cancelTodoSync()
            self.teleprompterFollow.connectionClosed()
            self.teleprompterEvents.async { [weak self] in
                guard let self else { return }
                self.operationLock.lock(); defer { self.operationLock.unlock() }
                self.cacheFollowPosition()
                if self.activeDocumentID != nil { self.teleprompterError = "眼镜连接已断开" }
            }
        })
    }

    var isConnected: Bool { transport.isConnected }
    var isBLEReady: Bool { transport.isBLEReady }
    var synchronizationStatus: [String: Any] { stateSynchronization.status }
    var diagnostics: [String: Any] {
        var result = transport.diagnostics
        result["appVisibility"] = visibilityStatus
        result["synchronization"] = stateSynchronization.status
        result["nativeAssistant"] = nativeAssistant.status
        return result
    }

    var visibilityStatus: [String: Any] {
        var result = transport.appVisibilityStatus
        visibilityStateLock.lock(); let recording = recordingVisibilitySnapshot; visibilityStateLock.unlock()
        result["recordingLastSentForeground"] = recording["recordingLastSentForeground"] ?? NSNull()
        result["recordingError"] = recording["recordingError"] ?? NSNull()
        return result
    }

    func synchronizeAppVisibility(_ foreground: Bool) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        defer {
            visibilityStateLock.lock()
            recordingVisibilitySnapshot = ["recordingLastSentForeground": recordingForeground as Any? ?? NSNull(),
                "recordingError": recordingVisibilityError as Any? ?? NSNull()]
            visibilityStateLock.unlock()
        }
        var failure: Error?
        do { try transport.setAppForeground(foreground) } catch { failure = error }
        let status = transport.appVisibilityStatus
        let generation = status["connectionGeneration"] as? Int
        if transport.isConnected, recordingForeground != foreground || recordingVisibilityGeneration != generation {
            do {
                try nativeRecording.reportForeground(foreground)
                recordingForeground = foreground; recordingVisibilityGeneration = generation
                recordingVisibilityError = nil
            } catch {
                recordingVisibilityError = (error as? BridgeError)?.message ?? error.localizedDescription
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    var teleprompterStatus: [String: Any] {
        operationLock.lock(); defer { operationLock.unlock() }
        cacheFollowPosition()
        let smart = activeTeleprompterSettings["scroll"] as? Int == 1
        var result = smart ? teleprompterFollow.status : [:]
        result["running"] = activeDocumentID != nil
        result["previewing"] = pendingDocumentID != nil && activeDocumentID == nil
        result["did"] = activeDocumentID ?? lastDocumentID as Any? ?? NSNull()
        result["paused"] = teleprompterPaused
        result["pageOffset"] = teleprompterPageOffset
        result["highLightOffset"] = teleprompterHighlightOffset
        result["totalBytes"] = activeDocumentText.utf8.count
        result["offsetUnit"] = "utf8_bytes"
        result["scroll"] = activeTeleprompterSettings["scroll"] as? Int ?? 2
        result["settings"] = activeTeleprompterSettings
        result["state"] = activeDocumentID != nil ? (teleprompterPaused ? 2 : 1) : (pendingDocumentID == nil ? 3 : 4)
        result["controlEvents"] = transport.displayEvents.filter { $0["protocol"] as? Int == 0x14 }
        if let teleprompterError { result["error"] = teleprompterError }
        return result
    }

    private func cacheFollowPosition() {
        guard activeTeleprompterSettings["scroll"] as? Int == 1 else { return }
        let state = teleprompterFollow.status
        teleprompterPageOffset = state["pageOffset"] as? Int ?? teleprompterPageOffset
        teleprompterHighlightOffset = state["highLightOffset"] as? Int ?? teleprompterHighlightOffset
    }

    private func receiveTeleprompterControl(_ message: RemoteMessage) {
        guard let type = message.messageType, let json = message.json else { return }
        operationLock.lock(); defer { operationLock.unlock() }
        if json["action"] as? Int == 1, [UInt64(1), 2, 3].contains(type) {
            do {
                switch type {
                case 1:
                    if json["type"] as? Int == 4, json["chunkid"] == nil, json["chunkId"] == nil,
                       let code = json["code"] as? Int, [20, 21, 26, 28].contains(code) {
                        throw BridgeError(status: 409, message: "眼镜提词快捷操作发生冲突，code=\(code)")
                    }
                    let items = try teleprompterRepository.listMetadata()
                    try sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": 1, "total": items.count,
                        "chunkinfo": ["chunkid": 1, "total_items": items.count, "islast": true], "items": items])
                case 2: try prepareGlassesTeleprompter(json)
                case 3: try playGlassesTeleprompter(json)
                default: break
                }
            } catch {
                teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription
                if type == 1 { try? sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": 1, "code": 2, "total": 0, "items": []]) }
            }
            return
        }
        if [UInt64(7), 8].contains(type), json["action"] as? Int == 1,
           let did = json["did"] as? String {
            do {
                try sendTeleprompter(type: type, action: 2, body: ["action": 2, "did": did, "code": 1])
                guard did == activeDocumentID || did == pendingDocumentID else { return }
                if type == 8 {
                    cacheFollowPosition()
                    let total = activeDocumentText.utf8.count
                    let page = min(total, max(0, json["pageOffset"] as? Int ?? teleprompterPageOffset))
                    let highlight = min(total, max(page, json["highLightOffset"] as? Int ?? teleprompterHighlightOffset))
                    guard page != teleprompterPageOffset || highlight != teleprompterHighlightOffset else { return }
                    teleprompterPageOffset = page
                    teleprompterHighlightOffset = highlight
                    if activeTeleprompterSettings["scroll"] as? Int == 1 { teleprompterFollow.seek(byteOffset: highlight) }
                } else {
                    guard did == activeDocumentID else { return }
                    var next = activeTeleprompterSettings
                    for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
                        if let value = json[key] { next[key] = value }
                    }
                    guard !NSDictionary(dictionary: next).isEqual(to: activeTeleprompterSettings) else { return }
                    cacheFollowPosition()
                    activeTeleprompterSettings = next
                    if next["scroll"] as? Int == 1 {
                        try teleprompterFollow.start(did: did, text: activeDocumentText, settings: next)
                        teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
                        teleprompterFollow.setPaused(teleprompterPaused)
                    } else { teleprompterFollow.stop() }
                }
            } catch { teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription }
            return
        }
        guard [UInt64(4), 5, 6].contains(type) else { return }
        guard let documentID = activeDocumentID, json["did"] as? String == documentID,
              let action = json["action"] as? Int, action == 1 || action == 2 else { return }
        if action == 2, let code = json["code"] as? Int, code != 1 {
            teleprompterError = "眼镜拒绝提词控制 type=\(type)，code=\(code)"
            return
        }
        cacheFollowPosition()
        switch type {
        case 4:
            teleprompterPaused = true
            teleprompterFollow.setPaused(true)
        case 5:
            teleprompterPaused = false
            teleprompterFollow.setPaused(false)
        case 6:
            teleprompterFollow.stop()
            activeDocumentID = nil
            pendingDocumentID = nil
        default: break
        }
        if action == 1 {
            do { try sendTeleprompter(type: type, action: 2, body: ["action": 2, "did": documentID, "code": 1]) }
            catch { teleprompterError = error.localizedDescription }
        }
    }

    private func prepareGlassesTeleprompter(_ body: [String: Any]) throws {
        let did = body["did"] as? String ?? ""
        guard !did.isEmpty, let document = try teleprompterRepository.load(did: did) else {
            try sendTeleprompter(type: 2, action: 2, body: ["action": 2, "did": did, "code": 5])
            throw BridgeError(status: 404, message: "眼镜选择的稿件未保存在这台 Mac")
        }
        if activeDocumentID == did || pendingDocumentID == did { return }
        teleprompterFollow.stop()
        activeDocumentID = nil; pendingDocumentID = did; lastDocumentID = did
        activeDocumentText = document.text; activeTeleprompterSettings = document.settings.wireBody
        teleprompterPageOffset = 0; teleprompterHighlightOffset = 0; teleprompterPaused = false; teleprompterError = nil
        var response = document.settings.wireBody
        response.merge(["action": 2, "did": did, "code": 1, "pageOffset": 0, "highLightOffset": 0]) { _, new in new }
        let started = Date()
        do {
            try sendTeleprompter(type: 2, action: 2, body: response)
            try sendScriptTransfer(taskID: "task_2_\(Int64(Date().timeIntervalSince1970 * 1000))", documentID: did, content: Data(document.text.utf8))
            try waitForTeleprompterAcceptance(type: 2, documentID: did, since: started, timeout: 30, transferFinishedAt: Date())
        } catch {
            pendingDocumentID = nil
            throw error
        }
    }

    private func playGlassesTeleprompter(_ body: [String: Any]) throws {
        let did = body["did"] as? String ?? ""
        guard !did.isEmpty, did == pendingDocumentID || did == activeDocumentID else {
            try sendTeleprompter(type: 3, action: 2, body: ["action": 2, "did": did, "code": 2])
            throw BridgeError(status: 409, message: "眼镜请求播放的稿件与已准备稿件不一致")
        }
        do {
            if activeTeleprompterSettings["scroll"] as? Int == 1 {
                try teleprompterFollow.start(did: did, text: activeDocumentText, settings: activeTeleprompterSettings)
                teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
            }
            var response = activeTeleprompterSettings
            response.merge(["action": 2, "did": did, "code": 1,
                "checksum": ProtocolCodec.fnv1a32(Data(activeDocumentText.utf8)),
                "pageOffset": teleprompterPageOffset, "highLightOffset": teleprompterHighlightOffset]) { _, new in new }
            try sendTeleprompter(type: 3, action: 2, body: response)
            activeDocumentID = did; pendingDocumentID = nil; teleprompterPaused = false; teleprompterError = nil
        } catch {
            teleprompterFollow.stop()
            try? sendTeleprompter(type: 3, action: 2, body: ["action": 2, "did": did, "code": 2])
            throw error
        }
    }

    func connect() throws {
        try transport.ensureConnected()
        _ = stateSynchronization.request(generation: transport.currentConnectionGeneration).wait(timeout: .now() + 35)
    }

    func prepareSystemPairing() throws {
        try transport.prepareSystemPairing()
    }

    func synchronizeDeviceState() throws -> [String: Any] {
        try transport.ensureConnected()
        _ = stateSynchronization.request(generation: transport.currentConnectionGeneration, refresh: true).wait(timeout: .now() + 35)
        return stateSynchronization.status
    }

    func interruptDataChannel() {
        transport.interruptDataChannel()
    }

    func suspendConnectionRecovery() {
        transport.suspendRecovery()
    }

    private func connectionSynchronizationSteps() -> [DeviceStateSynchronization.Step] {
        [
            .init(name: "clock", confirmation: "sent", read: { [self] in
                try settings.synchronizeClock()
                return ["sent": true]
            }),
            .init(name: "visibility", confirmation: "sent", read: { [self] in
                try synchronizeAppVisibility(transport.appVisibilityStatus["requestedForeground"] as? Bool ?? true)
                return visibilityStatus
            }),
            .init(name: "recording", confirmation: "read_back", read: { [self] in
                operationLock.lock(); defer { operationLock.unlock() }
                try nativeRecording.queryCurrentStatus()
                let state = try nativeRecording.route(method: "GET", path: "/v1/native-recording", body: [:])?.1 ?? [:]
                return ["activeUUID": state["activeUUID"] ?? NSNull(), "activeState": state["activeState"] ?? NSNull()]
            }),
            .init(name: "status", confirmation: "read_back", read: { [self] in
                try settings.route(method: "GET", path: "/v1/glasses/status", body: [:])?.1 ?? [:]
            }),
            .init(name: "settings", confirmation: "read_back", read: { [self] in
                try settings.route(method: "GET", path: "/v1/glasses/settings", body: [:])?.1 ?? [:]
            }),
            .init(name: "teleprompter", confirmation: "read_back", read: { [self] in
                let state = try synchronizeTeleprompterState()
                return state.filter { ["did", "state", "paused", "pageOffset", "highLightOffset", "totalBytes", "error"].contains($0.key) }
            })
        ]
    }

    func postNotification(title: String, body: String, source: [String: Any] = [:]) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "notificationUID": source["notificationUID"] as? String ?? String(timestamp),
            "appId": source["appId"] as? String ?? "com.openrayneo.bridge",
            "appName": source["appName"] as? String ?? "OpenRayneo Bridge",
            "title": title,
            "subtitle": source["subtitle"] as? String as Any? ?? NSNull(),
            "content": body,
            "timestamp": source["timestamp"] as? String ?? String(timestamp),
            "category": source["category"] as? Int ?? 0,
            "reply": false,
            "type": 1
        ]
        try sendNotification(payload)
    }

    func startTeleprompter(title: String, text: String, speed: Int, documentID requestedID: String? = nil, options: [String: Any] = [:]) throws -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !text.isEmpty else { throw BridgeError(status: 400, message: "text must not be empty") }
        if activeDocumentID != nil { try controlTeleprompter("stop") }
        pendingDocumentID = nil

        let documentID = requestedID ?? Self.uuidV7()
        let content = Data(text.utf8)
        let characterCount = content.count
        let timestamp = Int64(Date().timeIntervalSince1970)
        let timezone = TimeZone.current.secondsFromGMT()
        var settings: [String: Any] = [
            "countdown": 3,
            "scroll": 2,
            "speed": speed,
            "gear": 1,
            "depth": 1,
            "size": 18,
            "width": 492,
            "leading": 4
        ]
        for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
            if let value = options[key] { settings[key] = value }
        }
        let pageOffset = max(0, min(content.count, options["pageOffset"] as? Int ?? 0))
        let highlightOffset = max(pageOffset, min(content.count, options["highLightOffset"] as? Int ?? pageOffset))
        let savedSettings = try JSONDecoder().decode(TeleprompterPlaybackSettings.self, from: JSONSerialization.data(withJSONObject: settings))
        try teleprompterRepository.upsert(did: documentID, title: title, text: text, settings: savedSettings,
            pageOffset: pageOffset, highLightOffset: highlightOffset)

        teleprompterFollow.stop()
        if settings["scroll"] as? Int == 1 {
            try teleprompterFollow.start(did: documentID, text: text, settings: settings)
            teleprompterFollow.seek(byteOffset: highlightOffset)
        }
        var started = false
        defer {
            if !started {
                teleprompterFollow.stop()
                if transport.isConnected { try? sendTeleprompter(type: 6, action: 1, body: ["action": 1, "did": documentID]) }
            }
        }

        var startBody: [String: Any] = settings
        startBody["action"] = 1
        startBody["total"] = characterCount
        startBody["did"] = documentID
        startBody["pageOffset"] = pageOffset
        startBody["highLightOffset"] = highlightOffset
        var item: [String: Any] = [
            "did": documentID,
            "pin": false,
            "title": title,
            "offset": 0,
            "scroll": settings["scroll"] as? Int ?? 2,
            "total": characterCount,
            "timestamp": timestamp,
            "preview": String(text.prefix(80)),
            "timezone": timezone
        ]
        if title.isEmpty { item["title"] = "Untitled" }
        let listBody: [String: Any] = [
            "action": 2,
            "type": 3,
            "total": try teleprompterRepository.listMetadata().count,
            "chunkinfo": ["chunkid": 1, "total_items": 1, "islast": true],
            "items": [item]
        ]
        try sendTeleprompter(type: 1, action: 2, body: listBody)

        let handshakeStarted = Date()
        try sendTeleprompter(type: 2, action: 1, body: startBody)
        let taskID = "task_2_\(Int64(Date().timeIntervalSince1970 * 1000))"
        try sendScriptTransfer(taskID: taskID, documentID: documentID, content: content)
        try waitForTeleprompterAcceptance(type: 2, documentID: documentID, since: handshakeStarted, timeout: 30, transferFinishedAt: Date())
        // Firmware 1.0.5.12 sends its receipt before the 300 ms startup view
        // transition finishes. An immediate play request cannot start its countdown.
        usleep(350_000)

        var transferBody: [String: Any] = settings
        transferBody["action"] = 1
        transferBody["did"] = documentID
        transferBody["total"] = characterCount
        transferBody["pageOffset"] = pageOffset
        transferBody["highLightOffset"] = highlightOffset
        transferBody["code"] = 1
        transferBody["checksum"] = ProtocolCodec.fnv1a32(content)
        let playRequested = Date()
        try sendTeleprompter(type: 3, action: 1, body: transferBody)
        try waitForTeleprompterAcceptance(type: 3, documentID: documentID, since: playRequested, timeout: 15)

        activeDocumentID = documentID
        pendingDocumentID = nil
        lastDocumentID = documentID
        activeDocumentText = text
        activeTeleprompterSettings = settings
        teleprompterPageOffset = pageOffset
        teleprompterHighlightOffset = highlightOffset
        teleprompterPaused = false
        teleprompterError = nil
        started = true
        return documentID
    }

    func controlTeleprompter(_ action: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let documentID = activeDocumentID ?? (action == "stop" ? pendingDocumentID : nil) else {
            throw BridgeError(status: 409, message: "No teleprompter script is active")
        }
        cacheFollowPosition()
        switch action {
        case "pause":
            try sendTeleprompter(type: 4, action: 1, body: [
                "action": 1,
                "did": documentID,
                "offset": 0,
                "code": 1,
                "isCompleted": false
            ])
            teleprompterFollow.setPaused(true)
            teleprompterPaused = true
        case "resume":
            try sendTeleprompter(type: 5, action: 1, body: ["action": 1, "did": documentID])
            teleprompterFollow.setPaused(false)
            teleprompterPaused = false
        case "stop":
            teleprompterFollow.stop()
            try sendTeleprompter(type: 6, action: 1, body: ["action": 1, "did": documentID])
            activeDocumentID = nil
            pendingDocumentID = nil
        default:
            throw BridgeError(status: 404, message: "Unknown teleprompter action")
        }
    }

    func updateTeleprompterSettings(_ settings: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let documentID = activeDocumentID else { throw BridgeError(status: 409, message: "No teleprompter script is active") }
        var body = settings
        body["action"] = 1; body["did"] = documentID
        var nextSettings = activeTeleprompterSettings
        for (key, value) in settings { nextSettings[key] = value }
        if nextSettings["scroll"] as? Int == 1 {
            cacheFollowPosition()
            try teleprompterFollow.start(did: documentID, text: activeDocumentText, settings: nextSettings)
            teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
            teleprompterFollow.setPaused(teleprompterPaused)
        } else { teleprompterFollow.stop() }
        try sendTeleprompter(type: 7, action: 1, body: body)
        activeTeleprompterSettings = nextSettings
    }

    func updateTeleprompterProgress(_ position: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let documentID = activeDocumentID else { throw BridgeError(status: 409, message: "No teleprompter script is active") }
        var body = position
        body["action"] = 1; body["did"] = documentID
        try sendTeleprompter(type: 8, action: 1, body: body)
        if let offset = position["pageOffset"] as? Int { teleprompterPageOffset = offset }
        if let offset = position["highLightOffset"] as? Int { teleprompterHighlightOffset = offset }
        if let offset = position["highLightOffset"] as? Int { teleprompterFollow.seek(byteOffset: offset) }
    }

    func updateTeleprompterLibrary(_ body: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try transport.ensureConnected()
        let items = body["items"] as? [[String: Any]] ?? []
        try sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": body["type"] as? Int ?? 3,
            "total": body["total"] as? Int ?? items.count, "items": items,
            "chunkinfo": ["chunkid": 1, "total_items": items.count, "islast": true]])
    }

    func synchronizeTeleprompterState() throws -> [String: Any] {
        operationLock.lock(); defer { operationLock.unlock() }
        let started = Date()
        try sendTeleprompter(type: 10, action: 1, body: ["action": 1, "checksum": "", "state": NSNull(), "pageOffset": 0, "highLightOffset": 0])
        guard let reply = transport.waitForMessage(timeout: 10, matching: {
            $0.protocolID == 0x14 && $0.messageType == 10 && $0.receivedAt >= started && $0.json?["action"] as? Int == 2
        })?.json else {
            throw BridgeError(status: 504, message: "眼镜未返回提词状态")
        }
        if let code = reply["code"] as? Int, code != 1 {
            throw BridgeError(status: 503, message: "眼镜拒绝提词状态查询，code=\(code)")
        }
        guard let state = reply["state"] as? Int, (1...4).contains(state) else {
            throw BridgeError(status: 502, message: "眼镜返回了无法识别的提词状态")
        }
        cacheFollowPosition()
        if state == 3 {
            teleprompterFollow.stop(); activeDocumentID = nil; pendingDocumentID = nil
            teleprompterPaused = false; teleprompterError = nil
            return teleprompterStatus
        }
        guard let did = reply["did"] as? String, !did.isEmpty,
              let document = try teleprompterRepository.load(did: did) else {
            throw BridgeError(status: 404, message: "眼镜当前稿件不在本地稿件库，无法恢复播放状态")
        }
        let checksum = ProtocolCodec.fnv1a32(Data(document.text.utf8))
        if let remoteChecksum = reply["checksum"] as? String, !remoteChecksum.isEmpty, remoteChecksum != checksum {
            throw BridgeError(status: 409, message: "眼镜稿件与本地正文校验值不同，请重新传输后播放")
        }
        var restoredSettings = document.settings.wireBody
        for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
            if let value = reply[key] { restoredSettings[key] = value }
        }
        let total = document.text.utf8.count
        teleprompterPageOffset = min(total, max(0, reply["pageOffset"] as? Int ?? 0))
        teleprompterHighlightOffset = min(total, max(teleprompterPageOffset, reply["highLightOffset"] as? Int ?? teleprompterPageOffset))
        teleprompterFollow.stop()
        lastDocumentID = did; activeDocumentText = document.text; activeTeleprompterSettings = restoredSettings
        activeDocumentID = state == 4 ? nil : did; pendingDocumentID = state == 4 ? did : nil
        teleprompterPaused = state == 2; teleprompterError = nil
        if state != 4, restoredSettings["scroll"] as? Int == 1 {
            do {
                try teleprompterFollow.start(did: did, text: document.text, settings: restoredSettings)
                teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
                teleprompterFollow.setPaused(teleprompterPaused)
            } catch { teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription }
        }
        return teleprompterStatus
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

    private func waitForTeleprompterAcceptance(type: UInt64, documentID: String, since started: Date, timeout: TimeInterval, transferFinishedAt: Date? = nil) throws {
        guard let reply = transport.waitForMessage(timeout: timeout, matching: {
            guard $0.protocolID == 0x14 && $0.messageType == type && $0.receivedAt >= started &&
                $0.json?["action"] as? Int == 2 && $0.json?["did"] as? String == documentID else { return false }
            if type == 2, $0.json?["code"] as? Int == 1, let transferFinishedAt {
                return $0.receivedAt >= transferFinishedAt
            }
            return true
        })?.json else { throw BridgeError(status: 504, message: "眼镜未确认提词请求 type=\(type)") }
        guard let code = reply["code"] as? Int, code == 1 || (type == 2 && code == 7) else {
            throw BridgeError(status: 503, message: "眼镜拒绝提词请求 type=\(type)，code=\(reply["code"] ?? "missing")")
        }
    }

    private func sendScriptTransfer(taskID: String, documentID: String, content: Data) throws {
        var info = ProtocolCodec.field(1, string: taskID)
        info.append(ProtocolCodec.field(2, string: documentID))
        info.append(ProtocolCodec.field(3, varint: UInt64(content.count)))
        info.append(ProtocolCodec.field(4, string: ProtocolCodec.md5(content)))
        info.append(ProtocolCodec.field(5, varint: 17))
        try transport.send(ProtocolCodec.fileTransferFrame(protobuf: ProtocolCodec.field(1, bytes: info)))

        while true {
            let message = transport.waitForMessage(timeout: 30) {
                guard $0.protocolID == 0x11, let field = ProtocolCodec.firstFieldNumber($0.protobuf),
                      [UInt64(3), 5, 6].contains(field), let payload = ProtocolCodec.nestedBytes($0.protobuf, field: field) else { return false }
                return ProtocolCodec.stringValue(payload, field: 1) == taskID
            }
            guard let message, let field = ProtocolCodec.firstFieldNumber(message.protobuf),
                  let request = ProtocolCodec.nestedBytes(message.protobuf, field: field) else {
                throw BridgeError(status: 504, message: "Glasses script transfer timed out")
            }
            if field == 6 { throw BridgeError(status: 409, message: "Glasses cancelled script transfer") }
            if field == 5 {
                guard (ProtocolCodec.varintValue(request, field: 2) ?? 0) == 0 else {
                    throw BridgeError(status: 503, message: "Glasses rejected script transfer")
                }
                fputs("[RayNeo iO transfer] Glasses confirmed \(content.count) bytes\n", stderr)
                return
            }
            guard let requestedSize = ProtocolCodec.varintValue(request, field: 4) else {
                throw BridgeError(status: 502, message: "Glasses requested a script chunk without its size")
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
        }
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
    private static let maxHeaderBytes = 32_768
    private static let maxBodyBytes = 1_000_000

    private let port: UInt16
    private let token: String
    private let deviceController: BridgeController?
    private let recordSync = RecordSyncController()
    private let agentInput = AgentInputController()
    private let connectionSlots = DispatchSemaphore(value: 16)

    init(port: UInt16, token: String, controller: BridgeController?) {
        self.port = port
        self.token = token
        self.deviceController = controller
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
                self.connectionSlots.wait()
                DispatchQueue.global().async { [weak self] in
                    guard let self else { Darwin.close(clientFD); return }
                    defer { self.connectionSlots.signal() }
                    self.handle(clientFD)
                }
            }
        }
        while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)) }
    }

    private func configureClientSocket(_ clientFD: Int32) {
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        configureClientSocket(clientFD)
        do {
            let request = try readRequest(clientFD)
            let (status, response) = route(request)
            let body = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
            let reason = Self.reasonPhrase(for: status)
            var payload = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            payload.append(body)
            sendAll(clientFD, payload)
        } catch let error as BridgeError {
            writeError(clientFD, status: error.status, message: error.message)
        } catch {
            writeError(clientFD, status: 400, message: error.localizedDescription)
        }
    }

    private func route(_ request: HTTPRequest) -> (Int, [String: Any]) {
        guard Self.isAllowedHostHeader(request.headers["host"]) else {
            return (403, ["error": "forbidden host header"])
        }
        if request.method == "GET", request.path == "/health" {
            return (200, ["ok": true, "bleReady": deviceController?.isBLEReady ?? false, "rfcommConnected": deviceController?.isConnected ?? false])
        }
        guard Self.isValidBearerHeader(request.headers["authorization"], expectedToken: token) else {
            return (401, ["error": "missing or invalid bearer token"])
        }
        do {
            let object = request.body.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:])
            if let response = try recordSync.route(method: request.method, path: request.path, body: object) { return response }
            if let response = try agentInput.route(method: request.method, path: request.path, body: object) { return response }
        } catch let error as BridgeError { return (error.status, ["error": error.message]) }
        catch { return (400, ["error": error.localizedDescription]) }
        guard let controller = deviceController else {
            if request.method == "GET", request.path == "/v1/device" {
                return (200, ["mode": "local-services-only", "rfcommConnected": false, "ble": ["ready": false]])
            }
            return (409, ["error": "当前为本机记录服务模式；请连接眼镜后使用设备接口"])
        }
        if request.method == "GET", request.path == "/v1/device" {
            return (200, controller.diagnostics)
        }
        if request.method == "GET", request.path == "/v1/device/visibility" {
            return (200, controller.visibilityStatus)
        }
        if request.method == "GET", request.path == "/v1/device/synchronization" {
            return (200, controller.synchronizationStatus)
        }
        do {
            let object = request.body.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:])
            let audioStarts: Set<String> = ["/v1/captions/start", "/v1/prompts/start", "/v1/asr/start",
                "/v1/recording/start", "/v1/virtual-mic/start", "/v1/assistant-audio/start", "/v1/lifelog/observe",
                "/v1/native-recording/start", "/v1/teleprompter"]
            if request.method == "POST", audioStarts.contains(request.path), controller.nativeAssistant.status["capturing"] as? Bool == true {
                throw BridgeError(status: 409, message: "请先停止当前原生助手收音。")
            }
            if let response = try controller.settings.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.schedules.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.nativeRecording.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.files.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.networkRelay.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.capabilities.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.maintenance.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.ota.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if request.method == "POST", request.path == "/v1/assistant/native/start",
               (!controller.displays.canStartNativeAssistant || controller.nativeRecording.isRecording || controller.teleprompterStatus["running"] as? Bool == true) {
                throw BridgeError(status: 409, message: "请先结束当前显示或音频会话。")
            }
            if let response = try controller.nativeAssistant.route(method: request.method, path: request.path, body: object) { return response }
            if let response = try controller.assistantRuntime.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.speech.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if request.method == "POST", request.path.hasPrefix("/v1/teleprompter"),
               !["/v1/teleprompter/library", "/v1/teleprompter/check-state"].contains(request.path), controller.displays.isSpeechReserved {
                throw BridgeError(status: 409, message: "Stop the audio session before using the teleprompter")
            }
            if let response = try controller.displays.route(method: request.method, path: request.path, body: object) {
                return response
            }
            switch (request.method, request.path) {
            case ("POST", "/v1/device/visibility"):
                guard let foreground = object["isAppForeground"] as? Bool else {
                    throw BridgeError(status: 400, message: "isAppForeground must be Boolean")
                }
                try controller.synchronizeAppVisibility(foreground)
                return (202, controller.visibilityStatus)
            case ("POST", "/v1/device/connect"):
                try controller.connect()
                return (200, controller.diagnostics)
            case ("POST", "/v1/device/pairing/prepare"):
                try controller.prepareSystemPairing()
                return (200, controller.diagnostics)
            case ("POST", "/v1/device/synchronize"):
                return (200, try controller.synchronizeDeviceState())
            case ("POST", "/v1/device/recover-data-channel"):
                controller.interruptDataChannel()
                return (202, controller.diagnostics)
            case ("POST", "/v1/device/recovery/suspend"):
                controller.suspendConnectionRecovery()
                return (200, controller.diagnostics)
            case ("POST", "/v1/notifications"):
                guard let title = object["title"] as? String, let body = object["body"] as? String else {
                    throw BridgeError(status: 400, message: "title and body are required")
                }
                try controller.postNotification(title: title, body: body, source: object)
                return (202, ["ok": true, "sent": "notification"])
            case ("POST", "/v1/teleprompter"):
                guard let text = object["text"] as? String else {
                    throw BridgeError(status: 400, message: "text is required")
                }
                let title = object["title"] as? String ?? "OpenRayneo"
                let speed = object["speed"] as? Int ?? 120
                let documentID = try controller.startTeleprompter(title: title, text: text, speed: speed, documentID: object["did"] as? String, options: object["settings"] as? [String: Any] ?? [:])
                return (202, ["ok": true, "sent": "teleprompter", "did": documentID])
            case ("GET", "/v1/teleprompter"):
                return (200, controller.teleprompterStatus)
            case ("POST", "/v1/teleprompter/check-state"):
                return (200, try controller.synchronizeTeleprompterState())
            case ("POST", "/v1/teleprompter/library"):
                try controller.updateTeleprompterLibrary(object)
                return (202, ["ok": true, "sent": "library_update"])
            case ("POST", "/v1/teleprompter/settings"):
                try controller.updateTeleprompterSettings(object)
                return (202, ["ok": true, "sent": "settings_update"])
            case ("POST", "/v1/teleprompter/progress"):
                try controller.updateTeleprompterProgress(object)
                return (202, ["ok": true, "sent": "progress_update"])
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

    private static func parseRequestBuffer(_ data: Data) throws -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes {
                throw BridgeError(status: 431, message: "request headers too large")
            }
            return nil
        }
        let headerBytesCount = data.distance(from: data.startIndex, to: boundary.lowerBound)
        guard headerBytesCount <= maxHeaderBytes else {
            throw BridgeError(status: 431, message: "request headers too large")
        }
        let headerText = String(decoding: data[data.startIndex..<boundary.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { throw BridgeError(status: 400, message: "malformed request line") }
        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count >= 2 else { throw BridgeError(status: 400, message: "malformed request line") }
        let rawTarget = String(requestParts[1])
        let components = URLComponents(string: rawTarget)
        let path = components?.path ?? String(rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !path.isEmpty, path.hasPrefix("/") else { throw BridgeError(status: 400, message: "malformed request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw BridgeError(status: 400, message: "malformed header line") }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { throw BridgeError(status: 400, message: "invalid content-length") }
            guard parsed <= maxBodyBytes else { throw BridgeError(status: 413, message: "request body too large") }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let bodyOffset = data.distance(from: data.startIndex, to: boundary.upperBound)
        let requiredBytes = bodyOffset + contentLength
        guard data.count >= requiredBytes else { return nil }

        let bodyStart = data.index(data.startIndex, offsetBy: bodyOffset)
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        var query: [String: Any] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value { query[item.name] = Int(value).map { $0 as Any } ?? value }
        }
        return HTTPRequest(
            method: String(requestParts[0]),
            path: path,
            headers: headers,
            body: contentLength == 0 && !query.isEmpty ? try JSONSerialization.data(withJSONObject: query) : data.subdata(in: bodyStart..<bodyEnd)
        )
    }

    private static func isAllowedHostHeader(_ rawHost: String?) -> Bool {
        guard let rawHost = rawHost?.trimmingCharacters(in: .whitespaces), !rawHost.isEmpty else { return true }
        let lower = rawHost.lowercased()
        if lower.hasPrefix("[::1]") {
            let rest = lower.dropFirst(5)
            return rest.isEmpty || (rest.first == ":" && UInt16(rest.dropFirst()) != nil)
        }
        let parts = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard UInt16(parts[1]) != nil else { return false }
        }
        let host = String(parts[0])
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func isValidBearerHeader(_ header: String?, expectedToken: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let candidate = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(expectedToken.utf8)
        guard !expected.isEmpty else { return false }
        var diff = candidate.count ^ expected.count
        let count = max(candidate.count, expected.count)
        for index in 0..<count {
            let lhs = index < candidate.count ? candidate[index] : 0
            let rhs = index < expected.count ? expected[index] : 0
            diff |= Int(lhs ^ rhs)
        }
        return diff == 0
    }

    private func readRequest(_ fd: Int32) throws -> HTTPRequest {
        let maxReadLimit = Self.maxHeaderBytes + Self.maxBodyBytes + 4096
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maxReadLimit {
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if received < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw BridgeError(status: 408, message: "request timed out")
                }
                throw BridgeError(status: 400, message: "socket read failed")
            }
            if received == 0 { break }
            data.append(contentsOf: buffer.prefix(received))
            if let request = try Self.parseRequestBuffer(data) { return request }
        }
        if let request = try Self.parseRequestBuffer(data) { return request }
        throw BridgeError(status: 400, message: data.isEmpty ? "empty request" : "incomplete HTTP request")
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < rawBuffer.count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), rawBuffer.count - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func writeError(_ fd: Int32, status: Int, message: String) {
        let response = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = Self.reasonPhrase(for: status)
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(response.count)\r\n\r\n".utf8)
        bytes.append(response)
        sendAll(fd, bytes)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Internal Server Error"
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

if let index = CommandLine.arguments.firstIndex(of: "--decode-official-audio") {
    guard CommandLine.arguments.indices.contains(index + 2) else {
        fputs("Usage: openrayneo-bridge --decode-official-audio SOURCE-AUDIO OUTPUT-DIRECTORY\n", stderr); exit(1)
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
    Task { @MainActor in
        do {
            let audio = try await OfficialCloudAudioImport.prepare(source: source, directory: directory) { _ in }
            let result: [String: Any] = ["audioPath": audio.audioURL.path, "duration": audio.duration,
                "channelCount": audio.channelCount, "containerDuration": audio.containerDuration as Any? ?? NSNull(), "cloudRequests": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); exit(0)
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    RunLoop.main.run(); exit(0)
}

if CommandLine.arguments.contains("--official-upload-status") {
    MainActor.assumeIsolated {
        let model = OfficialRecordingUploadModel.shared
        model.background.accountChanged()
        let cloud = OfficialCloudAudioModel.shared
        let jobs: [[String: Any]] = model.records.values.sorted { $0.taskID < $1.taskID }.map {
            ["entryID": $0.entryID.uuidString, "taskID": $0.taskID, "phase": $0.phase,
             "paused": $0.paused == true, "automaticallyResume": $0.automaticallyResume == true,
             "transcriptionState": $0.transcriptionState, "pendingUpload": $0.needsUpload,
             "pendingResult": $0.needsResult]
        }
        let output: [String: Any] = ["configured": model.configured, "jobs": jobs,
            "automaticQueueEnabled": model.configured && model.background.policy.resumeQueued,
            "automaticNewNativeEnabled": model.configured && model.background.policy.newNativeRecordings,
            "cloudAudioConfigured": cloud.configured, "downloadRecords": cloud.records.count,
            "automaticCloudSyncEnabled": cloud.configured && cloud.automaticallyDownload,
            "runtimeStarted": false, "networkRequests": false]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--prepare-official-audio") {
    guard CommandLine.arguments.indices.contains(index + 2), let entryID = UUID(uuidString: CommandLine.arguments[index + 1]) else {
        fputs("Usage: openrayneo-bridge --prepare-official-audio LIBRARY-ENTRY-UUID OUTPUT-DIRECTORY\n", stderr)
        exit(1)
    }
    let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
    Task { @MainActor in
        do {
            let indexURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenRayneo/RecordingLibrary/index.json")
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([RecordingLibraryEntry].self,
                from: JSONSerialization.data(withJSONObject: root?["entries"] ?? []))
            guard let entry = entries.first(where: { $0.id == entryID }) else {
                throw OfficialMemoryFailure(message: "录音库中没有这个条目 ID。")
            }
            let audio = try await OfficialRecordingUploadAudio.prepare(entry: entry, destinationDirectory: destination) { _ in }
            let output: [String: Any] = ["entryID": entryID.uuidString, "filePath": audio.fileURL.path,
                "durationMilliseconds": audio.durationMilliseconds, "channelCount": audio.channelCount, "uploaded": false]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    RunLoop.main.run(); exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--official-device-identity") {
    guard CommandLine.arguments.indices.contains(index + 1),
          let mac = OfficialCloudDeviceRepository.Record.normalizedMAC(CommandLine.arguments[index + 1]) else {
        fputs("Usage: openrayneo-bridge --official-device-identity AA-BB-CC-DD-EE-FF\n", stderr)
        exit(1)
    }
    let identity = OfficialCloudDeviceRepository.Record.nativeID(normalizedMAC: mac)
    let result = ["macAddr": mac, "localDeviceID": identity, "cloudMFISerialNumber": identity]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--official-email-agreements") {
    guard CommandLine.arguments.indices.contains(index + 1) else {
        fputs("Usage: openrayneo-bridge --official-email-agreements COUNTRY-CODE\n", stderr); exit(1)
    }
    let country = CommandLine.arguments[index + 1]
    Task {
        do {
            let agreements = try await OfficialEmailLoginService().agreements(country: country)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(agreements), as: UTF8.self)); exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    RunLoop.main.run(); exit(0)
}

if CommandLine.arguments.contains("--official-agreements") {
    Task {
        do {
            let agreements = try await OfficialPhoneLoginService().agreements()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(agreements)
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

if let commandIndex = CommandLine.arguments.firstIndex(where: { $0 == "--pair" || $0 == "--pairing-status" || $0 == "--unpair" }) {
    guard CommandLine.arguments.indices.contains(commandIndex + 1) else {
        fputs("Usage: openrayneo-bridge --unpair|--pair|--pairing-status AA-BB-CC-DD-EE-FF\n", stderr)
        exit(1)
    }
    let address = CommandLine.arguments[commandIndex + 1]
    if CommandLine.arguments[commandIndex] == "--unpair" { exit(runUnpairingCommand(address: address)) }
    exit(runPairingCommand(address: address, statusOnly: CommandLine.arguments[commandIndex] == "--pairing-status"))
}

if !CommandLine.arguments.contains("--headless"),
   Bundle.main.bundlePath.hasSuffix(".app") || CommandLine.arguments.contains("--gui") {
    MainActor.assumeIsolated { runDesktopApplication() }
}

private let localServicesOnly = CommandLine.arguments.contains("--local-services-only")
private let address = localServicesOnly ? nil : resolveRayneoAddress()
if !localServicesOnly, address == nil {
    fputs("Pair one RayNeo iO with this Mac, set RAYNEO_ADDRESS, or use --local-services-only for Agent records without glasses.\n", stderr); exit(1)
}
let token = ProcessInfo.processInfo.environment["OPENRAYNEO_API_TOKEN"] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
let port = UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765
private let controller = address.map { BridgeController(address: $0) }
private let server = LocalHTTPServer(port: port, token: token, controller: controller)
print("API token: \(token)")
do {
    try server.run()
} catch {
    fputs("OpenRayneo Bridge failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
