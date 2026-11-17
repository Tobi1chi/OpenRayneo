// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialRecordingUploadPanel: View {
    let entry: RecordingLibraryEntry
    let localBusy: Bool
    @ObservedObject private var model = OfficialRecordingUploadModel.shared
    @State private var recordingStart = Date()
    @State private var confirmingResubmission = false

    private var record: OfficialRecordingUploadRecord? { model.record(for: entry) }
    private var jobID: UUID { record?.entryID ?? entry.id }
    private var canUseCurrentUpload: Bool { model.canUseCurrentUpload(for: entry) }
    private var canStart: Bool {
        model.configured && (!model.busy || canUseCurrentUpload) && !localBusy
            && ((entry.finalized && entry.available) || record?.stagedFilePath != nil)
            && !["accepted", "completed", "submitting", "uncertain", "failed"].contains(record?.transcriptionState ?? "")
            && (!(record?.requestedTranscription == true || model.requestTranscription)
                || record?.summaryModel != nil || model.usableModel != nil)
    }

    var body: some View {
        GroupBox("官方云备份与转写") {
            VStack(alignment: .leading, spacing: 10) {
                Text("将这条完整录音发送至雷鸟官方云服务。官方转写与本页的百炼转写、DeepSeek 摘要分别管理。")
                    .font(.caption).foregroundStyle(.secondary)
                if let record {
                    Text(record.phase).font(.callout)
                    Text("云任务：\(record.taskID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("录音开始：" + record.recordingStart.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(record.backupAudio ? "正式云备份" : "临时上传用于转写").font(.caption)
                    if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                } else {
                    DatePicker("录音实际开始时间", selection: $recordingStart)
                    Text("导入、恢复和剪辑副本的创建时间可能不是原录音时间，请在首次上传前确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("国家／地区代码", text: $model.regionCode)
                    Toggle("将音频备份到正式云空间", isOn: $model.backupAudio)
                    Toggle("中断后自动继续已加入队列的任务", isOn: $model.resumeAutomatically)
                }
                Toggle("提交官方转写与摘要", isOn: Binding(
                    get: { record?.requestedTranscription == true || model.requestTranscription },
                    set: { model.requestTranscription = $0 }))
                    .disabled((model.busy && !canUseCurrentUpload) || record?.requestedTranscription == true)
                if model.requestTranscription || record?.requestedTranscription == true {
                    HStack {
                        Button("读取官方模型") { model.loadModels() }.disabled(model.modelsLoading || !model.configured)
                        Picker("摘要模型", selection: $model.selectedModel) {
                            Text("请选择可用模型").tag("")
                            ForEach(model.models) { item in
                                Text(item.displayName + (item.usable ? "" : "（不可用）")).tag(item.id).disabled(!item.usable)
                            }
                        }.disabled(model.modelsLoading || (model.busy && !canUseCurrentUpload) || record?.requestedTranscription == true)
                    }
                    if !model.modelNotice.isEmpty { Text(model.modelNotice).font(.caption).foregroundStyle(.secondary) }
                    if let code = record?.summaryModel {
                        Text("当前云任务使用：" + (model.models.first { $0.id == code }?.displayName ?? code))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("识别语言，auto 自动检测", text: $model.sourceLanguage)
                        Toggle("区分说话人", isOn: $model.separateSpeakers)
                    }.disabled(record?.requestedTranscription == true || (model.busy && !canUseCurrentUpload))
                }
                HStack {
                    Button(canUseCurrentUpload ? "复用当前上传" : record == nil ? "开始官方上传" : "继续上传／提交转写") {
                        model.start(entry: entry, recordingStart: recordingStart)
                    }.disabled(!canStart)
                    Button("刷新云任务结果") { model.refreshResult(entryID: jobID) }
                        .disabled(model.busy || record?.sessionCreated != true)
                    if ["submitting", "uncertain", "failed"].contains(record?.transcriptionState ?? "") {
                        Button("重新提交转写") { confirmingResubmission = true }
                            .disabled(model.busy || localBusy || (record?.stagedFilePath == nil && (!entry.available || !entry.finalized)))
                    }
                }
                if model.busy, model.activeEntryID == jobID {
                    HStack { ProgressView(value: model.progress); Button("取消当前操作") { model.cancel() } }
                }
                if model.pollingEntryIDs.contains(jobID) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在等待云转写结果…").font(.caption)
                        Button("停止等待") { model.stopPolling(entryID: jobID) }
                    }
                }
                Text(model.notice).font(.caption).foregroundStyle(model.configured ? Color.secondary : Color.orange).textSelection(.enabled)
                if let detail = model.results[jobID] { result(detail) }
            }.padding(6)
        }
        .onAppear { loadSelection() }
        .onChange(of: entry.id) { _ in loadSelection(); confirmingResubmission = false }
        .alert("重新提交官方转写？", isPresented: $confirmingResubmission) {
            Button("取消", role: .cancel) { }
            Button("重新提交") { model.start(entry: entry, recordingStart: recordingStart, allowResubmission: true) }
        } message: {
            Text("将复用同一云任务和已上传音频。若上次提交结果未确认，建议先刷新；重复提交可能再次处理并使用账号额度。")
        }
    }

    private func loadSelection() {
        recordingStart = record?.recordingStart
            ?? entry.startedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? entry.createdAt
        if let record {
            model.requestTranscription = record.requestedTranscription
            model.sourceLanguage = record.sourceLanguage; model.separateSpeakers = record.separateSpeakers
        }
    }

    @ViewBuilder private func result(_ detail: [String: Any]) -> some View {
        let recording = detail["recording"] as? [String: Any] ?? [:]
        if let reason = recording["message"] as? String ?? recording["reasonMsg"] as? String
            ?? (detail["aiTask"] as? [String: Any])?["reasonMsg"] as? String,
           !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        let text = (recording["clips"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }.joined(separator: "\n")
        if !text.isEmpty {
            DisclosureGroup("官方转写结果") {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if (detail["summary"] as? [[String: Any]] ?? []).isEmpty,
           let legacy = recording["summary"] as? String, !legacy.isEmpty {
            DisclosureGroup("已有摘要（旧格式）") {
                Text(legacy).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        ForEach(Array((detail["summary"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, summary in
            if let reason = summary["reasonMsg"] as? String, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let text = (summary["content"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                DisclosureGroup(summary["name"] as? String ?? "官方摘要") {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
