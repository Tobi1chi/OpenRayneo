// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import SwiftUI

private enum PromptModule: String, CaseIterable, Identifiable {
    case completeness = "完整性判断", routing = "分支路由", shortReply = "眼镜短回复", agent = "Agent 任务", asr = "ASR 辅助"
    var id: String { rawValue }
}

@MainActor
struct PromptEditorPanel: View {
    @ObservedObject var model: DesktopAssistant
    @ObservedObject var bridge: DesktopBridge
    @ObservedObject var store: PromptProfileStore
    @State private var module: PromptModule = .completeness
    @State private var historicalRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("配置名称", text: $store.draft.name).frame(maxWidth: 260)
                Text("已保存 r\(store.saved.revision)\(store.hasChanges ? " · 草稿有修改" : "")").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存并应用") { Task { await model.savePrompts() } }.disabled(model.applyingPrompts || !store.hasChanges)
                Button("恢复默认草稿") { store.restoreDefaults() }
                Button("导入配置…") { store.importProfile() }
                Button("导出草稿…") { store.exportProfile() }
            }
            if !store.history.isEmpty {
                HStack {
                    Picker("历史版本", selection: $historicalRevision) {
                        Text("选择版本").tag(0)
                        ForEach(store.history, id: \.revision) { value in
                            Text("r\(value.revision) · \(value.name)").tag(value.revision)
                        }
                    }.frame(maxWidth: 320)
                    Button("载入草稿") {
                        if let value = store.history.first(where: { $0.revision == historicalRevision }) { store.restore(value) }
                    }.disabled(historicalRevision == 0)
                }
            }
            Text("保存完成后，下一条新整句使用新版；同一条请求的两阶段判定和回复固定使用同一版本。ASR 设置从下一收音轮次生效。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = store.message { Text(message).font(.caption).textSelection(.enabled) }
            if !model.promptStatus.isEmpty { Text(model.promptStatus).font(.caption).textSelection(.enabled) }
            Picker("模块", selection: $module) {
                ForEach(PromptModule.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch module {
            case .completeness:
                classifier($store.draft.completeness, options: ["complete", "incomplete"])
                field("complete 的含义", text: $store.draft.completeDescription)
                field("incomplete 的含义", text: $store.draft.incompleteDescription)
            case .routing:
                classifier($store.draft.routing, options: ["ignore", "glasses_hint", "agent_task"])
                field("忽略 · ignore", text: $store.draft.ignoreDescription)
                field("短提示 · glasses_hint", text: $store.draft.hintDescription)
                field("Agent · agent_task", text: $store.draft.agentDescription)
            case .shortReply: response($store.draft.shortReply, limit: 4000)
            case .agent:
                response($store.draft.agent, limit: 8000)
                field("任务时区", text: $store.draft.timeZoneIdentifier)
                Text("工具名称和参数由程序提供。这里调整任务规则与表达方式；当前时间、默认城市和最近工具结果会自动作为运行时上下文传入。")
                    .font(.caption).foregroundStyle(.secondary)
            case .asr:
                editor("领域上下文", text: $store.draft.asr.context, height: 90)
                Text("\(store.draft.asr.context.count)/400 字").font(.caption)
                PromptStringList(title: "识别热词", values: $store.draft.asr.hotwords, placeholder: "例如：基尔霍夫定律")
                PromptStringList(title: "语种提示（留空自动判断，最多4项）", values: $store.draft.asr.languageHints, placeholder: "例如 zh 或 en")
                Toggle("使用近场语音检测", isOn: $store.draft.asr.nearField)
            }
            DisclosureGroup("编译后的提示词预览") {
                Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            trialPanel
        }.padding(8)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            TextField(title, text: text, axis: .vertical).lineLimit(1...5)
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            TextEditor(text: text).font(.body).frame(height: height).border(Color.secondary.opacity(0.2))
        }
    }

    private func classifier(_ value: Binding<ClassifierPrompt>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field("判定目标", text: value.objective)
            PromptStringList(title: "判定规则", values: value.rules, placeholder: "添加一条独立规则")
            Text("分类示例").font(.callout.weight(.medium))
            ForEach(value.examples) { example in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        editor("上一次成功表达（每行一个整句）", text: lines(example.previous), height: 55)
                        editor("当前表达（每行一个整句）", text: lines(example.current), height: 55)
                        HStack {
                            Picker("预期类别", selection: example.expected) {
                                ForEach(options, id: \.self) { Text($0).tag($0) }
                            }.frame(maxWidth: 300)
                            Spacer()
                            Button("删除示例") {
                                let id = example.wrappedValue.id
                                value.wrappedValue.examples.removeAll { $0.id == id }
                            }
                        }
                    }.padding(5)
                }
            }
            Button("添加示例") { value.wrappedValue.examples.append(.init(expected: options[0])) }
        }
    }

    private func response(_ value: Binding<ResponsePrompt>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field("角色", text: value.role)
            editor("任务目标", text: value.objective, height: 80)
            field("输出风格", text: value.style)
            Stepper("建议回复长度：\(value.wrappedValue.maximumCharacters) 字", value: value.maximumCharacters, in: 20...limit, step: 20)
            PromptStringList(title: "处理与输出规则", values: value.rules, placeholder: "添加一条规则")
        }
    }

    private func lines(_ values: Binding<[String]>) -> Binding<String> {
        Binding(get: { values.wrappedValue.joined(separator: "\n") },
                set: { values.wrappedValue = $0.isEmpty ? [] : $0.components(separatedBy: "\n") })
    }

    private var preview: String {
        switch module {
        case .completeness: return store.draft.completeness.rendered
        case .routing: return store.draft.routing.rendered
        case .shortReply: return store.draft.shortReply.rendered
        case .agent: return store.draft.agent.rendered
        case .asr:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? String(decoding: encoder.encode(store.draft.asr), as: UTF8.self)) ?? ""
        }
    }

    private var trialPanel: some View {
        DisclosureGroup("用草稿试运行（不操作眼镜）") {
            VStack(alignment: .leading, spacing: 10) {
                editor("上次成功 Array（每行一个整句）", text: $model.trialPreviousText, height: 60)
                editor("当前 Array（每行一个整句）", text: $model.trialCurrentText, height: 80)
                HStack {
                    Button(model.trialRunning ? "正在试运行…" : "使用草稿试运行") { model.runPromptTrial(bridge: bridge) }.disabled(model.trialRunning)
                    Button("取消") { model.cancelPromptTrial() }.disabled(!model.trialRunning)
                    Button("载入历史 JSONL…") { model.loadTrialSamples() }
                    Button("导出结果…") { model.exportTrialResult() }.disabled(model.trialResult == nil)
                }
                if !model.trialSamples.isEmpty {
                    HStack {
                        Picker("历史样本", selection: $model.trialSampleIndex) {
                            ForEach(model.trialSamples.indices, id: \.self) { index in
                                Text("\(index + 1) · \(model.trialSamples[index].currentSentences.last ?? "")").tag(index)
                            }
                        }
                        Button("使用样本") {
                            if model.trialSamples.indices.contains(model.trialSampleIndex) { model.useTrialSample(model.trialSamples[model.trialSampleIndex]) }
                        }
                    }
                }
                if let error = model.trialError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if let result = model.trialResult {
                    Text(result.status).font(.callout.weight(.medium))
                    trialDecision("完整性", result.completeness)
                    if let routing = result.routing { trialDecision("分支", routing) }
                    if let reply = result.reply { Text(reply.text).textSelection(.enabled) }
                    ForEach(Array(result.toolEvents.enumerated()), id: \.offset) { _, event in
                        Text("拟调用 \(event.call.name)：\(event.call.arguments)").font(.caption).textSelection(.enabled)
                    }
                    if let request = result.modelRequests.first {
                        DisclosureGroup("实际模型请求（含运行时上下文）") {
                            Text(request.bodyJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }.padding(8)
        }
    }

    private func trialDecision(_ label: String, _ value: ChoiceResult) -> some View {
        Text("\(label)：\(value.choice) · 概率 \(value.probabilities[value.choice] ?? 0, specifier: "%.2f") · 置信度 \(value.confidence, specifier: "%.2f")")
            .font(.caption).monospacedDigit()
    }
}

private struct PromptStringList: View {
    let title: String
    @Binding var values: [String]
    let placeholder: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            ForEach(Array(values.indices), id: \.self) { index in
                HStack(alignment: .top) {
                    Text("\(index + 1). ").font(.caption).foregroundStyle(.secondary)
                    TextField(placeholder, text: Binding(get: { values.indices.contains(index) ? values[index] : "" },
                        set: { if values.indices.contains(index) { values[index] = $0 } }), axis: .vertical).lineLimit(1...7)
                    Button { if values.indices.contains(index) { values.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .help("删除这一项")
                }
            }
            Button("添加一项") { values.append("") }
        }
    }
}
