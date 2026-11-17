// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

private struct DashboardLayoutDraft: Codable {
    var mode = 0
    var widgets = [2, 3, 1]
    var modeEdited = false
    var widgetsEdited = false
    var removedWidgets: [Int] = []
}

private struct DashboardLayoutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DashboardLayoutModel: ObservableObject {
    @Published var mode = 0 {
        didSet {
            guard !restoring, mode != oldValue else { return }
            modeRevision += 1
            modeEdited = deviceMode.map { mode != $0 } ?? true
            saveDraft()
        }
    }
    @Published var widgets = [2, 3, 1] {
        didSet {
            guard !restoring, widgets != oldValue else { return }
            widgetsRevision += 1
            removedWidgets.formUnion(oldValue.filter { !widgets.contains($0) })
            removedWidgets.subtract(widgets)
            widgetsEdited = configured ? widgets != deviceWidgets : true
            saveDraft()
        }
    }
    @Published private(set) var deviceConfig: [String: Any] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var notice = "可先编辑首页布局，连接眼镜后应用。"
    @Published private(set) var error: String?

    private weak var bridge: DesktopBridge?
    private let defaults = UserDefaults.standard
    private let storageKey = "dashboardLayoutDraftsV1"
    private var drafts: [String: DashboardLayoutDraft] = [:]
    private var configurations: [String: [String: Any]] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var address = ""
    private var connectionRevision = 0
    private var modeRevision = 0
    private var widgetsRevision = 0
    private var modeEdited = false
    private var widgetsEdited = false
    private var removedWidgets = Set<Int>()
    private var restoring = false

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: DashboardLayoutDraft].self, from: data) {
            drafts = saved
        }
        selectDevice(bridge.selectedAddress)
        bridge.$selectedAddress.removeDuplicates().dropFirst().sink { [weak self] value in
            self?.selectDevice(value)
        }.store(in: &subscriptions)
        bridge.$connected.removeDuplicates().dropFirst().sink { [weak self] connected in
            guard let self else { return }
            connectionRevision += 1
            if !connected { loaded = false }
            objectWillChange.send()
        }.store(in: &subscriptions)
    }

    var connected: Bool { bridge?.connected == true }
    var configured: Bool { deviceMode != nil && deviceConfig["widgets"] is [Int] }
    var deviceMode: Int? { deviceConfig["simple_mode"] as? Int }
    var deviceWidgets: [Int] { deviceConfig["widgets"] as? [Int] ?? [] }
    var draftConfig: [String: Any] { ["simple_mode": mode, "widgets": widgets] }
    var hasChanges: Bool {
        configured ? mode != deviceMode || widgets != deviceWidgets : modeEdited || widgetsEdited
    }

    func addWidget(_ id: Int) {
        guard !widgets.contains(id) else { return }
        guard widgets.count < 5 else {
            error = "最多支持添加 5 个组件。"
            return
        }
        error = nil
        widgets.append(id)
    }

    func removeWidget(_ id: Int) {
        guard !widgets.contains(id) || widgets.count > 1 else {
            error = "首页至少保留 1 个组件。"
            return
        }
        error = nil
        widgets.removeAll { $0 == id }
    }

    /// Destination is the item's final index, for the up/down buttons.
    func moveWidget(from source: Int, to destination: Int) {
        guard widgets.indices.contains(source), widgets.indices.contains(destination), source != destination else { return }
        var value = widgets
        value.insert(value.remove(at: source), at: destination)
        widgets = value
    }

    /// SwiftUI onMove uses an insertion boundary before the source is removed.
    func moveWidgets(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ widgets.indices.contains($0) }),
              (0...widgets.count).contains(destination) else { return }
        let moving = offsets.map { widgets[$0] }
        var value = widgets.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        value.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        widgets = value
    }

    func resetDraft() {
        guard let deviceMode, configured else { return }
        restoring = true
        mode = deviceMode; widgets = deviceWidgets
        restoring = false
        modeRevision += 1; widgetsRevision += 1
        modeEdited = false; widgetsEdited = false; removedWidgets = []
        error = nil
        notice = "已恢复上次读取的眼镜布局，尚未向眼镜发送。"
        saveDraft()
    }

    func read() async {
        guard !busy else { return }
        guard let bridge, connected else {
            error = "请先连接眼镜；本地草稿已保留。"
            return
        }
        let expectedAddress = address, revision = connectionRevision
        let initialModeRevision = modeRevision, initialWidgetsRevision = widgetsRevision
        busy = true; error = nil
        defer { busy = false }
        do {
            let response = try await bridge.request("/v1/dashboard", method: "GET", timeout: 10)
            guard isCurrent(expectedAddress, revision: revision) else { return }
            try ingest(response, preserveMode: modeEdited || modeRevision != initialModeRevision,
                       preserveWidgets: widgetsEdited || widgetsRevision != initialWidgetsRevision)
            notice = hasChanges ? "已读取眼镜布局，保留本地未应用的编辑。" : "已读取眼镜首页布局。"
        } catch {
            guard isCurrent(expectedAddress, revision: revision) else { return }
            self.error = error.localizedDescription
        }
    }

    func apply(synchronizeAdded: (@MainActor ([Int]) async throws -> Void)? = nil) async {
        guard !busy else { return }
        guard let bridge, connected, !address.isEmpty else {
            error = "请先选择并连接眼镜；本地草稿已保留。"
            return
        }
        let expectedAddress = address, revision = connectionRevision
        let initialModeRevision = modeRevision, initialWidgetsRevision = widgetsRevision
        busy = true; error = nil
        defer { busy = false }
        var sent = false
        do {
            // Read first so an offline draft cannot silently discard an unknown device widget.
            let before = try await bridge.request("/v1/dashboard", method: "GET", timeout: 10)
            guard isCurrent(expectedAddress, revision: revision) else { return }
            try ingest(before, preserveMode: modeEdited || modeRevision != initialModeRevision,
                       preserveWidgets: widgetsEdited || widgetsRevision != initialWidgetsRevision)
            let requestedMode = mode, requestedWidgets = widgets
            let addedWidgets = requestedWidgets.filter { !deviceWidgets.contains($0) }
            _ = try await bridge.request("/v1/glasses/dashboard", method: "PATCH", body: draftConfig, timeout: 8)
            sent = true
            guard isCurrent(expectedAddress, revision: revision) else { return }
            try await synchronizeAdded?(addedWidgets)
            guard isCurrent(expectedAddress, revision: revision) else { return }
            let response = try await bridge.request("/v1/dashboard", method: "GET", timeout: 10)
            guard isCurrent(expectedAddress, revision: revision) else { return }
            try ingest(response, preserveMode: true, preserveWidgets: true)
            guard deviceMode == requestedMode, deviceWidgets == requestedWidgets else {
                throw DashboardLayoutFailure(message: "眼镜读回的首页布局与发送内容不同，草稿已保留，请检查当前布局后重试。")
            }
            notice = hasChanges ? "眼镜已确认本次布局；发送期间的新编辑尚未应用。" : "眼镜已确认首页模式和组件顺序。"
        } catch {
            guard isCurrent(expectedAddress, revision: revision) else { return }
            self.error = sent ? "布局已发送，但未完成读回确认：\(error.localizedDescription)" : error.localizedDescription
        }
    }

    private func ingest(_ response: [String: Any], preserveMode: Bool, preserveWidgets: Bool) throws {
        guard let config = response["config"] as? [String: Any],
              let currentMode = config["simple_mode"] as? Int,
              let currentWidgets = config["widgets"] as? [Int] else {
            throw DashboardLayoutFailure(message: "眼镜未返回完整的首页模式和组件列表。")
        }
        restoring = true
        if !preserveMode { mode = currentMode }
        if !preserveWidgets { widgets = currentWidgets }
        else {
            for id in currentWidgets where !(1...6).contains(id) && !widgets.contains(id) && !removedWidgets.contains(id) {
                widgets.append(id)
            }
        }
        restoring = false
        deviceConfig = config
        configurations[address] = config
        loaded = true
        modeEdited = mode != currentMode
        widgetsEdited = widgets != currentWidgets
        saveDraft()
    }

    private func selectDevice(_ value: String) {
        address = value.uppercased().replacingOccurrences(of: ":", with: "-")
        connectionRevision += 1
        let draft = drafts[address] ?? DashboardLayoutDraft()
        restoring = true
        mode = draft.mode; widgets = draft.widgets
        restoring = false
        modeEdited = draft.modeEdited; widgetsEdited = draft.widgetsEdited
        removedWidgets = Set(draft.removedWidgets)
        deviceConfig = configurations[address] ?? [:]
        loaded = false; error = nil
        notice = "可离线编辑当前眼镜的草稿，连接后读取或应用。"
    }

    private func saveDraft() {
        drafts[address] = DashboardLayoutDraft(mode: mode, widgets: widgets, modeEdited: modeEdited,
                                             widgetsEdited: widgetsEdited, removedWidgets: Array(removedWidgets))
        if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: storageKey) }
    }

    private func isCurrent(_ expected: String, revision: Int) -> Bool {
        connected && address == expected && connectionRevision == revision
    }
}
