// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreBluetooth
import IOBluetooth
import Foundation

enum RayneoAdvertisement {
    static func classicAddress(_ advertisement: [String: Any]) -> String? {
        // Official APK S3.C0912a: company 0x5716, model 0x06, six address bytes.
        // CoreBluetooth includes the little-endian company ID in manufacturer data.
        guard let data = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 9, Array(data.prefix(3)) == [0x16, 0x57, 0x06] else { return nil }
        return data.dropFirst(3).prefix(6).map { String(format: "%02X", $0) }.joined(separator: "-")
    }
}

private struct PairingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension PairedGlasses {
    static func systemInventory() async throws -> [PairedGlasses] {
        // IOBluetooth pairedDevices() can block indefinitely in GUI processes.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "10"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let controllers = report["SPBluetoothDataType"] as? [[String: Any]] else {
                throw PairingError(message: "读取系统蓝牙设备失败，请打开蓝牙设置后重试。")
            }
            var result: [PairedGlasses] = []
            for controller in controllers {
                for key in ["device_connected", "device_not_connected"] {
                    for entry in controller[key] as? [[String: Any]] ?? [] {
                        for (name, value) in entry where name.localizedCaseInsensitiveContains("RayNeo iO") {
                            if let info = value as? [String: Any], let address = info["device_address"] as? String {
                                let normalized = address.replacingOccurrences(of: ":", with: "-")
                                if !result.contains(where: { $0.id == normalized }) { result.append(PairedGlasses(id: normalized, name: name)) }
                            }
                        }
                    }
                }
            }
            return result
        }.value
    }
}

/// Discovery stays in the UI; native pairing and status checks run in separate processes.
@MainActor
final class BluetoothPairing: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var candidates: [PairedGlasses] = []
    private var helper: Process?
    private var cancelled = false
    private var scanning = false
    private var alert: NSAlert?

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func pair(progress: (String, String) -> Void) async throws -> PairedGlasses? {
        cancelled = false
        candidates = []
        defer { stopDiscovery(); dismissAlert() }
        let target: PairedGlasses
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        progress("等待蓝牙就绪", "如 macOS 询问蓝牙权限，请允许 OpenRayneo。")
        let deadline = Date().addingTimeInterval(90)
        while central?.state != .poweredOn {
            try checkState()
            guard Date() < deadline else { throw PairingError(message: "等待系统蓝牙超时，请处理权限弹窗后重试。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        progress("正在寻找眼镜", "请保持眼镜处于配对模式、手机蓝牙关闭。")
        scanning = true
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let scanStart = Date()
        while Date().timeIntervalSince(scanStart) < (candidates.isEmpty ? 20 : 8) {
            try checkState()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stopDiscovery()
        guard !candidates.isEmpty else { throw PairingError(message: "未发现眼镜广播。请退出后重新进入眼镜配对模式，再点一次添加；不要连续重试。") }
        if candidates.count == 1 { target = candidates[0] }
        else {
            let prompt = NSAlert()
            prompt.messageText = "选择要配对的眼镜"
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
            picker.addItems(withTitles: candidates.map { "\($0.name) · \($0.id.suffix(5))" })
            prompt.accessoryView = picker
            prompt.addButton(withTitle: "继续")
            prompt.addButton(withTitle: "取消")
            guard await show(prompt) == .alertFirstButtonReturn else { return nil }
            target = candidates[picker.indexOfSelectedItem]
        }
        try checkState()
        progress("清除 Mac 旧配对", "正在移除 \(target.name) 的本地配对记录。请保持眼镜当前状态，不要同时操作系统蓝牙设置。")
        _ = try await runHelper(["--unpair", target.id], timeout: 15)
        progress("确认配对已清除", "正在独立确认眼镜在 Mac 上已未配对、未连接。")
        let clean = try await pairingState(target.id)
        guard !clean.paired, !clean.connected else {
            throw PairingError(message: "Mac 仍保留配对或连接，已停止，未发起新配对。请在系统蓝牙设置中忽略目标眼镜后再试。")
        }
        progress("正在配对眼镜", "正在与 \(target.name) 建立新配对。请勿同时在系统设置中忽略设备或重新进入眼镜配对模式。")
        _ = try await runHelper(["--pair", target.id], timeout: 35)
        progress("确认系统配对", "配对助手已退出，正在独立确认配对记录。")
        guard try await pairingState(target.id).paired else {
            throw PairingError(message: "配对助手已结束，但 Mac 没有保存配对。请停止操作系统蓝牙设置，检查眼镜状态后再试。")
        }
        try checkState()
        return target
    }

    private func pairingState(_ address: String) async throws -> (paired: Bool, connected: Bool) {
        let output = try await runHelper(["--pairing-status", address], timeout: 10)
        guard let state = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let paired = state["isPaired"] as? Bool,
              let connected = state["isConnected"] as? Bool else {
            throw PairingError(message: "无法读取系统配对状态。")
        }
        return (paired, connected)
    }

    private func runHelper(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["OPENRAYNEO_PAIRING_UI"] = "1"
        child.environment = environment
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardError = output
        child.standardInput = input
        try child.run()
        helper = child
        let reader = Task.detached { [self] () throws -> String in
            var pending = Data()
            var text = ""
            while let data = try output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    text += line + "\n"
                    await handleLine(line, child: child, input: input.fileHandleForWriting)
                }
            }
            return text + String(decoding: pending, as: UTF8.self)
        }
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while child.isRunning {
                try checkState()
                guard Date() < deadline else { throw PairingError(message: "配对助手超时，已停止；请检查眼镜状态后再试。") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            dismissAlert()
            let text = try await reader.value
            helper = nil
            try checkState()
            guard child.terminationStatus == 0 else {
                throw PairingError(message: "配对未完成（\(child.terminationStatus)）。\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text
        } catch {
            dismissAlert()
            if child.isRunning { child.terminate() }
            await Task.detached {
                for _ in 0..<20 where child.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }.value
            _ = try? await reader.value
            helper = nil
            throw error
        }
    }

    private func handleLine(_ line: String, child: Process, input: FileHandle) async {
        guard !cancelled, helper === child, child.isRunning,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let event = object["event"] else { return }
        let prompt = NSAlert()
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        switch event {
        case "confirmation":
            prompt.messageText = "核对眼镜配对数字"
            prompt.informativeText = "仅当眼镜上的数字与下方一致时，点击配对。"
            prompt.accessoryView = NSTextField(labelWithString: object["value"] ?? "")
            prompt.addButton(withTitle: "配对")
        case "pin":
            prompt.messageText = "输入眼镜蓝牙 PIN"
            prompt.informativeText = "请输入眼镜提示的 PIN。"
            prompt.accessoryView = field
            prompt.addButton(withTitle: "提交")
        case "passkey":
            prompt.messageText = "在眼镜上输入配对码"
            prompt.accessoryView = NSTextField(labelWithString: object["value"] ?? "")
            prompt.addButton(withTitle: "完成")
        default: return
        }
        prompt.addButton(withTitle: "取消")
        let accepted = await show(prompt) == .alertFirstButtonReturn
        guard !cancelled, helper === child, child.isRunning else { return }
        if !accepted { cancel(); return }
        let reply = event == "pin" ? field.stringValue : "yes"
        if event != "passkey" { try? input.write(contentsOf: Data((reply + "\n").utf8)) }
    }

    private func checkState() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        switch central?.state {
        case .unauthorized: throw PairingError(message: "请在系统隐私设置中允许 OpenRayneo 访问蓝牙。")
        case .poweredOff: throw PairingError(message: "Mac 蓝牙已关闭，请打开蓝牙后重试。")
        case .unsupported: throw PairingError(message: "这台 Mac 不支持所需的蓝牙连接。")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "RayNeo iO"
        guard let address = RayneoAdvertisement.classicAddress(advertisementData) else { return }
        if !candidates.contains(where: { $0.id == address }) { candidates.append(PairedGlasses(id: address, name: name)) }
    }

    private func show(_ prompt: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return .abort }
        alert = prompt
        defer { alert = nil }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            prompt.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func dismissAlert() {
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
    }

    func cancel() {
        cancelled = true
        stopDiscovery()
        dismissAlert()
        if helper?.isRunning == true { helper?.terminate() }
    }

    private func stopDiscovery() {
        scanning = false
        central?.stopScan()
        central?.delegate = nil
        central = nil
    }
}
