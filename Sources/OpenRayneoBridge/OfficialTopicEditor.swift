// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialTopicEditor: View {
    @ObservedObject var model: OfficialMemoryModel
    let target: OfficialTopicEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var aliases: String
    @State private var facts = ""
    @State private var selectedFactIDs: Set<String>

    init(model: OfficialMemoryModel, target: OfficialTopicEditTarget) {
        self.model = model; self.target = target
        _name = State(initialValue: target.title)
        _aliases = State(initialValue: target.synonyms.joined(separator: "\n"))
        _selectedFactIDs = State(initialValue: Set(target.facts.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.topicID == nil ? "新建官方主题" : "确认推荐主题").font(.title2.weight(.semibold))
            TextField("主题名称", text: $name)
            Text("关键词／别名，每行一项").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $aliases).frame(height: 90).border(.quaternary)
            if target.topicID == nil {
                Text("补充事实，每行一项（可选）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $facts).frame(height: 110).border(.quaternary)
            } else if !target.facts.isEmpty {
                Text("保留到主题的相关事实").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(target.facts, id: \.id) { fact in
                            Toggle(fact.content, isOn: Binding(get: { selectedFactIDs.contains(fact.id) }, set: { included in
                                if included { selectedFactIDs.insert(fact.id) } else { selectedFactIDs.remove(fact.id) }
                            }))
                        }
                    }
                }.frame(maxHeight: 160)
            }
            Text("将写入当前雷鸟官方账号；创建后由官方服务继续整理主题内容。").font(.caption).foregroundStyle(.secondary)
            Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(target.topicID == nil ? "创建主题" : "确认并启用") {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = target.topicID {
                        model.confirmTopic(.init(topicID: id, name: title,
                            relatedFactIDs: target.facts.filter { selectedFactIDs.contains($0.id) }.map(\.id),
                            synonyms: lines(aliases)), target: target) { dismiss() }
                    } else {
                        model.createTopic(.init(name: title, aliases: lines(aliases), facts: lines(facts)), target: target) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 550)
        .onChange(of: model.accountGeneration) { _ in dismiss() }
    }
    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

@MainActor
struct OfficialTopicActionsPanel: View {
    @ObservedObject var model: OfficialMemoryModel
    @State private var synonym = ""
    @State private var confirmation: OfficialTopicEditTarget?
    @State private var deletion: OfficialTopicEditTarget?
    @State private var showDelete = false

    var body: some View {
        if let target = model.topicEditorTarget() {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("刷新主题内容") {
                        model.loadTopic(OfficialMemoryRow(["topicId": target.topicID ?? "", "topicName": target.title], identity: "topicId"))
                    }
                    Button("标记已读") { model.markSelectedTopicRead(target: target) }
                    if let status = model.selectedTopicStatus {
                        Text(status.title).font(.caption).foregroundStyle(.secondary)
                        if status == .active { Button("暂停跟踪") { model.changeTopicStatus(.paused, target: target) } }
                        if status == .paused { Button("恢复跟踪") { model.changeTopicStatus(.active, target: target) } }
                        if status == .recommended { Button("确认推荐主题…") { confirmation = target } }
                    }
                    if let favourite = model.selectedTopicFavourite {
                        Button(favourite ? "取消收藏" : "收藏主题") { model.changeTopicFavourite(!favourite, target: target) }
                    }
                    Spacer()
                    Button("删除主题…", role: .destructive) { deletion = target; showDelete = true }
                }
                GroupBox("关键词与别名") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(target.synonyms, id: \.self) { value in
                            HStack { Text(value); Spacer(); Button("移除") { model.changeTopicSynonym(value, removing: true, target: target) } }
                        }
                        HStack {
                            TextField("添加关键词／别名", text: $synonym)
                            Button("添加") { model.changeTopicSynonym(synonym.trimmingCharacters(in: .whitespacesAndNewlines), removing: false, target: target) { synonym = "" } }
                                .disabled(synonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(8)
                }.disabled(model.selectedTopicStatus != .active)
            }.disabled(model.busy)
            .sheet(item: $confirmation) { item in OfficialTopicEditor(model: model, target: item) }
            .alert("删除官方主题？", isPresented: $showDelete) {
                Button("取消", role: .cancel) { deletion = nil }
                Button("删除", role: .destructive) {
                    if let deletion { model.changeTopicStatus(.deleted, target: deletion) }
                    deletion = nil
                }
            } message: { Text("将从官方账号删除“\(deletion?.title ?? "")”。该操作会改变云端主题状态。") }
            .onChange(of: model.selectedTopicID) { _ in synonym = ""; confirmation = nil; deletion = nil; showDelete = false }
            .onChange(of: model.accountGeneration) { _ in synonym = ""; confirmation = nil; deletion = nil; showDelete = false }
        }
    }
}
