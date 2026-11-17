// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialAccountDataPanel: View {
    @ObservedObject private var model = OfficialAccountDataModel.shared
    @State private var confirmDeletion = false
    @State private var deletionAccount: UUID?
    @State private var knownRequestID = ""
    @State private var knownKind = OfficialUserDataJob.Kind.export
    @State private var verificationOperation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy { ProgressView().controlSize(.small) }
            GroupBox("个人数据申请") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出申请会发送到指定邮箱。删除个人数据与注销账号分别处理，本地音频文件和账号会话独立保留。")
                        .font(.callout).foregroundStyle(.secondary)
                    exportControls
                    Divider()
                    Toggle("我已了解：删除将清除这个官方账号的云端个人数据", isOn: $model.acknowledgeDeletion)
                        .disabled(!model.configured || model.busy)
                    Button("申请删除云端个人数据…", role: .destructive) {
                        deletionAccount = model.accountGeneration; confirmDeletion = true
                    }.disabled(!model.canDelete)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.jobs.isEmpty {
                GroupBox("申请记录") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.jobs.reversed()) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(job.title).font(.headline)
                                    Spacer()
                                    Text(job.state?.title ?? submissionLabel(job))
                                    Button("刷新状态") { model.refresh(job.id) }.disabled(model.busy || job.requestID == nil)
                                }
                                if let id = job.requestID { Text("申请编号：" + id).textSelection(.enabled) }
                                if let receipt = job.receipt { Text("受理时间：" + receipt.createdAt).font(.caption).foregroundStyle(.secondary) }
                                if let status = job.exportStatus {
                                    Text("接收邮箱：" + status.email).textSelection(.enabled)
                                    Text("服务端状态：" + status.status).font(.caption)
                                    if let date = status.completedAt { Text("完成时间：" + date).font(.caption) }
                                }
                                if let status = job.deletionStatus {
                                    Text("服务端状态：" + status.status).font(.caption)
                                    Text(status.hasRemainingData ? "服务端仍报告有剩余数据。" : "服务端报告无剩余数据。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let date = status.completedAt { Text("完成时间：" + date).font(.caption) }
                                }
                                if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                            Divider()
                        }
                    }.padding(8)
                }
            }
            DisclosureGroup("查询已有申请") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("申请类型", selection: $knownKind) {
                        Text("导出").tag(OfficialUserDataJob.Kind.export)
                        Text("删除").tag(OfficialUserDataJob.Kind.deletion)
                    }
                    TextField("已有申请编号", text: $knownRequestID)
                    Button("查询这个编号") { model.rememberExistingRequest(id: knownRequestID, kind: knownKind) }
                        .disabled(!model.configured || model.busy || knownRequestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.vertical, 6)
            }
        }.padding(.vertical, 8)
        .onAppear { model.watchStatus() }
        .onDisappear { verificationOperation?.cancel(); verificationOperation = nil; model.leavePanel() }
        .confirmationDialog("删除这个官方账号的云端个人数据？", isPresented: $confirmDeletion) {
            Button("提交云端个人数据删除申请", role: .destructive) {
                if let account = deletionAccount { model.requestDeletion(expectedAccount: account) }
                deletionAccount = nil
            }
        } message: { Text("这会向雷鸟官方提交云端个人数据删除申请。受理不代表处理已经完成，请查看后续申请状态。") }
        .onChange(of: model.accountGeneration) { _ in confirmDeletion = false; deletionAccount = nil; knownRequestID = "" }
    }
    @ViewBuilder private var exportControls: some View {
        switch model.exportStep {
        case .idle:
            Button("验证身份并导出个人数据") { verificationOperation = Task { await model.beginExportVerification() } }
                .disabled(model.busy || model.exportUnavailableReason != nil)
            if let message = model.exportUnavailableReason { Text(message).font(.caption).foregroundStyle(.secondary) }
        case .code:
            Text("验证目标：" + model.verificationTarget).font(.callout).textSelection(.enabled)
            SecureField("6 位导出验证码", text: $model.verificationCode).disabled(model.busy)
            HStack {
                Button("验证并继续导出") { verificationOperation = Task { await model.verifyExportCode() } }.disabled(model.busy || model.verificationCode.isEmpty)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button("重新发送验证码") { verificationOperation = Task { await model.sendExportCode() } }
                        .disabled(model.busy || model.retryAt.map { $0 > context.date } == true)
                    if let date = model.retryAt, date > context.date { Text("\(Int(ceil(date.timeIntervalSince(context.date)))) 秒后可重发").font(.caption) }
                }
            }
            Text("验证邮箱成功后会向该绑定邮箱提交导出申请；手机号验证后可填写接收邮箱。").font(.caption).foregroundStyle(.secondary)
            Button("取消导出准备") { model.cancelExportVerification() }.disabled(model.busy)
        case .receiver:
            TextField("接收个人数据的邮箱", text: $model.receiverEmail).disabled(model.busy)
            Button("提交数据导出申请") { model.submitVerifiedExport() }.disabled(model.busy || model.receiverEmail.isEmpty)
            Button("取消导出准备") { model.cancelExportVerification() }.disabled(model.busy)
        }
    }
    private func submissionLabel(_ job: OfficialUserDataJob) -> String {
        switch job.submission {
        case "accepted": return "已受理"
        case "sending": return "正在申请"
        case "imported": return "待查询"
        default: return "结果未确认"
        }
    }
}
