// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
final class MaintenanceModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var busy = false
    @Published var firmware = "尚未读取固件信息"
    @Published var logStatus = "尚未请求设备日志"
    @Published var notice = ""
    @Published var confirmFactoryReset = false
    init(bridge: DesktopBridge) { self.bridge = bridge }
    var connected: Bool { bridge?.connected == true }
    func readFirmware() async {
        guard let bridge else { return }
        busy = true; defer { busy = false }
        do { updateFirmware(try await bridge.request("/v1/firmware", method: "GET")) }
        catch { notice = error.localizedDescription }
    }
    func requestLogs() async {
        guard let bridge else { return }
        busy = true; defer { busy = false }
        do { _ = try await bridge.request("/v1/logs/request"); await refresh() }
        catch { notice = error.localizedDescription }
    }
    func factoryReset() async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await bridge.prepareNativeRecording()
            let result = try await bridge.request("/v1/glasses/factory-reset", body: [:])
            if result["accepted"] as? Bool == true {
                _ = await bridge.shutdown(sendDeviceCommands: false)
                notice = "眼镜已确认恢复出厂请求，连接已关闭。设备重启后请重新配对。"
            }
        } catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard let bridge, connected else { return }
        do {
            let result = try await bridge.request("/v1/maintenance", method: "GET")
            if let value = result["firmware"] as? [String: Any], !value.isEmpty { updateFirmware(value) }
            if let logs = result["logs"] as? [String: Any], let payload = logs["payload"] as? [String: Any] {
                let state = payload["value"] as? Int ?? 4
                logStatus = [0: "日志已准备，文件正在传输", 1: "眼镜正在压缩日志", 2: "眼镜空间不足", 3: "日志压缩失败", 4: "日志获取失败"][state] ?? "状态 \(state)"
                if let id = payload["data"] as? String, !id.isEmpty { logStatus += "\n传输 ID：\(id)" }
            }
        } catch { notice = error.localizedDescription }
    }
    private func updateFirmware(_ value: [String: Any]) {
        firmware = "\(value["OsVersion"] as? String ?? "未知版本")\nOTA 状态：\(value["OtaValidationState"] as? String ?? "未知")\n支持包类型：\((value["PackageTypes"] as? [String] ?? []).joined(separator: ", "))"
    }
}

@MainActor
struct MaintenancePanel: View {
    @ObservedObject var model: MaintenanceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            GroupBox("固件") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.firmware).textSelection(.enabled)
                    Button("读取固件信息") { Task { await model.readFirmware() } }.disabled(!model.connected || model.busy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("设备日志") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.logStatus).textSelection(.enabled)
                    Button("获取眼镜日志") { Task { await model.requestLogs() } }.disabled(!model.connected || model.busy)
                    Text("完成的日志文件可在“文件传输”页打开。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("恢复出厂设置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("清除眼镜内容并恢复设备设置。Mac 上已保存的文件保留。此 Beta 不管理官方云端绑定。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("恢复眼镜出厂设置…", role: .destructive) { model.confirmFactoryReset = true }
                        .disabled(!model.connected || model.busy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .confirmationDialog("清除眼镜内容并恢复出厂设置？", isPresented: $model.confirmFactoryReset) {
            Button("清除眼镜并恢复出厂设置", role: .destructive) { Task { await model.factoryReset() } }
        } message: {
            Text("眼镜内的录音、待办、日程及设备设置将被清除。请先同步需要保留的内容。此操作无法通过 Mac 撤销。")
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
}
