// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct OTAFileRow: Identifiable {
    let id: String
    let size: Int
    let md5: String
    let burnMode: String
    let burnPath: String
    init?(_ json: [String: Any]) {
        guard let name = json["Name"] as? String else { return nil }
        id = name; size = json["Size"] as? Int ?? 0; md5 = json["Md5"] as? String ?? ""
        burnMode = json["BurnMode"].map { String(describing: $0) } ?? ""
        burnPath = json["BurnPath"] as? String ?? ""
    }
}

struct OfficialFirmwareRow {
    let id: String
    let version: String
    let notes: String
    let bytes: Int64
    let force: Bool
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let version = json["versionName"] as? String else { return nil }
        self.id = id; self.version = version; notes = json["updateDesc"] as? String ?? ""
        bytes = (json["apkSize"] as? NSNumber)?.int64Value ?? 0; force = json["isForceUpdate"] as? Bool == true
    }
}

@MainActor
final class OTAUpdateModel: ObservableObject {
    private struct AuthenticationFailureReference: Equatable {
        let requestGeneration: Int
        let identityEpoch: UUID?
        let credentialRevision: Int
        let serviceProcessID: Int32?
    }
    private weak var bridge: DesktopBridge?
    @Published var path = ""
    @Published var version = ""
    @Published var state = "idle"
    @Published var busy = false
    @Published var active = false
    @Published var progress = 0
    @Published var sentBytes = 0
    @Published var archiveBytes = 0
    @Published var totalFileBytes = 0
    @Published var preparedVersion = ""
    @Published var preparedPath = ""
    @Published var lastFile = ""
    @Published var files: [OTAFileRow] = []
    @Published var notice = "选择适配当前眼镜的完整官方 OTA ZIP，准备后可预览文件清单。"
    @Published var currentVersion = ""
    @Published var canVerify = false
    @Published var showStartConfirmation = false
    @Published var officialState = "idle"
    @Published var officialBusy = false
    @Published var officialConfigured = false
    @Published var officialConfigurationNotice = ""
    @Published var officialRegion = ""
    @Published var officialHost = ""
    @Published var officialNotice = ""
    @Published var officialCandidate: OfficialFirmwareRow?
    @Published var officialCandidateUsable = false
    @Published var officialDownloadedBytes: Int64 = 0
    @Published var officialExpectedBytes: Int64 = 0
    @Published var downloadedPath = ""
    @Published var downloadedVersion = ""

    private var accountSubscription: AnyCancellable?
    private var accountRevision = 0
    private var lastAuthenticationFailure: AuthenticationFailureReference?
    private var authenticationMarkTask: Task<Void, Never>?
    init(bridge: DesktopBridge) {
        self.bridge = bridge
        accountSubscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reloadAccount() }
        }
    }

    private func reloadAccount() async {
        accountRevision += 1
        lastAuthenticationFailure = nil
        let revision = accountRevision
        officialCandidate = nil; officialCandidateUsable = false; officialConfigured = false
        downloadedPath = ""; downloadedVersion = ""
        guard let bridge, bridge.serviceRunning else { return }
        do {
            ingest(try await bridge.request("/v1/ota/official/reload-session", body: [:]), accountRevision: revision)
        } catch { officialNotice = "官方会话已变化：" + error.localizedDescription }
    }
    var connected: Bool { bridge?.connected == true }
    var serviceRunning: Bool { bridge?.serviceRunning == true }
    var targetDescription: String {
        guard let device = bridge?.selectedDevice else { return "尚未选择眼镜" }
        return "\(device.name) · \(device.id)"
    }
    var canStart: Bool { !active && ["prepared", "failed", "cancelled"].contains(state) && !files.isEmpty }

    func choosePackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择根目录含 OtaFileInfo.json 的完整官方 OTA ZIP"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    func command(_ action: String) async {
        guard let bridge, !busy else { return }
        let revision = accountRevision
        busy = true; defer { busy = false }
        do {
            let body: [String: Any] = action == "prepare" ? ["path": path, "version": version] : [:]
            ingest(try await bridge.request("/v1/ota/\(action)", body: body), accountRevision: revision)
        } catch { notice = error.localizedDescription }
    }

    func refresh() async {
        guard let bridge, bridge.serviceRunning, !busy else { return }
        let revision = accountRevision
        do { ingest(try await bridge.request("/v1/ota", method: "GET"), accountRevision: revision) }
        catch { notice = error.localizedDescription }
    }

    func readFirmware() async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let json = try await bridge.request("/v1/firmware", method: "GET")
            currentVersion = json["OsVersion"] as? String ?? ""
        } catch { notice = error.localizedDescription }
    }

    func officialCommand(_ action: String) async {
        guard let bridge, !busy else { return }
        let revision = accountRevision
        busy = true; defer { busy = false }
        do {
            var body: [String: Any] = action == "download" ? ["candidateID": officialCandidate?.id ?? ""] : [:]
            if action == "check" {
                await authenticationMarkTask?.value
                let configuration = try await OfficialSessionCoordinator.shared.prepare()
                guard revision == accountRevision else { return }
                body["identityEpoch"] = configuration.identityEpoch?.uuidString as Any? ?? NSNull()
            }
            let route = action == "cancel" ? "/v1/ota/official/cancel" : "/v1/ota/\(action)"
            ingest(try await bridge.request(route, body: body), accountRevision: revision)
        } catch { officialNotice = error.localizedDescription }
    }

    func useDownloadedPackage() {
        path = downloadedPath; version = downloadedVersion
    }

    func revealDownload() {
        if !downloadedPath.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: downloadedPath)]) }
    }

    func reveal() {
        if !preparedPath.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preparedPath)]) }
    }

    private func ingest(_ json: [String: Any], accountRevision revision: Int) {
        state = json["state"] as? String ?? state; active = json["active"] as? Bool == true
        progress = json["progress"] as? Int ?? 0; sentBytes = json["sentBytes"] as? Int ?? 0
        lastFile = json["lastFile"] as? String ?? ""; canVerify = json["canVerify"] as? Bool == true
        if let firmware = json["firmware"] as? [String: Any] { currentVersion = firmware["OsVersion"] as? String ?? "" }
        if revision == accountRevision, let official = json["official"] as? [String: Any] {
            if let failure = official["authenticationFailure"] as? [String: Any],
               let request = failure["requestGeneration"] as? Int,
               let credentialRevision = failure["credentialRevision"] as? Int {
                let epoch = (failure["identityEpoch"] as? String).flatMap(UUID.init(uuidString:))
                let reference = AuthenticationFailureReference(requestGeneration: request, identityEpoch: epoch,
                    credentialRevision: credentialRevision, serviceProcessID: bridge?.serviceProcessID)
                if reference != lastAuthenticationFailure {
                    lastAuthenticationFailure = reference
                    authenticationMarkTask = Task {
                        try? await OfficialSessionCoordinator.shared.markWorkerAccessTokenExpired(
                            identityEpoch: epoch, credentialRevision: credentialRevision)
                    }
                }
            }
            let previousState = officialState
            officialState = official["state"] as? String ?? "idle"; officialBusy = official["busy"] as? Bool == true
            officialCandidate = (official["candidate"] as? [String: Any]).flatMap(OfficialFirmwareRow.init)
            officialCandidateUsable = official["candidateUsable"] as? Bool == true
            officialDownloadedBytes = (official["downloadedBytes"] as? NSNumber)?.int64Value ?? 0
            officialExpectedBytes = (official["expectedBytes"] as? NSNumber)?.int64Value ?? 0
            if let configuration = official["configuration"] as? [String: Any] {
                officialConfigured = configuration["sessionConfigured"] as? Bool == true
                officialRegion = configuration["region"] as? String ?? ""
                officialHost = configuration["apiHost"] as? String ?? ""
                officialConfigurationNotice = configuration["configurationError"] as? String ??
                    (officialConfigured ? "官方账号会话已从本机配置加载。" :
                        "请在官方账号面板保存已有会话并提供账号 ID，或通过启动环境配置。这是雷鸟官方账号会话。")
            }
            let download = official["download"] as? [String: Any] ?? [:]
            downloadedPath = download["path"] as? String ?? ""; downloadedVersion = download["version"] as? String ?? ""
            if let error = official["error"] as? String { officialNotice = error }
            else if previousState != officialState || officialNotice.isEmpty {
                officialNotice = ["idle": "读取眼镜当前版本后，可手动检查官方灰度更新。", "checking": "正在检查官方更新。",
                    "noUpdate": "官方检查成功，当前账号暂无可用升级。", "updateAvailable": "已取得官方升级候选，可手动下载。",
                    "downloading": "正在下载官方 ZIP。", "downloaded": "ZIP 已下载，填入准备区后请手动解压并准备。",
                    "cancelled": "官方检查或下载已取消。", "failed": "官方更新操作失败。"] [officialState] ?? officialState
            }
        }
        if let package = json["package"] as? [String: Any] {
            preparedPath = package["preparedPath"] as? String ?? ""
            preparedVersion = package["version"] as? String ?? ""
            archiveBytes = package["archiveBytes"] as? Int ?? 0; totalFileBytes = package["totalFileBytes"] as? Int ?? 0
            files = (package["files"] as? [[String: Any]] ?? []).compactMap(OTAFileRow.init)
        } else { files = []; preparedVersion = ""; preparedPath = ""; archiveBytes = 0; totalFileBytes = 0 }
        if let error = json["error"] as? String { notice = error }
        else {
            notice = ["idle": "尚未准备升级包。", "preparing": "正在解压并核对清单与文件。", "prepared": "升级包已准备，开始后将请求眼镜进入升级传输页。",
                "checkingSpace": "等待眼镜确认升级空间。", "openingTransferPage": "等待眼镜确认进入升级页面。", "waitingForVersion": "等待眼镜请求目标版本。",
                "waitingForManifest": "等待眼镜请求升级文件清单。", "transferring": "正在响应眼镜的升级分片请求。", "awaitingInstallation": "眼镜传输进度 100%，等待进入安装阶段。",
                "awaitingVerification": "眼镜已进入安装。重启并重新连接后，点击核验升级结果。", "completed": "已通过重启后的目标版本与验证确认。",
                "cancelled": "已撤销本地准备状态，未向眼镜发送取消指令。", "interrupted": "传输已中断，设备升级状态未确认。",
                "verificationUnconfirmed": "升级结果尚未确认，可重连后再次核验。", "failed": "升级流程失败。"] [state] ?? state
        }
    }
}

@MainActor
struct OTAUpdatePanel: View {
    @ObservedObject var model: OTAUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地固件升级").font(.title2.weight(.semibold))
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            GroupBox("升级目标") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.targetDescription).textSelection(.enabled)
                    Text(model.connected ? "眼镜已连接" : "请先在“设备连接”中连接眼镜")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(model.currentVersion.isEmpty ? "尚未读取固件版本" : "当前版本：\(model.currentVersion)")
                        Spacer()
                        Button("读取眼镜版本") { Task { await model.readFirmware() } }
                            .disabled(!model.connected || !model.serviceRunning || model.busy || model.active)
                    }
                    Text("从本机选择完整 OTA ZIP，通过 Mac 与眼镜的数据通道传输，无需官方账号或云服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if OfficialCloudPolicy.enabled { officialUpdates }
            GroupBox("准备官方升级包") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("OTA ZIP 路径", text: $model.path)
                        Button("选择 ZIP") { model.choosePackage() }
                    }
                    TextField("目标版本，例如 Strix OS 1.0.5.12", text: $model.version)
                    HStack {
                        Button("解压并准备") { Task { await model.command("prepare") } }
                            .disabled(!model.serviceRunning || model.path.isEmpty || model.version.isEmpty || model.active || model.officialBusy)
                        Button("查看准备目录") { model.reveal() }.disabled(model.preparedPath.isEmpty)
                    }
                    Text("准备仅在 Mac 解压并检查文件；实际安装从“开始升级”发起。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).disabled(model.busy || model.active)
            }
            if !model.files.isEmpty {
                GroupBox("已准备的升级清单") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("目标版本：\(model.preparedVersion)").font(.headline)
                        Text("压缩包 \(bytes(model.archiveBytes)) · \(model.files.count) 个文件 · 文件合计 \(bytes(model.totalFileBytes))")
                            .foregroundStyle(.secondary)
                        ForEach(model.files) { file in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(file.id).font(.system(.body, design: .monospaced)); Spacer(); Text(bytes(file.size)) }
                                Text("写入模式 \(file.burnMode)\(file.burnPath.isEmpty ? "" : " · " + file.burnPath)").font(.caption).foregroundStyle(.secondary)
                                Text("MD5 \(file.md5)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            if file.id != model.files.last?.id { Divider() }
                        }
                    }.padding(8).textSelection(.enabled)
                }
                HStack {
                    Button("开始升级") { model.showStartConfirmation = true }
                        .disabled(!model.connected || !model.canStart || model.busy || model.officialBusy)
                    Button("核验升级结果") { Task { await model.command("verify") } }
                        .disabled(!model.connected || !model.canVerify || model.busy)
                    Button("撤销本地准备") { Task { await model.command("cancel") } }
                        .disabled(model.active || model.busy)
                }
                ProgressView(value: Double(model.progress), total: 100)
                Text("眼镜报告进度 \(model.progress)% · 已发送 \(bytes(model.sentBytes))（含重传）")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.lastFile.isEmpty { Text("最近传输：\(model.lastFile)").font(.caption) }
                if !model.currentVersion.isEmpty { Text("眼镜最近报告版本：\(model.currentVersion)").font(.caption) }
            }
            if model.busy { ProgressView().controlSize(.small) }
            Text("进入传输或安装后，当前已确认协议没有取消指令。传输 100% 后还需重启核验。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("开始安装 \(model.preparedVersion)？", isPresented: $model.showStartConfirmation, titleVisibility: .visible) {
            Button("开始升级") { Task { await model.command("start") } }
            Button("返回", role: .cancel) {}
        } message: { Text("目标：\(model.targetDescription)。眼镜将进入升级页面并拉取本地文件，随后进入固件安装。请保持连接与设备供电。") }
        .task {
            await model.refresh()
        }
    }

    private var officialUpdates: some View {
        GroupBox("官方更新") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.officialConfigurationNotice).font(.caption).foregroundStyle(.secondary)
                if !model.officialHost.isEmpty {
                    Text("\(model.officialRegion == "overseas" ? "海外" : "境内") · \(model.officialHost)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.currentVersion.isEmpty ? "尚未读取眼镜版本" : "当前版本：\(model.currentVersion)")
                HStack {
                    Button("读取眼镜版本") { Task { await model.readFirmware() } }
                        .disabled(!model.connected || !model.serviceRunning || model.busy || model.active || model.officialBusy)
                    Button("检查官方更新") { Task { await model.officialCommand("check") } }
                        .disabled(!model.officialConfigured || model.currentVersion.isEmpty || !model.connected || !model.serviceRunning || model.busy || model.active || model.officialBusy)
                    if model.officialBusy {
                        Button("取消检查或下载") { Task { await model.officialCommand("cancel") } }.disabled(model.busy)
                    }
                }
                Text(model.officialNotice).foregroundStyle(.secondary).textSelection(.enabled)
                if let candidate = model.officialCandidate {
                    Divider()
                    HStack {
                        Text("目标版本：\(candidate.version)").font(.headline)
                        if candidate.force { Text("官方标记为强制更新").font(.caption).foregroundStyle(.secondary) }
                    }
                    if candidate.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file)).font(.caption) }
                    if !candidate.notes.isEmpty { Text(candidate.notes).textSelection(.enabled) }
                    Button("下载官方 ZIP") { Task { await model.officialCommand("download") } }
                        .disabled(!model.officialCandidateUsable || model.officialBusy || model.busy || model.active || !model.serviceRunning)
                    if !model.officialCandidateUsable { Text("设备或固件版本已变化，请重新检查。 ").font(.caption).foregroundStyle(.secondary) }
                }
                if model.officialState == "downloading" {
                    if model.officialExpectedBytes > 0 {
                        ProgressView(value: Double(model.officialDownloadedBytes), total: Double(max(model.officialExpectedBytes, model.officialDownloadedBytes)))
                    } else { ProgressView().controlSize(.small) }
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: model.officialDownloadedBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.downloadedPath.isEmpty {
                    Text(model.downloadedPath).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("填入准备区") { model.useDownloadedPackage() }.disabled(model.active || model.busy)
                        Button("在 Finder 中查看 ZIP") { model.revealDownload() }
                    }
                }
            }.padding(8)
        }
    }

    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}
