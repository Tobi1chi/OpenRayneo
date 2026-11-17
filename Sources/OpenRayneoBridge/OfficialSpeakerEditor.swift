// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct OfficialSpeakerEditTarget: Identifiable {
    let id = UUID()
    let transcript: OfficialTranscriptEditTarget
    let snapshot: OfficialSpeakerSnapshot
}

@MainActor
struct OfficialSpeakerEditor: View {
    @ObservedObject var model: OfficialMemoryModel
    let target: OfficialSpeakerEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var global = false
    @State private var clipIndex = 0
    @State private var name = ""
    @State private var names: [String: String] = [:]
    @State private var scope = OfficialSpeakerNamingScope.allClipsForSpeaker
    @State private var preview: OfficialSpeakerNamingPlan?
    @State private var projected: [OfficialTranscriptClip] = []
    @State private var notice = ""
    @State private var attemptedSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("说话人 · \(target.transcript.title)").font(.headline)
            Text("先预览片段归属，再保存到官方云端。使用已有名字会合并同名说话人。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("命名方式", selection: $global) {
                Text("单段与同一说话人").tag(false)
                Text("全部说话人").tag(true)
            }.pickerStyle(.segmented)
            if global { globalFields } else { singleFields }
            HStack {
                Button("预览变更") { makePreview() }.disabled(model.busy || !hasInput)
                if preview != nil { Text("预览已生成，点击保存后生效。").font(.caption).foregroundStyle(.secondary) }
            }
            if preview != nil { previewRows }
            else { Spacer(minLength: 0) }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if attemptedSave { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存说话人") {
                    if let preview {
                        attemptedSave = true
                        model.saveSpeakerNames(preview, target: target) { dismiss() }
                    }
                }.disabled(model.busy || preview == nil || projected == target.transcript.clips)
            }
        }.padding(20).frame(minWidth: 740, minHeight: 600)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: global) { _ in clearPreview() }
            .onChange(of: clipIndex) { _ in name = ""; clearPreview() }
            .onChange(of: name) { _ in clearPreview() }
            .onChange(of: names) { _ in clearPreview() }
            .onChange(of: scope) { _ in clearPreview() }
    }

    private var hasInput: Bool {
        if global { return names.values.contains { !OfficialSpeakerNormalization.trimmed($0).isEmpty } }
        return !OfficialSpeakerNormalization.trimmed(name).isEmpty
    }

    private var singleFields: some View {
        GroupBox("选择片段和作用范围") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("片段", selection: $clipIndex) {
                    ForEach(target.transcript.clips.indices, id: \.self) { index in
                        Text("\(index + 1) · " + label(for: target.transcript.clips[index].clipID, in: target.snapshot)).tag(index)
                    }
                }
                Text(target.transcript.clips[clipIndex].content ?? "（无原文）")
                    .lineLimit(4).font(.callout).textSelection(.enabled)
                HStack {
                    TextField("新名字，或使用已有说话人", text: $name)
                    Menu("使用已有说话人") {
                        ForEach(target.snapshot.identities, id: \.id) { identity in
                            Button(display(identity, in: target.snapshot)) {
                                name = target.snapshot.visibleDisplayNames[identity.id] ?? identity.name
                            }
                        }
                    }
                }
                Picker("作用范围", selection: $scope) {
                    ForEach(OfficialSpeakerNamingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("仅修改一个片段时可拆出新说话人；同名合并会影响已有同名身份的片段，预览中列出全部变化。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
        }
    }

    private var globalFields: some View {
        GroupBox("全部说话人命名") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(target.snapshot.identities, id: \.id) { identity in
                        HStack {
                            Text(display(identity, in: target.snapshot)).frame(width: 180, alignment: .leading)
                            TextField("留空保留当前名字", text: Binding(get: { names[identity.id] ?? "" },
                                set: { names[identity.id] = $0 }))
                            Text("\(target.snapshot.clips.filter { $0.speakerID == identity.id }.count) 段")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(4)
            }.frame(maxHeight: 200).disabled(model.busy)
        }
    }

    private var previewRows: some View {
        GroupBox("变更预览") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(projected.indices, id: \.self) { index in
                        if projected[index] != target.transcript.clips[index], let preview {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("片段 \(index + 1) · " + label(for: projected[index].clipID, in: target.snapshot)
                                     + " → " + label(for: projected[index].clipID, in: preview.result)).font(.subheadline)
                                Text(projected[index].content ?? "（无原文）").lineLimit(2).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }

    private func display(_ identity: OfficialSpeakerIdentity, in snapshot: OfficialSpeakerSnapshot) -> String {
        let name = snapshot.visibleDisplayNames[identity.id] ?? identity.name
        return (name.isEmpty ? "未命名说话人" : name) + " · " + identity.id + (identity.role == .myself ? "（我）" : "")
    }

    private func label(for clipID: String?, in snapshot: OfficialSpeakerSnapshot) -> String {
        guard let clipID, let clip = snapshot.clips.first(where: { $0.clipID == clipID }),
              let identity = snapshot.identities.first(where: { $0.id == clip.speakerID }) else { return "未知说话人" }
        return display(identity, in: snapshot)
    }

    private func clearPreview() {
        preview = nil; projected = []; notice = ""; attemptedSave = false
    }

    private func makePreview() {
        do {
            let plan: OfficialSpeakerNamingPlan
            if global { plan = try OfficialSpeakerNaming.global(target.snapshot, names: names) }
            else {
                let clip = target.transcript.clips[clipIndex]
                if let assignment = target.snapshot.clips.first(where: { $0.clipID == clip.clipID }),
                   target.snapshot.visibleDisplayNames[assignment.speakerID] == OfficialSpeakerNormalization.trimmed(name),
                   !target.snapshot.identities.contains(where: {
                       $0.id != assignment.speakerID && OfficialSpeakerNormalization.nameKey(
                           target.snapshot.visibleDisplayNames[$0.id] ?? $0.name) == OfficialSpeakerNormalization.nameKey(name)
                   }) {
                    notice = "名称没有变化。"; return
                }
                plan = try OfficialSpeakerNaming.single(target.snapshot, clipID: clip.clipID!, name: name, scope: scope)
            }
            guard plan.result != plan.source else { notice = "名称和片段归属没有变化。"; return }
            let clips = try plan.project(onto: target.transcript.clips)
            preview = plan; projected = clips
            let count = clips.indices.filter { clips[$0] != target.transcript.clips[$0] }.count
            notice = "将更新 \(count) 个片段，保存后为 \(plan.result.identities.count) 位说话人。"
        } catch { notice = error.localizedDescription }
    }
}
