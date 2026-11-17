// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
final class FileTransfersModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var path = ""
    @Published var largeCore = false
    @Published var transfers: [[String: Any]] = []
    @Published var notice = "眼镜发送的文件会自动接收并保存。"
    @Published var directory = ""
    @Published var busy = false
    init(bridge: DesktopBridge) { self.bridge = bridge }
    var connected: Bool { bridge?.connected == true }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { path = panel.url?.path ?? "" }
    }
    func send() async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await bridge.request("/v1/files/send", body: ["path": path, "core": largeCore ? "large" : "small"])
            notice = "文件信息已发送，等待眼镜请求分块。"
            await refresh()
        } catch { notice = error.localizedDescription }
    }
    func cancel(_ id: String) async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await bridge.request("/v1/files/cancel", body: ["uuid": id])
            if result["cancellationOrigin"] as? String == "local" {
                notice = result["cancelNotificationSent"] as? Bool == true ?
                    "本地任务已取消，已发出取消通知；远端是否停止尚未确认。" : "本地任务已取消，未向眼镜发出取消通知。"
            }
            await refresh()
        }
        catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard let bridge, bridge.serviceRunning else { return }
        do {
            let result = try await bridge.request("/v1/files", method: "GET")
            transfers = result["transfers"] as? [[String: Any]] ?? []
            directory = result["receiveDirectory"] as? String ?? ""
        } catch { notice = error.localizedDescription }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

@MainActor
struct FileTransfersPanel: View {
    @ObservedObject var model: FileTransfersModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { TextField("文件路径", text: $model.path); Button("选择文件") { model.chooseFile() } }
            HStack {
                Toggle("发送到 LargeCore（0x12）", isOn: $model.largeCore)
                if !model.largeCore { Text("当前目标：SmallCore（0x11）").font(.caption).foregroundStyle(.secondary) }
                Button("发送文件") { Task { await model.send() } }.disabled(!model.connected || model.busy || model.path.isEmpty)
            }
            if !model.connected { Text("眼镜未连接，仍可查看和取消本地任务。 ").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(model.transfers.enumerated()), id: \.offset) { _, transfer in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(transfer["fileName"] as? String ?? "文件")
                        Spacer()
                        Text(stateLabel(transfer))
                        Button("查看") { model.reveal(transfer["path"] as? String ?? "") }
                        if ["waiting", "transferring"].contains(transfer["state"] as? String ?? "") {
                            Button("取消") { Task { await model.cancel(transfer["uuid"] as? String ?? "") } }.disabled(model.busy)
                        }
                    }
                    ProgressView(value: transfer["progress"] as? Double ?? 0)
                    if let error = transfer["error"] as? String { Text(error).foregroundStyle(.orange).font(.caption) }
                }.padding(.vertical, 6)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private func stateLabel(_ transfer: [String: Any]) -> String {
        switch transfer["state"] as? String ?? "" {
        case "waiting": return "等待接收方请求"
        case "transferring": return "传输中"
        case "completed": return transfer["direction"] as? String == "receive" ? "已接收并校验" : "接收方已确认完成"
        case "failed": return "失败"
        case "cancelled": return transfer["cancellationOrigin"] as? String == "peer" ? "眼镜取消" : "本地已取消"
        default: return transfer["state"] as? String ?? ""
        }
    }
}
