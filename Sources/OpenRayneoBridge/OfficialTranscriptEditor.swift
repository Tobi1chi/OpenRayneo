// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialTranscriptEditor: View {
    @ObservedObject var model: OfficialMemoryModel
    let target: OfficialTranscriptEditTarget
    private let editableIndices: Set<Int>
    @Environment(\.dismiss) private var dismiss
    @State private var clips: [OfficialTranscriptClip]
    @State private var query = ""
    @State private var replacement = ""
    @State private var includeTranslation = true
    @State private var selectedMatch = 0
    @State private var attemptedSave = false

    init(model: OfficialMemoryModel, target: OfficialTranscriptEditTarget) {
        self.model = model; self.target = target; editableIndices = target.editableIndices
        _clips = State(initialValue: target.clips)
    }

    var body: some View {
        let highlightedClip = currentMatch?.clipIndex
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑\(target.kind.title) · \(target.title)").font(.headline)
            Text("修改原文或已有译文，也可查找替换。点击保存后更新官方云端转写。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    replacementControls {
                        if let match = currentMatch { proxy.scrollTo(match.clipIndex, anchor: .center) }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(clips.indices, id: \.self) { index in
                                clipEditor(index, highlighted: highlightedClip == index).id(index)
                            }
                        }.padding(4)
                    }
                }
            }
            if attemptedSave { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存转写") {
                    attemptedSave = true
                    model.saveTranscript(clips, target: target) { dismiss() }
                }.disabled(model.busy || clips == target.clips).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 720, minHeight: 620)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: query) { _ in selectedMatch = 0 }
            .onChange(of: includeTranslation) { _ in selectedMatch = 0 }
    }

    private var matches: [OfficialTranscriptText.Match] {
        OfficialTranscriptText.matches(in: clips, query: query, includeTranslation: includeTranslation, editableIndices: editableIndices)
    }

    private var currentMatch: OfficialTranscriptText.Match? {
        let values = matches
        return values.isEmpty ? nil : values[min(selectedMatch, values.count - 1)]
    }

    private func replacementControls(locate: @escaping () -> Void) -> some View {
        let values = matches
        return GroupBox("查找与替换") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("查找文字", text: $query)
                    TextField("替换为（可留空）", text: $replacement)
                }
                HStack {
                    Toggle("包含译文", isOn: $includeTranslation)
                    Text(values.isEmpty ? "未找到匹配" : "第 \(min(selectedMatch, values.count - 1) + 1) / \(values.count) 处")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("上一处") {
                        selectedMatch = (min(selectedMatch, values.count - 1) + values.count - 1) % values.count; locate()
                    }.disabled(values.isEmpty)
                    Button("下一处") { selectedMatch = (selectedMatch + 1) % values.count; locate() }.disabled(values.isEmpty)
                    Button("定位") { locate() }.disabled(values.isEmpty)
                    Button("替换当前") { replaceOne() }.disabled(values.isEmpty)
                    Button("全部替换") { replaceAll() }.disabled(values.isEmpty)
                }
                Text("忽略大小写，按文字匹配；替换先作用于本地草稿。").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
        }
    }

    private func clipEditor(_ index: Int, highlighted: Bool) -> some View {
        let clip = clips[index]
        let editable = editableIndices.contains(index)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("片段 \(index + 1)").font(.subheadline.weight(.medium))
                    if let speaker = clip.speakerName, !speaker.isEmpty { Text(speaker).foregroundStyle(.secondary) }
                    Spacer()
                    if highlighted { Text("当前匹配").font(.caption).foregroundStyle(.tint) }
                }
                TextEditor(text: textBinding(index, translation: false)).font(.body).frame(height: 85)
                    .border(Color.secondary.opacity(0.2))
                if includeTranslation, clip.translateContent != nil {
                    Text("译文").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: textBinding(index, translation: true)).font(.body).frame(height: 70)
                        .border(Color.secondary.opacity(0.2))
                }
                if !editable { Text("此片段暂无法定位，保留原内容。").font(.caption).foregroundStyle(.secondary) }
            }.disabled(model.busy || !editable)
        }
    }

    private func textBinding(_ index: Int, translation: Bool) -> Binding<String> {
        Binding(get: { translation ? clips[index].translateContent ?? "" : clips[index].content ?? "" }, set: {
            if translation { clips[index].translateContent = $0 } else { clips[index].content = $0 }
        })
    }

    private func replaceOne() {
        let values = matches
        guard !values.isEmpty else { return }
        let index = min(selectedMatch, values.count - 1), match = values[min(selectedMatch, values.count - 1)]
        OfficialTranscriptText.replace(match, with: replacement, in: &clips)
        let next = matches
        // Continue after inserted text so a replacement containing the query is not selected again immediately.
        let end = match.range.location + (replacement as NSString).length
        selectedMatch = next.firstIndex {
            $0.clipIndex > match.clipIndex || ($0.clipIndex == match.clipIndex &&
                (($0.field == match.field && $0.range.location >= end) || (match.field == .content && $0.field == .translation)))
        } ?? min(index, max(0, next.count - 1))
    }

    private func replaceAll() {
        let values = matches
        for match in values.reversed() { OfficialTranscriptText.replace(match, with: replacement, in: &clips) }
        selectedMatch = 0
    }
}
