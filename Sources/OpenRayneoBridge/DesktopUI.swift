// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

private enum ControlPage: String, CaseIterable, Identifiable {
    case workspace = "Agent 工作台", setup = "设备连接", officialAccount = "官方账号", settings = "眼镜设置", homeContent = "首页内容", dashboardCards = "首页预览与布局", nativeRecording = "原生录音", recordingLibrary = "录音资料库", memory = "回忆与项目", files = "文件传输", maintenance = "固件与日志", feedback = "问题反馈", navigation = "导航演示", video = "字符视频", text = "文字显示", notification = "通知", teleprompter = "提词器", audio = "语音与录音", assistant = "AI 助手"
    case voice = "声音与说话人"
    case recordingDeveloper = "录音开发者工具"
    case ota = "固件升级"
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .workspace: return L("Agent 工作台", "Agent Workspace")
        case .setup: return L("设备连接", "Device Setup")
        case .officialAccount: return L("官方账号", "Official Account")
        case .settings: return L("眼镜设置", "Glasses Settings")
        case .homeContent: return L("首页内容", "Home Content")
        case .dashboardCards: return L("首页预览与布局", "Dashboard Layout")
        case .nativeRecording: return L("原生录音", "Native Recording")
        case .recordingLibrary: return L("录音资料库", "Recording Library")
        case .recordingDeveloper: return L("录音开发者工具", "Recording Dev Tools")
        case .memory: return L("回忆与项目", "Memories & Projects")
        case .files: return L("文件传输", "File Transfers")
        case .maintenance: return L("固件与日志", "Maintenance & Logs")
        case .feedback: return L("问题反馈", "Feedback")
        case .navigation: return L("导航演示", "Navigation Demo")
        case .video: return L("字符视频", "Character Video")
        case .text: return L("文字显示", "Text Display")
        case .notification: return L("通知", "Notifications")
        case .teleprompter: return L("提词器", "Teleprompter")
        case .audio: return L("语音与录音", "Voice & Audio")
        case .assistant: return L("AI 助手", "AI Assistant")
        case .voice: return L("声音与说话人", "Voice & Speakers")
        case .ota: return L("固件升级", "Firmware OTA")
        }
    }
    var icon: String {
        switch self {
        case .voice: return "person.wave.2"
        case .ota: return "arrow.down.doc"
        case .workspace: return "terminal"
        case .setup: return "link"
        case .officialAccount: return "person.crop.circle"
        case .settings: return "gearshape"
        case .nativeRecording: return "record.circle"
        case .recordingLibrary: return "waveform.and.magnifyingglass"
        case .recordingDeveloper: return "hammer"
        case .memory: return "books.vertical"
        case .files: return "arrow.up.arrow.down"
        case .dashboardCards: return "rectangle.grid.1x2"
        case .maintenance: return "wrench.and.screwdriver"
        case .feedback: return "bubble.left.and.exclamationmark.bubble.right"
        case .homeContent: return "square.grid.2x2"
        case .navigation: return "arrow.turn.up.right"
        case .video: return "film"
        case .text: return "text.bubble"
        case .notification: return "bell"
        case .teleprompter: return "doc.text"
        case .audio: return "waveform"
        case .assistant: return "sparkles"
        }
    }
}

@MainActor
private struct DesktopControlView: View {
    @ObservedObject var bridge: DesktopBridge
    @ObservedObject private var language = AppLanguageStore.shared
    @State private var page: ControlPage = .workspace
    @State private var direction: NavigationDirection = .uturn
    @State private var meters = 100
    @State private var videoStyle: TextVideoStyle = .fullWidth
    @State private var videoFPS = 10
    @State private var invertVideo = false
    @State private var enhanceVideoContrast = false
    @State private var alignVideoUpdates = true
    @State private var caption = "你好，OpenRayneo。\n这段文字来自 Mac 控制面板。"
    @State private var answer = ""
    @State private var usePrompt = true
    @State private var finalText = true
    @State private var clearAfterSending = false
    @State private var clearAfterSeconds = 10
    @State private var notificationTitle = "OpenRayneo"
    @State private var notificationBody = "来自 Mac 的通知"
    @State private var locale = "zh-CN"
    @State private var audioDuration = 60
    @State private var saveAudio = false
    @State private var saveLifeLogAudio = true

    private var unavailable: Bool { bridge.busy || bridge.stopping || bridge.officialDeviceOperationActive }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Token.sideBarBorder).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 18)
                if let error = bridge.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Token.bannerWarningForeground)
                        Text(error).textSelection(.enabled).font(.callout)
                    }.padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Token.bannerWarningBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 36).padding(.bottom, 14)
                }
                if page == .recordingLibrary {
                    RecordingReviewPanel(library: bridge.recordingLibrary, bridge: bridge, serviceRunning: bridge.serviceRunning)
                        .padding(.horizontal, 36).padding(.bottom, 20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch page {
                            case .workspace: AgentWorkspacePanel(bridge: bridge)
                            case .setup: setupPanel
                            case .officialAccount:
                                OfficialAccountPanel()
                                OfficialCloudDevicesPanel(model: bridge.cloudDevices)
                            case .settings: GlassesSettingsPanel(model: bridge.glassesSettings, openDashboard: { page = .dashboardCards })
                            case .nativeRecording: NativeRecordingPanel(model: bridge.nativeRecording)
                            case .recordingLibrary: EmptyView() // Rendered full-height above, outside this ScrollView, so its two columns scroll independently.
                            case .recordingDeveloper: RecordingDeveloperPanel(model: bridge.recordingLibrary)
                            case .voice: LocalVoicePanel(bridge: bridge, model: bridge.voiceLab, asr: bridge.localASR)
                            case .memory:
                                MemoryLibraryPanel(model: bridge.memoryLibrary, openRecording: { id in
                                    bridge.recordingLibrary.selectedID = id
                                    bridge.recordingLibrary.reviewRequestID = id
                                    page = .recordingLibrary
                                })
                            case .files: FileTransfersPanel(model: bridge.files)
                            case .dashboardCards:
                                DashboardHomePanel(bridge: bridge)
                            case .maintenance:
                                MaintenancePanel(model: bridge.maintenance)
                            case .ota: OTAUpdatePanel(model: bridge.ota)
                            case .feedback: OfficialFeedbackPanel(model: bridge.feedback)
                            case .homeContent:
                                CurrentLocationWeatherPanel(model: bridge.currentLocationWeather)
                                HomeContentPanel(model: bridge.homeContent, schedules: bridge.schedules, calendarSync: bridge.calendarSync)
                            case .navigation: navigationPanel
                            case .video: videoPanel
                            case .text: textPanel
                            case .notification:
                                notificationPanel
                                NotificationMirrorPanel(model: bridge.notificationMirror)
                            case .teleprompter: TeleprompterLibraryPanel(model: bridge.teleprompterLibrary)
                            case .audio:
                                audioPanel
                                CaptionSettingsPanel(model: bridge.captionSettings)
                            case .assistant: AssistantPanel(model: bridge.assistant, bridge: bridge)
                            }
                            if page == .setup { connectionHelp }
                        }.frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 36).padding(.bottom, 32)
                    }
                }
                HStack(spacing: 8) {
                    if bridge.busy || bridge.stopping { ProgressView().controlSize(.small) }
                    Text(bridge.notice).font(.system(size: 12)).foregroundStyle(Token.statusBarForeground).lineLimit(2).help(bridge.notice).textSelection(.enabled)
                    Spacer()
                }.padding(.horizontal, 36).padding(.vertical, 8).frame(minHeight: 34)
                    .background(Token.statusBarBackground)
                    .overlay(alignment: .top) { Rectangle().fill(Token.statusBarBorder).frame(height: 1) }
            }.background(Token.pageBackground)
        }.frame(minWidth: 960, minHeight: 640)
        .groupBoxStyle(PanelGroupBoxStyle())
        .tint(Token.buttonBackground)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: bridge.nativeWakeID) { id in
            guard id != nil, bridge.nativeAssistantActive else { return }
            page = .assistant
            if UserDefaults.standard.bool(forKey: "nativeWakeAutoCapture") { bridge.assistant.answerNativeWake(bridge: bridge) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "OpenRayneo" })?.makeKeyAndOrderFront(nil)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.localizedTitle).font(.system(size: 26, weight: .semibold)).tracking(-0.3)
                Text(
                    page == .officialAccount ? L("管理雷鸟官方会话和云端设备", "Manage official RayNeo sessions and cloud devices")
                    : page == .feedback ? L("向官方反馈问题，管理本地草稿与附件", "Send feedback and manage local drafts & attachments")
                    : page == .workspace ? L("本机服务 · 按需收音 · Agent 控制", "Local service · On-demand audio · Agent control")
                    : page == .recordingLibrary ? L("按天回看手机与 Mac 的录音、摘要和对话", "Review daily recordings, summaries, and conversations")
                    : page == .recordingDeveloper ? L("剪辑、标记、重新转写和恢复本机录音，用于测试与排错", "Trim, mark, re-transcribe, and recover local recordings")
                    : bridge.activeSession.map { L("当前功能：\($0.title)", "Active: \($0.title)") } ?? L("准备好后发送到眼镜", "Ready to send to glasses")
                )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if let session = bridge.activeSession {
                StatusChip(text: session.title)
                Button(L("结束当前功能", "Stop Active Session"), systemImage: "stop.fill") { bridge.stopSession() }.disabled(unavailable)
            }
        }
    }

    private func groupLabel(_ group: String) -> String {
        switch group {
        case "工作台": return L("工作台", "Workspace")
        case "眼镜": return L("眼镜", "Glasses")
        case "内容": return L("内容", "Content")
        default: return L("进阶工具", "Tools")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("OpenRayneo").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("BETA").font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3).overlay(Capsule().strokeBorder(Token.widgetBorder))
            }.padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 16)
            deviceCard.padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(["工作台", "眼镜", "内容", "进阶工具"], id: \.self) { group in
                        Text(groupLabel(group)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Token.sideBarSectionHeaderForeground)
                            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                        ForEach(pages(in: group)) { navItem($0) }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Token.sideBarSectionHeaderForeground)
                    Picker("", selection: $language.mode) {
                        ForEach(AppLanguageMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                    Spacer()
                }
                Text(L("手机占用连接时，请先关闭手机蓝牙。", "Turn off phone Bluetooth if your phone holds the glasses link."))
                    .font(.system(size: 11)).foregroundStyle(Token.sideBarSectionHeaderForeground).fixedSize(horizontal: false, vertical: true)
            }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Token.sideBarBorder).frame(height: 1) }
        }.frame(width: 256).frame(maxHeight: .infinity).background(Token.sideBarBackground)
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassesModelView(pose: bridge.connected ? .connected : bridge.serviceRunning && !bridge.localServicesOnly ? .connecting : .resting)
                .frame(height: 104).padding(.horizontal, -12).padding(.top, -6)
            HStack(spacing: 8) {
                SignalDot(active: bridge.connected)
                Text(bridge.phase).font(.system(size: 12.5, weight: .medium)).lineLimit(2).help(bridge.phase)
                Spacer(minLength: 4)
                Menu {
                    Button(L("刷新已配对设备", "Refresh Paired Devices"), systemImage: "arrow.clockwise") { bridge.refreshDevices() }
                        .disabled(bridge.serviceRunning || bridge.refreshingDevices || unavailable)
                    Button(L("添加并配对眼镜", "Pair New Glasses"), systemImage: "plus") { page = .setup; bridge.pairAndConnect() }
                        .disabled(unavailable || bridge.refreshingDevices)
                    Divider()
                    Button(L("打开蓝牙设置", "Open Bluetooth Settings")) { bridge.openBluetoothSettings() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                    .help(L("更多操作", "More Actions")).accessibilityLabel(L("更多操作", "More Actions"))
            }
            Picker(L("眼镜", "Glasses"), selection: $bridge.selectedAddress) {
                if bridge.devices.isEmpty { Text(bridge.refreshingDevices ? L("正在读取已配对设备…", "Loading paired devices…") : L("尚未找到眼镜", "No glasses found")).tag("") }
                ForEach(bridge.devices) { Text("\($0.name) · \($0.id.suffix(5))").tag($0.id) }
            }.labelsHidden().disabled(bridge.serviceRunning || unavailable)
            if bridge.serviceRunning {
                if !bridge.connected {
                    Button { bridge.connect() } label: {
                        Label { Text(L("重新连接", "Reconnect")) } icon: { Image(systemName: "arrow.triangle.2.circlepath").fontWeight(.medium) }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(unavailable)
                }
                Button { bridge.disconnect() } label: {
                    Text(bridge.stopping ? L("正在断开…", "Disconnecting…") : L("断开连接", "Disconnect")).frame(maxWidth: .infinity)
                }.controlSize(.large).disabled(bridge.stopping || bridge.officialDeviceOperationActive)
            } else {
                Button { bridge.connect() } label: {
                    Label { Text(L("连接眼镜", "Connect Glasses")) } icon: { GlassesGlyph() }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(bridge.selectedAddress.isEmpty || unavailable)
            }
            Button { bridge.enterMicrophoneMode() } label: {
                Label(bridge.activeSession == .prompts ? L("重新进入麦克风模式", "Re-enter Microphone Mode") : L("进入麦克风模式", "Enter Microphone Mode"), systemImage: "mic").frame(maxWidth: .infinity)
            }.disabled(unavailable || bridge.selectedAddress.isEmpty)
            if bridge.microphoneForwarding {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(Token.statusIndicatorActive)
                    Text(bridge.microphoneRecovering ? L("麦克风正在恢复", "Microphone recovering") : bridge.microphoneAudioState == "waiting" ? L("等待眼镜音频", "Waiting for audio") : L("两路麦克风已开启", "Dual mics active"))
                    Spacer()
                    Text(String(format: L("%.1f 秒", "%.1fs"), bridge.audioSeconds)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.system(size: 11.5))
            }
        }.card(padding: 12)
    }

    private func navItem(_ item: ControlPage) -> some View {
        let selected = page == item
        return Button { page = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? Token.listActiveSelectionIconForeground : Token.iconForeground)
                Text(item.localizedTitle).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Token.listActiveSelectionForeground : Token.listInactiveForeground)
                Spacer()
            }.padding(.vertical, 6.5).padding(.horizontal, 10)
                .background(selected ? Token.listActiveSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(Token.listActiveSelectionIndicator).frame(width: 3, height: 14).offset(x: -1.5) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func pages(in group: String) -> [ControlPage] {
        switch group {
        case "工作台": return [.workspace, .assistant, .text]
        case "眼镜": return [.setup, .settings, .dashboardCards, .homeContent, .ota]
        case "内容": return [.notification, .teleprompter, .nativeRecording, .recordingLibrary, .recordingDeveloper, .voice, .memory]
        default: return [.audio, .files, .maintenance, .navigation, .video]
        }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                setupStep(number: 1, title: L("发现并配对", "Discover & Pair"), complete: bridge.verifiedPairingAddress == bridge.selectedAddress,
                          detail: bridge.selectedDevice.map { L("已选择 \($0.name)", "Selected \($0.name)") } ?? L("让眼镜进入配对模式，点击下方按钮发现并配对。", "Put glasses in pairing mode and click below to discover and pair."))
                HStack(spacing: 12) {
                    Button(L("添加并配对眼镜", "Pair New Glasses"), systemImage: "plus") { bridge.pairAndConnect() }
                        .disabled(unavailable || bridge.refreshingDevices)
                    Text(L("已有配对可保留使用；需要修复时可明确选择重新配对。", "Existing pairings can be reused; re-pair only when troubleshooting.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 40)
                if bridge.pairingActive {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("请保持眼镜开机、手机蓝牙关闭。开始后不要同时忽略 Mac 配对或重新进入眼镜配对模式；如弹出数字，请核对。", "Keep glasses awake and phone Bluetooth off. Confirm the passkey prompt if shown."))
                            .font(.callout).foregroundStyle(.secondary)
                        Button(L("取消配对流程", "Cancel Pairing")) { bridge.cancelPairing() }
                    }.padding(.leading, 40)
                }
            }.card()
            VStack(alignment: .leading, spacing: 14) {
                setupStep(number: 2, title: L("连接眼镜", "Connect Glasses"), complete: bridge.connected,
                          detail: bridge.connected ? L("蓝牙认证与数据通道已建立。", "BLE authentication and data channel are ready.") : L("已配对的眼镜可直接连接；后台服务和鉴权令牌会自动准备。", "Paired glasses can connect directly; local API and auth token start automatically."))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button { bridge.connect() } label: { Label { Text(bridge.connected ? L("已连接", "Connected") : L("连接并启用 API", "Connect & Start API")) } icon: { GlassesGlyph() } }
                            .buttonStyle(.borderedProminent).disabled(bridge.connected || bridge.selectedAddress.isEmpty || unavailable)
                        Button(bridge.restartingService ? L("正在重启连接服务…", "Restarting Bridge…") : L("重启连接服务", "Restart Bridge"), systemImage: "arrow.clockwise") {
                            bridge.restartConnectionService()
                        }
                        .disabled(bridge.selectedAddress.isEmpty || bridge.stopping || bridge.restartingService || bridge.pairingActive || bridge.refreshingDevices || bridge.officialDeviceOperationActive)
                    }.controlSize(.large)
                    Text(L("连接卡住时可重启服务，窗口保持打开、系统配对保留。当前显示或录音会话会结束，API 地址和令牌可能更新。", "Restart the bridge if connection stalls while keeping the window and pairing intact."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 40)
            }.card()
            VStack(alignment: .leading, spacing: 14) {
                setupStep(number: 3, title: L("本机 API", "Local API"), complete: bridge.apiReady,
                          detail: bridge.apiReady ? L("健康检查和带令牌的设备查询已通过。", "Health check and authenticated device query succeeded.") : bridge.serviceRunning ? L("服务已启动，正在等待眼镜连接或 API 检查。", "Service running; waiting for glasses or API check.") : L("连接完成后，即可复制地址与调用命令。", "Address and curl example appear once connected."))
                VStack(alignment: .leading, spacing: 10) {
                    if bridge.serviceRunning {
                        Text(bridge.apiAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button(L("复制地址", "Copy URL")) { bridge.copyAPIAddress() }
                            Button(L("复制令牌", "Copy Token")) { bridge.copyAPIToken() }
                            Button(L("检查 API", "Verify API")) { bridge.checkAPI() }.disabled(unavailable)
                        }
                        Text(bridge.apiExample).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Token.textCodeBlockBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button(L("复制带令牌的调用示例", "Copy curl Example"), systemImage: "doc.on.doc") { bridge.copyAPIExample() }
                        if let verified = bridge.apiVerifiedAt {
                            Text(L("最近检查：\(verified.formatted(date: .omitted, time: .standard))", "Last verified: \(verified.formatted(date: .omitted, time: .standard))")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(L("API 仅供这台 Mac 调用。断开或退出后服务停止；再次连接时请以当前地址和令牌为准。", "Localhost-only API for this Mac. Stops on disconnect or quit."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 40)
            }.card()
            microphoneSettings.card()
        }
    }

    private func setupStep(number: Int, title: String, complete: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StepBadge(number: number, complete: complete)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }.padding(.top, 4)
        }
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("极简字符导航", detail: "模拟转向和距离，尚未接入地图或 GPS。")
            HStack(spacing: 24) {
                Picker("方向", selection: $direction) {
                    ForEach(NavigationDirection.allCases) { Text($0.title).tag($0) }
                }.frame(width: 180)
                Stepper(value: $meters, in: 0...9990, step: 10) {
                    Text(meters == 0 ? "现在转向" : "距离：\(meters) 米").monospacedDigit()
                }
            }
            let cells = NavigationFrame.rows(direction: direction, meters: meters).flatMap { Array($0) }
            LensSurface(title: "20×5 排版预览 · 实际字体以眼镜为准") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 0), count: 20), spacing: 0) {
                    ForEach(cells.indices, id: \.self) { index in
                        Text(String(cells[index])).font(.system(size: 16, weight: .regular, design: .monospaced)).frame(width: 16, height: 20)
                    }
                }.fixedSize()
            }
            HStack {
                Button(bridge.activeSession == .navigation ? "更新导航" : "显示导航", systemImage: "paperplane") {
                    bridge.showNavigation(direction: direction, meters: meters)
                }.buttonStyle(.borderedProminent)
                Button("重新打开显示") { bridge.showNavigation(direction: direction, meters: meters, reopen: true) }
            }.controlSize(.large).disabled(unavailable || bridge.selectedAddress.isEmpty)
            Text("首行自动对齐：首次显示不修正，后续刷新自动修正。在眼镜上手动退出后，使用“重新打开显示”。").font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("显示页面", selection: $usePrompt) {
                Text("实时字幕").tag(false)
                Text("实时提示").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            VStack(alignment: .leading, spacing: 14) {
                fieldLabel(usePrompt ? "提示标题" : "显示文字")
                editor($caption, height: usePrompt ? 80 : 170)
                if usePrompt {
                    fieldLabel("回答正文")
                    editor($answer, height: 120)
                    Text("文字显示不主动开启收音；已进入麦克风模式时，更新回答会保留音频。").font(.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
                Toggle("作为完整结果发送（final）", isOn: $finalText)
                Text("完整结果用于结束当前识别片段；清屏请使用下方独立操作。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("发送后自动清屏", isOn: $clearAfterSending)
                    if clearAfterSending { Stepper("\(clearAfterSeconds) 秒", value: $clearAfterSeconds, in: 1...600).frame(width: 180) }
                }
            }.card()
            HStack {
                HStack {
                    Button("发送到眼镜", systemImage: "paperplane") { bridge.showText(caption, translation: answer, prompt: usePrompt, final: finalText, clearAfterMilliseconds: clearAfterSending ? clearAfterSeconds * 1000 : 0) }
                        .buttonStyle(.borderedProminent)
                    Button("重新打开显示") { bridge.showText(caption, translation: answer, prompt: usePrompt, reopen: true, final: finalText, clearAfterMilliseconds: clearAfterSending ? clearAfterSeconds * 1000 : 0) }
                }.disabled(unavailable || caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.selectedAddress.isEmpty)
                Spacer()
                Button("清空当前屏幕", systemImage: "eraser") { bridge.clearDisplay(prompt: usePrompt) }
                    .disabled(unavailable || (usePrompt ? bridge.activeSession != .prompts && bridge.activeSession != .assistantAudio : bridge.activeSession != .captions))
            }.controlSize(.large)
            Text("清屏保留显示会话和收音；新内容会取消上一条内容的延时清屏。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("把本地视频变成眼镜上的字符动画", detail: "可用 Bad Apple 等黑白剪影视频。使用 26×7 全角字符格，无声播放；首版支持最长 10 分钟。")
            HStack {
                Button("选择视频…", systemImage: "folder") { bridge.chooseVideo() }
                    .disabled(unavailable || bridge.videoImporting || bridge.videoPlaying)
                if bridge.videoImporting {
                    ProgressView().controlSize(.small)
                    Button("取消解码") { bridge.cancelVideoImport() }
                }
                Button("检查字符对齐") { bridge.showVideoAlignment() }
                    .disabled(unavailable || bridge.selectedAddress.isEmpty)
                Button("结束显示", systemImage: "stop.fill") { bridge.stopSession() }
                    .disabled(unavailable || bridge.activeSession != .video)
            }
            Text(L("对齐标尺包含方块、空白、全角字母和标点。先确认七行左右竖线对齐，再播放视频。", "The alignment ruler includes blocks, spaces, full-width letters, and punctuation. Verify all 7 rows align before playing.")).font(.caption).foregroundStyle(.secondary)
            Toggle(L("保持原视频比例（黑边填充）", "Preserve Aspect Ratio (Letterbox)"), isOn: Binding(
                get: { bridge.preserveVideoAspectRatio },
                set: { bridge.setPreserveVideoAspectRatio($0) }
            )).disabled(bridge.videoImporting || bridge.videoPlaying)
            if let video = bridge.textVideo {
                Divider()
                Text("\(video.name) · \(Int(video.duration)) 秒").font(.headline).textSelection(.enabled)
                HStack {
                    Picker("字符", selection: $videoStyle) {
                        ForEach(TextVideoStyle.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 250)
                    Picker("帧率", selection: $videoFPS) {
                        Text("5 帧/秒").tag(5)
                        Text("10 帧/秒").tag(10)
                    }.frame(width: 170)
                }.disabled(bridge.videoPlaying)
                HStack(spacing: 18) {
                    Toggle("黑白反转", isOn: $invertVideo)
                    Toggle("增强对比度", isOn: $enhanceVideoContrast)
                    Toggle("后续刷新时首行补一格", isOn: $alignVideoUpdates)
                }.disabled(bridge.videoPlaying)
                Text("全角灰度按区域亮度选择字符，用全角空格占位。亮度以苹方字体校准，眼镜上的字形和对齐仍以标尺实测为准。").font(.caption).foregroundStyle(.secondary)
                let preview = bridge.videoSeconds > 0 || bridge.videoPlaying ? bridge.videoPreview : video.frames[0].text(style: videoStyle, inverted: invertVideo, enhanceContrast: enhanceVideoContrast)
                LensSurface(title: "字符画面预览", live: bridge.videoPlaying) {
                    Text(preview).font(.custom("PingFangSC-Regular", size: 14)).lineSpacing(0)
                }
                ProgressView(value: min(bridge.videoSeconds, video.duration), total: video.duration)
                Text("\(Int(bridge.videoSeconds)) / \(Int(video.duration)) 秒").font(.caption).monospacedDigit()
                HStack {
                    Button("从头播放到眼镜", systemImage: "play.fill") {
                        bridge.playVideo(style: videoStyle, fps: videoFPS, inverted: invertVideo, alignUpdates: alignVideoUpdates, enhanceContrast: enhanceVideoContrast)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(unavailable || bridge.videoImporting || bridge.videoPlaying || bridge.selectedAddress.isEmpty)
                }
                Text("连接跟不上时会跳帧，不积压追赶。播放结束后保留最后发送的画面；点击“结束显示”退出。").font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var notificationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(L("发送一条通知", "Send a Notification"))
            TextField(L("通知标题", "Notification Title"), text: $notificationTitle).textFieldStyle(.roundedBorder)
            editor($notificationBody, height: 150)
            Button(L("发送通知", "Send Notification"), systemImage: "bell.badge") { bridge.notify(title: notificationTitle, body: notificationBody) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(unavailable || notificationBody.isEmpty || bridge.selectedAddress.isEmpty)
        }.card()
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("直接使用眼镜麦克风", detail: "本地识别中文或英文；录音保存为双声道 WAV。开始后会替换当前实时提示会话。")
            HStack(spacing: 24) {
                Picker("识别语言", selection: $locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }.frame(width: 200)
                Picker("时长", selection: $audioDuration) { Text("1 分钟").tag(60); Text("3 分钟").tag(180); Text("5 分钟").tag(300); Text("10 分钟").tag(600) }.frame(width: 180)
            }
            Toggle("识别时同时保存录音", isOn: $saveAudio)
            HStack {
                Button("开始语音识别", systemImage: "waveform") { bridge.startAudio(recognize: true, record: saveAudio, duration: audioDuration, locale: locale) }
                    .buttonStyle(.borderedProminent)
                Button("仅录音", systemImage: "record.circle") { bridge.startAudio(recognize: false, record: true, duration: audioDuration, locale: locale) }
            }.controlSize(.large).disabled(unavailable || bridge.selectedAddress.isEmpty || (bridge.activeSession == .asr || bridge.activeSession == .recording))
            if bridge.activeSession?.isAudio == true || bridge.audioSeconds > 0 {
                Text(String(format: "已接收 %.1f 秒音频", bridge.audioSeconds)).monospacedDigit()
            }
            if !bridge.transcript.isEmpty {
                Text(bridge.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Token.textCodeBlockBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let path = bridge.recordingPath {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bridge.recordingFinalized ? "录音已保存" : "正在写入录音文件").font(.headline)
                    Text(path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                    HStack {
                        Button("在 Finder 中显示") { bridge.revealRecording() }
                        Button("播放录音") { bridge.playRecording() }.disabled(!bridge.recordingFinalized)
                    }
                }
            }
        }.card()
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("全天智记音频（实验）", detail: "按上方时长自动停止，可保存音频后回放。当前真机收到的是单声道，暂不替换两路虚拟麦克风；没有人声时可能不上传音频。")
            Toggle("保存单声道 WAV 和原始音频分段", isOn: $saveLifeLogAudio)
                .disabled(bridge.activeSession == .lifeLog)
            Text("保留的分段可在“录音资料库”恢复；恢复不会自动执行历史语音中的任务。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始全天智记采集") { bridge.startLifeLog(duration: audioDuration, record: saveLifeLogAudio) }
                    .disabled(unavailable || bridge.selectedAddress.isEmpty || bridge.activeSession == .lifeLog)
                Button("触发一轮音频") { bridge.triggerLifeLogAudio() }
                    .disabled(unavailable || bridge.activeSession != .lifeLog)
                Button("停止全天智记") { bridge.stopSession() }
                    .disabled(unavailable || bridge.activeSession != .lifeLog)
            }
            if bridge.activeSession == .lifeLog || bridge.lifeLogSeconds > 0 {
                Text(String(format: "已解码 %.1f 秒音频", bridge.lifeLogSeconds)).monospacedDigit()
                Text(bridge.lifeLogChannels).font(.callout)
                if bridge.lifeLogDecodeErrors > 0 {
                    Text("解码失败：\(bridge.lifeLogDecodeErrors) 帧").foregroundStyle(Token.bannerWarningForeground)
                }
            }
            Text("声道 1：骨传导麦，采集自己。声道 2：前向麦，采集他人。当前 ASR 混合识别两路声音。")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
        }
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("眼镜麦克风", detail: "连接后保持空闲。点击“进入麦克风模式”才开启双麦和实时提示，问题与回答可同时显示。")
            HStack(spacing: 10) {
                if bridge.builtInMicrophonesReady { StatusChip(text: "两路内置麦克风已就绪") }
                else { StatusChip(text: "尚未安装内置麦克风", active: false) }
                Spacer()
                Button("刷新设备") { bridge.refreshVirtualAudioDevices() }
                    .disabled(unavailable || bridge.microphoneForwarding)
                Button(bridge.builtInMicrophonesReady ? "重新安装驱动…" : "安装内置驱动…") {
                    bridge.openVirtualMicrophoneInstaller()
                }.disabled(unavailable || bridge.activeSession?.isAudio == true)
            }
            Picker("麦克风自动停止", selection: $bridge.microphoneDuration) {
                Text("10 分钟").tag(600)
                Text("1 小时").tag(3_600)
                Text("6 小时").tag(21_600)
            }.frame(width: 280).disabled(bridge.microphoneForwarding)
            Text("OpenRayneo Microphone Channel 1：自己的声音；Channel 2：前方声音。")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("打开声音设置") { bridge.openSoundSettings() }
                Button("恢复音频输出") { bridge.recoverMicrophoneOutput() }
                    .disabled(unavailable || bridge.activeSession != .prompts || !bridge.microphoneForwarding)
                if bridge.microphoneForwarding {
                    Text(bridge.microphoneRecovering ? "音频设备暂不可用，正在恢复" : bridge.microphoneAudioState == "waiting" ? "等待眼镜上传音频，页面保持开启" : "正在转送两路声音").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("进入失败或在眼镜上退出后，点击左侧“进入／重新进入麦克风模式”。切换系统声音设备会自动恢复输出，保留眼镜页面；也可手动恢复音频输出。转送不录音、不识别；切换到字幕、视频或提词器会暂停转送。达到自动停止时长或点击“结束当前功能”才正常结束。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { bridge.refreshVirtualAudioDevices() }
    }

    private var connectionHelp: some View {
        DisclosureGroup("连接帮助与诊断") {
            VStack(alignment: .leading, spacing: 10) {
                Text("首次使用：让眼镜进入配对模式，点击“添加并配对眼镜”。发现目标后建立系统配对，再独立确认记录保存，最后连接数据通道。")
                Text("已有配对日常使用请选择“连接眼镜”。“添加并配对”会询问保留还是重新配对，不再自动删除已有记录。")
                Button("打开系统蓝牙设置") { bridge.openBluetoothSettings() }
                if let pid = bridge.serviceProcessID { Text("连接服务进程：\(pid)").textSelection(.enabled) }
                if !bridge.apiAddress.isEmpty {
                    Text("本机 API：\(bridge.apiAddress)").textSelection(.enabled)
                    Button("复制 API 令牌") { bridge.copyAPIToken() }
                }
                if !bridge.diagnostics.isEmpty { Text(bridge.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.card(padding: 16)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(10).frame(height: height)
            .background(Token.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Token.widgetBorder))
    }
}

@MainActor
private final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    private let bridge = DesktopBridge()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 OpenRayneo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 OpenRayneo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "OpenRayneo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: DesktopControlView(bridge: bridge))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        bridge.refreshDevices()
        if OfficialCloudPolicy.enabled {
            OfficialRecordingUploadModel.shared.startBackground(library: bridge.recordingLibrary)
            OfficialCloudAudioModel.shared.start(library: bridge.recordingLibrary)
        }
        OfficialAccountModel.shared.prepareSignOut = { [weak bridge = bridge] in
            guard let bridge else { return true }
            await OfficialRecordingUploadModel.shared.suspendForSignOut()
            await OfficialCloudAudioModel.shared.suspendForSignOut()
            await bridge.feedback.suspendForTermination()
            await OfficialAccountDataModel.shared.suspendForTermination()
            return await bridge.shutdown()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.cancelPairing()
        Task {
            await OfficialRecordingUploadModel.shared.suspendForTermination()
            await OfficialCloudAudioModel.shared.suspendForTermination()
            await bridge.feedback.suspendForTermination()
            await OfficialAccountDataModel.shared.suspendForTermination()
            let stopped = await bridge.shutdown()
            if !stopped {
                OfficialRecordingUploadModel.shared.startBackground(library: bridge.recordingLibrary)
                OfficialCloudAudioModel.shared.start(library: bridge.recordingLibrary)
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

@MainActor
func runDesktopApplication() -> Never {
    let app = NSApplication.shared
    let delegate = DesktopApplicationDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}
