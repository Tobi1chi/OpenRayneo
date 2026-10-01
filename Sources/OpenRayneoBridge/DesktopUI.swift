// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

private enum ControlPage: String, CaseIterable, Identifiable {
    case setup = "设备与 API", navigation = "导航演示", video = "字符视频", text = "文字显示", notification = "通知", teleprompter = "提词器", audio = "语音与录音"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: return "link"
        case .navigation: return "arrow.turn.up.right"
        case .video: return "film"
        case .text: return "text.bubble"
        case .notification: return "bell"
        case .teleprompter: return "doc.text"
        case .audio: return "waveform"
        }
    }
}

@MainActor
private struct DesktopControlView: View {
    @ObservedObject var bridge: DesktopBridge
    @State private var page: ControlPage = .setup
    @State private var direction: NavigationDirection = .uturn
    @State private var meters = 100
    @State private var videoStyle: TextVideoStyle = .fullWidth
    @State private var videoFPS = 10
    @State private var invertVideo = false
    @State private var enhanceVideoContrast = false
    @State private var alignVideoUpdates = true
    @State private var caption = "你好，OpenRayneo。\n这段文字来自 Mac 控制面板。"
    @State private var answer = ""
    @State private var usePrompt = false
    @State private var notificationTitle = "OpenRayneo"
    @State private var notificationBody = "来自 Mac 的通知"
    @State private var scriptTitle = "我的提词稿"
    @State private var scriptText = ""
    @State private var scriptSpeed = 60
    @State private var locale = "zh-CN"
    @State private var audioDuration = 60
    @State private var saveAudio = false

    private var unavailable: Bool { bridge.busy || bridge.stopping }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.rawValue).font(.title2.weight(.semibold))
                        Text(bridge.activeSession.map { "当前功能：\($0.title)" } ?? "准备好后发送到眼镜")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bridge.activeSession != nil {
                        Button("结束当前功能", systemImage: "stop.fill") { bridge.stopSession() }.disabled(unavailable)
                    }
                }
                if let error = bridge.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled).font(.callout)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .setup: setupPanel
                        case .navigation: navigationPanel
                        case .video: videoPanel
                        case .text: textPanel
                        case .notification: notificationPanel
                        case .teleprompter: teleprompterPanel
                        case .audio: audioPanel
                        }
                        connectionHelp
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if bridge.busy || bridge.stopping { ProgressView().controlSize(.small) }
                    Text(bridge.notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.frame(minHeight: 24)
            }.padding(24)
        }.frame(minWidth: 900, minHeight: 630)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("OpenRayneo", systemImage: "eyeglasses").font(.title3.weight(.semibold))
            HStack(spacing: 7) {
                Circle().fill(bridge.connected ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                Text(bridge.phase).font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(bridge.refreshingDevices ? "正在读取已配对设备…" : "已配对眼镜").font(.caption).foregroundStyle(.secondary)
                Picker("眼镜", selection: $bridge.selectedAddress) {
                    if bridge.devices.isEmpty { Text("尚未找到眼镜").tag("") }
                    ForEach(bridge.devices) { Text("\($0.name) · \($0.id.suffix(5))").tag($0.id) }
                }.labelsHidden().disabled(bridge.serviceRunning || unavailable)
                HStack {
                    Button("刷新", systemImage: "arrow.clockwise") { bridge.refreshDevices() }
                        .disabled(bridge.serviceRunning || bridge.refreshingDevices || unavailable)
                    Button("蓝牙设置") { bridge.openBluetoothSettings() }
                }.controlSize(.small)
                Button("添加并配对眼镜") { page = .setup; bridge.pairAndConnect() }
                    .disabled(unavailable || bridge.refreshingDevices)
                if bridge.serviceRunning {
                    if !bridge.connected {
                        Button("重新连接") { bridge.connect() }.disabled(unavailable)
                    }
                    Button(bridge.stopping ? "正在断开…" : "断开连接") { bridge.disconnect() }.disabled(bridge.stopping)
                } else {
                    Button("连接眼镜") { bridge.connect() }
                        .buttonStyle(.borderedProminent).disabled(bridge.selectedAddress.isEmpty || unavailable)
                }
            }
            Divider()
            ForEach(ControlPage.allCases) { item in
                Button { page = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10)
                        .background(page == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            Spacer()
            Text("手机占用连接时，请先关闭手机蓝牙。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 240).frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            setupStep(number: 1, title: "发现并配对", complete: bridge.verifiedPairingAddress == bridge.selectedAddress,
                      detail: bridge.selectedDevice.map { "已选择 \($0.name)" } ?? "让眼镜进入配对模式，点击下方按钮发现并配对。")
            HStack {
                Button("添加并配对眼镜", systemImage: "plus") { bridge.pairAndConnect() }
                    .disabled(unavailable || bridge.refreshingDevices)
                Text("先清除目标眼镜在 Mac 上的旧配对，再配对并启用 API。").font(.caption).foregroundStyle(.secondary)
            }
            if bridge.pairingActive {
                Text("请保持眼镜开机、手机蓝牙关闭。开始后不要同时忽略 Mac 配对或重新进入眼镜配对模式；如弹出数字，请核对。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("取消配对流程") { bridge.cancelPairing() }
                }
            }
            Divider()
            setupStep(number: 2, title: "连接眼镜", complete: bridge.connected,
                      detail: bridge.connected ? "蓝牙认证与数据通道已建立。" : "已配对的眼镜可直接连接；后台服务和鉴权令牌会自动准备。")
            Button(bridge.connected ? "已连接" : "连接并启用 API", systemImage: "bolt.horizontal") { bridge.connect() }
                .buttonStyle(.borderedProminent).disabled(bridge.connected || bridge.selectedAddress.isEmpty || unavailable)
            Button(bridge.restartingService ? "正在重启连接服务…" : "重启连接服务", systemImage: "arrow.clockwise") {
                bridge.restartConnectionService()
            }
            .disabled(bridge.selectedAddress.isEmpty || bridge.stopping || bridge.restartingService || bridge.pairingActive || bridge.refreshingDevices)
            Text("连接卡住时可重启服务，窗口保持打开、系统配对保留。当前显示或录音会话会结束，API 地址和令牌可能更新。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            setupStep(number: 3, title: "本机 API", complete: bridge.apiReady,
                      detail: bridge.apiReady ? "健康检查和带令牌的设备查询已通过。" : bridge.serviceRunning ? "服务已启动，正在等待眼镜连接或 API 检查。" : "连接完成后，即可复制地址与调用命令。")
            if bridge.serviceRunning {
                Text(bridge.apiAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("复制地址") { bridge.copyAPIAddress() }
                    Button("复制令牌") { bridge.copyAPIToken() }
                    Button("检查 API") { bridge.checkAPI() }.disabled(unavailable)
                }
                Text(bridge.apiExample).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                Button("复制带令牌的调用示例", systemImage: "doc.on.doc") { bridge.copyAPIExample() }
                if let verified = bridge.apiVerifiedAt {
                    Text("最近检查：\(verified.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("API 仅供这台 Mac 调用。断开或退出后服务停止；再次连接时请以当前地址和令牌为准。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setupStep(number: Int, title: String, complete: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2).foregroundStyle(complete ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("极简字符导航").font(.headline)
            Text("模拟转向和距离，尚未接入地图或 GPS。").foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Picker("方向", selection: $direction) {
                    ForEach(NavigationDirection.allCases) { Text($0.title).tag($0) }
                }.frame(width: 180)
                Stepper(value: $meters, in: 0...9990, step: 10) {
                    Text(meters == 0 ? "现在转向" : "距离：\(meters) 米").monospacedDigit()
                }
            }
            let cells = NavigationFrame.rows(direction: direction, meters: meters).flatMap { Array($0) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 0), count: 20), spacing: 0) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(String(cells[index])).font(.system(size: 16, weight: .regular, design: .monospaced)).frame(width: 16, height: 20)
                }
            }.padding(20).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            Text("20×5 排版预览，实际字体以眼镜为准。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(bridge.activeSession == .navigation ? "更新导航" : "显示导航", systemImage: "paperplane") {
                    bridge.showNavigation(direction: direction, meters: meters)
                }.buttonStyle(.borderedProminent)
                Button("重新打开显示") { bridge.showNavigation(direction: direction, meters: meters, reopen: true) }
            }.disabled(unavailable || bridge.selectedAddress.isEmpty)
            Text("首行自动对齐：首次显示不修正，后续刷新自动修正。").font(.caption).foregroundStyle(.secondary)
            Text("在眼镜上手动退出后，使用“重新打开显示”。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("显示页面", selection: $usePrompt) {
                Text("实时字幕").tag(false)
                Text("实时提示").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 340)
            Text(usePrompt ? "提示标题" : "显示文字").font(.headline)
            editor($caption, height: usePrompt ? 80 : 170)
            if usePrompt {
                Text("回答正文").font(.headline)
                editor($answer, height: 120)
                Text("实时提示页面会开启眼镜麦克风上行；这里不保存或识别音频。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("发送到眼镜", systemImage: "paperplane") { bridge.showText(caption, translation: answer, prompt: usePrompt) }
                    .buttonStyle(.borderedProminent)
                Button("重新打开显示") { bridge.showText(caption, translation: answer, prompt: usePrompt, reopen: true) }
            }.disabled(unavailable || caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.selectedAddress.isEmpty)
        }
    }

    private var videoPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("把本地视频变成眼镜上的字符动画").font(.headline)
            Text("可用 Bad Apple 等黑白剪影视频。使用 26×7 全角字符格，无声播放；首版支持最长 10 分钟。").foregroundStyle(.secondary)
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
            Text("对齐标尺包含方块、空白、全角字母和标点。先确认七行左右竖线对齐，再播放视频。").font(.caption).foregroundStyle(.secondary)
            if let video = bridge.textVideo {
                Text("\(video.name) · \(Int(video.duration)) 秒").textSelection(.enabled)
                HStack {
                    Picker("字符", selection: $videoStyle) {
                        ForEach(TextVideoStyle.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 250)
                    Picker("帧率", selection: $videoFPS) {
                        Text("5 帧/秒").tag(5)
                        Text("10 帧/秒").tag(10)
                    }.frame(width: 170)
                }.disabled(bridge.videoPlaying)
                Toggle("黑白反转", isOn: $invertVideo).disabled(bridge.videoPlaying)
                Toggle("增强对比度", isOn: $enhanceVideoContrast).disabled(bridge.videoPlaying)
                Toggle("后续刷新时首行补一格", isOn: $alignVideoUpdates).disabled(bridge.videoPlaying)
                Text("全角灰度按区域亮度选择字符，用全角空格占位。亮度以苹方字体校准，眼镜上的字形和对齐仍以标尺实测为准。").font(.caption).foregroundStyle(.secondary)
                let preview = bridge.videoSeconds > 0 || bridge.videoPlaying ? bridge.videoPreview : video.frames[0].text(style: videoStyle, inverted: invertVideo, enhanceContrast: enhanceVideoContrast)
                Text(preview).font(.custom("PingFangSC-Regular", size: 14)).lineSpacing(0)
                    .padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                ProgressView(value: min(bridge.videoSeconds, video.duration), total: video.duration)
                Text("\(Int(bridge.videoSeconds)) / \(Int(video.duration)) 秒").font(.caption).monospacedDigit()
                HStack {
                    Button("从头播放到眼镜", systemImage: "play.fill") {
                        bridge.playVideo(style: videoStyle, fps: videoFPS, inverted: invertVideo, alignUpdates: alignVideoUpdates, enhanceContrast: enhanceVideoContrast)
                    }.buttonStyle(.borderedProminent)
                        .disabled(unavailable || bridge.videoImporting || bridge.videoPlaying || bridge.selectedAddress.isEmpty)
                }
                Text("连接跟不上时会跳帧，不积压追赶。播放结束后保留最后发送的画面；点击“结束显示”退出。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("通知标题", text: $notificationTitle).textFieldStyle(.roundedBorder)
            editor($notificationBody, height: 150)
            Button("发送通知", systemImage: "bell.badge") { bridge.notify(title: notificationTitle, body: notificationBody) }
                .buttonStyle(.borderedProminent)
                .disabled(unavailable || notificationBody.isEmpty || bridge.selectedAddress.isEmpty)
        }
    }

    private var teleprompterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("稿件标题", text: $scriptTitle).textFieldStyle(.roundedBorder)
            editor($scriptText, height: 220)
            Picker("滚动速度", selection: $scriptSpeed) {
                Text("60").tag(60)
                Text("120").tag(120)
            }.frame(width: 180)
            HStack {
                Button("发送并播放", systemImage: "play.fill") { bridge.startTeleprompter(title: scriptTitle, text: scriptText, speed: scriptSpeed) }
                    .buttonStyle(.borderedProminent).disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.selectedAddress.isEmpty)
                Button("暂停") { bridge.controlTeleprompter("pause") }.disabled(bridge.activeSession != .teleprompter)
                Button("继续") { bridge.controlTeleprompter("resume") }.disabled(bridge.activeSession != .teleprompter)
            }.disabled(unavailable)
        }
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("直接使用眼镜麦克风").font(.headline)
            Text("本地识别中文或英文；录音保存为双声道 WAV。需安装 libopus（brew install opus）。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Picker("识别语言", selection: $locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }.frame(width: 200)
                Picker("时长", selection: $audioDuration) { Text("1 分钟").tag(60); Text("3 分钟").tag(180); Text("5 分钟").tag(300); Text("10 分钟").tag(600) }.frame(width: 180)
            }
            Toggle("识别时同时保存录音", isOn: $saveAudio)
            HStack {
                Button("开始语音识别", systemImage: "waveform") { bridge.startAudio(recognize: true, record: saveAudio, duration: audioDuration, locale: locale) }
                    .buttonStyle(.borderedProminent)
                Button("仅录音", systemImage: "record.circle") { bridge.startAudio(recognize: false, record: true, duration: audioDuration, locale: locale) }
            }.disabled(unavailable || bridge.selectedAddress.isEmpty || bridge.activeSession == .asr || bridge.activeSession == .recording)
            if bridge.activeSession == .asr || bridge.activeSession == .recording || bridge.audioSeconds > 0 {
                Text(String(format: "已接收 %.1f 秒音频", bridge.audioSeconds)).monospacedDigit()
            }
            if !bridge.transcript.isEmpty {
                Text(bridge.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
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
            Text("声道 1：骨传导麦，采集自己。声道 2：前向麦，采集他人。当前 ASR 混合识别两路声音。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionHelp: some View {
        DisclosureGroup("连接帮助与诊断") {
            VStack(alignment: .leading, spacing: 10) {
                Text("首次使用：让眼镜进入配对模式，点击“添加并配对眼镜”。应用会先清除目标眼镜在 Mac 上的旧配对，确认未配对、未连接后再建立新配对。")
                Text("已有配对日常使用请选择“连接眼镜”。需要重新配对时，让眼镜进入配对模式，再点击“添加并配对眼镜”；若系统不支持自动清除，再按错误提示手动忽略。")
                Button("打开系统蓝牙设置") { bridge.openBluetoothSettings() }
                if let pid = bridge.serviceProcessID { Text("连接服务进程：\(pid)").textSelection(.enabled) }
                if !bridge.apiAddress.isEmpty {
                    Text("本机 API：\(bridge.apiAddress)").textSelection(.enabled)
                    Button("复制 API 令牌") { bridge.copyAPIToken() }
                }
                if !bridge.diagnostics.isEmpty { Text(bridge.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).padding(8).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenRayneo"
        window.contentView = NSHostingView(rootView: DesktopControlView(bridge: bridge))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        bridge.refreshDevices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.cancelPairing()
        Task { let stopped = await bridge.shutdown(); sender.reply(toApplicationShouldTerminate: stopped) }
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
