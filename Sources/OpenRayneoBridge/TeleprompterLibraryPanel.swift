// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct TeleprompterPlaybackSettings: Codable, Equatable {
    var countdown = 3
    var scroll = 2
    var speed = 60
    var gear = 1
    var depth = 1
    var size = 18
    var width = 492
    var leading = 4

    var wireBody: [String: Any] {
        ["countdown": countdown, "scroll": scroll, "speed": speed, "gear": gear,
         "depth": depth, "size": size, "width": width, "leading": leading]
    }
}

struct TeleprompterLibraryDocument: Codable, Identifiable {
    let id: String
    var title: String
    var text: String
    var pinned = false
    var createdAt = Date()
    var updatedAt = Date()
    var position = 0
    var pageOffset: Int?
    var highLightOffset: Int?
    var settings = TeleprompterPlaybackSettings()

    var playbackPosition: (page: Int, highlight: Int) {
        let total = text.utf8.count
        let page = min(total, max(0, pageOffset ?? position))
        return (page, min(total, max(page, highLightOffset ?? position)))
    }

    var metadata: [String: Any] {
        ["did": id, "pin": pinned, "title": title, "offset": 0, "scroll": settings.scroll,
         "total": text.utf8.count, "timestamp": Int64(updatedAt.timeIntervalSince1970),
         "preview": String(text.prefix(80)), "timezone": TimeZone.current.secondsFromGMT(for: updatedAt)]
    }
}

struct TeleprompterPlaybackSnapshot: Equatable {
    let running: Bool
    let previewing: Bool
    let did: String
    let paused: Bool
    let pageOffset: Int
    let highLightOffset: Int
    let totalBytes: Int
    let scroll: Int
    let transcript: String
    let matchConfidence: Double
    let error: String?

    var progress: Double { totalBytes > 0 ? min(1, max(0, Double(highLightOffset) / Double(totalBytes))) : 0 }
}

@MainActor
final class TeleprompterLibraryModel: ObservableObject {
    private struct Mutation: Codable {
        let id: UUID
        let type: Int
        let document: TeleprompterLibraryDocument
        let total: Int
    }

    private weak var bridge: DesktopBridge?
    private let directory: URL
    private var subscriptions = Set<AnyCancellable>()
    private var mutations: [Mutation] = []
    private var progressSaveTask: Task<Void, Never>?
    private var dirtyProgressIDs = Set<String>()
    private var lastProgressSave = Date.distantPast
    @Published private(set) var documents: [TeleprompterLibraryDocument] = []
    @Published private(set) var playback: TeleprompterPlaybackSnapshot?
    @Published private(set) var syncing = false
    @Published private(set) var importing = false
    @Published private(set) var playing = false
    @Published private(set) var pendingCount = 0
    @Published var search = ""
    @Published var selectedID: String?
    @Published var title = ""
    @Published var text = ""
    @Published var settings = TeleprompterPlaybackSettings()
    @Published var notice = "创建或导入稿件，保存在这台 Mac 的提词库。"

    init(bridge: DesktopBridge, directory: URL? = nil) {
        self.bridge = bridge
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/Teleprompter", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" && url.lastPathComponent != "pending-sync.json" {
                documents.append(try JSONDecoder().decode(TeleprompterLibraryDocument.self, from: Data(contentsOf: url)))
            }
            let pending = self.directory.appendingPathComponent("pending-sync.json")
            if FileManager.default.fileExists(atPath: pending.path) {
                mutations = try JSONDecoder().decode([Mutation].self, from: Data(contentsOf: pending))
            }
            pendingCount = mutations.count
            sortDocuments()
            if let first = documents.first { load(first) }
        } catch { notice = "读取提词库失败：\(error.localizedDescription)" }
        bridge.$connected.dropFirst().sink { [weak self] connected in
            self?.objectWillChange.send()
            if connected { Task { @MainActor [weak self] in await self?.synchronize() } }
            else { self?.persistPlaybackProgress() }
        }.store(in: &subscriptions)
        bridge.$activeSession.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        if bridge.connected { Task { @MainActor [weak self] in await self?.synchronize() } }
    }

    var connected: Bool { bridge?.connected == true }
    var sessionActive: Bool { bridge?.activeSession == .teleprompter }
    var playbackTitle: String { documents.first { $0.id == playback?.did }?.title ?? "当前稿件" }
    var filteredDocuments: [TeleprompterLibraryDocument] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? documents : documents.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }

    func newDocument() {
        saveCurrentIfChanged()
        selectedID = nil; title = ""; text = ""; settings = TeleprompterPlaybackSettings()
        notice = "输入标题和正文后保存。"
    }

    func select(_ document: TeleprompterLibraryDocument) {
        guard selectedID != document.id else { return }
        saveCurrentIfChanged()
        load(document)
    }

    private func load(_ document: TeleprompterLibraryDocument) {
        selectedID = document.id; title = document.title; text = document.text; settings = document.settings
    }

    func ingestPlayback(_ data: [String: Any]) {
        guard let id = data["did"] as? String, !id.isEmpty else {
            if playback != nil { persistPlaybackProgress(); playback = nil }
            return
        }
        if !documents.contains(where: { $0.id == id }),
           let document = try? TeleprompterRepository(directory: directory).load(did: id) {
            documents.append(document)
            sortDocuments()
        }
        let total = max(0, data["totalBytes"] as? Int ?? 0)
        let page = min(total, max(0, data["pageOffset"] as? Int ?? 0))
        let highlight = min(total, max(page, data["highLightOffset"] as? Int ?? page))
        let next = TeleprompterPlaybackSnapshot(running: data["running"] as? Bool ?? false,
            previewing: data["previewing"] as? Bool ?? false,
            did: id, paused: data["paused"] as? Bool ?? false, pageOffset: page,
            highLightOffset: highlight, totalBytes: total, scroll: data["scroll"] as? Int ?? 2,
            transcript: data["transcript"] as? String ?? "",
            matchConfidence: data["matchConfidence"] as? Double ?? 0, error: data["error"] as? String)
        let previous = playback
        if next != playback { playback = next }
        if let index = documents.firstIndex(where: { $0.id == id }), documents[index].text.utf8.count == total {
            if let wire = data["settings"] as? [String: Any],
               let bytes = try? JSONSerialization.data(withJSONObject: wire),
               let received = try? JSONDecoder().decode(TeleprompterPlaybackSettings.self, from: bytes),
               received != documents[index].settings {
                if selectedID == id, settings == documents[index].settings { settings = received }
                documents[index].settings = received
                dirtyProgressIDs.insert(id)
            }
            if documents[index].pageOffset != page || documents[index].highLightOffset != highlight {
                documents[index].position = page
                documents[index].pageOffset = page
                documents[index].highLightOffset = highlight
                dirtyProgressIDs.insert(id)
            }
        }
        if previous?.did != id || previous?.paused != next.paused || !next.running {
            persistPlaybackProgress()
        } else if !dirtyProgressIDs.isEmpty {
            scheduleProgressSave()
        }
    }

    private func scheduleProgressSave() {
        let remaining = 3 - Date().timeIntervalSince(lastProgressSave)
        guard remaining > 0 else { persistPlaybackProgress(); return }
        guard progressSaveTask == nil else { return }
        progressSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            self?.persistPlaybackProgress()
        }
    }

    private func persistPlaybackProgress() {
        progressSaveTask?.cancel(); progressSaveTask = nil
        guard !dirtyProgressIDs.isEmpty else { return }
        lastProgressSave = Date()
        for id in dirtyProgressIDs {
            guard let document = documents.first(where: { $0.id == id }) else {
                dirtyProgressIDs.remove(id)
                continue
            }
            do { try write(document); dirtyProgressIDs.remove(id) }
            catch { notice = "保存播放位置失败：\(error.localizedDescription)" }
        }
    }

    @discardableResult
    func save() -> TeleprompterLibraryDocument? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "请先输入稿件正文。"; return nil }
        let old = documents.first { $0.id == selectedID }
        var document = old ?? TeleprompterLibraryDocument(id: UUID().uuidString.lowercased(), title: "", text: "")
        document.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if document.title.isEmpty { document.title = String(text.split(separator: "\n").first?.prefix(32) ?? "未命名稿件") }
        if document.text != text {
            document.position = 0; document.pageOffset = 0; document.highLightOffset = 0
        }
        document.text = text; document.settings = settings; document.updatedAt = Date()
        do {
            try write(document)
            dirtyProgressIDs.remove(document.id)
            if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = document }
            else { documents.append(document) }
            sortDocuments(); load(document)
            try enqueue(type: old == nil ? 3 : 5, document: document)
            notice = "稿件已保存。\(connected ? "正在同步眼镜列表。" : "连接眼镜后同步列表。")"
            Task { await synchronize() }
            return document
        } catch { notice = "保存失败：\(error.localizedDescription)"; return nil }
    }

    private func saveCurrentIfChanged() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let old = documents.first { $0.id == selectedID }
        if old?.title != title || old?.text != text || old?.settings != settings { _ = save() }
    }

    func togglePin(_ document: TeleprompterLibraryDocument) {
        var updated = documents.first { $0.id == document.id } ?? document
        updated.pinned.toggle(); updated.updatedAt = Date()
        do {
            try write(updated)
            if let index = documents.firstIndex(where: { $0.id == updated.id }) { documents[index] = updated }
            sortDocuments()
            try enqueue(type: 2, document: updated)
            notice = updated.pinned ? "稿件已置顶。" : "已取消置顶。"
            Task { await synchronize() }
        } catch { notice = error.localizedDescription }
    }

    func delete(_ document: TeleprompterLibraryDocument) {
        do {
            try FileManager.default.trashItem(at: fileURL(document.id), resultingItemURL: nil)
            documents.removeAll { $0.id == document.id }
            dirtyProgressIDs.remove(document.id)
            if selectedID == document.id {
                if let next = documents.first { load(next) }
                else { selectedID = nil; title = ""; text = "" }
            }
            try enqueue(type: 4, document: document)
            notice = "稿件已移入废纸篓。"
            Task { await synchronize() }
        } catch { notice = "删除失败：\(error.localizedDescription)" }
    }

    func play() async {
        guard !playing, let bridge, let document = save() else { return }
        playing = true; defer { playing = false }
        do {
            var options = document.settings.wireBody
            let position = document.playbackPosition
            options["pageOffset"] = position.page
            options["highLightOffset"] = position.highlight
            try await bridge.playTeleprompterDocument(id: document.id, title: document.title, text: document.text, settings: options)
            notice = "稿件已传输并请求播放。"
        } catch { notice = "播放失败：\(error.localizedDescription)" }
    }

    func control(_ action: String) { bridge?.controlTeleprompter(action) }
    func synchronizePlayback() { bridge?.synchronizeTeleprompterState() }

    func synchronize() async {
        guard let bridge, bridge.connected, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            while let mutation = mutations.first {
                _ = try await bridge.request("/v1/teleprompter/library", body: [
                    "type": mutation.type, "items": [mutation.document.metadata], "total": mutation.total
                ])
                mutations.removeAll { $0.id == mutation.id }
                try persistMutations()
            }
            if !documents.isEmpty { notice = "提词库已保存，眼镜列表信息已发送；播放时传输正文。" }
        } catch { notice = "稿件已保存在 Mac，列表同步未完成：\(error.localizedDescription)" }
    }

    func importDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.plainText, .pdf] + ["doc", "docx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        saveCurrentIfChanged()
        let urls = panel.urls
        importing = true
        Task {
            defer { importing = false }
            do {
                let imports = try await Task.detached(priority: .userInitiated) {
                    try urls.map { url in (url.deletingPathExtension().lastPathComponent, try Self.readDocument(url)) }
                }.value
                for (name, content) in imports {
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let document = TeleprompterLibraryDocument(id: UUID().uuidString.lowercased(), title: name, text: content)
                    try write(document); documents.append(document)
                    try enqueue(type: 3, document: document)
                    load(document)
                }
                sortDocuments(); notice = "已导入 \(imports.count) 个文件。"
                await synchronize()
            } catch { notice = "导入失败：\(error.localizedDescription)" }
        }
    }

    func revealLibrary() { NSWorkspace.shared.open(directory) }

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }
    private func write(_ document: TeleprompterLibraryDocument) throws {
        try JSONEncoder().encode(document).write(to: fileURL(document.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL(document.id).path)
    }
    private func sortDocuments() {
        documents.sort { $0.pinned != $1.pinned ? $0.pinned : $0.updatedAt > $1.updatedAt }
    }
    private func enqueue(type: Int, document: TeleprompterLibraryDocument) throws {
        mutations.append(Mutation(id: UUID(), type: type, document: document, total: documents.count))
        try persistMutations()
    }
    private func persistMutations() throws {
        let url = directory.appendingPathComponent("pending-sync.json")
        try JSONEncoder().encode(mutations).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pendingCount = mutations.count
    }

    nonisolated private static func readDocument(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        case "doc", "docx":
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "txt", "-stdout", url.path]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "OpenRayneo.TeleprompterImport", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self)
        default:
            var encoding = String.Encoding.utf8
            return try String(contentsOf: url, usedEncoding: &encoding)
        }
    }
}

@MainActor
struct TeleprompterLibraryPanel: View {
    @ObservedObject var model: TeleprompterLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("搜索标题或正文", text: $model.search)
                Button("新建", systemImage: "plus") { model.newDocument() }
                Button("导入文件", systemImage: "square.and.arrow.down") { model.importDocuments() }.disabled(model.importing)
            }
            if model.importing { ProgressView("正在导入…").controlSize(.small) }
            if !model.filteredDocuments.isEmpty {
                GroupBox("稿件库") {
                    VStack(spacing: 5) {
                        ForEach(model.filteredDocuments) { document in
                            HStack {
                                Button { model.select(document) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(document.title).fontWeight(model.selectedID == document.id ? .semibold : .regular)
                                        Text("\(document.text.count) 字 · \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { model.togglePin(document) } label: { Image(systemName: document.pinned ? "pin.fill" : "pin") }
                                Button(role: .destructive) { model.delete(document) } label: { Image(systemName: "trash") }
                            }.padding(7).background(model.selectedID == document.id ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(4)
                }
            }
            TextField("稿件标题", text: $model.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $model.text).font(.body).frame(minHeight: 210)
                .padding(5).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("保存稿件", systemImage: "square.and.arrow.down") { model.save() }.disabled(model.text.isEmpty)
                Button("发送并播放", systemImage: "play.fill") { Task { await model.play() } }
                    .buttonStyle(.borderedProminent).disabled(!model.connected || model.playing || model.text.isEmpty)
                Button("暂停") { model.control("pause") }.disabled(!model.sessionActive)
                Button("继续") { model.control("resume") }.disabled(!model.sessionActive)
                Button("结束") { model.control("stop") }.disabled(!model.sessionActive)
            }
            if let playback = model.playback {
                GroupBox("播放状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.playbackTitle).font(.headline)
                            Spacer()
                            Text(playback.previewing ? "预览中，等待眼镜开始" : !playback.running ? "已结束" : playback.paused ? "已暂停" : "播放中")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: playback.progress)
                        Text("\(Int(playback.progress * 100))% · 高亮 \(playback.highLightOffset) / \(playback.totalBytes) 字节 · 页面 \(playback.pageOffset) 字节")
                            .font(.caption).foregroundStyle(.secondary)
                        if playback.scroll == 1 {
                            Text("语音跟随 · 匹配置信度 \(Int(playback.matchConfidence * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(playback.transcript.isEmpty ? "等待本地识别结果…" : playback.transcript)
                                .font(.callout).textSelection(.enabled)
                        }
                        if let error = playback.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            DisclosureGroup("播放与显示设置") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("滚动模式", selection: $model.settings.scroll) {
                        Text("匀速滚动").tag(2)
                        Text("手动控制").tag(3)
                        Text("语音跟随（Mac 离线识别）").tag(1)
                    }
                    if model.settings.scroll == 1 {
                        Text("使用眼镜收音和 Mac 本地语音识别，根据朗读内容推进正文高亮与滚动；需先在实时语音页面完成识别授权。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Stepper("倒计时 \(model.settings.countdown) 秒", value: $model.settings.countdown, in: 0...10)
                        Stepper("速度 \(model.settings.speed)", value: $model.settings.speed, in: 1...300, step: 10)
                    }
                    HStack {
                        Picker("速度档", selection: $model.settings.gear) {
                            Text("低").tag(1); Text("中").tag(2); Text("高").tag(3)
                        }
                        Picker("景深", selection: $model.settings.depth) {
                            Text("浅").tag(1); Text("中").tag(2); Text("深").tag(3)
                        }
                        Picker("字号", selection: $model.settings.size) {
                            Text("小 18").tag(18); Text("中 20").tag(20); Text("大 24").tag(24)
                        }
                    }
                    HStack {
                        Stepper("行宽 \(model.settings.width)", value: $model.settings.width, in: 120...540, step: 12)
                        Stepper("行距 \(model.settings.leading)", value: $model.settings.leading, in: 0...20)
                    }
                }.padding(.top, 10)
            }
            HStack {
                Button(model.syncing ? "正在同步…" : "同步稿件列表") { Task { await model.synchronize() } }
                    .disabled(!model.connected || model.syncing)
                if model.pendingCount > 0 { Text("\(model.pendingCount) 项等待同步").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("打开提词库文件夹") { model.revealLibrary() }
            }
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Button("从眼镜恢复播放状态") { model.synchronizePlayback() }.disabled(!model.connected)
        }
    }
}
