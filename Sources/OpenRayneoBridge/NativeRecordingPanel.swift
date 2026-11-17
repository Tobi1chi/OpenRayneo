// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct NativeRecordingRow: Identifiable {
    let id: String
    let state: String
    let seconds: Double
    let path: String?
    let finalized: Bool
    let localUUID: String?
    let origin: String
    init?(_ json: [String: Any]) {
        guard let id = json["uuid"] as? String else { return nil }
        self.id = id; state = json["state"] as? String ?? "idle"
        let recording = json["recording"] as? [String: Any] ?? [:]
        seconds = recording["seconds"] as? Double ?? 0
        path = recording["path"] as? String; finalized = recording["finalized"] as? Bool == true
        localUUID = json["localUUID"] as? String; origin = json["origin"] as? String ?? "unknown"
    }
}

@MainActor
final class NativeRecordingModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var state = "idle"
    @Published var busy = false
    @Published var notice = "使用眼镜原生录音，实时音频和离线补传分别保存。"
    @Published var seconds = 0.0
    @Published var elapsedSeconds = 0.0
    @Published var markers: [RecordingMarker] = []
    @Published var markerContent = ""
    @Published var markNotice = ""
    @Published var path: String?
    @Published var finalized = false
    @Published var mode = 1
    @Published var activeUUID: String?
    @Published var activeState = "idle"
    @Published var selectedUUID: String?
    @Published var recordings: [NativeRecordingRow] = []
    @Published var offlineItems: [[String: Any]] = []
    @Published var selectedOfflineIDs: Set<String> = []
    @Published var showDeleteConfirmation = false
    @Published var offlineImport: [String: Any] = [:]
    init(bridge: DesktopBridge) { self.bridge = bridge }
    var connected: Bool { bridge?.connected == true }
    var active: Bool { activeUUID != nil }
    var importing: Bool { (offlineImport["pending"] as? Int ?? 0) > 0 }
    var unmatchedCount: Int {
        offlineItems.filter { item in
            guard let id = item["uuid"] as? String, !id.isEmpty else { return false }
            guard let local = recordings.first(where: { $0.id == id }) else { return true }
            return local.origin == "offline_import" && !local.finalized
        }.count
    }

    func command(_ action: String, body: [String: Any]? = nil) async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            if action == "start" { try await bridge.prepareNativeRecording() }
            ingest(try await bridge.request("/v1/native-recording/\(action)", body: body ?? (action == "start" || action == "mode" ? ["mode": mode] : nil)))
            if action == "mark" { markerContent = "" }
        }
        catch { notice = error.localizedDescription }
    }

    func refresh() async {
        guard let bridge, bridge.connected, !busy else { return }
        do { ingest(try await bridge.request("/v1/native-recording", method: "GET")) }
        catch { notice = error.localizedDescription }
    }

    func reveal(_ path: String? = nil) {
        if let value = path ?? self.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)]) }
    }

    private func ingest(_ data: [String: Any]) {
        state = data["state"] as? String ?? state
        activeUUID = data["activeUUID"] as? String
        activeState = data["activeState"] as? String ?? "idle"
        selectedUUID = data["uuid"] as? String
        elapsedSeconds = data["elapsedSeconds"] as? Double ?? 0
        markers = (data["markers"] as? [[String: Any]] ?? []).compactMap(RecordingMarker.init(json:))
        if let result = data["markResult"] as? [String: Any], let code = result["code"] as? Int {
            markNotice = [1: "标记已保存到本地。", 2: "距上一标记不足五秒，无需重复标记。", 3: "当前录音不匹配或标记保存失败。未添加标记。"][code] ?? ""
        }
        offlineItems = data["offlineItems"] as? [[String: Any]] ?? []
        offlineImport = data["offlineImport"] as? [String: Any] ?? [:]
        recordings = (data["recordings"] as? [[String: Any]] ?? []).compactMap(NativeRecordingRow.init)
        let available = Set(offlineItems.compactMap { $0["uuid"] as? String })
        selectedOfflineIDs.formIntersection(available)
        if let recording = data["recording"] as? [String: Any] {
            seconds = recording["seconds"] as? Double ?? 0
            path = recording["path"] as? String
            finalized = recording["finalized"] as? Bool == true
        }
        if let error = data["error"] as? String { notice = error }
        else { notice = ["idle": "尚未开始", "starting": "已发出开始请求，等待眼镜确认", "recording": "录音中", "pausing": "等待眼镜确认暂停", "paused": "已暂停", "resuming": "等待眼镜确认继续", "stopping": "已请求停止，等待音频传输完成", "waitingForData": "等待缺失音频范围补齐", "syncing": "正在同步离线录音", "interrupted": "上次传输已中断，可重新查询眼镜并继续同步", "completed": "录音已完成并保存", "failed": "眼镜未能开始录音" ][state] ?? state }
    }
}

@MainActor
struct NativeRecordingPanel: View {
    @ObservedObject var model: NativeRecordingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("眼镜原生录音").font(.title2.weight(.semibold))
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("收音模式", selection: $model.mode) {
                Text("宽频／环境声音").tag(1)
                Text("人声隔离").tag(2)
            }.pickerStyle(.segmented)
            HStack {
                Button("开始录音") { Task { await model.command("start") } }.disabled(!model.connected || model.active || model.importing)
                Button(model.activeState == "paused" ? "继续" : "暂停") { Task { await model.command(model.activeState == "paused" ? "resume" : "pause") } }
                    .disabled(!model.connected || !model.active || !["recording", "paused"].contains(model.activeState))
                Button("切换收音模式") { Task { await model.command("mode") } }.disabled(!model.connected || !model.active)
                Button("停止并保存") { Task { await model.command("stop") } }.disabled(!model.connected || !model.active)
                Button("核对眼镜状态") { Task { await model.command("query-status") } }.disabled(!model.connected)
            }.disabled(model.busy)
            Text(String(format: "当前录音已保存 %.2f 秒双声道音频", model.seconds)).monospacedDigit()
            HStack {
                TextField("标记内容（可选）", text: $model.markerContent)
                Button("标记当前时刻") { Task { await model.command("mark", body: ["content": model.markerContent]) } }
                    .disabled(!model.connected || model.busy || !["recording", "paused"].contains(model.activeState))
            }
            if !model.markNotice.isEmpty { Text(model.markNotice).font(.caption).foregroundStyle(.secondary) }
            if !model.markers.isEmpty {
                GroupBox("录音标记") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.markers) { marker in
                            Text("\(RecordingAudioRange.timeLabel(marker.positionSeconds)) · \(marker.content.isEmpty ? "重点标记" : marker.content)")
                                .font(.caption).textSelection(.enabled)
                        }
                        Text("标记按录音时间定位；资料库可查看、跳转和编辑。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if let path = model.path {
                Text(path).font(.caption).textSelection(.enabled)
                Button("在 Finder 中查看 WAV") { model.reveal() }
                Text(model.finalized ? "WAV 已完成" : "WAV 正在写入").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("眼镜离线录音") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("查询离线列表") { Task { await model.command("list") } }.disabled(!model.connected || model.busy)
                    Button("导入本机未匹配的离线录音（\(model.unmatchedCount)）") {
                        Task { await model.command("import-unmatched") }
                    }.disabled(!model.connected || model.busy || model.active || model.importing || model.unmatchedCount == 0)
                    Text("按眼镜整批导入协议重新查询并接收录音，也会继续未完成的导入。请求不携带单条名单，眼镜可能同时补传本机已有记录；不删除眼镜内容。下方勾选仅用于所选同步和删除。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let total = model.offlineImport["total"] as? Int,
                       let unmatched = model.offlineImport["unmatched"] as? Int,
                       let known = model.offlineImport["known"] as? Int,
                       let pending = model.offlineImport["pending"] as? Int {
                        Text("本批 \(total) 条：导入 \(unmatched) 条、已有补传 \(known) 条，\(pending == 0 ? "已保存完成" : "尚有 \(pending) 条未完成")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.offlineItems.enumerated()), id: \.offset) { _, item in
                        if let id = item["uuid"] as? String {
                            Toggle(isOn: Binding(get: { model.selectedOfflineIDs.contains(id) }, set: { selected in
                                if selected { model.selectedOfflineIDs.insert(id) } else { model.selectedOfflineIDs.remove(id) }
                            })) {
                                HStack { Text(id).font(.caption).textSelection(.enabled); Spacer(); Text("\((item["offlineSize"] as? Int) ?? 0) bytes").font(.caption) }
                            }.toggleStyle(.checkbox)
                        }
                    }
                    HStack {
                        Button("同步所选录音") { Task { await model.command("sync", body: ["uuids": Array(model.selectedOfflineIDs)]) } }
                        Button("删除眼镜中的所选录音", role: .destructive) { model.showDeleteConfirmation = true }
                    }.disabled(!model.connected || model.busy || model.importing || model.selectedOfflineIDs.isEmpty)
                    Text("删除仅清理眼镜端所选项目，本地已保存的音频保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if !model.recordings.isEmpty {
                GroupBox("本地录音") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.recordings) { recording in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recording.id).font(.caption).textSelection(.enabled)
                                    Text(String(format: "%.2f 秒 · %@", recording.seconds, recording.finalized ? "已保存" : recording.state)).font(.caption).foregroundStyle(.secondary)
                                    if recording.origin == "offline_import" {
                                        Text("来源：眼镜离线导入 · 本地 ID \(recording.localUUID ?? "")")
                                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                                Button("查看") { Task { await model.command("select", body: ["uuid": recording.id]) } }
                                Button("导出 WAV") { Task { await model.command("export", body: ["uuid": recording.id]) } }
                                if let path = recording.path { Button("Finder") { model.reveal(path) } }
                            }
                        }
                    }.padding(8)
                }
            }
        }
        .confirmationDialog("从眼镜删除所选的 \(model.selectedOfflineIDs.count) 条录音？", isPresented: $model.showDeleteConfirmation) {
            Button("删除眼镜端录音", role: .destructive) { Task { await model.command("delete-offline", body: ["uuids": Array(model.selectedOfflineIDs)]) } }
        } message: { Text("本地音频保留，眼镜端这些录音将被移除。") }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
}
