// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AssistantCore
import SwiftUI

@MainActor
struct AssistantPanel: View {
    @ObservedObject var model: DesktopAssistant
    @ObservedObject var bridge: DesktopBridge
    @State private var duration = 300
    @AppStorage("nativeWakeAutoCapture") private var nativeWakeAutoCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if bridge.nativeAssistantActive {
                GroupBox("眼镜助手已唤醒") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mac 已收到唤醒，原生音频包：\(bridge.nativeAssistantAudioPackets)。")
                        Button("接听并开始对话", systemImage: "mic") { model.answerNativeWake(bridge: bridge) }
                            .disabled(model.live || model.starting || model.startingAudio || model.stopping)
                        Text("使用基础 ASR，收音最多 60 秒；整句经本机 API 交给 Agent，Agent 使用当前 wakeID 回写原生助手页。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("语音、意图与任务").font(.headline)
            Text("默认将最终整句交给本机 Agent。等待、提示、任务和回复由 Agent 决定；应用负责 ASR 与官方输入输出通道。")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.environmentStatus).font(.caption)
            Toggle("模型实验模式（显式测试内建 Decision 与回复）", isOn: $model.modelExperiment).disabled(model.active || model.starting)
            Toggle("原生唤醒后自动接听（基础 ASR → 本机 Agent）", isOn: $nativeWakeAutoCapture)
            Text(L(
                "眼镜等待接听的时间较短，语音交互建议开启自动接听。开启后，小雷小雷唤醒会把音频发送给已配置的 ASR 服务；关闭时只打开窗口。正在进行的其他助手收音会话保留。",
                "Glasses wait briefly for pickup, so auto-answer is recommended. When enabled, \"Hey RayNeo\" wake sends audio to your configured ASR; when off, it only opens this window while keeping active sessions intact."
            ))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始助手会话") { model.start(bridge: bridge) }.disabled(model.active || model.stopping || model.starting)
                Button(model.stopping ? "正在收尾…" : "停止助手会话") { Task { await model.stop(bridge: bridge) } }
                    .disabled((!model.active && !model.starting) || model.stopping)
                Text(model.state.phase).font(.callout)
            }
            if let error = model.error ?? model.state.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !model.lastUtterance.isEmpty {
                GroupBox("最近输入") {
                    Text(model.lastUtterance).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            replyPanel
            if !model.state.toolEvents.isEmpty {
                DisclosureGroup("工具执行记录（\(model.state.toolEvents.count)）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.state.toolEvents.suffix(16).enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(event.phase) · \(event.call.name)").font(.callout.weight(.medium))
                                Text(event.call.arguments).font(.caption).textSelection(.enabled)
                                if let result = event.result { Text(result).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            GroupBox("输入消息") {
                VStack(alignment: .leading) {
                    TextEditor(text: $model.sentenceText).frame(height: 65)
                    Button("发送给助手") { model.submitMessage() }
                        .disabled(!model.active || model.stopping || model.live || model.startingAudio || model.importing || model.sentenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("导入音频并识别…") { model.importAudio() }.disabled(!model.active || model.live || model.startingAudio || model.importing || model.stopping)
                }.padding(6)
            }
            GroupBox("眼镜语音输入") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("音频来源", selection: $model.captureSource) {
                        ForEach(AssistantCaptureSource.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(model.live || model.startingAudio)
                        .onChange(of: model.captureSource) { source in
                            if source != .lifeLog, duration == 0 { duration = 300 }
                        }
                    if model.captureSource == .realtime {
                        Picker("识别声道", selection: $model.microphoneChannel) {
                            Text("双路：1本人＋2识别（默认）").tag(3)
                            Text("实验：两路混合").tag(0); Text("实验：仅通道1全量识别").tag(1); Text("实验：仅通道2").tag(2)
                        }.disabled(model.live || model.startingAudio)
                    }
                    Picker("采集时长", selection: $duration) {
                        Text("1 分钟").tag(60); Text("5 分钟").tag(300); Text("10 分钟").tag(600)
                        if model.captureSource == .lifeLog { Text("直到手动停止").tag(0) }
                    }.frame(width: 220).disabled(model.live)
                    if model.captureSource == .lifeLog {
                        Toggle("保留本地音频分段，供中断后手动恢复", isOn: $model.preserveLifeLogAudio)
                            .disabled(model.live || model.startingAudio)
                        Stepper("VAD 触发延迟：\(model.lifeLogVADDelay) 秒", value: $model.lifeLogVADDelay, in: 1...60)
                            .disabled(model.live || model.startingAudio)
                        Text("保留的分段在录音资料库中恢复和转写；恢复操作不会把历史对话交给 Decision 执行。持续收音需要这台 Mac 保持运行并连接眼镜。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(model.captureSource == .native ? "接收原生助手音频" : model.captureSource == .realtime ? "开始实时双麦识别" : "开始 AlwaysOn 收音") { model.startCapture(bridge: bridge, duration: duration) }
                        .disabled(!model.active || model.live || model.startingAudio || model.importing || model.stopping || bridge.busy || bridge.selectedAddress.isEmpty)
                    Toggle("将回复自动发送到眼镜", isOn: $model.sendRepliesToGlasses)
                    if model.captureSource == .realtime {
                        Stepper(model.replyClearAfterSeconds == 0 ? "回复保持显示" : "回复显示 \(model.replyClearAfterSeconds) 秒后清屏", value: $model.replyClearAfterSeconds, in: 0...600, step: 5)
                        Text("设为 0 保持显示；新回复会取消上一条回复的清屏定时。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.asrStatus).font(.caption)
                    if model.captureSource != .lifeLog {
                        Text("已收到 \(model.receivedAudioPackets) 包，已解码 \(model.receivedAudioSeconds, specifier: "%.1f") 秒")
                            .font(.caption).monospacedDigit()
                    }
                    Text(model.captureSource == .native
                         ? "原生助手音频在本机解码后发送给已配置 ASR，回答显示在 Mac 并写入眼镜原生助手页。"
                         : model.captureSource == .realtime
                         ? "实时模式使用提示页双麦音频，按所选声道送百炼识别；不启用系统虚拟麦克风。文字和模型结果记录为本地 JSONL。"
                         : "AlwaysOn 按批量音频处理，转写在分块到达后开始。文字和模型结果记录为本地 JSONL。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            DisclosureGroup("提示词配置与试运行") {
                PromptEditorPanel(model: model, bridge: bridge, store: model.promptStore)
            }
            DisclosureGroup("模型、服务地址与运行时配置") {
                AssistantRuntimePanel(assistant: model)
            }
            Text("当前配置：\(model.state.promptVersion.isEmpty ? model.promptStore.saved.versionLabel : model.state.promptVersion)")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("判定阈值（实验初值，尚未校准）") {
                VStack(alignment: .leading) {
                    threshold("描述完整概率", value: $model.completeProbability)
                    threshold("完整性置信度", value: $model.completeConfidence)
                    threshold("分支概率", value: $model.routeProbability)
                    threshold("分支置信度", value: $model.routeConfidence)
                }.disabled(model.active)
            }
            DisclosureGroup("识别、Decision 与数据集诊断") {
                sentences("当前 Array", model.state.current)
                sentences("上次成功 Array（仅参照）", model.state.previous)
                if let result = model.state.completeness { decision("完整性", result) }
                if let result = model.state.routing { decision("分支", result) }
            Text("进行中的请求：\(model.state.pendingRequests)").font(.caption)
            if !model.state.logPath.isEmpty {
                Text(model.state.logPath).font(.caption).textSelection(.enabled)
                Button("在 Finder 中显示数据集") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.state.logPath)])
                }
            }
            }
        }
    }
    private var replyPanel: some View {
        GroupBox("助手回复") {
            VStack(alignment: .leading, spacing: 10) {
                if model.state.replyPending {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成回复…").font(.callout)
                    }
                }
                if let error = model.state.replyError {
                    Text("生成失败：\(error)").foregroundStyle(.orange).textSelection(.enabled)
                }
                if !model.state.output.isEmpty {
                    HStack {
                        Text(model.state.outputRoute == .agentTask ? "Agent 任务回答" : "眼镜短提示")
                            .font(.callout.weight(.medium))
                        if model.state.replyPending || model.state.replyError != nil {
                            Text("上次已完成回复").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("复制回复") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.state.output, forType: .string)
                        }
                        Button("显示到实时提示") { bridge.showText("AI 助手", translation: model.state.output, prompt: true, clearAfterMilliseconds: max(0, min(600, model.replyClearAfterSeconds)) * 1000) }
                            .disabled(bridge.busy || bridge.selectedAddress.isEmpty || model.replySending)
                        Button(model.replySending ? "正在发送…" : "重新发送到眼镜") { model.sendReply(bridge: bridge) }
                            .disabled(!model.canSendReply)
                    }
                    ScrollView {
                        Text(model.state.output).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                    if let version = model.state.outputPromptVersion {
                        Text("生成时配置：\(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.replyDeliveryStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else if !model.state.replyPending, model.state.replyError == nil {
                    Text("输入消息或开启眼镜语音输入，回复会显示在这里。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func threshold(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label).frame(width: 140, alignment: .leading); TextField(label, value: value, format: .number).frame(width: 80) }
    }
    private func sentences(_ title: String, _ values: [String]) -> some View {
        GroupBox(title) {
            Text(values.isEmpty ? "[]" : values.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n"))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func decision(_ title: String, _ result: ChoiceResult) -> some View {
        Text("\(title)：\(result.choice) · 概率 \(result.probabilities[result.choice] ?? 0, specifier: "%.2f") · 置信度 \(result.confidence, specifier: "%.2f")")
            .font(.callout).monospacedDigit()
    }
}
