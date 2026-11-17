// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
struct OfficialFeedbackPanel: View {
    @ObservedObject var model: OfficialFeedbackModel
    @State private var confirmSubmit = false
    @State private var confirmNew = false
    @State private var confirmRetry = false
    @State private var confirmImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            if !model.configured {
                Label("官方账号尚未登录；提交和分类读取将在登录后可用。", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.localDraftAvailable {
                Button("复制登录前草稿…") { confirmImport = true }.disabled(!model.editable)
            }
            if !model.persistenceNotice.isEmpty { Text(model.persistenceNotice).foregroundStyle(.orange) }
            if let number = model.draft.orderNo {
                LabeledContent("反馈编号", value: number).textSelection(.enabled)
            }
            form.disabled(!model.editable)
            attachments.disabled(!model.editable)
            if model.busy {
                ProgressView(value: model.progress)
                if !model.submitting { Button("停止准备／上传") { model.cancel() } }
            }
            if model.collectingLogs { HStack { ProgressView().controlSize(.small); Text("正在收集日志…"); Button("停止等待") { model.cancel() } } }
            actions
        }
        .onChange(of: model.draft) { _ in model.saveDraft() }
        .confirmationDialog("向雷鸟官方提交这份反馈？", isPresented: $confirmSubmit) {
            Button("上传附件并提交反馈") { model.submit() }
        } message: {
            Text("\(model.selectedTitle)\n\(model.draft.title)\n包含 \(model.draft.attachments.count) 个附件及填写的联系方式。")
        }
        .confirmationDialog("新建一份空白反馈？", isPresented: $confirmNew) {
            Button("新建空白草稿") { model.newDraft(keepContent: false) }
        } message: { Text("当前草稿将被替换，已发送的反馈会保留在官方服务。") }
        .confirmationDialog("将内容复制为新反馈？", isPresented: $confirmRetry) {
            Button("复制内容并重新取号") { model.newDraft(keepContent: true) }
        } message: { Text("上一份反馈可能已经被官方接受。请先核对，重新提交可能创建重复工单。") }
        .confirmationDialog("复制登录前草稿到当前账号？", isPresented: $confirmImport) {
            Button("复制并替换当前草稿") { model.copyLocalDraft() }
        } message: { Text("当前账号的编辑草稿将被替换；登录前的原草稿与源附件会保留。复制后需要重新选择官方分类。") }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("问题描述") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("官方分类", selection: Binding(get: { model.draft.categoryID }, set: { model.selectCategory($0) })) {
                            Text("请选择").tag(Int?.none)
                            ForEach(model.choices) { choice in Text(choice.title).tag(Optional(choice.id)) }
                        }
                        Button("读取分类") { model.loadCategories() }.disabled(!model.configured)
                    }
                    TextField("问题标题", text: $model.draft.title)
                    Text("复现步骤、实际表现和期望结果").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.draft.description).font(.body).frame(minHeight: 110)
                        .padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    if let options = options(model.selectedCategory?.displayFields?["description"]?.frequencyOfIssue), !options.isEmpty {
                        Picker("发生频率", selection: $model.draft.frequency) {
                            Text("请选择").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                    } else { TextField("发生频率（可选）", text: $model.draft.frequency) }
                    if let options = options(model.selectedCategory?.displayFields?["description"]?.lastOccurrenceTime), !options.isEmpty {
                        Picker("最近发生时间", selection: $model.draft.lastOccurrence) {
                            Text("请选择").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                    } else { TextField("最近发生时间（可选）", text: $model.draft.lastOccurrence) }
                }.padding(8)
            }
            GroupBox("设备与联系方式") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(model.shows("SN") ? "眼镜 SN（当前分类需要）" : "眼镜 SN（可选）", text: $model.draft.sn)
                    HStack {
                        TextField("眼镜型号", text: $model.draft.glassesType)
                        TextField("眼镜系统版本（可选）", text: $model.draft.glassesSystemVersion)
                    }
                    TextField("称呼（可选）", text: $model.draft.nickname)
                    HStack {
                        TextField("联系邮箱", text: $model.draft.email)
                        TextField("联系电话（可选）", text: $model.draft.phone)
                    }
                    Text("设备环境会如实注明 macOS 和 OpenRayneo 版本。").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if model.shows("purchaseConfig") {
                GroupBox("购买信息") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let platforms = model.selectedCategory?.displayFields?["purchaseConfig"]?.PurchasePlatform, !platforms.isEmpty {
                            Picker("购买平台", selection: $model.draft.purchasePlatform) {
                                Text("请选择").tag("")
                                ForEach(platforms, id: \.self) { Text($0).tag($0) }
                            }
                        } else { TextField("购买平台", text: $model.draft.purchasePlatform) }
                        TextField("订单号", text: $model.draft.purchaseOrderNumber)
                        TextField("购买日期 yyyy-MM-dd", text: $model.draft.purchaseDate)
                        if model.selectedCategory?.displayFields?["purchaseConfig"]?.PurchaseReceipt == true {
                            Button("添加购买凭证") { model.chooseAttachments(role: .purchaseReceipt) }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private var attachments: some View {
        GroupBox("附件与日志") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("添加图片／视频／文件") { model.chooseAttachments() }
                    Button("添加已有眼镜日志") { model.chooseAttachments(role: .glassesLog) }
                    Button("添加 Mac 日志") { model.chooseAttachments(role: .appLog) }
                }
                HStack {
                    Button("从眼镜收集日志") { model.collectGlassesLog() }.disabled(!model.connected)
                    if !model.connected { Text("眼镜未连接").font(.caption).foregroundStyle(.secondary) }
                }
                if let category = model.selectedCategory, category.needAppLog == true || category.needGlassesLog == true {
                    Text("官方建议附带：" + [category.needAppLog == true ? "应用日志" : nil, category.needGlassesLog == true ? "眼镜日志" : nil].compactMap { $0 }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.draft.attachments) { attachment in
                    HStack {
                        Text(attachment.name).lineLimit(1).help(attachment.name)
                        Text(roleName(attachment.role)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)]) }
                        Button("移除") { model.removeAttachment(attachment) }
                    }
                }
                if model.draft.attachments.isEmpty { Text("尚未添加附件。").font(.caption).foregroundStyle(.secondary) }
                else {
                    HStack {
                        Button("在本机准备附件包") { model.prepareBundle() }
                        if let path = model.draft.bundlePath {
                            Button("查看附件包") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.draft.submissionState == "uncertain" {
            Text("上一份提交结果尚未确认；请先核对官方记录。").foregroundStyle(.orange)
            Button("复制内容为新反馈…") { confirmRetry = true }.disabled(model.busy)
        } else if model.draft.submissionState == "submitted" {
            Label("官方已接受此反馈", systemImage: "checkmark.circle").foregroundStyle(.green)
            Button("新建反馈…") { confirmNew = true }.disabled(model.busy)
        } else {
            HStack {
                Button("提交官方反馈…") { confirmSubmit = true }.disabled(!model.canSubmit)
                Button("新建草稿…") { confirmNew = true }.disabled(!model.editable)
                Text("自动保存到本机").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.validationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func options(_ value: String?) -> [String]? { value.map { $0.split(separator: ",").map(String.init) } }
    private func roleName(_ role: OfficialFeedbackAttachment.Role) -> String {
        switch role {
        case .attachment: return "问题附件"
        case .purchaseReceipt: return "购买凭证"
        case .glassesLog: return "眼镜日志"
        case .appLog: return "Mac 日志"
        }
    }
}
