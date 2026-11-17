// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

struct CaptionDisplayDraft: Codable, Equatable {
    var fontSize = 2
    var contentWidth = 100
    var maxLines = 5
    var position = "center"
    var isDisplay = true
    var straightView = "original"
    var payload: [String: Any] {
        ["font_size": fontSize, "content_width": contentWidth, "max_lines": maxLines,
         "position": position, "is_display": isDisplay, "straight_view": straightView]
    }
    mutating func merge(_ body: [String: Any]) {
        if let value = body["font_size"] as? Int { fontSize = value }
        if let value = body["content_width"] as? Int { contentWidth = value }
        if let value = body["max_lines"] as? Int { maxLines = value }
        if let value = body["position"] as? String { position = value }
        if let value = body["is_display"] as? Bool { isDisplay = value }
        if let value = body["straight_view"] as? String { straightView = value }
    }
}

@MainActor
final class CaptionSettingsModel: ObservableObject {
    @Published var draft = CaptionDisplayDraft() { didSet { saveLocalDraft() } }
    @Published var language = "zh-CN"
    @Published var scenario = "face_to_face"
    @Published private(set) var effective: [String: Any] = [:]
    @Published private(set) var session: [String: Any] = [:]
    @Published private(set) var activePromptSettings: [String: Any] = [:]
    @Published private(set) var pendingGlobal = false
    @Published private(set) var busy = false
    @Published private(set) var notice = "保存显示草稿，预览字幕布局，或配置实时提示的语言和收音场景。"
    private weak var bridge: DesktopBridge?
    private var subscriptions = Set<AnyCancellable>()
    private var serverDraft = CaptionDisplayDraft()
    private var serverLanguage = "zh-CN"
    private var serverScenario = "face_to_face"
    private var reconnection: Task<Void, Never>?
    private var deferredAttempted = false
    private var loadingDraft = false
    private let defaults = UserDefaults.standard

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        loadLocalDraft()
        bridge.$connected.dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                objectWillChange.send()
                if connected { reconnect() }
                else { reconnection?.cancel(); deferredAttempted = false }
            }
        }.store(in: &subscriptions)
        bridge.$selectedAddress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                reconnection?.cancel(); effective = [:]; session = [:]; activePromptSettings = [:]
                pendingGlobal = false; deferredAttempted = false
                loadLocalDraft()
                if connected { reconnect() }
            }
        }.store(in: &subscriptions)
        if bridge.connected { reconnect() }
    }

    var connected: Bool { bridge?.connected == true }
    var previewActive: Bool { session["active"] as? Bool == true && session["business"] as? Int == 0x13 }
    var promptActive: Bool { session["active"] as? Bool == true && session["business"] as? Int == 0x17 }
    var dirty: Bool { draft != serverDraft }
    var sessionLabel: String {
        let labels = ["idle": "空闲", "starting": "等待启动确认", "active": "运行中", "paused": "眼镜已暂停", "closed": "已结束", "failed": "启动未获接受"]
        let phase = session["phase"] as? String ?? "idle"
        let business = session["business"] as? Int
        return (business == 0x13 ? "字幕预览 · " : business == 0x17 ? "实时提示 · " : "") + (labels[phase] ?? phase)
    }

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    func refresh() async {
        guard connected, !busy, let bridge else { return }
        let expected = bridge.selectedAddress
        do {
            let value = try await bridge.request("/v1/caption-settings", method: "GET")
            guard bridge.selectedAddress == expected, !Task.isCancelled else { return }
            apply(value)
        } catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }

    func saveDraft() async { await perform("草稿已保存。") { try await self.writeDraft($0) } }

    func preview() async {
        await perform("字幕预览请求已发送。") { bridge in
            try await self.writeDraft(bridge)
            if self.previewActive {
                return try await bridge.request("/v1/captions/config", body: ["scope": "temporary", "sid": self.session["sid"] as? String ?? ""])
            }
            return try await bridge.request("/v1/captions/start")
        }
    }

    func applyGlobal() async {
        await perform("全局显示配置已提交。") { bridge in
            try await self.writeDraft(bridge)
            return try await bridge.request("/v1/captions/config", body: ["scope": "global"])
        }
    }

    func closePreview() async {
        guard previewActive, let sid = session["sid"] as? String else { return }
        await perform("字幕预览已关闭。") { try await $0.request("/v1/captions/stop", body: ["sid": sid]) }
    }

    func applyPromptPreferences() async {
        var body: [String: Any] = [:]
        if language != serverLanguage { body["language"] = language }
        if scenario != serverScenario { body["scenario"] = scenario }
        if promptActive, let sid = session["sid"] as? String { body["sid"] = sid }
        await perform(promptActive ? "实时提示设置已发出，实际生效以眼镜响应为准。" : "实时提示设置已保存，下次启动使用。") {
            try await $0.request("/v1/prompts/settings", body: body)
        }
    }

    private func perform(_ success: String, operation: (DesktopBridge) async throws -> [String: Any]) async {
        guard !busy, connected, let bridge else { return }
        busy = true
        let expected = bridge.selectedAddress
        defer { busy = false }
        do {
            let value = try await operation(bridge)
            guard expected == bridge.selectedAddress, !Task.isCancelled else { return }
            apply(value)
            let result = value["result"] as? [String: Any] ?? value
            if result["deferred"] as? Bool == true { notice = "草稿已保留，等待重连后再同步全局显示配置。" }
            else if result["accepted"] as? Bool == false || result["applicationAccepted"] as? Bool == false {
                let code = (result["reply"] as? [String: Any])?["code"] ?? result["code"] ?? "未知"
                notice = "眼镜未接受此设置（\(code)），原回读配置已保留。"
            } else if result["acknowledged"] as? Bool == false { notice = "请求已发出，尚未收到眼镜应用层确认。" }
            else { notice = success }
        } catch { notice = error.localizedDescription }
    }

    @discardableResult
    private func writeDraft(_ bridge: DesktopBridge) async throws -> [String: Any] {
        let expected = bridge.selectedAddress
        let submitted = draft
        let value = try await bridge.request("/v1/caption-settings/display", method: "PATCH", body: submitted.payload)
        guard bridge.connected, bridge.selectedAddress == expected, !Task.isCancelled else { throw CancellationError() }
        serverDraft = submitted
        return value
    }

    private func apply(_ value: [String: Any]) {
        if let remote = value["displayDraft"] as? [String: Any] {
            let wasDirty = dirty
            serverDraft.merge(remote)
            if !wasDirty { draft = serverDraft }
        }
        if let readback = value["effectiveDisplay"] as? [String: Any] { effective.merge(readback) { _, new in new } }
        if let state = value["session"] as? [String: Any] { session = state }
        if let state = value["activePromptSettings"] as? [String: Any] { activePromptSettings = state }
        if let preferences = value["prompts"] as? [String: String] {
            let languageEdited = language != serverLanguage, scenarioEdited = scenario != serverScenario
            serverLanguage = preferences["language"] ?? serverLanguage
            serverScenario = preferences["scenario"] ?? serverScenario
            if !languageEdited { language = serverLanguage }
            if !scenarioEdited { scenario = serverScenario }
        }
        pendingGlobal = value["pendingGlobal"] as? Bool ?? pendingGlobal
        if let result = value["result"] as? [String: Any], let error = result["error"] as? String { notice = error }
    }

    private func reconnect() {
        reconnection?.cancel()
        reconnection = Task { [weak self] in
            guard let self else { return }
            await refresh()
            guard connected, pendingGlobal, !deferredAttempted, !busy, let bridge, !Task.isCancelled else { return }
            deferredAttempted = true
            await perform("已补发之前待同步的全局显示配置。") { _ in
                try await bridge.request("/v1/captions/config", body: ["scope": "global"])
            }
        }
    }

    private var localKey: String { "captionDisplayDraft.\(bridge?.selectedAddress ?? "default")" }
    private func saveLocalDraft() {
        guard !loadingDraft, let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: localKey)
    }
    private func loadLocalDraft() {
        loadingDraft = true
        defer { loadingDraft = false }
        draft = defaults.data(forKey: localKey).flatMap { try? JSONDecoder().decode(CaptionDisplayDraft.self, from: $0) } ?? CaptionDisplayDraft()
        serverDraft = CaptionDisplayDraft()
        language = "zh-CN"; scenario = "face_to_face"
        serverLanguage = language; serverScenario = scenario
    }
}
