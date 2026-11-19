// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Test and repair tooling for Mac-local recordings; the daily review page stays read-mostly.
@MainActor
struct RecordingDeveloperPanel: View {
    @ObservedObject var model: RecordingLibraryModel
    @ObservedObject private var officialUpload = OfficialRecordingUploadModel.shared
    @ObservedObject private var cloudAudio = OfficialCloudAudioModel.shared
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("刷新本地录音", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.busy || officialUpload.busy)
                Button("导入音频", systemImage: "square.and.arrow.down") { model.importAudio() }.disabled(model.busy || officialUpload.busy)
            }
            RealtimeRecentRecordingSettings()
            if OfficialCloudPolicy.enabled {
                OfficialRecordingUploadQueuePanel(model: officialUpload, background: officialUpload.background)
                OfficialCloudAudioPanel(model: cloudAudio)
            }
            if model.busy {
                HStack { ProgressView(value: model.progress); Button("取消") { model.cancel() } }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("搜索标题、标签、转写与摘要", text: $model.search)
                    Picker("标签", selection: $model.selectedTag) {
                        Text("全部标签").tag("")
                        ForEach(model.allTags, id: \.self) { Text($0).tag($0) }
                    }
                    List(model.filteredEntries, selection: $model.selectedID) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).lineLimit(2)
                            Text("\(entry.source == "lifelog" ? "原始分段" : entry.durationLabel) · \(entry.sourceName)").font(.caption).foregroundStyle(.secondary)
                            Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            if entry.source == "lifelog" { Text("保留原始分段，手动恢复后播放").font(.caption).foregroundStyle(.secondary) }
                            else if !entry.available { Text("音频尚未同步或文件已移走").font(.caption).foregroundStyle(.secondary) }
                            else if !entry.finalized { Text("音频尚未完成保存").font(.caption).foregroundStyle(.secondary) }
                        }.tag(entry.id).padding(.vertical, 3)
                    }.frame(minHeight: 380)
                    Text("\(model.filteredEntries.count) 条录音").font(.caption).foregroundStyle(.secondary)
                }.frame(width: 270)
                if let entry = model.selected {
                    detail(entry).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("选择一条本地录音，或导入音频。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
        .confirmationDialog("将这条本地录音移至废纸篓？", isPresented: $confirmingDelete) {
            Button("移至废纸篓", role: .destructive) { model.deleteSelected() }
        } message: { Text("对应的本地音频和原生同步缓存会被移走，录音库中的转写与摘要也会移除。") }
    }

    private func detail(_ entry: RecordingLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("录音标题", text: $model.titleDraft).font(.headline)
            TextField("标签，以逗号分隔", text: $model.tagsDraft)
            HStack {
                Button("保存标题和标签") { model.saveDetails() }
                Spacer()
                Button("移至废纸篓", role: .destructive) { confirmingDelete = true }.disabled(!entry.finalized && entry.source != "lifelog")
            }.disabled(model.busy || officialUpload.busy)
            HStack {
                Button(model.playingID == entry.id ? "停止播放" : "播放") { model.togglePlayback() }
                Button("导出 WAV") { model.exportWAV() }
                Button("Finder") { model.reveal() }
            }.disabled(model.busy || officialUpload.busy || !entry.available || !entry.finalized)
            if entry.available, entry.finalized, model.trimDuration > 0 {
                trimEditor
            }
            markerEditor(entry)
            HStack {
                Button(entry.transcript.isEmpty ? "转写录音" : "重新转写") { model.transcribe() }
                    .disabled(!entry.available || !entry.finalized)
                Button(entry.summary.isEmpty ? "生成摘要" : "重新生成摘要") { model.summarize() }.disabled(entry.transcript.isEmpty)
            }.disabled(model.busy || officialUpload.busy)
            Text("转写使用百炼和 AI 页已保存的 ASR 设置；摘要将转写内容发送至 DeepSeek。")
                .font(.caption).foregroundStyle(.secondary)
            if OfficialCloudPolicy.enabled { OfficialRecordingUploadPanel(entry: entry, localBusy: model.busy) }
            if entry.source == "lifelog" {
                GroupBox("AlwaysOn 分段恢复") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("把完整收到的原始分段另存为 WAV。跨分段空白和丢失语音不会被补造；恢复后可单独转写或总结，不自动调用 Decision 或派发任务。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("恢复已收到的音频") { model.recoverLifeLogAudio() }.disabled(model.busy || officialUpload.busy)
                    }.padding(8)
                }
            }
            if entry.source == "native", !entry.finalized {
                GroupBox("部分录音恢复") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("只恢复从录音开头连续收到的完整音频包，另存为可播放的部分录音；原 raw、元数据及 WAV 均保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = model.recoveryUnavailableReason(entry) {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("恢复已收到的连续片段") { model.recoverContinuousAudio() }.disabled(model.busy || officialUpload.busy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if let uuid = entry.originNativeUUID {
                Text("原生录音 UUID：\(uuid)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let note = entry.recoveryNote {
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let original = entry.trimmedFromEntryID, let ranges = entry.trimmedRanges {
                Text("剪辑自 \(original.uuidString) · " + ranges.map(\.label).joined(separator: "；"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            identifiers(entry)
            if let failure = entry.lastError { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("转写全文\(transcriptState(entry))") {
                ScrollView { Text(entry.transcript.isEmpty ? "尚未转写" : entry.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .frame(minHeight: 160, maxHeight: 300)
            }
            GroupBox("摘要") {
                ScrollView { Text(entry.summary.isEmpty ? "尚未生成摘要" : entry.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private var trimEditor: some View {
        GroupBox("音频剪辑") {
            VStack(alignment: .leading, spacing: 10) {
                Text("选择原音频中的时间范围，保留或删除选区；保留片段将按时间顺序拼接。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("开始（秒）")
                    TextField("开始", value: Binding(get: { model.trimStart }, set: { model.setTrimStart($0) }),
                              format: .number.precision(.fractionLength(0...3))).frame(width: 100)
                    Slider(value: Binding(get: { model.trimStart }, set: { model.setTrimStart($0) }), in: 0...model.trimDuration)
                }
                HStack {
                    Text("结束（秒）")
                    TextField("结束", value: Binding(get: { model.trimEnd }, set: { model.setTrimEnd($0) }),
                              format: .number.precision(.fractionLength(0...3))).frame(width: 100)
                    Slider(value: Binding(get: { model.trimEnd }, set: { model.setTrimEnd($0) }), in: 0...model.trimDuration)
                }
                HStack {
                    Button("仅保留选区") { model.keepTrimSelection() }.disabled(!model.trimSelectionValid)
                    Button("删除选区") { model.deleteTrimSelection() }.disabled(!model.trimSelectionValid)
                    Button("撤销") { model.undoTrim() }.disabled(!model.trimUndoAvailable)
                    Button("恢复全部") { model.resetTrim() }
                }
                if !model.trimSelectionValid {
                    Text("开始时间需早于结束时间，并位于音频范围内。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.trimRanges.isEmpty {
                    Text("当前没有保留片段，可撤销或恢复全部。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.trimRanges.enumerated()), id: \.offset) { index, range in
                                Text("片段 \(index + 1)：\(range.label)").monospacedDigit()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                    Text("结果时长 \(RecordingAudioRange.timeLabel(model.trimmedDuration)) · \(model.trimRanges.count) 个片段")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button(model.previewingTrim ? "停止试听" : "试听剪辑结果") { model.previewTrim() }
                        .disabled(model.trimRanges.isEmpty)
                    if model.previewingTrim {
                        Text("原音频 \(RecordingAudioRange.timeLabel(model.previewPosition))")
                            .font(.caption).monospacedDigit()
                    }
                }
                HStack {
                    TextField("剪辑副本名称", text: $model.trimTitleDraft)
                    Button("保存新副本") { model.saveTrimmedCopy() }
                        .disabled(model.trimRanges.isEmpty || model.trimTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(8)
        }.disabled(model.busy || officialUpload.busy)
    }

    private func markerEditor(_ entry: RecordingLibraryEntry) -> some View {
        GroupBox("录音标记") {
            VStack(alignment: .leading, spacing: 8) {
                if entry.markers?.isEmpty != false {
                    Text("暂无标记").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(entry.markers ?? []) { marker in
                    HStack(alignment: .top) {
                        Button(RecordingAudioRange.timeLabel(marker.positionSeconds)) { model.jumpToMarker(marker) }
                            .monospacedDigit().disabled(!entry.finalized || !entry.available || marker.positionSeconds >= entry.duration)
                        Text(marker.content.isEmpty ? "重点标记" : marker.content).textSelection(.enabled)
                        Spacer()
                        Button("编辑") { model.selectMarker(marker) }
                        Button("删除", role: .destructive) { model.deleteMarker(marker) }
                    }
                }
                if entry.finalized, entry.available {
                    Divider()
                    HStack {
                        Text("时间（秒）")
                        TextField("时间", value: $model.markerSecondsDraft,
                                  format: .number.precision(.fractionLength(0...3))).frame(width: 110)
                        Button("取播放位置 / 新标记") { model.newMarkerDraft() }
                    }
                    TextField("标记内容", text: $model.markerContentDraft)
                    Button(model.selectedMarkerID == nil ? "添加本地标记" : "保存标记修改") { model.saveMarker() }
                    Text("编辑只保存到本地资料库。若标记位于尚未补齐的音频之后，暂不能跳转。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.disabled(model.busy || officialUpload.busy)
    }

    private func identifiers(_ entry: RecordingLibraryEntry) -> some View {
        let rows: [(String, String?)] = [("录音库 ID", entry.id.uuidString), ("来源", entry.source), ("音频", entry.audioPath),
            ("原生元数据", entry.nativeMetadataPath), ("原生 raw", entry.rawAudioPath), ("AlwaysOn 清单", entry.lifeLogManifestPath),
            ("云任务", entry.cloudTaskID), ("云压缩副本", entry.cloudCompressedPath), ("转写状态", entry.transcriptionState)]
        return DisclosureGroup("标识与路径") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.filter { $0.1 != nil }, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                        Text(value ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }.font(.caption).padding(.top, 6)
        }
    }

    private func transcriptState(_ entry: RecordingLibraryEntry) -> String {
        let labels = ["running": " · 转写中", "completed": " · 已完成", "official_completed": " · 官方已完成", "official_available": " · 官方已有内容", "cancelled": " · 已取消，部分内容",
                      "interrupted": " · 上次转写中断", "failed": " · 未完成"]
        return labels[entry.transcriptionState] ?? ""
    }
}
