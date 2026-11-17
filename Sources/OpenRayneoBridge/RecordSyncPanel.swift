// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct RecordSyncPanel: View {
    @ObservedObject var bridge: DesktopBridge
    @State private var peerURL = ""
    @State private var token = ""
    @State private var enabled = true
    @State private var resetCursor = false
    @State private var message = "配置手机独立同步端口后，同网可达时自动补齐；本机设备控制接口保持回环监听。"
    @State private var busy = false

    var body: some View {
        GroupBox("手机记录相遇同步") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("手机同步地址，例如 http://192.168.1.10:8767", text: $peerURL)
                SecureField("手机同步专用令牌", text: $token)
                Toggle("每 15 秒自动尝试同步", isOn: $enabled)
                Toggle("重新从头补齐（更换地址时开启，已有副本保留）", isOn: $resetCursor)
                HStack {
                    Button("保存连接配置") { save() }.disabled(!bridge.serviceRunning || busy || peerURL.isEmpty)
                    Button("立即同步并查看状态") { refresh(sync: true) }.disabled(!bridge.serviceRunning || busy)
                    Button("刷新状态") { refresh(sync: false) }.disabled(!bridge.serviceRunning || busy)
                }
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("默认同步时间、转写、总结和人物关联；音频由 Agent 按需获取。副本在“回忆与项目”查看；Agent 使用 /v1/records/query 与 /v1/records/derived 读写关联分析、标签和笔记。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }.task { if bridge.serviceRunning { refresh(sync: false) } }
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var body: [String: Any] = ["peerURL": peerURL, "enabled": enabled, "resetCursor": resetCursor]
                if !token.isEmpty { body["token"] = token }
                let status = try await bridge.request("/v1/records/sync", method: "PATCH", body: body)
                token = ""; resetCursor = false; show(status)
            } catch { message = error.localizedDescription }
        }
    }
    private func refresh(sync: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let status = try await bridge.request("/v1/records/sync", method: sync ? "POST" : "GET")
                peerURL = status["peerURL"] as? String ?? ""; enabled = status["enabled"] as? Bool ?? false
                show(status)
            } catch { message = error.localizedDescription }
        }
    }
    private func show(_ status: [String: Any]) {
        message = "副本 \(status["recordCount"] as? Int ?? 0) 条 · 待回写 \(status["pendingCount"] as? Int ?? 0) 条 · 游标 \(status["cursor"] as? Int ?? 0)"
        if let error = status["error"] as? String { message += " · \(error)" }
    }
}
