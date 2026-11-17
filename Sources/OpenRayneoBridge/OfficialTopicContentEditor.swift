// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialTopicItemEditor: View {
    @ObservedObject var model: OfficialMemoryModel
    let target: OfficialTopicItemEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var description: String
    @State private var starred: Bool
    @State private var completion = -1

    init(model: OfficialMemoryModel, target: OfficialTopicItemEditTarget) {
        self.model = model; self.target = target
        _content = State(initialValue: target.content)
        _description = State(initialValue: target.description)
        _starred = State(initialValue: target.starred)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((target.itemID == nil ? "添加" : "编辑") + (target.kind == .fact ? "主题事实" : "官方待办"))
                .font(.title2.weight(.semibold))
            TextEditor(text: $content).frame(minHeight: 100).border(.quaternary)
            if target.kind == .task {
                Toggle("星标", isOn: $starred)
                if target.itemID != nil {
                    Text("待办说明").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $description).frame(height: 75).border(.quaternary)
                    Picker("完成状态", selection: $completion) {
                        Text("保持当前状态").tag(-1)
                        Text("标为完成").tag(1)
                        Text("标为未完成").tag(0)
                    }
                }
                Text("编辑会更新官方账号中的同一条待办。").font(.caption).foregroundStyle(.secondary)
            } else if target.itemID != nil {
                Text("这是共享事实；修改文字可能影响其他引用它的主题。").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存到官方账号") {
                    model.saveTopicItem(target, content: content, description: description, starred: starred,
                        completed: completion < 0 ? nil : completion == 1) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 520)
        .onChange(of: model.accountGeneration) { _ in dismiss() }
        .onChange(of: model.selectedTopicID) { _ in dismiss() }
    }
}

@MainActor
struct OfficialTopicContentPanel: View {
    @ObservedObject var model: OfficialMemoryModel
    let data: [String: Any]
    @State private var editor: OfficialTopicItemEditTarget?
    @State private var removal: Removal?
    @State private var showRemoval = false
    private struct Removal {
        enum Kind { case fact, event, task }
        let kind: Kind
        let id: String
        let title: String
        let target: OfficialTopicEditTarget
    }
    private var editable: Bool { !model.busy && model.selectedTopicStatus == .active }

    var body: some View {
        if let topic = model.topicEditorTarget() {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("相关事实") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((data["relatedFacts"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, fact in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(fact["content"] as? String ?? "").textSelection(.enabled)
                                if let id = fact["factsId"] as? String ?? fact["factIds"] as? String ?? fact["factId"] as? String {
                                    HStack {
                                        Button("编辑共享事实…") {
                                            editor = .init(topic: topic, kind: .fact, itemID: id, content: fact["content"] as? String ?? "")
                                        }
                                        Button("移除此主题关联…") { requestRemoval(.fact, id: id, title: fact["content"] as? String ?? "事实", topic: topic) }
                                    }.disabled(!editable)
                                }
                            }
                        }
                        Button("添加事实…") { editor = .init(topic: topic, kind: .fact, itemID: nil, content: "") }.disabled(!editable)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("相关待办") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((data["relatedTasks"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, task in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    if task["starred"] as? Bool == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                    Text(task["content"] as? String ?? "").textSelection(.enabled)
                                }
                                if let description = task["description"] as? String, !description.isEmpty {
                                    Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if let id = task["taskId"] as? String, !id.hasPrefix("local_") {
                                    HStack {
                                        Button("编辑待办…") {
                                            editor = .init(topic: topic, kind: .task, itemID: id, content: task["content"] as? String ?? "",
                                                description: task["description"] as? String ?? "", starred: task["starred"] as? Bool ?? false)
                                        }
                                        Button("标记完成") { model.completeTopicTask(id: id, target: topic) }
                                        Button("删除官方待办…", role: .destructive) { requestRemoval(.task, id: id, title: task["content"] as? String ?? "待办", topic: topic) }
                                    }.disabled(!editable)
                                }
                            }
                        }
                        Button("添加官方待办…") { editor = .init(topic: topic, kind: .task, itemID: nil, content: "") }.disabled(!editable)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("相关事件") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((data["relatedEvents"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, event in
                            HStack {
                                Text(event["title"] as? String ?? "事件").textSelection(.enabled)
                                Spacer()
                                if let id = event["eventId"] as? String {
                                    Button("移除此主题关联…") { requestRemoval(.event, id: id, title: event["title"] as? String ?? "事件", topic: topic) }
                                        .disabled(!editable)
                                }
                            }
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sheet(item: $editor) { item in OfficialTopicItemEditor(model: model, target: item) }
            .alert(removal?.kind == .task ? "删除官方待办？" : "从主题移除关联？", isPresented: $showRemoval) {
                Button("取消", role: .cancel) { removal = nil }
                Button(removal?.kind == .task ? "删除待办" : "移除关联", role: .destructive) {
                    guard let removal else { return }
                    if removal.kind == .task { model.deleteTopicTask(id: removal.id, target: removal.target) }
                    else { model.unlinkTopicContent(id: removal.id, fact: removal.kind == .fact, target: removal.target) }
                    self.removal = nil
                }
            } message: {
                Text(removal?.kind == .task
                    ? "将删除官方账号中的“\(removal?.title ?? "")”，其他地方引用的也是同一条待办。"
                    : "将从当前主题移除“\(removal?.title ?? "")”的关联，源记录保留。")
            }
            .onChange(of: model.accountGeneration) { _ in editor = nil; removal = nil; showRemoval = false }
            .onChange(of: model.selectedTopicID) { _ in editor = nil; removal = nil; showRemoval = false }
        }
    }
    private func requestRemoval(_ kind: Removal.Kind, id: String, title: String, topic: OfficialTopicEditTarget) {
        removal = Removal(kind: kind, id: id, title: title, target: topic); showRemoval = true
    }
}
