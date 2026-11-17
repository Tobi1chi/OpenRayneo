// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct MailDashboardPanel: View {
    @ObservedObject var model: MailDashboardModel

    var body: some View {
        GroupBox("Apple Mail 邮件来源") {
            VStack(alignment: .leading, spacing: 12) {
                Text("读取这台 Mac 已登录的 Apple Mail 账户，并将你选择的邮箱映射到眼镜卡片。此功能使用本机 Mail 自动化，尚未接入官方手机 App 的 Gmail / Outlook OAuth。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("授权并读取 Apple Mail 账户") { Task { await model.authorizeAndReadAccounts() } }
                    .disabled(model.busy)
                Text(model.accessDescription).font(.caption).foregroundStyle(.secondary)
                ForEach(MailDashboardProvider.allCases) { provider in source(provider) }
                Toggle("眼镜连接时自动读取所选邮箱并同步摘要", isOn: $model.automatic)
                    .disabled(!model.automatic && !model.hasSelection)
                Picker("刷新间隔", selection: $model.refreshSeconds) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("15 分钟").tag(900)
                }
                HStack {
                    Button("读取摘要到 Mac 预览") { Task { await model.refresh() } }
                        .disabled(model.busy || !model.hasSelection)
                    Button("读取并同步到眼镜") { Task { await model.refresh(synchronize: true) } }
                        .disabled(model.busy || !model.hasSelection || !model.connected)
                    Button("同步当前预览") { Task { await model.pushPreview() } }
                        .disabled(model.busy || !model.hasMatchingPreview || !model.connected)
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Text("仅统计所选文件夹未读邮件，展示最新一封的发件人、主题和最多 150 字符的正文预览。目录读取不会读取正文；未选来源不自动读取。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.notice).font(.callout).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func source(_ provider: MailDashboardProvider) -> some View {
        let selection = model.selection(provider)
        let account = model.accounts.first { $0.id == selection.accountID }
        return GroupBox(provider.label) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("来源账户", selection: Binding(get: { model.selection(provider).accountID }, set: { model.setAccount($0, for: provider) })) {
                    Text("不自动读取此卡片").tag("")
                    ForEach(model.accounts) { account in
                        Text(account.label + (account.enabled ? "" : "（已停用）")).tag(account.id)
                    }
                    if !selection.accountID.isEmpty && account == nil { Text("原账户未出现在当前目录中").tag(selection.accountID) }
                }
                if let account {
                    Picker("来源邮箱", selection: Binding(get: { model.selection(provider).mailbox }, set: { model.setMailbox($0, for: provider) })) {
                        Text("请选择，例如 INBOX / 收件箱").tag([String]())
                        ForEach(account.mailboxes, id: \.self) { path in Text(path.joined(separator: " / ")).tag(path) }
                        if !selection.mailbox.isEmpty && !account.mailboxes.contains(selection.mailbox) {
                            Text("原邮箱未出现在当前目录中").tag(selection.mailbox)
                        }
                    }
                    Text("账户与卡片的对应关系由你选择，不根据账户名称或地址自动推断。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preview = model.snapshots[provider.rawValue] {
                    if preview.selection != selection {
                        Text("下方是之前来源的缓存；不会按当前选择自动发送。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("未读 \(preview.unread) · 获取于 \(preview.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if preview.unread > 0 {
                        Text(preview.subject.isEmpty ? "（无主题）" : preview.subject).font(.headline)
                        Text(preview.senderName.isEmpty ? preview.sender : "\(preview.senderName) <\(preview.sender)>").font(.caption)
                        if let receivedAt = preview.receivedAt {
                            Text("邮件时间：\(receivedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(preview.preview).font(.callout).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
