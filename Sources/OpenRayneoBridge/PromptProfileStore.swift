// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AssistantCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PromptProfileStore: ObservableObject {
    @Published var draft: PromptProfile
    @Published private(set) var saved: PromptProfile
    @Published private(set) var history: [PromptProfile] = []
    @Published var message: String?
    private let folder: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/PromptProfiles")
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let defaults = PromptProfile.defaultProfile
        saved = defaults; draft = defaults
        let current = self.folder.appendingPathComponent("active.json")
        if FileManager.default.fileExists(atPath: current.path) {
            do {
                let loaded = try decoder.decode(PromptProfile.self, from: Data(contentsOf: current))
                try loaded.validate(); saved = loaded; draft = loaded
            } catch { message = "提示词配置未能读取，暂用默认值：\(error.localizedDescription)" }
        }
        reloadHistory()
    }

    var hasChanges: Bool { draft != saved }

    func reloadIfUnchanged() {
        guard !hasChanges else { return }
        do {
            let profile = try AssistantProfileFiles.load(folder: folder)
            saved = profile; draft = profile; reloadHistory()
        } catch { message = "配置未能重载：\(error.localizedDescription)" }
    }

    func save() throws -> PromptProfile {
        try draft.validate()
        reloadHistory()
        var value = draft
        value.revision = max(saved.revision, history.map(\.revision).max() ?? 0) + 1
        value.savedAt = Date()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let archive = folder.appendingPathComponent("revision-\(value.revision).json")
        try data.write(to: archive, options: .atomic)
        try data.write(to: folder.appendingPathComponent("active.json"), options: .atomic)
        saved = value; draft = value; message = "已保存 r\(value.revision)"
        reloadHistory()
        return value
    }

    func restoreDefaults() { draft = .defaultProfile; message = "默认配置已载入草稿，保存后生效" }
    func restore(_ value: PromptProfile) { draft = value; message = "历史 r\(value.revision) 已载入草稿，保存将创建新版本" }

    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try decoder.decode(PromptProfile.self, from: Data(contentsOf: url))
            try value.validate(); draft = value; message = "配置已导入草稿，保存后生效"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    func exportProfile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "OpenRayneo-prompts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try encoder.encode(draft).write(to: url, options: .atomic); message = "已导出当前草稿" }
        catch { message = "导出失败：\(error.localizedDescription)" }
    }

    private func reloadHistory() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        history = files.filter { $0.lastPathComponent.hasPrefix("revision-") && $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PromptProfile.self, from: Data(contentsOf: $0)) }.sorted { $0.revision > $1.revision }
    }
}
