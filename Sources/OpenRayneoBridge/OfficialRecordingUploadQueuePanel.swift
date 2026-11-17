// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialRecordingUploadQueuePanel: View {
    @ObservedObject var model: OfficialRecordingUploadModel
    @ObservedObject var background: OfficialRecordingUploadBackground
    @State private var expanded = false
    @State private var transfers = OfficialOSSTransferQueue.Snapshot(running: nil, waiting: [], completedPreemptions: 0)

    var body: some View {
        DisclosureGroup("官方录音后台同步与队列", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                transferStatus
                Toggle("自动继续已授权入队的任务", isOn: Binding(get: { background.policy.resumeQueued },
                    set: { background.updatePolicy(resume: $0) }))
                Toggle("自动备份此后由本机发起的完整原生录音", isOn: Binding(get: { background.policy.newNativeRecordings },
                    set: { background.updatePolicy(autoNative: $0) }))
                Text("开启时记录已有录音基线；历史录音、当时未传完的旧录音、导入及剪辑副本不会自动入队。新实时录音的开始时间以本机记录为准。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("同时包含眼镜发起或重连后首次发现的实时录音", isOn: Binding(
                    get: { background.policy.includeGlassesStarts == true },
                    set: { background.updatePolicy(includeGlassesStarts: $0) }))
                Text("首次发现的眼镜录音可能在连接前已经开始，本机记录的是收到开始事件的时间。此项默认关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("新录音同时提交官方转写与摘要", isOn: Binding(get: { background.policy.transcribeNewRecordings },
                    set: { background.updatePolicy(transcribe: $0) }))
                if background.policy.transcribeNewRecordings {
                    Text("自动任务模型：" + (background.policy.summaryModel ?? "尚未选择"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("系统自动同步仅使用 Wi-Fi", isOn: Binding(get: { background.policy.wifiOnly },
                    set: { background.updatePolicy(wifiOnly: $0) }))
                HStack {
                    Button("读取官方模型") { model.loadModels() }.disabled(model.modelsLoading)
                    Picker("新任务摘要模型", selection: $model.selectedModel) {
                        Text("请选择").tag("")
                        ForEach(model.models) { item in Text(item.displayName).tag(item.id).disabled(!item.usable) }
                    }.disabled(model.modelsLoading)
                    Button("更新自动任务模型") { background.updatePolicy(transcribe: true) }
                        .disabled(!background.policy.transcribeNewRecordings || model.usableModel == nil)
                }
                if !model.modelNotice.isEmpty { Text(model.modelNotice).font(.caption).foregroundStyle(.secondary) }
                TextField("新任务国家／地区代码", text: $model.regionCode)
                    .disabled(background.policy.newNativeRecordings)
                Text(background.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("立即处理已入队任务") { background.wake(reason: "用户手动处理", force: true) }
                ForEach(jobs, id: \.entryID) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.callout)
                            Text((record.paused == true ? "已暂停 · " : "") + record.phase)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if record.paused == true {
                            Button("继续") { model.setPaused(false, entryID: record.entryID) }.disabled(model.busy)
                        } else {
                            Button("暂停") { model.setPaused(true, entryID: record.entryID) }
                        }
                        Button("优先处理") { model.prioritize(entryID: record.entryID) }
                            .disabled(model.activeEntryID == record.entryID)
                    }
                }
                if jobs.isEmpty { Text("当前账号没有待处理的上传任务。").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8).disabled(!model.configured)
        }
        .task(id: expanded) {
            guard expanded else { return }
            while !Task.isCancelled {
                transfers = await OfficialOSSTransferQueue.shared.snapshot()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var transferStatus: some View {
        GroupBox("音频传输状态") {
            VStack(alignment: .leading, spacing: 4) {
                if let running = transfers.running, running.ownerScope == model.ownerScope {
                    Text((running.kind == .upload ? "正在上传音频" : "正在下载音频")
                        + (running.preemptionRequested ? " · 正在为优先任务让位" : ""))
                    Text(running.source == .systemCloudSync ? "系统同步" : running.source == .userInitiatedSync ? "手动发起" : "其他传输")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("当前没有正在传输的音频") }
                Text("等待传输 \(transfers.waiting.filter { $0.ownerScope == model.ownerScope }.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(transfers.awaitingResult.filter { $0.ownerScope == model.ownerScope }, id: \.id) { item in
                    HStack {
                        Text("仍未结束的超时" + (item.kind == .upload ? "上传" : "下载") + " · " + transferTitle(item))
                            .font(.caption).foregroundStyle(.orange).lineLimit(2)
                        Spacer()
                        Button("停止此传输") {
                            Task { await OfficialOSSTransferQueue.shared.cancelUnfinished(id: item.id, ownerScope: item.ownerScope) }
                        }
                    }
                }
                if transfers.completedPreemptions > 0 {
                    Text("传输队列本次运行已为优先任务让位 \(transfers.completedPreemptions) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var jobs: [OfficialRecordingUploadRecord] {
        model.records.values.filter { $0.needsUpload || $0.needsResult || $0.paused == true }
            .sorted { ($0.queuedAtMilliseconds ?? 0) < ($1.queuedAtMilliseconds ?? 0) }
    }

    private func transferTitle(_ item: OfficialOSSTransferQueue.Item) -> String {
        guard let id = item.taskID else { return "音频传输" }
        return model.records.values.first(where: { $0.taskID == id })?.title
            ?? OfficialCloudAudioModel.shared.records[id]?.title ?? id
    }
}
