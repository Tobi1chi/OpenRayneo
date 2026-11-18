// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct AgentWorkspacePanel: View {
    @ObservedObject var bridge: DesktopBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LensSurface(title: "OPENRAYNEO · LOCAL AGENT", live: bridge.connected) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("让 Agent 看见、听见，并把结果送到眼前。")
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.2)
                    Text("连接眼镜后，本机 Agent 可以通过带令牌的 HTTP API 控制显示、收音、待办和设备设置。收音按需开启，断开连接会停止服务。")
                        .font(.callout).foregroundStyle(Token.hudSecondaryForeground).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 6)
            }
            HStack(spacing: 14) {
                status("眼镜", value: bridge.connected ? "已连接" : "等待连接", icon: "eyeglasses", live: bridge.connected)
                status("本机 API", value: bridge.apiReady ? "可用" : "未就绪", icon: "terminal", live: bridge.apiReady)
                status("当前会话", value: bridge.activeSession?.title ?? "空闲", icon: "rectangle.on.rectangle", live: bridge.activeSession != nil)
            }
            GroupBox("接入你的 Agent") {
                VStack(alignment: .leading, spacing: 12) {
                    if bridge.serviceRunning {
                        Text(bridge.apiAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("复制 API 地址") { bridge.copyAPIAddress() }
                            Button("复制令牌") { bridge.copyAPIToken() }
                            Button("复制调用示例") { bridge.copyAPIExample() }
                            Button("检查服务") { bridge.checkAPI() }.disabled(bridge.busy)
                        }
                        Button("复制 Agent 接入配置（含令牌）", systemImage: "doc.on.doc") { bridge.copyAgentConfiguration() }
                        Text("工具包随应用提供，不需要克隆仓库；把接入配置交给本机 Agent 即可读取使用说明。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(bridge.apiExample).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("连接眼镜后自动准备设备服务；也可先启动本机记录 API。")
                        Button("连接并启动服务") { bridge.connect() }
                            .buttonStyle(.borderedProminent).disabled(bridge.selectedAddress.isEmpty || bridge.busy)
                        Button("仅启动记录与 Agent 服务") { bridge.startLocalServices() }.disabled(bridge.busy)
                    }
                    Text("接口仅监听本机。令牌在连接服务重启后可能更新；将地址和令牌提供给你信任的本地 Agent。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("显示与收音") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("开启双麦实时提示", systemImage: "mic") { bridge.enterMicrophoneMode() }
                            .disabled(!bridge.connected || bridge.busy)
                        Button("清空提示屏幕", systemImage: "eraser") { bridge.clearDisplay(prompt: true) }
                            .disabled(bridge.busy || (bridge.activeSession != .prompts && bridge.activeSession != .assistantAudio))
                        Button("结束当前功能", systemImage: "stop") { bridge.stopSession() }
                            .disabled(bridge.busy || bridge.activeSession == nil)
                    }
                    Text("Agent 发送文字时可设置 clear_after_ms，或单独调用 /v1/prompts/clear、/v1/captions/clear。清屏保留会话，停止会话则退出页面。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("语音 Agent 接入") {
                Text("默认只做基础 ASR。轮询 GET /v1/agent/events?after=游标 读取整句及 replyTarget；原生唤醒、退出与 PCM 从 /v1/assistant/native 获取。Agent 自行决定等待、提示与回复，回写时携带当前 wakeID 或 SID；过期会话会拒绝覆盖。模型实验可在助手页单独开启。")
                    .font(.callout).textSelection(.enabled).padding(10)
            }
            RecordSyncPanel(bridge: bridge)
            Label("独立服务模式", systemImage: "network.slash").font(.headline)
            Text("雷鸟官方账号、云端上传、固件下载和官方反馈已停用。语义策略由本机 Agent 负责；天气等独立数据源按功能设置联网。")
                .foregroundStyle(.secondary)
        }
    }

    private func status(_ title: String, value: String, icon: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                SignalDot(active: live, size: 6)
            }
            Text(value).font(.system(size: 17, weight: .semibold))
        }.card(padding: 16)
    }
}
