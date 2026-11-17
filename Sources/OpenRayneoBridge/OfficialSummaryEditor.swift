// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct OfficialSummaryEditTarget: Identifiable {
    let id = UUID()
    let summaryID: String
    let taskID: String
    let account: UUID
    let title: String
    let markdown: String
    var speakerIdentities: [OfficialSpeakerIdentity] = []
    var speakerReferenceTexts: [String] = []
    var speakerLanguageCode: String?

    var displayTitle: String {
        let names = OfficialSummarySpeakerNames.resolve(identities: speakerIdentities,
            texts: [title, markdown] + speakerReferenceTexts,
            labels: .forSummary(languageCode: speakerLanguageCode))
        return OfficialSummarySpeakerNames.display(title, names: names)
    }
}

@MainActor
struct OfficialSummaryEditor: View {
    @ObservedObject var model: OfficialMemoryModel
    let target: OfficialSummaryEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String
    @State private var attemptedSave = false

    init(model: OfficialMemoryModel, target: OfficialSummaryEditTarget) {
        self.model = model; self.target = target
        _markdown = State(initialValue: target.markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑“\(OfficialSummarySpeakerNames.display(target.title, names: previewNames))”").font(.headline)
            Text("正文支持 Markdown。点击保存后写入官方云端。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $markdown).font(.body).disabled(model.busy)
                .border(Color.secondary.opacity(0.3))
            if target.markdown.contains("{{") {
                Text("请保留正文中的 {{…}} 说话人标记。").font(.caption).foregroundStyle(.secondary)
            }
            if !OfficialSummarySpeakerNames.referencedIDs(in: markdown).isEmpty {
                DisclosureGroup("阅读预览") {
                    ScrollView {
                        Text(OfficialSummarySpeakerNames.display(markdown, names: previewNames))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 180)
                }
            }
            if attemptedSave { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存正文") {
                    attemptedSave = true
                    model.saveSummaryContent(id: target.summaryID, markdown: markdown,
                        expectedTaskID: target.taskID, expectedAccount: target.account) { dismiss() }
                }.disabled(model.busy || markdown == target.markdown).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 600, minHeight: 440)
            .interactiveDismissDisabled(model.busy)
    }

    private var previewNames: [String: String] {
        OfficialSummarySpeakerNames.resolve(identities: target.speakerIdentities,
            texts: [target.title, markdown] + target.speakerReferenceTexts,
            labels: .forSummary(languageCode: target.speakerLanguageCode))
    }
}
