// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct MemoryLibraryPanel: View {
    @ObservedObject var model: MemoryLibraryModel
    var openRecording: ((UUID) -> Void)? = nil
    @State private var confirmingProjectRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if OfficialCloudPolicy.enabled {
                DisclosureGroup("官方云回忆与会话") { OfficialMemoryPanel().padding(.vertical, 8) }
            }
            HStack {
                Text("本地回忆与项目").font(.title2.weight(.semibold))
                Spacer()
                Button("刷新已有记录") { Task { await model.refresh() } }.disabled(model.busy)
            }
            Text("整理这台 Mac 的助手会话、录音与手机同步副本。Agent 分析和笔记可经本机 API 关联原记录回写手机；本地项目独立保存。")
                .foregroundStyle(.secondary)
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    if model.summarizing { Button("取消摘要") { model.cancelSummary() } }
                }
            }
            filters
            projectControls
            if !model.readWarnings.isEmpty {
                DisclosureGroup("来源读取提示（\(model.readWarnings.count)）") {
                    ForEach(Array(model.readWarnings.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                entryList.frame(width: 280)
                if let entry = model.selected {
                    ScrollView { detail(entry).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minHeight: 450)
                } else {
                    Text("没有选中的记录。可以刷新已有内容或调整筛选。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
                }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("移除这个本地项目？", isPresented: $confirmingProjectRemoval) {
            Button("移除项目", role: .destructive) { model.deleteProject() }
        } message: { Text("只解除项目归档。助手日志、录音和本地标注均保留。") }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索原文、回复、工具记录、标题、标注和摘要", text: $model.search)
            HStack {
                Picker("来源", selection: $model.sourceFilter) {
                    Text("全部来源").tag("all")
                    Text("助手 ASR 会话").tag("assistant")
                    Text("录音内容库").tag("recording")
                    Text("手机同步记录").tag("phone")
                }.frame(width: 210)
                Picker("项目", selection: $model.projectFilter) {
                    Text("全部项目").tag("all")
                    Text("未归档").tag("unassigned")
                    ForEach(model.projects) { project in
                        Text(project.name + (project.archived ? " · 已封存" : "")).tag(project.id.uuidString)
                    }
                }.frame(minWidth: 180)
                Toggle("按日期", isOn: $model.filterDay)
                if model.filterDay {
                    DatePicker("日期", selection: $model.day, displayedComponents: .date).labelsHidden()
                }
            }
        }
    }

    private var projectControls: some View {
        HStack {
            TextField("新建本地项目", text: $model.projectNameDraft).frame(maxWidth: 250)
            Button("创建") { model.createProject() }
                .disabled(!model.canEdit || model.projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let project = model.selectedProject {
                Button(project.archived ? "重新打开项目" : "封存项目") { model.toggleProjectArchive() }
                    .disabled(!model.canEdit)
                Button("移除项目", role: .destructive) { confirmingProjectRemoval = true }.disabled(!model.canEdit)
            }
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(model.filteredEntries, selection: $model.selectedID) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayTitle(entry)).font(.headline).lineLimit(2)
                    Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                    Text(entry.sourceLabel).lineLimit(2)
                    Text(entry.kind == "assistant" ? "\(entry.sentences.count) 个整句 · \(entry.requests.count) 个判定请求" : entry.status)
                    if !model.projectNames(entry).isEmpty { Text(model.projectNames(entry)).foregroundStyle(.primary) }
                }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 4).tag(entry.id)
            }.frame(minHeight: 450)
            Text("筛选结果 \(model.filteredEntries.count) 条；会话内按句子 ID 保留原文。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ entry: MemoryLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.displayTitle(entry)).font(.headline)
                Spacer()
                Button("来源文件") { model.revealSource() }
                if entry.audioPath != nil { Button("音频位置") { model.revealAudio() } }
                if let id = entry.recordingID, let openRecording {
                    Button("打开录音库") { openRecording(id) }
                }
            }
            Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.status).font(.caption).foregroundStyle(.secondary)
            annotationEditor
            if entry.kind == "assistant" { sentenceList(entry) }
            else { textBlock("录音转写", text: entry.transcript, empty: "尚未转写；可在录音内容库中手动转写。") }
            summary(entry)
            if !entry.requests.isEmpty {
                DisclosureGroup("Decision、回复与工具记录（\(entry.requests.count)）") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entry.requests) { request in requestDetail(request) }
                    }
                }
            }
            DisclosureGroup("来源与完整性说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.sourcePath).textSelection(.enabled)
                    Text("本地来源 ID：\(entry.id)").textSelection(.enabled)
                    ForEach(Array(entry.provenance.enumerated()), id: \.offset) { _, note in Text(note).textSelection(.enabled) }
                    if !entry.tags.isEmpty { Text("录音标签：" + entry.tags.joined(separator: "、")) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.trailing, 8)
    }

    private var annotationEditor: some View {
        GroupBox("本地标注与项目归档") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("自定义标题（留空沿用来源标题）", text: $model.titleDraft)
                Text("标注").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.noteDraft).frame(height: 75)
                if model.projects.isEmpty {
                    Text("先创建本地项目，再将这条记录归档。原始记录也可同时属于多个项目。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.projects) { project in
                        Toggle(project.name + (project.archived ? " · 已封存" : ""), isOn: Binding(
                            get: { model.projectIDsDraft.contains(project.id) },
                            set: { if $0 { model.projectIDsDraft.insert(project.id) } else { model.projectIDsDraft.remove(project.id) } }))
                    }
                }
                Button("保存本地标注与归档") { model.saveDetails() }.disabled(!model.canEdit)
            }.padding(6)
        }
    }

    private func sentenceList(_ entry: MemoryLibraryEntry) -> some View {
        GroupBox("ASR 原始整句（包含 ignore）") {
            if entry.sentences.isEmpty { Text("这份会话没有最终整句记录。").foregroundStyle(.secondary) }
            else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.sentences) { sentence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sentence.text).textSelection(.enabled)
                            if let channel = sentence.sourceChannel {
                                Text("通道\(channel) · \(sentence.identityBasis ?? "unknown")").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(sentence.receivedAt, format: .dateTime.hour().minute().second())
                                if let begin = sentence.beginMS, let end = sentence.endMS {
                                    Text("轮次偏移 \(begin)–\(end) ms")
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            Text("\(sentence.roundID) · \(sentence.id)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(6)
            }
        }
    }

    private func summary(_ entry: MemoryLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entry.originalSummary.isEmpty { textBlock("录音库已有摘要", text: entry.originalSummary, empty: "") }
            let annotation = model.selectedAnnotation
            textBlock("本地回忆摘要", text: annotation.summary, empty: "尚未生成摘要。")
            if let modelName = annotation.summaryModel {
                Text("\(modelName) · 配置 \(annotation.summaryPromptVersion ?? "未知")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(annotation.summary.isEmpty ? "生成所选记录摘要" : "重新生成所选记录摘要") { model.summarizeSelected() }
                .disabled(!model.canEdit || entry.text.isEmpty)
            Text("仅点击后，所选记录的原始转写会发送到 AI 页已保存的 DeepSeek 服务配置。不会发送项目其他记录，不调用工具或派发任务。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func requestDetail(_ request: MemoryRequest) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.receivedAt, format: .dateTime.hour().minute().second()).font(.caption)
                Text("请求 \(request.id)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if !request.promptVersion.isEmpty { Text("配置：\(request.promptVersion)").font(.caption) }
                if !request.completeness.isEmpty { Text("完整性：\(request.completeness)") }
                if !request.routing.isEmpty { Text("路由：\(request.routing)") }
                if !request.route.isEmpty { Text("已消费分支：\(request.route)") }
                DisclosureGroup("该次输入快照（不重复计入原文）") {
                    Text(request.current.joined(separator: "\n")).textSelection(.enabled)
                    if !request.previous.isEmpty {
                        Text("上次成功参照").font(.caption).foregroundStyle(.secondary)
                        Text(request.previous.joined(separator: "\n")).textSelection(.enabled)
                    }
                }
                if !request.reply.isEmpty {
                    Text("回复 · \(request.replyModel)").font(.caption).foregroundStyle(.secondary)
                    Text(request.reply).textSelection(.enabled)
                }
                ForEach(Array(request.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func textBlock(_ title: String, text: String, empty: String) -> some View {
        GroupBox(title) {
            Text(text.isEmpty ? empty : text).textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
