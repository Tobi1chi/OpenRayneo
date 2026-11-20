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
    let deviceType: String?
    init(id: String, name: String, deviceType: String? = nil) {
        self.id = id; self.name = name; self.deviceType = deviceType
    }
}

enum DesktopSession: String {
    case navigation, video, captions, prompts, teleprompter, asr, recording, lifeLog, assistantAudio, nativeAssistant
    var isAudio: Bool { self == .asr || self == .recording || self == .prompts || self == .assistantAudio }
    var stopPath: String {
        switch self {
        case .navigation, .video, .captions: return "/v1/captions/stop"
        case .prompts: return "/v1/prompts/stop"
        case .teleprompter: return "/v1/teleprompter/stop"
        case .asr, .recording: return "/v1/asr/stop"
        case .lifeLog: return "/v1/lifelog/stop"
        case .assistantAudio: return "/v1/assistant-audio/stop"
        case .nativeAssistant: return "/v1/assistant/native/stop"
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
        case .lifeLog: return "全天智记实验"
        case .assistantAudio: return "AI 实时双麦识别"
        case .nativeAssistant: return "眼镜原生助手"
        }
    }
}

private struct DesktopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DesktopBridge: ObservableObject {
    lazy var homeContent = HomeContentModel(bridge: self)
    lazy var glassesSettings = GlassesSettingsModel(bridge: self)
    lazy var captionSettings = CaptionSettingsModel(bridge: self)
    lazy var schedules = SchedulesModel(bridge: self)
    lazy var calendarSync = CalendarSyncModel(bridge: self)
    lazy var currentLocationWeather = CurrentLocationWeatherModel(bridge: self)
    lazy var nativeRecording = NativeRecordingModel(bridge: self)
    lazy var recordingLibrary = RecordingLibraryModel(bridge: self)
    let voiceLab = LocalVoiceLab()
    let localASR = LocalASRSettings.shared
    lazy var memoryLibrary = MemoryLibraryModel(assistant: assistant)
    lazy var notificationMirror = NotificationMirrorModel(bridge: self)
    lazy var files = FileTransfersModel(bridge: self)
    lazy var dashboardCards = DashboardCardsModel(bridge: self)
    lazy var dashboardLayout = DashboardLayoutModel(bridge: self)
    lazy var mailDashboard = MailDashboardModel(bridge: self)
    lazy var maintenance = MaintenanceModel(bridge: self)
    lazy var feedback = OfficialFeedbackModel(bridge: self)
    lazy var teleprompterLibrary = TeleprompterLibraryModel(bridge: self)
    lazy var ota = OTAUpdateModel(bridge: self)
    lazy var cloudDevices = OfficialCloudDevicesModel(bridge: self)
    let assistant = DesktopAssistant()
    @Published var devices: [PairedGlasses] = []
    @Published var selectedAddress = ""
    @Published private(set) var connected = false
    @Published private(set) var serviceRunning = false
    @Published private(set) var serviceProcessID: Int32?
    @Published private(set) var restartingService = false
    @Published private(set) var refreshingDevices = false
    @Published private(set) var pairingActive = false
    @Published private(set) var officialDeviceOperationActive = false
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
    @Published private(set) var lifeLogSeconds = 0.0
    @Published private(set) var lifeLogChannels = "尚未收到音频"
    @Published private(set) var lifeLogDecodeErrors = 0
    @Published private(set) var lifeLogEnabled: Bool?
    @Published private(set) var virtualAudioDevices: [VirtualAudioDevice] = []
    @Published private(set) var virtualMicrophoneName: String?
    @Published private(set) var microphoneForwarding = false
    @Published private(set) var microphoneRecovering = false
    @Published private(set) var microphoneAudioState = "stopped"
    @Published var microphoneDuration = 3_600
    var builtInMicrophonesReady: Bool {
        VirtualMicrophone.builtInDeviceUIDs.allSatisfy { uid in virtualAudioDevices.contains { $0.id == uid } }
    }
    @Published private(set) var recordingPath: String?
    @Published private(set) var recordingFinalized = false
    @Published private(set) var apiAddress = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var apiVerifiedAt: Date?
    @Published private(set) var nativeWakeID: String?
    @Published private(set) var nativeAssistantActive = false
    @Published private(set) var nativeAssistantAudioPackets = 0
    @Published private(set) var textVideo: TextVideo?
    @Published private(set) var videoImporting = false
    @Published private(set) var videoPlaying = false
    @Published private(set) var videoSeconds = 0.0
    @Published private(set) var videoPreview = ""
    @Published var preserveVideoAspectRatio = false

    var apiReady: Bool { serviceRunning && (connected || localServicesOnly) && apiVerifiedAt != nil }
    @Published private(set) var localServicesOnly = false
    var selectedDevice: PairedGlasses? { devices.first { $0.id == selectedAddress } }

    var apiExample: String {
        "curl '\(apiAddress.isEmpty ? "http://127.0.0.1:8765" : apiAddress)/v1/device' \\\n  -H 'Authorization: Bearer <API_TOKEN>'"
    }

    private var nativeCaptureID: String?
    private var service: Process?
    private var navigationFrameSent = false
    private var lastPromptContent: [String: Any]?
    private var lastVideoURL: URL?
    private var videoImport: Task<Void, Never>?
    private var videoPlayback: Task<Void, Never>?
    private let pairing = BluetoothPairing()
    private var token = ""
    private var stderrPipe: Pipe?
    private var stderrText = ""
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var monitor: Task<Void, Never>?
    private var appForeground = false
    private var visibilityRevision = 0
    private var visibilityTask: Task<Void, Never>?
    private var visibilityTaskID = UUID()
    private var visibilityDisplayedError: String?
    private var lastSynchronizedGeneration: Int?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    init() {
        appForeground = NSApp.isActive
        _ = homeContent
        _ = currentLocationWeather
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appForeground = NSApp.isActive
                    self.scheduleVisibilitySync()
                }
            })
        }
    }

    deinit {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityTask?.cancel()
    }

    private func scheduleVisibilitySync() {
        guard let child = service, child.isRunning, !stopping else { return }
        visibilityRevision += 1
        guard visibilityTask == nil else { return }
        let id = UUID(); visibilityTaskID = id
        visibilityTask = Task { [weak self, weak child] in
            guard let self, let child else { return }
            defer { if self.visibilityTaskID == id { self.visibilityTask = nil } }
            while self.service === child, child.isRunning, !Task.isCancelled {
                let revision = self.visibilityRevision, foreground = self.appForeground
                do {
                    _ = try await self.request("/v1/device/visibility", body: ["isAppForeground": foreground], timeout: 8)
                    guard self.service === child, self.visibilityTaskID == id, !Task.isCancelled else { return }
                    if self.errorMessage == self.visibilityDisplayedError { self.errorMessage = nil }
                    self.visibilityDisplayedError = nil
                } catch {
                    guard self.service === child, self.visibilityTaskID == id, !Task.isCancelled else { return }
                    let message = "前后台状态同步失败：\(error.localizedDescription)"
                    self.visibilityDisplayedError = message; self.errorMessage = message
                }
                guard self.service === child, self.visibilityTaskID == id, !Task.isCancelled else { return }
                if revision == self.visibilityRevision { return }
            }
        }
    }

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
            guard let result = try await self.pairing.pair(progress: { phase, notice in
                self.phase = phase
                self.notice = notice
            }, preflight: { device in
                if OfficialCloudPolicy.enabled { try await self.cloudDevices.preflightPairing(device) }
            }, prepareSystemPairing: { device in
                self.selectedAddress = device.id
                self.setApplicationRegistrationPending(true, address: device.id)
                try await self.startService()
                _ = try await self.request("/v1/device/pairing/prepare", body: [:], timeout: 25)
            }) else {
                self.phase = "配对已取消"
                self.notice = "已取消配对，未启动 API。"
                return
            }
            let device = result.device
            self.devices.removeAll { $0.id == device.id }
            self.devices.append(device)
            self.selectedAddress = device.id
            self.setApplicationRegistrationPending(result.intent == .register, address: device.id)
            self.verifiedPairingAddress = device.id
            if OfficialCloudPolicy.enabled { self.cloudDevices.recordPairedDevice(device) }
            UserDefaults.standard.set(device.id, forKey: "selectedGlasses")
            self.pairingActive = false
            self.notice = "配对完成，正在连接并启用 API…"
            try await self.ensureConnected()
            try await self.restoreDeviceSessionIfNeeded()
            self.notice = "配对、连接已完成，本机 API 已就绪。"
        }
    }

    func cancelPairing() {
        pairing.cancel()
        operation?.cancel()
    }

    func connect() {
        guard !busy, !stopping else { return }
        setApplicationRegistrationPending(false, address: selectedAddress)
        // Stop outside perform: shutdown cancels and awaits the current operation.
        // Calling it from that operation would make the task await itself.
        if serviceRunning && !connected {
            Task {
                guard await shutdown() else { return }
                self.connect()
            }
            return
        }
        perform("正在连接眼镜…") {
            try await self.ensureConnected()
            try await self.restoreDeviceSessionIfNeeded()
        }
    }

    func disconnect() {
        guard !officialDeviceOperationActive else { return }
        Task { if await shutdown() { notice = "已断开，后台服务已停止。" } }
    }

    func beginOfficialDeviceOperation() throws {
        guard !busy, !stopping, !pairingActive, !officialDeviceOperationActive else {
            throw DesktopError(message: "请等待当前连接操作结束后再解绑。")
        }
        officialDeviceOperationActive = true
    }
    func endOfficialDeviceOperation() { officialDeviceOperationActive = false }

    func isConnected(toOfficialMAC mac: String?) -> Bool {
        guard let mac else { return false }
        return connected && OfficialCloudDevicesModel.mac(selectedAddress) == OfficialCloudDevicesModel.mac(mac)
    }

    func eraseForOfficialUnbind(address: String) async throws {
        guard isConnected(toOfficialMAC: address) else { throw DesktopError(message: "目标眼镜未连接。") }
        try await prepareNativeRecording()
        guard isConnected(toOfficialMAC: address) else { throw DesktopError(message: "目标连接已变化，未发送清除。") }
        let response = try await request("/v1/glasses/unbind-reset", body: [:])
        guard response["accepted"] as? Bool == true else { throw DesktopError(message: "眼镜未明确确认解绑清除。") }
    }

    func removeOfficialLocalPairing(address: String) async throws {
        let selected = OfficialCloudDevicesModel.mac(selectedAddress) == OfficialCloudDevicesModel.mac(address)
        if selected, serviceRunning {
            guard await shutdown(sendDeviceCommands: false) else { throw DesktopError(message: "旧连接服务尚未停止，未移除配对。") }
        }
        try await pairing.unpair(address: address)
        devices.removeAll { OfficialCloudDevicesModel.mac($0.id) == OfficialCloudDevicesModel.mac(address) }
        if selected {
            selectedAddress = ""; verifiedPairingAddress = nil
            UserDefaults.standard.removeObject(forKey: "selectedGlasses")
        }
    }

    func restartConnectionService() {
        guard !stopping, !restartingService, !pairingActive, !refreshingDevices, !officialDeviceOperationActive, !selectedAddress.isEmpty else { return }
        restartingService = true
        Task {
            defer { restartingService = false }
            guard await shutdown() else { return }
            perform("正在重新启动连接服务…") {
                try await self.ensureConnected()
                try await self.restoreDeviceSessionIfNeeded()
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
        let keepAspect = preserveVideoAspectRatio
        videoImporting = true
        errorMessage = nil
        notice = "正在解码视频：\(url.lastPathComponent)…"
        videoImport = Task {
            defer { videoImporting = false; videoImport = nil }
            do {
                let video = try await TextVideo.load(url, preserveAspectRatio: keepAspect)
                try Task.checkCancellation()
                lastVideoURL = url
                textVideo = video
                videoSeconds = 0
                videoPreview = video.frames[0].text(style: .fullWidth, inverted: false)
                notice = "视频已就绪，可选择字符模式播放。"
            } catch is CancellationError {
                notice = "已取消视频解码。"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setPreserveVideoAspectRatio(_ enabled: Bool) {
        guard preserveVideoAspectRatio != enabled else { return }
        preserveVideoAspectRatio = enabled
        if let url = lastVideoURL, !videoImporting, !videoPlaying, !busy, !stopping {
            loadVideo(url)
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

    func showText(_ text: String, translation: String, prompt: Bool, reopen: Bool = false, final: Bool = true, clearAfterMilliseconds: Int = 0) {
        perform("正在发送文字…") {
            let mode: DesktopSession = prompt ? .prompts : .captions
            try await self.prepareDisplay(mode, reopen: reopen)
            var body: [String: Any] = ["text": text, "final": final, "clear_after_ms": clearAfterMilliseconds]
            if prompt { body["translation"] = translation }
            _ = try await self.request(prompt ? "/v1/prompts/text" : "/v1/captions/text", body: body)
            if prompt { self.lastPromptContent = body }
            self.notice = "文字已发送。"
        }
    }

    func clearDisplay(prompt: Bool) {
        perform("正在清空眼镜画面…") {
            _ = try await self.request(prompt ? "/v1/prompts/clear" : "/v1/captions/clear", body: [:])
            self.lastPromptContent = nil
            self.notice = "已发送清屏，显示会话保持打开。"
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
            if let state = try? await self.request("/v1/teleprompter", method: "GET", timeout: 2) {
                self.teleprompterLibrary.ingestPlayback(state)
            }
            if action == "stop" { self.activeSession = nil }
            self.notice = action == "pause" ? "暂停指令已发送。" : action == "stop" ? "停止指令已发送。" : "继续指令已发送。"
        }
    }

    func synchronizeTeleprompterState() {
        perform("正在核对眼镜提词状态…") {
            let state = try await self.request("/v1/teleprompter/check-state", body: [:])
            self.teleprompterLibrary.ingestPlayback(state)
            if state["running"] as? Bool == true { self.activeSession = .teleprompter }
            else if self.activeSession == .teleprompter { self.activeSession = nil }
            self.notice = "眼镜提词状态已读回。"
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

    func startLifeLog(duration: Int, record: Bool) {
        perform("正在开启全天智记实验…") {
            try await self.ensureConnected()
            try await self.stopCurrent()
            let result = try await self.request("/v1/lifelog/observe", body: ["duration": duration, "inspect_audio": true, "record": record])
            self.activeSession = .lifeLog
            self.updateLifeLog(result)
            do {
                let reply = try await self.request("/v1/lifelog/switch", body: ["enabled": true])
                guard reply["accepted"] as? Bool == true else {
                    throw DesktopError(message: reply["error"] as? String ?? "全天智记开关尚未确认成功。")
                }
            } catch {
                try? await self.stopCurrent()
                throw error
            }
            self.notice = "全天智记观察已开始，可以自然说话或点击“触发一轮音频”。"
        }
    }

    func startAssistantLifeLog(duration: Int, preserveAudio: Bool = false, vadDelay: Int = 2) async throws {
        try await ensureConnected()
        try await stopCurrent()
        _ = try await request("/v1/lifelog/observe", body: ["duration": duration, "assistant_capture": true,
            "preserve_audio": preserveAudio, "vad_start_delay_sec": vadDelay])
        activeSession = .lifeLog
        do {
            let reply = try await request("/v1/lifelog/switch", body: ["enabled": true])
            guard reply["accepted"] as? Bool == true else {
                throw DesktopError(message: reply["error"] as? String ?? "全天智记开关尚未确认成功。")
            }
        } catch { try? await stopCurrent(); throw error }
    }

    func startAssistantRealtime(duration: Int, channel: Int, sampleRate: Int = 16000, stereo: Bool = false) async throws -> String {
        try await ensureConnected()
        try await stopCurrent()
        let response = try await request("/v1/assistant-audio/start", body: ["duration": duration, "channel": channel, "sample_rate": sampleRate, "pcm_layout": stereo ? "stereo" : "mono",
            "save_latest": UserDefaults.standard.bool(forKey: RealtimeRecentRecordingSettings.key)])
        activeSession = .assistantAudio
        guard let sid = response["sid"] as? String else { throw DesktopError(message: "实时收音未返回会话标识") }
        return sid
    }

    func startAssistantNative(duration: Int) async throws -> String {
        try await ensureConnected()
        guard let id = nativeWakeID, nativeAssistantActive else {
            throw DesktopError(message: L("请先说“小雷小雷”唤醒眼镜。", "Say \"Hey RayNeo\" to wake the glasses first."))
        }
        try await stopCurrent()
        _ = try await request("/v1/assistant/native/start", body: ["wakeID": id, "duration": duration])
        activeSession = .nativeAssistant; nativeCaptureID = id
        return id
    }

    func assistantAudioEvents(after: Int, source: AssistantCaptureSource) async throws -> [String: Any] {
        let path = source == .native ? "/v1/assistant/native/audio" : source == .realtime ? "/v1/assistant-audio/events" : "/v1/lifelog/assistant-audio"
        var body: [String: Any] = ["after": after]
        if source == .native { body["wakeID"] = nativeCaptureID }
        return try await request(path, body: body, timeout: 3)
    }

    func stopAssistantCapture(source: AssistantCaptureSource, expectedSID: String? = nil) async throws {
        if source == .realtime, let expectedSID {
            _ = try await request("/v1/assistant-audio/stop", body: ["sid": expectedSID])
            if activeSession == .assistantAudio { activeSession = nil }
            return
        }
        if activeSession == (source == .native ? .nativeAssistant : source == .realtime ? .assistantAudio : .lifeLog) { try await stopCurrent() }
    }

    func displayAssistantReply(_ text: String, source: AssistantCaptureSource, sid: String?, clearAfterMilliseconds: Int = 0, query: String = "") async throws -> String {
        guard connected else { throw DesktopError(message: "眼镜未连接，结果已保留在 Mac") }
        if source == .native {
            guard nativeAssistantActive, let sid, sid == nativeWakeID else { throw DesktopError(message: "原生助手已退出，回复保留在 Mac。") }
            _ = try await request("/v1/assistant/native/reply", body: ["wakeID": sid, "text": text, "query": query], timeout: 5)
            return "native_assistant"
        }
        if source == .realtime {
            guard activeSession == .assistantAudio, let sid else {
                throw DesktopError(message: "实时提示收音会话已结束，回复保留在 Mac")
            }
            _ = try await request("/v1/prompts/text", body: ["sid": sid, "text": "AI 回复", "translation": text, "final": true, "clear_after_ms": clearAfterMilliseconds], timeout: 5)
            return "realtime_prompt"
        }
        guard activeSession == .lifeLog else { throw DesktopError(message: "AlwaysOn 会话已结束，回复保留在 Mac") }
        _ = try await request("/v1/notifications", body: ["title": "AI 回复", "body": text], timeout: 5)
        return "notification"
    }

    func triggerLifeLogAudio() {
        perform("正在请求一轮全天智记音频…") {
            let result = try await self.request("/v1/lifelog/record", body: [:])
            self.updateLifeLog(result)
            self.notice = "已请求一轮全天智记音频。"
        }
    }

    private func updateLifeLog(_ data: [String: Any]) {
        if let enabled = data["observedEnabled"] as? Bool { lifeLogEnabled = enabled }
        let inspection = data["audioInspection"] as? [String: Any] ?? [:]
        lifeLogSeconds = inspection["decodedSeconds"] as? Double ?? 0
        lifeLogDecodeErrors = inspection["decodeErrors"] as? Int ?? 0
        let recording = inspection["recording"] as? [String: Any]
        recordingPath = recording?["path"] as? String
        recordingFinalized = recording?["finalized"] as? Bool == true
        if let error = inspection["recordingError"] as? String { errorMessage = error }
        let channels = inspection["encodedChannelCounts"] as? [String: Int] ?? [:]
        lifeLogChannels = channels.isEmpty ? "尚未收到音频" : channels.keys.sorted().map {
            "\($0) 声道：\(channels[$0]!) 帧"
        }.joined(separator: "；")
        if let error = data["error"] as? String { errorMessage = error }
        if let error = inspection["captureError"] as? String { errorMessage = error }
    }

    func enterMicrophoneMode() {
        perform("正在进入麦克风模式…") {
            self.refreshVirtualAudioDevices()
            guard self.builtInMicrophonesReady else {
                throw DesktopError(message: "请先在“设备连接”安装内置驱动并刷新设备，再进入麦克风模式。")
            }
            try await self.prepareDisplay(.prompts, reopen: true, microphone: true)
            if let content = self.lastPromptContent {
                _ = try await self.request("/v1/prompts/text", body: content)
            }
            self.notice = "已进入麦克风模式；声音设备切换期间会保留眼镜页面。"
        }
    }

    func recoverMicrophoneOutput() {
        perform("正在恢复音频输出…") {
            let result = try await self.request("/v1/virtual-mic/recover", body: [:])
            self.updateAudio(result)
            self.notice = "已重新检查两路音频输出，眼镜页面保持开启。"
        }
    }

    func refreshVirtualAudioDevices() {
        do {
            virtualAudioDevices = try VirtualMicrophone.availableDevices()
        } catch { errorMessage = error.localizedDescription }
    }

    func openVirtualMicrophoneInstaller() {
        guard let installer = Bundle.main.url(forResource: "OpenRayneoAudio", withExtension: "pkg") else {
            errorMessage = "未找到内置驱动安装包，请使用 scripts/build-app.sh 重新构建应用。"
            return
        }
        if NSWorkspace.shared.open(installer) {
            notice = "请在系统安装器中完成内置驱动安装；安装完成后会自动重载音频服务，返回点击“刷新设备”即可。"
        } else { errorMessage = "无法打开内置驱动安装包。" }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func stopSession() {
        perform("正在结束当前功能…") {
            try await self.stopCurrent()
            self.notice = "结束指令已发送。"
        }
    }

    func prepareNativeRecording() async throws {
        if assistant.active || assistant.starting || assistant.startingAudio {
            await assistant.stop(bridge: self)
        }
        try await stopCurrent()
    }

    func playTeleprompterDocument(id: String, title: String, text: String, settings: [String: Any]) async throws {
        try await prepareNativeRecording()
        _ = try await request("/v1/teleprompter", body: ["did": id, "title": title, "text": text, "settings": settings])
        activeSession = .teleprompter
        notice = "稿件已发送到眼镜。"
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

    func copyAgentConfiguration() {
        guard serviceRunning else { return }
        let skill = Bundle.main.resourceURL?.appendingPathComponent("AgentSkill/openrayneo-api").path ?? ""
        let payload: [String: String] = ["OPENRAYNEO_API_URL": apiAddress, "OPENRAYNEO_API_TOKEN": token,
            "skill_path": skill, "session_rule": "Check device, retain SID/wakeID; use /clear or clear_after_ms to clear without stopping.",
            "voice_input": "GET /v1/agent/events?after=CURSOR; native wake/exit: GET /v1/assistant/native; PCM: POST /v1/assistant/native/audio with wakeID/after",
            "voice_result": "Use replyTarget from ASR events: native POST /v1/assistant/native/reply {wakeID,text}; realtime POST /v1/prompts/text {sid,text,translation,final:true}",
            "records": "POST /v1/records/query {from,to,recordId,text}; POST /v1/records/derived {recordId,sourceRevision,kind,text,tags}; PATCH /v1/records/sync {peerURL,token,enabled:true}"]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            notice = "Agent 接入配置已复制，包含本机 API 令牌。"
        } catch { errorMessage = error.localizedDescription }
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
            self.notice = self.localServicesOnly ? "本机记录 API 健康检查与鉴权正常。" : "API 健康检查、鉴权和眼镜连接均正常。"
        }
    }

    private func verifyAPI() async throws {
        apiVerifiedAt = nil
        let health = try await request("/health", method: "GET", timeout: 5)
        let device = try await request("/v1/device", method: "GET", timeout: 5)
        guard health["ok"] as? Bool == true else { throw DesktopError(message: "本机 API 健康检查未通过。") }
        if localServicesOnly { apiVerifiedAt = Date(); return }
        let ble = device["ble"] as? [String: Any] ?? [:]
        connected = device["rfcommConnected"] as? Bool == true && ble["ready"] as? Bool == true
        guard connected else { throw DesktopError(message: "API 可以访问，但眼镜未连接。请重新连接眼镜。") }
        apiVerifiedAt = Date()
    }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !stopping, !officialDeviceOperationActive else { return }
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
                    notice = "当前操作已取消。"
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
        setApplicationRegistrationPending(false, address: selectedAddress)
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

    private func prepareDisplay(_ mode: DesktopSession, reopen: Bool, microphone: Bool = false) async throws {
        try await ensureConnected()
        if activeSession == mode, !reopen { return }
        try await stopCurrent()
        let prefix = mode == .prompts ? "/v1/prompts" : "/v1/captions"
        let font = mode == .video ? 1 : 2
        let lines = mode == .video ? 7 : 5
        var body: [String: Any] = ["font_size": font, "content_width": 100, "max_lines": lines]
        if mode == .prompts {
            refreshVirtualAudioDevices()
            body["microphone_enabled"] = microphone && builtInMicrophonesReady
            body["duration"] = microphoneDuration
        }
        let response = try await request(prefix + "/start", body: body)
        guard response["accepted"] as? Bool == true else {
            _ = try? await request(prefix + "/stop", body: [:], timeout: 5)
            if response["acknowledged"] as? Bool == true {
                let reply = response["reply"] as? [String: Any]
                let code = (reply?["code"] as? NSNumber)?.intValue
                let detail = code.map { L("（错误码 \($0)）", " (code \($0))") } ?? ""
                throw DesktopError(message: L(
                    "眼镜拒绝了显示启动请求\(detail)，请确认眼镜已展开且未被其他模式占用后重试。",
                    "Glasses rejected the display start request\(detail). Ensure the glasses are unfolded and idle, then retry."
                ))
            }
            throw DesktopError(message: L(
                "未收到眼镜的显示启动确认（等待超时），请确认眼镜蓝牙连接正常并重试。",
                "Timed out waiting for display start confirmation from the glasses. Check Bluetooth and retry."
            ))
        }
        activeSession = mode
        if mode == .prompts { updateAudio(response) }
        if mode == .navigation || mode == .video {
            let config = (response["reply"] as? [String: Any])?["effective_config"] as? [String: Any]
            guard config?["font_size"] as? Int == font, config?["max_lines"] as? Int == lines, config?["content_width"] as? Int == 100 else {
                try await stopCurrent()
                throw DesktopError(message: "眼镜返回了不同的布局配置，暂不发送字符网格。")
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func restoreDeviceSessionIfNeeded() async throws {
        guard activeSession == nil else { return }
        await nativeRecording.refresh()
        if nativeRecording.active {
            notice = "眼镜正在原生录音，已恢复录音状态。"
            return
        }
        let restored = try await request("/v1/teleprompter/check-state", body: [:], timeout: 12)
        teleprompterLibrary.ingestPlayback(restored)
        if restored["running"] as? Bool == true {
            activeSession = .teleprompter
            notice = "已恢复眼镜上的提词会话与阅读位置。"
            return
        }
        if restored["previewing"] as? Bool == true {
            notice = "眼镜正在预览稿件，已恢复稿件状态。"
            return
        }
        notice = "眼镜已连接，Agent API 已就绪。收音与显示按需开启。"
    }

    private func stopCurrent() async throws {
        await cancelVideoPlayback()
        guard let current = activeSession else { return }
        let result = try await request(current.stopPath, body: current == .nativeAssistant ? ["wakeID": nativeCaptureID as Any? ?? NSNull()] : [:])
        if current == .lifeLog { updateLifeLog(result) }
        else if current.isAudio { updateAudio(result) }
        else if current == .teleprompter, let state = try? await request("/v1/teleprompter", method: "GET", timeout: 2) {
            teleprompterLibrary.ingestPlayback(state)
        }
        activeSession = nil
    }

    func request(_ path: String, method: String = "POST", body: [String: Any]? = nil, timeout: TimeInterval = 75) async throws -> [String: Any] {
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

    private func setApplicationRegistrationPending(_ pending: Bool, address: String) {
        var addresses = Set(UserDefaults.standard.stringArray(forKey: "pendingApplicationRegistrations") ?? [])
        if pending { addresses.insert(address) } else { addresses.remove(address) }
        UserDefaults.standard.set(Array(addresses), forKey: "pendingApplicationRegistrations")
    }

    func startLocalServices() {
        perform("正在启动本机记录与 Agent 服务…") {
            try await self.startService(localOnly: true)
            try await self.verifyAPI()
            self.phase = "本机记录服务运行中"
            self.notice = "已启动本机 API，可同步和查询手机记录。连接眼镜时会切换到设备服务。"
        }
    }

    private func startService(localOnly: Bool = false) async throws {
        guard service?.isRunning != true else { throw DesktopError(message: "旧连接服务尚未退出，未启动新进程。") }
        guard localOnly || !selectedAddress.isEmpty else { throw DesktopError(message: "请先点击“添加并配对眼镜”，或刷新已配对设备列表。") }
        activeSession = nil
        microphoneForwarding = false
        apiVerifiedAt = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        monitor?.cancel()
        visibilityTask?.cancel(); visibilityTask = nil; visibilityTaskID = UUID()
        lastSynchronizedGeneration = nil
        appForeground = NSApp.isActive
        let port = try Self.availablePort()
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = localOnly ? ["--headless", "--local-services-only"] : ["--headless"]
        localServicesOnly = localOnly
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var environment = ProcessInfo.processInfo.environment
        environment["OPENRAYNEO_API_TOKEN"] = token
        environment["OPENRAYNEO_PORT"] = String(port)
        environment["RAYNEO_ADDRESS"] = selectedAddress
        let registrationPending = UserDefaults.standard.stringArray(forKey: "pendingApplicationRegistrations")?.contains(selectedAddress) == true
        environment["OPENRAYNEO_CONNECTION_INTENT"] = (registrationPending ? ConnectionIntent.register : .reconnect).rawValue
        environment["OPENRAYNEO_APP_FOREGROUND"] = appForeground ? "1" : "0"
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
                self.microphoneForwarding = false
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
            if !localOnly {
                scheduleVisibilitySync()
                await visibilityTask?.value
            }
            guard service === child else { return }
            guard child.isRunning else { throw DesktopError(message: "连接服务已退出，请重新连接。") }
            if !localOnly { startMonitoring() }
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
                    let deviceConnected = data["rfcommConnected"] as? Bool == true && (data["ble"] as? [String: Any])?["ready"] as? Bool == true
                    if connected != deviceConnected {
                        connected = deviceConnected
                        if deviceConnected { scheduleVisibilitySync() }
                    }
                    if !connected { apiVerifiedAt = nil }
                    if let native = data["nativeAssistant"] as? [String: Any] {
                        let wakeCode = (native["wake"] as? [String: Any])?["rc"] as? Int ?? 0
                        nativeAssistantActive = native["active"] as? Bool == true && (1...6).contains(wakeCode)
                        nativeAssistantAudioPackets = native["audioPackets"] as? Int ?? 0
                        if activeSession == .nativeAssistant, native["capturing"] as? Bool != true { activeSession = nil }
                        if let id = native["wakeID"] as? String, id != nativeWakeID {
                            nativeWakeID = id
                            notice = "眼镜助手已唤醒。可在 Mac 继续交互，或由本机 Agent 接管。"
                        }
                    }
                    let ble = data["ble"] as? [String: Any] ?? [:]
                    let rawPhase = ble["phase"] as? String ?? "idle"
                    let names = ["idle": "等待连接", "waitingForBluetooth": "等待系统蓝牙", "scanning": "正在寻找眼镜", "connecting": "正在连接眼镜", "discoveringServices": "正在发现蓝牙服务", "discoveringCharacteristics": "正在准备蓝牙通道", "readingIdentity": "正在核对眼镜身份", "subscribing": "正在准备通知通道", "exchangingDeviceInfo": "正在交换设备信息", "authenticating": "正在认证眼镜", "authenticated": "正在打开数据通道", "failed": "连接失败"]
                    let link = data["dataLink"] as? [String: Any] ?? [:]
                    let synchronization = data["synchronization"] as? [String: Any] ?? [:]
                    let syncPhase = synchronization["phase"] as? String ?? "idle"
                    if connected {
                        phase = ["queued", "syncing"].contains(syncPhase) ? "已连接，正在恢复状态" : "已连接"
                    } else {
                        let phases = ["recovering": "正在恢复连接", "waitingForBLE": "正在恢复 BLE 认证",
                            "queryingSDP": "正在查询数据通道", "openingSPP": "正在恢复数据通道",
                            "backoff": "等待重试连接", "waitingToRetry": "眼镜暂不可用，将自动重试",
                            "suspended": "连接恢复已暂停"]
                        phase = phases[link["phase"] as? String ?? ""]
                            ?? (ble["bluetoothState"] as? Int == 0 ? "等待系统蓝牙就绪" : names[rawPhase] ?? "连接阶段：\(rawPhase)")
                    }
                    if connected, ["ready", "partial"].contains(syncPhase),
                       let generation = synchronization["generation"] as? Int, generation != lastSynchronizedGeneration {
                        lastSynchronizedGeneration = generation
                        await nativeRecording.refresh()
                    }
                    if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { diagnostics = String(decoding: bytes, as: UTF8.self) }
                } else if !Task.isCancelled {
                    if connected { connected = false }
                    apiVerifiedAt = nil; phase = "后台服务暂时无响应"
                }
                await ota.refresh()
                if connected,
                   let state = try? await request("/v1/lifelog", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    updateLifeLog(state)
                    if state["observing"] as? Bool == true || state["finalizing"] as? Bool == true {
                        if activeSession != .lifeLog {
                            activeSession = .lifeLog
                            notice = "AlwaysOn 正在采集，可在当前窗口停止。"
                        }
                    } else if activeSession == .lifeLog {
                        activeSession = nil
                        notice = "全天智记观察已结束。"
                        recordingLibrary.refresh()
                    }
                }
                if connected,
                   let display = try? await request("/v1/caption-settings", method: "GET", timeout: 2),
                   let session = display["session"] as? [String: Any] {
                    if session["active"] as? Bool == true, session["phase"] as? String == "active" {
                        if session["business"] as? Int == 0x17, activeSession != .assistantAudio { activeSession = .prompts }
                        if session["business"] as? Int == 0x13, ![.navigation, .video].contains(activeSession) { activeSession = .captions }
                    } else if activeSession == .prompts || activeSession == .captions {
                        activeSession = nil; microphoneForwarding = false
                    }
                }
                if activeSession == .asr || activeSession == .recording || activeSession == .assistantAudio || (activeSession == .prompts && microphoneForwarding),
                   let audio = try? await request("/v1/asr", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    updateAudio(audio)
                    if audio["running"] as? Bool == false, audio["stopping"] as? Bool != true {
                        activeSession = nil
                        notice = "音频会话已结束。"
                    }
                }
                if connected,
                   let state = try? await request("/v1/teleprompter", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    teleprompterLibrary.ingestPlayback(state)
                    if state["running"] as? Bool == true {
                        if activeSession != .teleprompter {
                            activeSession = .teleprompter
                            notice = "眼镜已开始提词播放。"
                        }
                    } else if activeSession == .teleprompter {
                        activeSession = nil
                        notice = "提词播放已结束，阅读位置已保存在本机。"
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateAudio(_ data: [String: Any]) {
        transcript = data["transcript"] as? String ?? ""
        audioSeconds = data["decodedSeconds"] as? Double ?? 0
        let microphones = data["virtualMicrophones"] as? [[String: Any]] ?? []
        microphoneAudioState = data["audioState"] as? String ?? "stopped"
        microphoneForwarding = data["running"] as? Bool == true && data["engine"] as? String == "virtual-microphone"
        microphoneRecovering = microphoneForwarding && microphones.contains { $0["recovering"] as? Bool == true }
        virtualMicrophoneName = microphones.compactMap { $0["deviceName"] as? String }.joined(separator: "、")
        if let recording = data["recording"] as? [String: Any] {
            recordingPath = recording["path"] as? String
            recordingFinalized = recording["finalized"] as? Bool == true
        } else {
            recordingPath = nil
            recordingFinalized = false
        }
        if let error = data["error"] as? String { errorMessage = error }
    }

    @discardableResult
    func shutdown(sendDeviceCommands: Bool = true) async -> Bool {
        await voiceLab.suspend()
        assistant.cancelPromptTrial()
        recordingLibrary.cancel()
        recordingLibrary.stopPlayback()
        memoryLibrary.cancelSummary()
        currentLocationWeather.cancel()
        if assistant.active || assistant.starting || assistant.startingAudio || assistant.stopping {
            await assistant.stop(bridge: self)
        }
        guard !stopping else { return false }
        stopping = true
        defer { stopping = false }
        // Finish the prior lifecycle send before the final background update.
        await visibilityTask?.value
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
            if sendDeviceCommands {
                await nativeRecording.refresh()
                if nativeRecording.active { await nativeRecording.command("stop") }
                if let current = activeSession {
                    if let result = try? await request(current.stopPath, body: [:], timeout: 5) {
                        if current == .lifeLog { updateLifeLog(result) }
                        else if current.isAudio { updateAudio(result) }
                        else if current == .teleprompter,
                                let state = try? await request("/v1/teleprompter", method: "GET", timeout: 2) {
                            teleprompterLibrary.ingestPlayback(state)
                        }
                    }
                }
                // Also catches a start request completed by the server after client cancellation.
                if let result = try? await request("/v1/asr/stop", body: [:], timeout: 3) { updateAudio(result) }
                _ = try? await request("/v1/device/visibility", body: ["isAppForeground": false], timeout: 3)
                _ = try? await request("/v1/device/recovery/suspend", body: [:], timeout: 3)
            }
            guard await BridgeProcessLifecycle.stop(child) else {
                connected = false
                apiVerifiedAt = nil
                busy = false
                phase = "连接服务未能退出"
                errorMessage = "旧连接进程尚未退出，已停止重启流程。请保留诊断后重试。"
                return false
            }
        }
        teleprompterLibrary.ingestPlayback([:])
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        service = nil
        serviceProcessID = nil
        connected = false
        apiVerifiedAt = nil
        serviceRunning = false
        activeSession = nil
        microphoneForwarding = false
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
