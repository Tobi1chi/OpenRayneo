// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import SwiftUI

@MainActor
struct AssistantRuntimePanel: View {
    @ObservedObject private var assistant: DesktopAssistant
    @ObservedObject private var store: PromptProfileStore

    init(assistant: DesktopAssistant) {
        self.assistant = assistant; store = assistant.promptStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("助手运行时").font(.title2.weight(.semibold))
            Text("与提示词共用同一份版本配置。模型、地址、超时与上下文在下次启动助手会话时生效。")
                .foregroundStyle(.secondary)
            ProviderCredentialsPanel()
            LocalASRPanel(model: LocalASRSettings.shared)
            GroupBox("模型与服务") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Decision 模型", text: setting(\.decisionModel))
                    TextField("Decision API 完整地址", text: setting(\.decisionEndpoint))
                    TextField("Agent 模型", text: setting(\.agentModel))
                    TextField("Agent Chat Completions 完整地址", text: setting(\.agentEndpoint))
                    TextField("百炼 ASR 模型", text: setting(\.asrModel))
                    TextField("ASR WSS 地址（留空使用环境变量或百炼默认地址）", text: setting(\.asrEndpoint))
                    Text("服务地址需兼容对应的 Decision、Chat Completions 或百炼 ASR 协议。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(assistant.environmentStatus).font(.caption).foregroundStyle(.secondary)
                    Text("支持钥匙串中的密钥，也兼容 OPENAI_API_KEY、DEEPSEEK_API_KEY、BAILIAN_API_KEY／DASHSCOPE_API_KEY 环境变量。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("超时") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("模型 HTTP 请求超时（秒）"); TextField("60", value: setting(\.requestTimeoutSeconds), format: .number).frame(width: 100) }
                    HStack { Text("ASR WebSocket 建连超时（秒）"); TextField("20", value: setting(\.asrConnectionTimeoutSeconds), format: .number).frame(width: 100) }
                }.padding(8)
            }
            GroupBox("可选上下文") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("用户称呼", text: setting(\.userName))
                    TextField("设备型号", text: setting(\.deviceModel))
                    TextField("设备序列号", text: setting(\.deviceSerial))
                    HStack {
                        TextField("纬度", value: setting(\.latitude), formatter: coordinateFormatter)
                        TextField("经度", value: setting(\.longitude), formatter: coordinateFormatter)
                        Button("清空位置") { var runtime = store.draft.runtimeSettings; runtime.latitude = nil; runtime.longitude = nil; store.draft.runtime = runtime }
                    }
                    Text("填写内容会作为数据随 Agent 请求发送。经纬度仅使用手动填写的值，不自动获取 Mac 位置。ASR 热词、语种与上下文继续在提示词编辑器中设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button("保存配置") { Task { await assistant.savePrompts() } }.disabled(assistant.applyingPrompts)
                Text(assistant.promptStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("此页配置 Mac 的百炼 → Decision → Agent 链路。眼镜自身的语音唤醒、声线和语言仍由设备设置管理。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { store.reloadIfUnchanged() }
    }

    private func setting<T>(_ key: WritableKeyPath<AssistantRuntimeSettings, T>) -> Binding<T> {
        Binding(get: { store.draft.runtimeSettings[keyPath: key] }, set: {
            var value = store.draft.runtimeSettings; value[keyPath: key] = $0; store.draft.runtime = value
        })
    }

    private var coordinateFormatter: NumberFormatter {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 8
        return formatter
    }
}
