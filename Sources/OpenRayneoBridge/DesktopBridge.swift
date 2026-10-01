// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PairedGlasses: Identifiable, Sendable {
    let id: String
    let name: String
}

enum DesktopSession: String {
    case navigation, video, captions, prompts, teleprompter, asr, recording
    var stopPath: String {
        switch self {
        case .navigation, .video, .captions: return "/v1/captions/stop"
        case .prompts: return "/v1/prompts/stop"
        case .teleprompter: return "/v1/teleprompter/stop"
        case .asr, .recording: return "/v1/asr/stop"
        }
    }
    var title: String {
        switch self {
        case .navigation: return "导航演示"
        case .video: return "字符视频"
        case .captions: return "实时字幕"
        case .prompts: return "实时提示"
        case .teleprompter: return "提词器"
        case .asr: return "语音识别"
        case .recording: return "录音"
        }
    }
}

private struct DesktopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DesktopBridge: ObservableObject {
    @Published var devices: [PairedGlasses] = []
    @Published var selectedAddress = ""
    @Published private(set) var connected = false
    @Published private(set) var serviceRunning = false
    @Published private(set) var serviceProcessID: Int32?
    @Published private(set) var restartingService = false
    @Published private(set) var refreshingDevices = false
    @Published private(set) var pairingActive = false
    @Published private(set) var verifiedPairingAddress: String?
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var phase = "尚未连接"
    @Published private(set) var notice = "选择已配对的眼镜，点击连接。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeSession: DesktopSession? {
        didSet { if activeSession != .navigation { navigationFrameSent = false } }
    }
    @Published private(set) var transcript = ""
    @Published private(set) var audioSeconds = 0.0
    @Published private(set) var recordingPath: String?
    @Published private(set) var recordingFinalized = false
    @Published private(set) var apiAddress = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var apiVerifiedAt: Date?
    @Published private(set) var textVideo: TextVideo?
    @Published private(set) var videoImporting = false
    @Published private(set) var videoPlaying = false
    @Published private(set) var videoSeconds = 0.0
    @Published private(set) var videoPreview = ""

    var apiReady: Bool { serviceRunning && connected && apiVerifiedAt != nil }
    var selectedDevice: PairedGlasses? { devices.first { $0.id == selectedAddress } }

    var apiExample: String {
        "curl '\(apiAddress.isEmpty ? "http://127.0.0.1:8765" : apiAddress)/v1/device' \\\n  -H 'Authorization: Bearer <API_TOKEN>'"
    }

    private var service: Process?
    private var navigationFrameSent = false
    private var videoImport: Task<Void, Never>?
    private var videoPlayback: Task<Void, Never>?
    private let pairing = BluetoothPairing()
    private var token = ""
    private var stderrPipe: Pipe?
    private var stderrText = ""
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var monitor: Task<Void, Never>?
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    func refreshDevices() {
        guard !serviceRunning, !refreshingDevices, !pairingActive else { return }
        refreshingDevices = true
        Task {
            defer { refreshingDevices = false }
            do {
                let found = try await PairedGlasses.systemInventory()
                guard !serviceRunning else { return }
                devices = found
                let preferred = (ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? UserDefaults.standard.string(forKey: "selectedGlasses"))?.replacingOccurrences(of: ":", with: "-")
                if !devices.contains(where: { $0.id == selectedAddress }) {
                    selectedAddress = devices.first(where: { $0.id == preferred })?.id ?? devices.first?.id ?? ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    func pairAndConnect() {
        guard !busy, !stopping, !refreshingDevices else { return }
        if serviceRunning {
            Task {
                guard await shutdown() else { return }
                self.pairAndConnect()
            }
            return
        }
        perform("准备配对眼镜…") {
            self.verifiedPairingAddress = nil
            self.pairingActive = true
            defer { self.pairingActive = false }
            guard let device = try await self.pairing.pair(progress: { phase, notice in
                self.phase = phase
                self.notice = notice
            }) else {
                self.phase = "配对已取消"
                self.notice = "已取消配对，未启动 API。"
                return
            }
            self.devices.removeAll { $0.id == device.id }
            self.devices.append(device)
            self.selectedAddress = device.id
            self.verifiedPairingAddress = device.id
            UserDefaults.standard.set(device.id, forKey: "selectedGlasses")
            self.pairingActive = false
            self.notice = "配对完成，正在连接并启用 API…"
            try await self.ensureConnected()
            self.notice = "配对、连接已完成，本机 API 已就绪。"
        }
    }

    func cancelPairing() {
        pairing.cancel()
        operation?.cancel()
    }

    func connect() { perform("正在连接眼镜…") { try await self.ensureConnected() } }

    func disconnect() {
        Task { if await shutdown() { notice = "已断开，后台服务已停止。" } }
    }

    func restartConnectionService() {
        guard !stopping, !restartingService, !pairingActive, !refreshingDevices, !selectedAddress.isEmpty else { return }
        restartingService = true
        Task {
            defer { restartingService = false }
            guard await shutdown() else { return }
            perform("正在重新启动连接服务…") {
                try await self.ensureConnected()
                self.notice = "连接服务已重启，API 已就绪。请使用当前显示的地址与令牌。"
            }
        }
    }

    func showNavigation(direction: NavigationDirection, meters: Int, reopen: Bool = false) {
        perform("正在发送导航…") {
            try await self.prepareDisplay(.navigation, reopen: reopen)
            _ = try await self.request("/v1/captions/text", body: NavigationFrame.payload(direction: direction, meters: meters, compensateFirstCell: self.navigationFrameSent))
            self.navigationFrameSent = true
            self.notice = "导航已发送：\(meters == 0 ? "现在" : "\(meters)米后")\(direction.title)"
        }
    }

    func chooseVideo() {
        guard !videoImporting, !videoPlaying, !busy, !stopping else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func loadVideo(_ url: URL) {
        guard !videoImporting, !videoPlaying, !busy, !stopping else { return }
        videoImporting = true
        errorMessage = nil
        notice = "正在解码视频：\(url.lastPathComponent)…"
        videoImport = Task {
            defer { videoImporting = false; videoImport = nil }
            do {
                let video = try await TextVideo.load(url)
                try Task.checkCancellation()
                textVideo = video
                videoSeconds = 0
                videoPreview = video.frames[0].text(style: .fullWidth, inverted: false)
                notice = "视频已就绪，可选择字符模式播放。"
            } catch is CancellationError {
                notice = "已取消视频解码。"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelVideoImport() { videoImport?.cancel() }

    func showVideoAlignment() {
        perform("正在发送字符对齐标尺…") {
            try await self.prepareDisplay(.video, reopen: true)
            let text = TextVideoStyle.alignmentRuler
            _ = try await self.request("/v1/captions/text", body: ["text": text, "final": true])
            self.videoPreview = text
            self.notice = "请看七行左右两侧的竖线是否对齐；第二行中间为空白，这是正常的。"
        }
    }

    func playVideo(style: TextVideoStyle, fps: Int, inverted: Bool, alignUpdates: Bool, enhanceContrast: Bool = false) {
        guard let video = textVideo, !videoImporting, !videoPlaying, [5, 10].contains(fps) else { return }
        perform("正在打开字符视频…") {
            try await self.prepareDisplay(.video, reopen: true)
            self.videoPlaying = true
            self.videoSeconds = 0
            self.notice = "正在播放字符视频（无声），可随时结束当前功能。"
            self.videoPlayback = Task {
                defer { self.videoPlaying = false }
                let started = ProcessInfo.processInfo.systemUptime
                var index = 0
                var lastIndex: Int?
                do {
                    while !Task.isCancelled {
                        let elapsed = ProcessInfo.processInfo.systemUptime - started
                        if elapsed >= video.duration { break }
                        while index + 1 < video.frames.count, video.frames[index + 1].seconds <= elapsed { index += 1 }
                        if lastIndex != index {
                            let text = video.frames[index].text(style: style, inverted: inverted, enhanceContrast: enhanceContrast)
                            _ = try await self.request("/v1/captions/text", body: ["text": (alignUpdates && lastIndex != nil ? style.firstCellPadding : "") + text, "final": true])
                            try Task.checkCancellation()
                            self.videoPreview = text
                            lastIndex = index
                            self.videoSeconds = min(elapsed, video.duration)
                        }
                        // Skip missed slots instead of accumulating frames behind the transport.
                        let now = ProcessInfo.processInfo.systemUptime - started
                        let next = (floor(now * Double(fps)) + 1) / Double(fps)
                        try await Task.sleep(nanoseconds: UInt64(max(0, next - now) * 1_000_000_000))
                    }
                    try Task.checkCancellation()
                    self.videoSeconds = video.duration
                    self.notice = "视频播放结束，最后发送的画面保留在眼镜上。"
                } catch is CancellationError {
                    // The operation that cancelled playback owns the next status message.
                } catch {
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                        self.notice = "视频播放已停止，可重启连接服务后再试。"
                    }
                }
            }
        }
    }

    private func cancelVideoPlayback() async {
        let previous = videoPlayback
        previous?.cancel()
        await previous?.value
        videoPlayback = nil
        videoPlaying = false
    }

    func showText(_ text: String, translation: String, prompt: Bool, reopen: Bool = false) {
        perform("正在发送文字…") {
            let mode: DesktopSession = prompt ? .prompts : .captions
            try await self.prepareDisplay(mode, reopen: reopen)
            var body: [String: Any] = ["text": text, "final": true]
            if prompt { body["translation"] = translation }
            _ = try await self.request(prompt ? "/v1/prompts/text" : "/v1/captions/text", body: body)
            self.notice = "文字已发送。"
        }
    }

    func notify(title: String, body: String) {
        perform("正在发送通知…") {
            try await self.ensureConnected()
            _ = try await self.request("/v1/notifications", body: ["title": title, "body": body])
            self.notice = "通知已发送。"
        }
    }

    func startTeleprompter(title: String, text: String, speed: Int) {
        perform("正在传输提词稿…") {
            try await self.ensureConnected()
            try await self.stopCurrent()
            _ = try await self.request("/v1/teleprompter", body: ["title": title, "text": text, "speed": speed])
            self.activeSession = .teleprompter
            self.notice = "提词稿已发送。"
        }
    }

    func controlTeleprompter(_ action: String) {
        perform("正在控制提词器…") {
            _ = try await self.request("/v1/teleprompter/\(action)", body: [:])
            self.notice = action == "pause" ? "暂停指令已发送。" : "继续指令已发送。"
        }
    }

    func startAudio(recognize: Bool, record: Bool, duration: Int, locale: String) {
        perform(recognize ? "正在启动语音识别…" : "正在启动录音…") {
            try await self.ensureConnected()
            if recognize {
                let permission = try await self.request("/v1/asr", method: "GET")
                if permission["speechAuthorization"] as? Int != 3 {
                    self.notice = "请在系统弹窗中允许语音识别。"
                    let authorized = try await self.request("/v1/asr/authorize", body: [:])
                    guard authorized["speechAuthorization"] as? Int == 3 else { throw DesktopError(message: "语音识别未获授权，请在系统隐私设置中允许 OpenRayneo。") }
                }
            }
            try await self.stopCurrent()
            let result = try await self.request(recognize ? "/v1/asr/start" : "/v1/recording/start", body: ["locale": locale, "duration": duration, "record": record])
            self.activeSession = recognize ? .asr : .recording
            self.updateAudio(result)
            self.notice = recognize ? "正在使用眼镜麦克风识别语音。" : "正在录制眼镜双声道音频。"
        }
    }

    func stopSession() {
        perform("正在结束当前功能…") {
            try await self.stopCurrent()
            self.notice = "结束指令已发送。"
        }
    }

    func revealRecording() {
        if let path = recordingPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    func playRecording() {
        if recordingFinalized, let path = recordingPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    func copyAPIToken() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        notice = "当前后台服务的 API 令牌已复制。"
    }

    func copyAPIAddress() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiAddress, forType: .string)
        notice = "API 地址已复制。"
    }

    func copyAPIExample() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiExample.replacingOccurrences(of: "<API_TOKEN>", with: token), forType: .string)
        notice = "已复制带令牌的查询命令，可在终端直接调用。"
    }

    func checkAPI() {
        perform("正在检查 API…") {
            try await self.verifyAPI()
            self.notice = "API 健康检查、鉴权和眼镜连接均正常。"
        }
    }

    private func verifyAPI() async throws {
        apiVerifiedAt = nil
        let health = try await request("/health", method: "GET", timeout: 5)
        let device = try await request("/v1/device", method: "GET", timeout: 5)
        guard health["ok"] as? Bool == true else { throw DesktopError(message: "本机 API 健康检查未通过。") }
        let ble = device["ble"] as? [String: Any] ?? [:]
        connected = device["rfcommConnected"] as? Bool == true && ble["ready"] as? Bool == true
        guard connected else { throw DesktopError(message: "API 可以访问，但眼镜未连接。请重新连接眼镜。") }
        apiVerifiedAt = Date()
    }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !stopping else { return }
        let id = UUID()
        operationID = id
        busy = true
        errorMessage = nil
        notice = message
        operation = Task {
            defer { if operationID == id { busy = false; operation = nil } }
            do { try await action() }
            catch is CancellationError {
                if operationID == id {
                    phase = "操作已取消"
                    notice = "已停止当前操作。已清除的旧配对不会恢复。"
                }
            }
            catch {
                if operationID == id, !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    if !serviceRunning { phase = "操作未完成" }
                    notice = "操作未完成，可检查连接后重试。"
                }
            }
        }
    }

    private func ensureConnected() async throws {
        try Task.checkCancellation()
        if service?.isRunning != true { try await startService() }
        let status = try await request("/v1/device", method: "GET", timeout: 3)
        connected = status["rfcommConnected"] as? Bool == true && (status["ble"] as? [String: Any])?["ready"] as? Bool == true
        if !connected {
            try await waitForBluetooth(status)
            phase = "正在建立蓝牙连接"
            notice = "正在认证眼镜并建立数据通道…"
            let response: [String: Any]
            do {
                response = try await request("/v1/device/connect", body: [:])
            } catch {
                let failure = error
                if !Task.isCancelled, let state = try? await request("/v1/device", method: "GET", timeout: 3),
                   let ble = state["ble"] as? [String: Any] {
                    if ble["ready"] as? Bool == true {
                        throw DesktopError(message: "眼镜已完成 BLE 认证，但数据通道未建立。请先断开并保留诊断，不要反复点击连接。\n\(failure.localizedDescription)")
                    }
                    if (ble["lastError"] as? String)?.contains("scanning") == true {
                        throw DesktopError(message: "未收到眼镜广播。请先断开，再退出并重新进入眼镜配对模式，准备好后只重试一次。\n\(failure.localizedDescription)")
                    }
                }
                throw failure
            }
            connected = response["rfcommConnected"] as? Bool == true
            guard connected else { throw DesktopError(message: "眼镜尚未连接，请保持开机并靠近 Mac。") }
        }
        phase = "已连接"
        if apiVerifiedAt == nil { try await verifyAPI() }
        verifiedPairingAddress = selectedAddress
        notice = "眼镜已连接，本机 API 已就绪。"
    }

    private func waitForBluetooth(_ initial: [String: Any]) async throws {
        var status = initial
        let deadline = Date().addingTimeInterval(90)
        while true {
            try Task.checkCancellation()
            let ble = status["ble"] as? [String: Any] ?? [:]
            let state = ble["bluetoothState"] as? Int ?? 0
            let authorization = ble["bluetoothAuthorization"] as? Int
            if state == 3 || authorization == 1 || authorization == 2 {
                throw DesktopError(message: "蓝牙访问未获授权，请在系统设置的“隐私与安全性 → 蓝牙”中允许 OpenRayneo。")
            }
            if state == 5 { return }
            if state == 4 { throw DesktopError(message: "Mac 蓝牙已关闭，请打开系统蓝牙后重试。") }
            if state == 2 { throw DesktopError(message: "这台 Mac 未提供可用的蓝牙支持。") }
            guard Date() < deadline else { throw DesktopError(message: "系统蓝牙尚未就绪。请处理权限弹窗后重新连接。") }
            phase = "等待系统蓝牙就绪"
            notice = "正在等待系统蓝牙；如有权限弹窗，请允许 OpenRayneo。"
            try await Task.sleep(nanoseconds: 500_000_000)
            status = try await request("/v1/device", method: "GET", timeout: 3)
        }
    }

    private func prepareDisplay(_ mode: DesktopSession, reopen: Bool) async throws {
        try await ensureConnected()
        if activeSession == mode, !reopen { return }
        try await stopCurrent()
        let prefix = mode == .prompts ? "/v1/prompts" : "/v1/captions"
        let font = mode == .video ? 1 : 2
        let lines = mode == .video ? 7 : 5
        let response = try await request(prefix + "/start", body: ["font_size": font, "content_width": 100, "max_lines": lines])
        guard response["accepted"] as? Bool == true else {
            _ = try? await request(prefix + "/stop", body: [:], timeout: 5)
            throw DesktopError(message: "未收到眼镜的显示启动确认，请重试。")
        }
        activeSession = mode
        if mode == .navigation || mode == .video {
            let config = (response["reply"] as? [String: Any])?["effective_config"] as? [String: Any]
            guard config?["font_size"] as? Int == font, config?["max_lines"] as? Int == lines, config?["content_width"] as? Int == 100 else {
                try await stopCurrent()
                throw DesktopError(message: "眼镜返回了不同的布局配置，暂不发送字符网格。")
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func stopCurrent() async throws {
        await cancelVideoPlayback()
        guard let current = activeSession else { return }
        let result = try await request(current.stopPath, body: [:])
        if current == .asr || current == .recording { updateAudio(result) }
        activeSession = nil
    }

    private func request(_ path: String, method: String = "POST", body: [String: Any]? = nil, timeout: TimeInterval = 75) async throws -> [String: Any] {
        guard !apiAddress.isEmpty else { throw DesktopError(message: "后台服务尚未启动，请先连接眼镜。") }
        var request = URLRequest(url: URL(string: apiAddress + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await network.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DesktopError(message: json["error"] as? String ?? "后台服务没有完成请求。")
        }
        return json
    }

    private func startService() async throws {
        guard service?.isRunning != true else { throw DesktopError(message: "旧连接服务尚未退出，未启动新进程。") }
        guard !selectedAddress.isEmpty else { throw DesktopError(message: "请先点击“添加并配对眼镜”，或刷新已配对设备列表。") }
        activeSession = nil
        apiVerifiedAt = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        monitor?.cancel()
        let port = try Self.availablePort()
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--headless"]
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var environment = ProcessInfo.processInfo.environment
        environment["OPENRAYNEO_API_TOKEN"] = token
        environment["OPENRAYNEO_PORT"] = String(port)
        environment["RAYNEO_ADDRESS"] = selectedAddress
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardError = pipe
        stderrText = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let child, self.service === child else { return }
                self.stderrText = String((self.stderrText + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.service === process, !self.stopping else { return }
                self.connected = false
                self.serviceRunning = false
                self.serviceProcessID = nil
                self.activeSession = nil
                self.videoPlayback?.cancel()
                self.apiVerifiedAt = nil
                self.phase = "后台服务已退出"
                self.errorMessage = self.stderrText.isEmpty ? "后台服务已退出，请重新连接。" : self.stderrText
            }
        }
        try child.run()
        service = child
        serviceProcessID = child.processIdentifier
        stderrPipe = pipe
        apiAddress = "http://127.0.0.1:\(port)"
        serviceRunning = true
        phase = "正在启动后台服务"
        UserDefaults.standard.set(selectedAddress, forKey: "selectedGlasses")
        do {
            var ready = false
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard child.isRunning else { throw DesktopError(message: stderrText.isEmpty ? "后台服务启动失败。" : stderrText) }
                // An authenticated read proves readiness of our child, not another service on the port.
                if (try? await request("/v1/device", method: "GET", timeout: 0.5)) != nil { ready = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ready else { throw DesktopError(message: "后台服务启动超时，请重试。") }
            startMonitoring()
        } catch {
            let stopped = await BridgeProcessLifecycle.stop(child)
            serviceRunning = !stopped
            if stopped { serviceProcessID = nil }
            throw error
        }
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task {
            while !Task.isCancelled, service?.isRunning == true {
                if let data = try? await request("/v1/device", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    connected = data["rfcommConnected"] as? Bool == true && (data["ble"] as? [String: Any])?["ready"] as? Bool == true
                    if !connected { apiVerifiedAt = nil }
                    let ble = data["ble"] as? [String: Any] ?? [:]
                    let rawPhase = ble["phase"] as? String ?? "idle"
                    let names = ["idle": "等待连接", "waitingForBluetooth": "等待系统蓝牙", "scanning": "正在寻找眼镜", "connecting": "正在连接眼镜", "discoveringServices": "正在发现蓝牙服务", "discoveringCharacteristics": "正在准备蓝牙通道", "readingIdentity": "正在核对眼镜身份", "subscribing": "正在准备通知通道", "exchangingDeviceInfo": "正在交换设备信息", "authenticating": "正在认证眼镜", "authenticated": "正在打开数据通道", "failed": "连接失败"]
                    phase = connected ? "已连接" : ble["bluetoothState"] as? Int == 0 ? "等待系统蓝牙就绪" : names[rawPhase] ?? "连接阶段：\(rawPhase)"
                    if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { diagnostics = String(decoding: bytes, as: UTF8.self) }
                } else if !Task.isCancelled { connected = false; apiVerifiedAt = nil; phase = "后台服务暂时无响应" }
                if activeSession == .asr || activeSession == .recording,
                   let audio = try? await request("/v1/asr", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    updateAudio(audio)
                    if audio["running"] as? Bool == false {
                        activeSession = nil
                        notice = "音频会话已结束。"
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateAudio(_ data: [String: Any]) {
        transcript = data["transcript"] as? String ?? ""
        audioSeconds = data["decodedSeconds"] as? Double ?? 0
        if let recording = data["recording"] as? [String: Any] {
            recordingPath = recording["path"] as? String
            recordingFinalized = recording["finalized"] as? Bool == true
        }
        if let error = data["error"] as? String { errorMessage = error }
    }

    @discardableResult
    func shutdown() async -> Bool {
        guard !stopping else { return false }
        stopping = true
        defer { stopping = false }
        phase = restartingService ? "正在重启连接服务" : "正在停止连接服务"
        pairing.cancel()
        await cancelVideoPlayback()
        operationID = nil
        let previousOperation = operation
        let previousMonitor = monitor
        previousOperation?.cancel()
        previousMonitor?.cancel()
        await previousOperation?.value
        await previousMonitor?.value
        operation = nil
        monitor = nil
        if let child = service, child.isRunning {
            if let current = activeSession {
                if let result = try? await request(current.stopPath, body: [:], timeout: 5), current == .asr || current == .recording { updateAudio(result) }
            }
            // Also catches a start request completed by the server after client cancellation.
            if let result = try? await request("/v1/asr/stop", body: [:], timeout: 3) { updateAudio(result) }
            guard await BridgeProcessLifecycle.stop(child) else {
                connected = false
                apiVerifiedAt = nil
                busy = false
                phase = "连接服务未能退出"
                errorMessage = "旧连接进程尚未退出，已停止重启流程。请保留诊断后重试。"
                return false
            }
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        service = nil
        serviceProcessID = nil
        connected = false
        apiVerifiedAt = nil
        serviceRunning = false
        activeSession = nil
        phase = "已断开"
        busy = false
        apiAddress = ""
        diagnostics = ""
        token = ""
        return true
    }

    private static func availablePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopError(message: "无法创建本地服务端口。") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = (UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765).bigEndian
        let bind = { withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        if bind() != 0 { address.sin_port = 0; guard bind() == 0 else { throw DesktopError(message: "无法分配本地服务端口。") } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard result == 0 else { throw DesktopError(message: "无法读取本地服务端口。") }
        return UInt16(bigEndian: address.sin_port)
    }
}
