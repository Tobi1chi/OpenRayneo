// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@MainActor
struct NotificationMirrorPanel: View {
    @ObservedObject var model: NotificationMirrorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mac 通知镜像").font(.title2.weight(.semibold))
            Toggle("将所选应用的新通知镜像到眼镜", isOn: Binding(get: { model.enabled }, set: { requested in
                Task { await model.setEnabled(requested) }
            })).disabled(!model.enabled && !model.canEnable)
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            GroupBox("通知来源访问") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.access).font(.headline)
                    HStack {
                        Button("检查来源与数据结构") { Task { await model.inspect() } }.disabled(model.inspecting)
                        Button("导出数据结构…") { Task { await model.exportSchema() } }.disabled(model.inspecting)
                        if model.inspecting || model.starting { ProgressView().controlSize(.small) }
                    }
                    Text("导出只包含表名、列名和类型，不包含通知记录、标题或正文。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.contentAdapterAvailable {
                        Text("尚未确认通知来源使用受支持的结构。检查来源成功后，才能手动开启镜像。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let schema = model.schema {
                        DisclosureGroup("已读取 \(schema.tables.count) 张表的结构") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(schema.tables.enumerated()), id: \.offset) { _, table in
                                    Text(table.name).font(.system(.caption, design: .monospaced).weight(.semibold))
                                    Text(table.columns.map { "\($0.name): \($0.type.isEmpty ? "无声明类型" : $0.type)" }.joined(separator: " · "))
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 8).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("系统拒绝访问时的操作位置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在系统设置 → 隐私与安全性 → 完全磁盘访问权限中，手动添加并允许当前 OpenRayneo App；随后退出并重新打开 App，再检查或导出结构。")
                    Text("当前 App：\(model.applicationPath)").font(.caption).textSelection(.enabled)
                    Button("打开完全磁盘访问权限设置") { model.openPrivacySettings() }
                    Text("此页不会替你修改授权，也不会申请通知发送权限来代替读取其他应用通知。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            GroupBox("选择来源应用") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("搜索应用名称或 Bundle ID", text: $model.search)
                        Button("刷新运行中的应用") { model.refreshApps() }
                    }
                    Text("列出当前运行的应用和之前选择的来源。选中只保存选择，不会开启镜像；开启时会跳过已有历史记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.filteredApps.isEmpty { Text("没有匹配的应用。可先打开要镜像的应用再刷新。") .foregroundStyle(.secondary) }
                    ForEach(model.filteredApps) { app in
                        HStack(spacing: 10) {
                            if let url = app.url {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                            }
                            Toggle(isOn: Binding(get: { model.selectedBundleIDs.contains(app.id) }, set: {
                                model.select(app.id, enabled: $0)
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.id).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("已选 \(model.selectedBundleIDs.count) 个来源").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if !model.deliveries.isEmpty {
                GroupBox("本次会话的镜像记录") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已交付 \(model.deliveredCount) 条 · 去重 \(model.duplicateCount) 条").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.deliveries) { delivery in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(delivery.event.appName) · \(delivery.outcome)").font(.caption).foregroundStyle(.secondary)
                                Text(delivery.event.title).font(.headline)
                                if !delivery.event.subtitle.isEmpty { Text(delivery.event.subtitle) }
                                Text(delivery.event.body)
                            }.textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
        }
        .task { if model.schema == nil { await model.inspect() } }
    }
}
