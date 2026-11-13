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
    private let streamDecoder = ProtocolStreamDecoder()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var sendCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var classicAddressBytes = Data()
    private var localDeviceID = Data()
    private var pairingSequence: UInt16 = 0
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
            "bluetoothAuthorization": CBManager.authorization.rawValue,
            "scanning": scanStarted, "discoveredPeripheralCount": observedPeripherals.count,
            "pairingState": pairingState.map { Int($0) } as Any? ?? NSNull(),
            "lastError": failure as Any? ?? NSNull()
        ]
    }

    func waitUntilReady(timeout: TimeInterval) throws {
        performOnMain {
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
        if Thread.isMainThread {
            while true {
                condition.lock()
                let done = ready || failure != nil
                if !done && Date() >= deadline {
                    failure = "RayNeo iO BLE timed out at \(phase); observed \(observedPeripherals.count) BLE peripherals"
                }
                let finished = ready || failure != nil
                condition.unlock()
                if finished { break }
                _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
            }
        } else {
            condition.lock()
            while !ready && failure == nil {
                if !condition.wait(until: deadline), !ready, failure == nil {
                    failure = "RayNeo iO BLE timed out at \(phase); observed \(observedPeripherals.count) BLE peripherals"
                }
            }
            condition.unlock()
        }

        condition.lock()
        let currentFailure = failure
        condition.unlock()
        if let currentFailure {
            performOnMain {
                self.clearConnection()
                self.setPhase("failed")
            }
            throw BridgeError(status: 503, message: currentFailure)
        }
    }

    private func performOnMain(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
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
            processPairingFrames(peripheral, chunk: value)
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
        streamDecoder.reset()
        condition.lock()
        peripheral = nil
        sendCharacteristic = nil
        receiveCharacteristic = nil
        ready = false
        scanRequested = false
        scanStarted = false
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

    private func processPairingFrames(_ peripheral: CBPeripheral, chunk: Data) {
        let frames = streamDecoder.append(chunk)
        for frame in frames {
            if frame.requiresAcknowledgement, let sendCharacteristic {
                let ack = ProtocolCodec.acknowledgementFrame(protocolID: frame.protocolID, sequence: frame.sequence)
                writeBLEFrame(ack, to: peripheral, characteristic: sendCharacteristic)
            }
            guard !frame.isAcknowledgement,
                  frame.protocolID == 0x10,
                  let (command, body, fields) = ProtocolCodec.pairingCommand(frame.payload) else {
                continue
            }
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
            writeBLEFrame(frame, to: peripheral, characteristic: sendCharacteristic)
        } catch {
            setFailure("RayNeo iO pairing command exceeds the protocol frame size")
            return
        }
        trace("Sent connection-pairing command \(command)")
    }

    private func writeBLEFrame(_ frame: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            peripheral.writeValue(frame.subdata(in: offset..<end), for: characteristic, type: .withoutResponse)
            offset = end
        }
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
