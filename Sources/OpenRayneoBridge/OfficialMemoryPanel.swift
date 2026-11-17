// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialMemoryPanel: View {
    @ObservedObject private var model = OfficialMemoryModel.shared
    @ObservedObject private var cloudAudio = OfficialCloudAudioModel.shared
    @State private var pendingDeletion: (taskID: String, account: UUID, title: String)?
    @State private var showDeleteConfirmation = false
    @State private var summaryEditor: OfficialSummaryEditTarget?
    @State private var summaryDeletion: OfficialSummaryEditTarget?
    @State private var showSummaryDeleteConfirmation = false
    @State private var transcriptEditor: OfficialTranscriptEditTarget?
    @State private var speakerEditor: OfficialSpeakerEditTarget?
    @State private var topicEditor: OfficialTopicEditTarget?
    @State private var confirmDisableRecommendations = false
    @State private var recommendationAccount: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("官方账号会话") { OfficialAccountPanel() }
            Text("管理官方账号的时间线、会话转写、摘要和主题。").foregroundStyle(.secondary)
            Text(model.configurationNotice).font(.caption).foregroundStyle(model.configured ? Color.secondary : Color.orange)
            Picker("官方内容", selection: $model.section) {
                Text("时间线").tag("timeline")
                Text("录音与会话").tag("sessions")
                Text("主题").tag("topics")
            }.pickerStyle(.segmented).disabled(model.busy)
            controls
            Text(model.contentSource).font(.caption).foregroundStyle(.secondary)
            if !model.cacheNotice.isEmpty { Text(model.cacheNotice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if model.busy {
                    ProgressView().controlSize(.small)
                    if model.canCancel { Button("取消读取") { model.cancel() } }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.headline)
                                if model.section != "timeline", let date = row.createdAt { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption) }
                                if let time = row.data["startTimeFormatted"] as? String { Text(time).font(.caption) }
                                if model.section == "topics", let status = row.data["status"] as? Int {
                                    Text([0: "整理中", 1: "活跃", 2: "已暂停", 3: "已删除", 9: "推荐"][status] ?? "状态 \(status)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if model.section == "sessions" { Text(status(row.data["status"])).font(.caption).foregroundStyle(.secondary) }
                                if let content = row.data["content"] as? String { Text(content).lineLimit(3).font(.callout) }
                            }
                            Spacer()
                            Button("查看") {
                                switch model.section {
                                case "sessions": model.loadSession(row)
                                case "topics": model.loadTopic(row)
                                default: model.showTimeline(row)
                                }
                            }.disabled(model.busy)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if rows.isEmpty { Text("尚无已读取的记录。选择日期或类型后点击读取。").foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 100, maxHeight: 300)
            if let data = model.selectedData {
                Divider()
                Text(model.selectedTitle).font(.headline)
                if model.selectedKind == "session", let taskID = model.selectedCloudTaskID {
                    HStack {
                        Button("刷新会话内容") { model.refreshSelectedSession() }
                        Button("刷新摘要状态") { model.refreshSelectedSummaries() }
                        Button("编辑" + (model.selectedTranscriptKind?.title ?? "转写")) { transcriptEditor = model.transcriptEditorTarget() }
                            .disabled(!model.canEditTranscript)
                        Button("管理说话人") { speakerEditor = model.speakerEditorTarget() }
                            .disabled(!model.canEditTranscript)
                        if let item = model.selectedAudioItem {
                            Button("下载音频到资料库") { cloudAudio.download(item, configuration: model.accountReference) }
                                .disabled(cloudAudio.busy || !cloudAudio.configured)
                        }
                        Spacer()
                        Button("删除云会话", role: .destructive) {
                            pendingDeletion = (taskID, model.accountGeneration, model.selectedTitle)
                            showDeleteConfirmation = true
                        }
                    }.disabled(model.busy)
                    Text(cloudAudio.notice).font(.caption).foregroundStyle(.secondary)
                    summaryControls
                }
                if model.selectedKind == "topic" { OfficialTopicActionsPanel(model: model) }
                detail(data)
                DisclosureGroup("原始记录") {
                    Text(json(data)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            DisclosureGroup("官方会话配置") {
                Text("可在官方账号面板导入已有会话并手动刷新，保存后本页即时切换；也支持 App 启动环境中的 RAYNEO_ACCESS_TOKEN。区域、业务域名和国家码需对应实际账号会话。修改启动环境需重启 App。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("清理当前账号的本地缓存") { model.clearCachedContent() }.disabled(model.busy)
        }
        .onChange(of: model.section) { _ in model.restoreCachedList() }
        .onChange(of: model.taskType) { _ in model.restoreCachedList() }
        .onChange(of: model.day) { _ in model.restoreCachedList() }
        .onChange(of: model.timezone) { _ in model.restoreCachedList() }
        .onChange(of: model.accountGeneration) { _ in
            pendingDeletion = nil; showDeleteConfirmation = false
            summaryEditor = nil; summaryDeletion = nil; showSummaryDeleteConfirmation = false
            transcriptEditor = nil; speakerEditor = nil
            topicEditor = nil
            confirmDisableRecommendations = false; recommendationAccount = nil
        }
        .onChange(of: model.selectedCloudTaskID) { _ in
            summaryEditor = nil; summaryDeletion = nil; showSummaryDeleteConfirmation = false
            transcriptEditor = nil; speakerEditor = nil
        }
        .alert("删除官方云会话？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) {
                if let target = pendingDeletion { model.deleteSession(taskID: target.taskID, expectedAccount: target.account) }
                pendingDeletion = nil
            }
        } message: {
            Text("将从官方云账号删除“\(pendingDeletion?.title ?? "")”及其会话内容。本地录音库中的独立音频文件保留。")
        }
        .alert("删除这份摘要？", isPresented: $showSummaryDeleteConfirmation) {
            Button("取消", role: .cancel) { summaryDeletion = nil }
            Button("删除", role: .destructive) {
                if let target = summaryDeletion {
                    model.deleteSummary(id: target.summaryID, expectedTaskID: target.taskID, expectedAccount: target.account)
                }
                summaryDeletion = nil
            }
        } message: {
            Text("将从官方云端删除“\(summaryDeletion?.displayTitle ?? "")”。会话音频和其他摘要保留。")
        }
        .sheet(item: $summaryEditor) { target in OfficialSummaryEditor(model: model, target: target) }
        .sheet(item: $transcriptEditor) { target in OfficialTranscriptEditor(model: model, target: target) }
        .sheet(item: $speakerEditor) { target in OfficialSpeakerEditor(model: model, target: target) }
        .sheet(item: $topicEditor) { target in OfficialTopicEditor(model: model, target: target) }
        .alert("关闭官方主题推荐？", isPresented: $confirmDisableRecommendations) {
            Button("取消", role: .cancel) { recommendationAccount = nil }
            Button("关闭推荐") {
                if let account = recommendationAccount { model.disableTopicRecommendations(expectedAccount: account) }
                recommendationAccount = nil
            }
        } message: { Text("将同步关闭当前雷鸟官方账号的主题推荐，已有主题保留。") }
    }

    private var summaryControls: some View {
        DisclosureGroup("生成与重试官方摘要") {
            VStack(alignment: .leading, spacing: 10) {
                Button("读取官方模板与模型") { model.loadSummaryCatalog() }.disabled(model.busy)
                Picker("模型", selection: $model.selectedSummaryModel) {
                    Text("请选择可用模型").tag("")
                    ForEach(model.summaryModels) { item in
                        Text(item.displayName + (item.usable ? "" : "（不可用）")).tag(item.id).disabled(!item.usable)
                    }
                }
                Picker("模板", selection: $model.selectedSummaryTemplate) {
                    Text("请选择模板").tag("")
                    ForEach(model.summaryTemplates) { item in Text(item.emoji + " " + item.displayName).tag(item.id) }
                }
                if let template = model.summaryTemplates.first(where: { $0.id == model.selectedSummaryTemplate }) {
                    Text(template.displayDescription).font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.summarySourceNotice { Text(message).font(.caption).foregroundStyle(.orange) }
                Button("按模板生成摘要") { model.createSelectedSummary() }
                    .disabled(model.busy || model.usableSummaryModel == nil || model.selectedSummaryTemplate.isEmpty || model.summarySourceNotice != nil)
                Text("使用官方账号的云摘要服务；模型权限及额度由该账号决定。提交后可手动刷新任务状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy).padding(.top, 6)
        }
    }

    private var rows: [OfficialMemoryRow] {
        switch model.section {
        case "sessions": return model.sessions
        case "topics": return model.topics
        default: return model.timeline
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.section {
        case "sessions":
            HStack {
                Picker("类型", selection: $model.taskType) {
                    Text("全部").tag("all"); Text("录音").tag("recording"); Text("字幕").tag("cc")
                    Text("会议").tag("meeting"); Text("对话").tag("conversation")
                }.frame(width: 190).disabled(model.busy)
                Button("读取会话") { model.loadSessions() }.disabled(model.busy)
                Button("读取更多") { model.loadSessions(next: true) }.disabled(!model.canLoadNext)
                if let count = model.sessionTotal { Text("已加载 \(model.sessions.count) / 云端 \(count)").font(.caption).foregroundStyle(.secondary) }
            }
        case "topics":
            HStack {
                Button("读取主题") { model.loadTopics() }.disabled(model.busy)
                Button("刷新所选主题") { model.refreshSelectedTopic() }.disabled(model.busy || !model.configured || model.selectedTopicID == nil)
                Button("新建主题…") { topicEditor = model.topicEditorTarget(new: true) }.disabled(model.busy || !model.configured)
                Button("关闭主题推荐…") { recommendationAccount = model.accountGeneration; confirmDisableRecommendations = true }
                    .disabled(model.busy || !model.configured)
                if let active = model.activeTopicCount, let limit = model.topicLimit {
                    Text("活跃主题 \(active) / \(limit)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.topicMutationNotice.isEmpty { Text(model.topicMutationNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        default:
            HStack {
                DatePicker("日期", selection: $model.day, displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: model.timezone) ?? .current).frame(maxWidth: 210)
                TextField("时区，例如 Asia/Shanghai", text: $model.timezone).frame(maxWidth: 240)
                Button("读取时间线") { model.loadTimeline() }
            }.disabled(model.busy)
            Text("当前读取结果：\(model.timelineScope)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func detail(_ data: [String: Any]) -> some View {
        switch model.selectedKind {
        case "session":
            let recording = data["recording"] as? [String: Any] ?? [:]
            Text("会话：" + status((data["aiTask"] as? [String: Any])?["status"]) + " · 录音：" + status(recording["status"], recording: true))
                .font(.caption).foregroundStyle(.secondary)
            if let reason = (data["aiTask"] as? [String: Any])?["reasonMsg"] as? String, !reason.isEmpty {
                Text(reason).foregroundStyle(.orange).textSelection(.enabled)
            }
            let summary = data["summary"] as? [[String: Any]] ?? []
            let identities = model.selectedSpeakerIdentities
            clips(recording["clips"] as? [[String: Any]] ?? [], title: "转写")
            if !summary.isEmpty {
                ForEach(Array(summary.enumerated()), id: \.offset) { index, item in
                    let content = item["content"] as? [String: Any] ?? [:]
                    let names = summaryNames(item, identities: identities)
                    GroupBox(OfficialSummarySpeakerNames.display(item["name"] as? String ?? "摘要 \(index + 1)", names: names)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(status(item["status"])).font(.caption).foregroundStyle(.secondary)
                            if let language = item["languageCode"] as? String { Text(language).font(.caption).foregroundStyle(.secondary) }
                            if let reason = item["reasonMsg"] as? String, !reason.isEmpty { Text(reason).foregroundStyle(.orange).textSelection(.enabled) }
                            if let text = content["content"] as? String {
                                Text(OfficialSummarySpeakerNames.display(text, names: names)).textSelection(.enabled)
                            }
                            if let outline = content["outline"] as? [[String: Any]], !outline.isEmpty {
                                DisclosureGroup("提纲") {
                                    ForEach(Array(outline.enumerated()), id: \.offset) { _, line in
                                        HStack(alignment: .top) {
                                            if let time = OfficialMemoryRow.text(line["timestamp"]) { Text(time).foregroundStyle(.secondary) }
                                            if let text = line["subtitle"] as? String {
                                                Text(OfficialSummarySpeakerNames.display(text, names: names)).textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                            }
                            if let map = content["mindMap"] as? [String: Any] {
                                DisclosureGroup("思维导图") {
                                    let lines = mindMapLines(map)
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(OfficialSummarySpeakerNames.display(line.title, names: names))
                                            .padding(.leading, CGFloat(line.depth) * 14).textSelection(.enabled)
                                    }
                                }
                            }
                            if (item["status"] as? NSNumber)?.intValue == 3,
                               let id = OfficialMemoryRow.text(item["summaryId"]) {
                                Button("使用所选模型重试") { model.retrySelectedSummary(id: id) }
                                    .disabled(model.busy || model.usableSummaryModel == nil || model.summarySourceNotice != nil)
                            }
                            summaryActions(item, identities: identities)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let text = recording["summary"] as? String { textSection("早期摘要", text) }
            if let cc = data["cc"] as? [[String: Any]] {
                clips(cc, title: "字幕转写")
            } else if let cc = data["cc"] as? [String: Any] {
                clips(cc["clips"] as? [[String: Any]] ?? [], title: "字幕转写")
            }
        case "topic":
            if let text = data["overview"] as? String { textSection("主题概览", text) }
            namedItems("要点", data["keyPoints"], name: "keyPointsName", content: "keyPointsDescription")
            namedItems("进展", data["progress"], name: "progressName", content: "progressDescription")
            OfficialTopicContentPanel(model: model, data: data)
        default:
            if let text = data["content"] as? String { textSection("内容", text) }
            if let text = data["summaryContent"] as? String { textSection("摘要", text) }
            clips(data["clips"] as? [[String: Any]] ?? [], title: "转写片段")
            ForEach(Array((data["transcriptionInfos"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, item in
                clips(item["clips"] as? [[String: Any]] ?? [], title: "原始转写")
            }
            let messages = data["messages"] as? [[String: Any]] ?? []
            if !messages.isEmpty {
                GroupBox("对话") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            if let text = message["text"] as? String {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let speaker = message["speakerLabel"] as? String { Text(speaker).font(.caption).foregroundStyle(.secondary) }
                                    Text(text).textSelection(.enabled)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func summaryNames(_ summary: [String: Any], identities: [OfficialSpeakerIdentity]) -> [String: String] {
        let content = summary["content"] as? [String: Any] ?? [:]
        let texts = [summary["name"] as? String ?? "", content["content"] as? String ?? ""] + summaryReferenceTexts(summary)
        return OfficialSummarySpeakerNames.resolve(identities: identities, texts: texts,
            labels: .forSummary(languageCode: summary["languageCode"] as? String))
    }

    private func summaryReferenceTexts(_ summary: [String: Any]) -> [String] {
        let content = summary["content"] as? [String: Any] ?? [:]
        var texts: [String] = []
        texts += (content["outline"] as? [[String: Any]] ?? []).compactMap { $0["subtitle"] as? String }
        if let map = content["mindMap"] as? [String: Any] { texts += mindMapLines(map).map(\.title) }
        return texts
    }

    @ViewBuilder private func summaryActions(_ summary: [String: Any], identities: [OfficialSpeakerIdentity]) -> some View {
        if let id = OfficialMemoryRow.text(summary["summaryId"]), model.isStoredSummary(id),
           let taskID = model.selectedCloudTaskID {
            let text = (summary["content"] as? [String: Any])?["content"] as? String
            let target = OfficialSummaryEditTarget(summaryID: id, taskID: taskID, account: model.accountGeneration,
                title: summary["name"] as? String ?? "摘要", markdown: text ?? "", speakerIdentities: identities,
                speakerReferenceTexts: summaryReferenceTexts(summary), speakerLanguageCode: summary["languageCode"] as? String)
            HStack {
                if text != nil { Button("编辑正文") { summaryEditor = target } }
                Button("删除摘要", role: .destructive) {
                    summaryDeletion = target; showSummaryDeleteConfirmation = true
                }.disabled(!model.canDeleteSummary(id: id))
            }.disabled(model.busy)
        }
    }

    @ViewBuilder private func clips(_ values: [[String: Any]], title: String) -> some View {
        if !values.isEmpty {
            GroupBox(title) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, clip in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if let speaker = clip["speakerName"] as? String { Text(speaker) }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let text = clip["content"] as? String { Text(text).textSelection(.enabled) }
                            if let text = clip["translateContent"] as? String, !text.isEmpty { Text(text).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func namedItems(_ title: String, _ value: Any?, name: String, content: String) -> some View {
        if let items = value as? [[String: Any]], !items.isEmpty {
            GroupBox(title) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = item[name] as? String { Text(title).font(.subheadline.weight(.medium)).textSelection(.enabled) }
                            if let text = item[content] as? String { Text(text).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func textSection(_ title: String, _ text: String) -> some View {
        if !text.isEmpty { GroupBox(title) { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    }

    private func json(_ data: [String: Any]) -> String {
        guard let value = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else { return "无法显示原始记录。" }
        return String(decoding: value, as: UTF8.self)
    }

    private func status(_ value: Any?, recording: Bool = false) -> String {
        guard let raw = value as? NSNumber else { return "状态未知" }
        let index = raw.intValue - (recording ? 1 : 0)
        return [0: "新建", 1: "处理中", 2: "已完成", 3: "失败"][index] ?? "未知状态 \(raw)"
    }

    private func mindMapLines(_ node: [String: Any], depth: Int = 0) -> [(title: String, depth: Int)] {
        let own = (node["title"] as? String).map { [(title: $0, depth: depth)] } ?? []
        return own + (node["children"] as? [[String: Any]] ?? []).flatMap { mindMapLines($0, depth: depth + 1) }
    }
}
