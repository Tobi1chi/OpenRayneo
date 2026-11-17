// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct CaptionSettingsPanel: View {
    @ObservedObject var model: CaptionSettingsModel
    private let languages = [("zh-CN", "普通话"), ("yue-CN", "粤语"), ("en-US", "英语"), ("fr-FR", "法语"),
        ("de-DE", "德语"), ("es-ES", "西班牙语"), ("it-IT", "意大利语"), ("ja-JP", "日语"), ("ko-KR", "韩语"), ("pl-PL", "波兰语")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("字幕与实时提示设置").font(.title2.weight(.semibold))
                Spacer()
                Text(model.sessionLabel).foregroundStyle(.secondary)
                Button("刷新状态") { Task { await model.refresh() } }.disabled(!model.connected || model.busy)
            }
            GroupBox("字幕显示草稿") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("字号档位"); TextField("字号", value: $model.draft.fontSize, format: .number)
                        Text("宽度值"); TextField("宽度", value: $model.draft.contentWidth, format: .number)
                        Text("最大行数"); TextField("行数", value: $model.draft.maxLines, format: .number)
                    }
                    TextField("显示位置", text: $model.draft.position)
                    Picker("正前方显示", selection: $model.draft.straightView) {
                        Text("原文").tag("original"); Text("译文").tag("translation")
                    }
                    Toggle("预览时显示文字", isOn: $model.draft.isDisplay)
                    Text("预览用于调整布局；全局应用会关闭预览并保存显示配置。此处不启动语音翻译。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("保存草稿") { Task { await model.saveDraft() } }
                        Button(model.previewActive ? "更新临时预览" : "临时预览") { Task { await model.preview() } }.disabled(model.promptActive)
                        Button("关闭预览") { Task { await model.closePreview() } }.disabled(!model.previewActive)
                        Button("全局应用") { Task { await model.applyGlobal() } }.disabled(model.promptActive)
                        if model.dirty { Text("有未应用草稿").font(.caption).foregroundStyle(.secondary) }
                    }.disabled(model.busy || !model.connected)
                    if model.pendingGlobal { Text("全局配置等待重连同步。").font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("眼镜实际回读") {
                        ForEach([("font_size", "字号档位"), ("content_width", "宽度值"), ("max_lines", "最大行数"),
                            ("position", "显示位置"), ("straight_view", "正前方内容"), ("is_display", "显示状态")], id: \.0) { key, label in
                            LabeledContent(label, value: model.effective[key].map { String(describing: $0) } ?? "尚未回读")
                        }
                    }
                }.padding(8)
            }
            GroupBox("实时提示语言与收音场景") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("对话语言", selection: $model.language) {
                        ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
                    }
                    Picker("收音场景", selection: $model.scenario) {
                        Text("面对面 · 前方").tag("face_to_face")
                        Text("多人交谈 · 周围").tag("group_conversation")
                    }
                    if let language = model.activePromptSettings["source_language"] as? String, model.promptActive {
                        Text("当前会话语言：\(language)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("语言和场景可同步到当前会话。本地识别会切换识别器；AI 收音会结束旧识别流并以新语言开始下一流，眼镜收音保持连接。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("云端支持的语言以当前 ASR 模型为准；发送设置后仍需等待服务启动与眼镜确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.promptActive ? "保存并同步实时提示设置" : "保存为下次启动设置") {
                        Task { await model.applyPromptPreferences() }
                    }.disabled(model.busy || !model.connected)
                }.padding(8)
            }
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }.task { await model.observe() }
    }
}
