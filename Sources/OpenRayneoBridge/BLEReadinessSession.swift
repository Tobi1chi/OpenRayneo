// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreBluetooth
import CryptoKit
import Foundation
import IOBluetooth

final class BLEReadinessSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
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
                if receiveBuffer.count > maxFrameBytes || ProtocolCodec.containsCompleteValidFrame(in: receiveBuffer) {
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

