// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOBluetooth
import ObjectiveC
import Darwin

/// Runs separately from both the desktop UI and the Bluetooth transport.
private final class CommandLinePairing: NSObject, IOBluetoothDevicePairDelegate {
    private let pair: IOBluetoothDevicePair
    private let stateLock = NSLock()
    private var result: IOReturn?
    private var needsInteraction = false
    private let desktop = ProcessInfo.processInfo.environment["OPENRAYNEO_PAIRING_UI"] == "1"
    let device: IOBluetoothDevice

    init?(device: IOBluetoothDevice) {
        guard let pair = IOBluetoothDevicePair(device: device) else { return nil }
        self.device = device
        self.pair = pair
        super.init()
        pair.delegate = self
    }

    private var finished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return result != nil || needsInteraction
    }

    func run() -> Int32 {
        // Match the standalone helper, including cleanup after successful pairing.
        defer { pair.stop(); pair.delegate = nil }
        signal(SIGTERM, SIG_IGN)
        let cancellation = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        cancellation.setEventHandler { self.pair.stop(); exit(130) }
        cancellation.resume()
        defer { cancellation.cancel() }
        print("Starting direct system pairing…")
        let started = pair.start()
        guard started == kIOReturnSuccess else {
            print("Pairing could not start: \(started)")
            return 1
        }
        let deadline = Date().addingTimeInterval(25)
        while !finished, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        stateLock.lock()
        let result = self.result
        let needsInteraction = self.needsInteraction
        stateLock.unlock()
        if needsInteraction { return 2 }
        guard let result else { print("Pairing timed out."); return 1 }
        print("Pairing result: \(result); isPaired: \(device.isPaired())")
        return result == kIOReturnSuccess && device.isPaired() ? 0 : 1
    }

    func devicePairingStarted(_ sender: Any!) { print("Pairing started") }
    func devicePairingConnecting(_ sender: Any!) { print("Connecting to device") }
    func devicePairingConnected(_ sender: Any!) { print("Baseband connected") }
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        stateLock.lock()
        result = error
        stateLock.unlock()
    }

    private func emit(_ event: String, value: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["event": event, "value": value]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private func readReply(_ apply: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let reply = readLine() ?? ""
            DispatchQueue.main.async { if !self.finished { apply(reply) } }
        }
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        let value = String(format: "%06u", numericValue)
        if desktop { emit("confirmation", value: value) }
        else {
            guard isatty(STDIN_FILENO) != 0 else {
                requireInteraction("Numeric comparison required. Run --pair in an interactive terminal.")
                return
            }
            print("Compare with the glasses: \(value)")
            print("Enter yes only if both numbers match; otherwise enter no:")
        }
        readReply { self.pair.replyUserConfirmation($0.lowercased() == "yes") }
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard desktop else {
            requireInteraction("PIN entry requires the desktop pairing assistant.")
            return
        }
        emit("pin", value: "")
        readReply { reply in
            let bytes = Array(reply.utf8)
            guard (1...16).contains(bytes.count) else {
                self.requireInteraction("PIN entry cancelled or invalid.")
                return
            }
            var pin = BluetoothPINCode()
            withUnsafeMutableBytes(of: &pin) { $0.copyBytes(from: bytes) }
            self.pair.replyPINCode(bytes.count, pinCode: &pin)
        }
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        let value = String(format: "%06u", passkey)
        if desktop { emit("passkey", value: value) }
        else { print("Enter this passkey on the glasses: \(value)") }
    }

    private func requireInteraction(_ message: String) {
        print(message)
        stateLock.lock()
        needsInteraction = true
        stateLock.unlock()
    }
}

func runPairingCommand(address: String, statusOnly: Bool) -> Int32 {
    setbuf(stdout, nil)
    guard let device = IOBluetoothDevice(addressString: address) else {
        fputs("Invalid Bluetooth device address.\n", stderr)
        return 1
    }
    if statusOnly {
        let state: [String: Any] = ["isPaired": device.isPaired(), "isConnected": device.isConnected(), "linkType": device.getLinkType(), "encrypted": device.getEncryptionMode() != 0]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        return 0
    }
    guard !device.isPaired(), !device.isConnected() else {
        fputs("Pairing requires an unpaired, disconnected device. Run --unpair, then verify --pairing-status first.\n", stderr)
        return 1
    }
    guard let command = CommandLinePairing(device: device) else { return 1 }
    return command.run()
}

/// Removes only the requested Mac bond; this does not reset the glasses.
func runUnpairingCommand(address: String) -> Int32 {
    setbuf(stdout, nil)
    guard let device = IOBluetoothDevice(addressString: address) else {
        fputs("Invalid Bluetooth device address.\n", stderr)
        return 1
    }
    // IOBluetooth does not expose unpairing in its public SDK. This native selector
    // is also used by blueutil's experimental --unpair implementation.
    let selector = NSSelectorFromString("remove")
    guard device.responds(to: selector),
          let method = class_getInstanceMethod(IOBluetoothDevice.self, selector),
          method_getNumberOfArguments(method) == 2 else {
        fputs("Native unpairing is unavailable. Forget the target device in macOS Bluetooth settings.\n", stderr)
        return 2
    }
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == "v" else {
        fputs("Unsupported native unpairing signature. Use macOS Bluetooth settings.\n", stderr)
        return 2
    }
    typealias RemoveDevice = @convention(c) (AnyObject, Selector) -> Void
    let remove = unsafeBitCast(method_getImplementation(method), to: RemoveDevice.self)
    remove(device, selector)
    let deadline = Date().addingTimeInterval(10)
    repeat {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        if !device.isPaired(), !device.isConnected() {
            print("Mac pairing removed; device disconnected. Verify from a new process before pairing.")
            return 0
        }
    } while Date() < deadline
    fputs("Mac pairing removal did not finish. No new pairing was started.\n", stderr)
    return 1
}
