// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialCloudAudioPanel: View {
    @ObservedObject var model: OfficialCloudAudioModel
    @State private var confirmDisableSync = false

    var body: some View {
        DisclosureGroup("官方云音频双向同步") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("按官方配置自动双向同步", isOn: Binding(get: { model.automaticallyDownload },
                    set: { model.setAutomatic($0) })).disabled(!model.configured)
                Text("完整核对云会话后，补传云端缺失的本地音频，并按官方自动下载设置保存云音频。只关联同一云任务；不会为本地历史录音另建云会话。")
                    .font(.caption).foregroundStyle(.secondary)
                if let config = model.cloudConfiguration {
                    Text("官方同步：\(config.syncFlag ? "开启" : "关闭") · 自动下载：\(config.autoSync ? "开启" : "关闭") · \(config.onlyWifiSync ? "仅 Wi-Fi" : "允许当前网络")")
                        .font(.caption).foregroundStyle(.secondary)
                    configurationEditor
                    if let capacity = config.capacity, capacity > 0 {
                        Text("云空间：\(bytes(config.usedCapacity ?? 0)) / \(bytes(capacity))（1024 进制）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("读取官方配置") { model.readConfiguration() }
                    Button("核对差集并加入补云队列") { model.synchronize(downloadMissing: false) }
                    Button("立即双向同步") { model.synchronize(downloadMissing: true) }
                }.disabled(!model.configured || model.busy)
                if let difference = model.difference {
                    Text("本地音频待补云 \(difference.localOnly.count) 条 · 云音频待下载 \(difference.cloudOnly.count) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.busy {
                    HStack {
                        ProgressView(value: model.progress)
                        if !model.writingConfiguration { Button("停止本轮同步") { model.cancel() } }
                    }
                }
                Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(records) { record in recordRow(record) }
                if !pendingItems.isEmpty {
                    Text("尚未保存到 Mac 的云音频").font(.callout)
                    ForEach(pendingItems, id: \.taskID) { item in
                        let reference = model.accountReference
                        HStack {
                            Text(item.title.isEmpty ? "未命名云会话" : item.title)
                            Spacer()
                            Button("下载") { model.download(item, configuration: reference) }
                                .disabled(model.busy || !model.canDownload(taskID: item.taskID))
                        }
                    }
                }
            }.padding(.top, 8)
        }
        .alert("关闭官方云同步？", isPresented: $confirmDisableSync) {
            Button("取消", role: .cancel) { }
            Button("关闭并保存", role: .destructive) { model.saveConfiguration() }
        } message: {
            Text("将停止按官方配置运行的音频上传和下载。已有云端内容保留。")
        }
        .onChange(of: model.accountReference?.identityEpoch) { _ in confirmDisableSync = false }
    }

    private var configurationEditor: some View {
        GroupBox("官方云设置") {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Toggle("启用官方云同步", isOn: $model.syncEnabledDraft)
                    Toggle("自动下载云端音频", isOn: $model.automaticDownloadDraft)
                    Toggle("仅通过 Wi-Fi 传输音频", isOn: $model.wifiOnlyDraft)
                }.disabled(model.writingConfiguration || !model.configured)
                HStack {
                    Button("保存官方配置") {
                        if model.configurationRequiresDisableConfirmation { confirmDisableSync = true }
                        else { model.saveConfiguration() }
                    }.disabled(!model.canSaveConfiguration)
                    Button("还原草稿") { model.resetConfigurationDraft() }
                        .disabled(!model.configurationDraftDirty || model.writingConfiguration)
                    if model.writingConfiguration { ProgressView().controlSize(.small) }
                }
                Text(model.configurationNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bytes(_ count: Int64) -> String {
        var value = Double(count), index = 0
        let units = ["B", "KB", "MB", "GB", "TB"]
        while abs(value) >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return value.formatted(.number.precision(.fractionLength(0...2))) + " " + units[index]
    }

    private var records: [OfficialCloudAudioRecord] {
        model.records.values.sorted { ($0.createdAtMilliseconds ?? 0) > ($1.createdAtMilliseconds ?? 0) }
    }
    private var pendingItems: [OfficialCloudAudioItem] {
        Array(model.cloudItems.filter { model.records[$0.taskID] == nil && $0.objectKey?.isEmpty == false }.prefix(20))
    }

    @ViewBuilder private func recordRow(_ record: OfficialCloudAudioRecord) -> some View {
        let reference = model.accountReference
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title.isEmpty ? "未命名云录音" : record.title).font(.callout)
                Text(model.isSuppressed(taskID: record.taskID, ownerScope: model.ownerScope) ? "已停止自动恢复" : stateName(record.state))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Spacer()
            if model.canDownload(taskID: record.taskID) {
                Button(record.state == "ready" ? "读取正文／恢复本地副本" : "继续下载／入库") {
                    model.download(.init(taskID: record.taskID, title: record.title, taskType: record.taskType,
                        createdAtMilliseconds: record.createdAtMilliseconds, bucketName: record.bucketName, objectKey: record.objectKey), configuration: reference)
                }.disabled(model.busy)
            }
        }
    }
    private func stateName(_ state: String) -> String {
        switch state {
        case "queued": return "等待下载"
        case "downloading": return "正在下载音频"
        case "downloaded": return "音频已下载，等待入库"
        case "preparing": return "正在准备可播放音频"
        case "ready": return "已加入录音资料库"
        case "paused": return "本轮已停止，完整文件保留"
        case "failed": return "尚未完成，可继续处理"
        default: return state
        }
    }
}
