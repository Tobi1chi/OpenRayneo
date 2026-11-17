// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
final class GlassesSettingsModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var busy = false
    @Published var loaded = false
    @Published var notice = "连接后读取眼镜设置。"
    @Published var status: [String: Any] = [:]
    @Published var settings: [String: Any] = [:]
    @Published var brightness = 5
    @Published private(set) var automaticBrightness: Bool?
    @Published var height = 1
    @Published var distance = 2
    @Published var headup = true
    @Published var angle = 11
    @Published var crownWake = 0
    @Published var autoLock = 40
    @Published var headGestures = true
    @Published var headMode = 0
    @Published var crownDirection = 1
    @Published var crownDouble = 0
    @Published var crownLongPress = 1
    @Published var language = "zh-CN"
    @Published var micEnabled = true
    @Published var ledEnabled = true
    @Published var ledAutomatic = true
    @Published var logsEnabled = true
    @Published var deviceName = ""
    @Published var focusEnabled = false
    @Published var focusGlassClose = true
    @Published var focusAutomatic = false
    @Published var focusBegin = "09:00"
    @Published var focusEnd = "18:00"
    @Published var focusDays = Array(0...6)
    @Published var relayEnabled = true
    @Published var relayDescription = ""
    @Published var capabilities: [[String]] = []
    @Published var voiceWake = true
    @Published var voiceState = true
    @Published var voiceInterrupt = true
    @Published var voiceLanguage = "zh-CN"
    @Published var voiceWakeWord = 1
    @Published var voiceModel = ""
    @Published var simpleDashboardMode = 0
    @Published var widgets = [2, 3, 1]
    @Published var dateFormat = "yyyy/M/d"
    @Published var timeFormat = 1
    @Published var temperatureUnit = 1
    @Published var measurement = 1
    private var loadedAddress: String?
    private var observing = false
    private var dashboardSnapshot: [String: Any] = [:]
    private var changesAfter = Date.distantPast

    init(bridge: DesktopBridge) { self.bridge = bridge }
    var connected: Bool { bridge?.connected == true }
    static let voiceLanguages: [(id: Int, code: String, name: String)] = [
        (1, "zh-CN", "普通话"), (2, "zh-HK", "粤语"), (3, "en-US", "英语"),
        (4, "fr-FR", "法语"), (5, "de-DE", "德语"), (6, "es-ES", "西班牙语"), (7, "it-IT", "意大利语")
    ]
    var assistantSettings: [String: Any] { settings["voiceAssistantConfig"] as? [String: Any] ?? [:] }

    func refresh(force: Bool = true) async {
        guard let bridge, connected, !busy else { return }
        busy = true; defer { busy = false }
        let started = Date()
        if loadedAddress != bridge.selectedAddress { status = [:]; settings = [:]; dashboardSnapshot = [:]; automaticBrightness = nil }
        do {
            let result = try await bridge.request("/v1/glasses/status", method: "GET")
            if let value = result["generalStatus"] as? [String: Any] { ingestStatus(value, force: force) }
            let config = try await bridge.request("/v1/glasses/settings", method: "GET")
            if let value = config["generalSettings"] as? [String: Any] { ingestSettings(value, force: force) }
            let dashboard = try await bridge.request("/v1/dashboard", method: "GET")
            if let config = dashboard["config"] as? [String: Any] {
                if let mode = config["simple_mode"] as? Int {
                    sync(\.simpleDashboardMode, mode, dashboardSnapshot["simple_mode"] as? Int, force: force)
                }
                sync(\.widgets, config["widgets"] as? [Int], dashboardSnapshot["widgets"] as? [Int], force: force)
                dashboardSnapshot = config
            }
            loaded = true; loadedAddress = bridge.selectedAddress; changesAfter = started
            if let relay = try? await bridge.request("/v1/network-relay", method: "GET") {
                relayEnabled = relay["enabled"] as? Bool ?? true
                relayDescription = "已转发 \(relay["completed"] as? Int ?? 0) 次请求，失败 \(relay["failed"] as? Int ?? 0) 次。"
            }
            notice = "已读取设备状态、设置和首页布局。"
        } catch { notice = error.localizedDescription }
    }

    func observeChanges() async {
        guard !observing else { return }
        observing = true; defer { observing = false }
        while !Task.isCancelled {
            if connected, !busy, let bridge {
                if !loaded || loadedAddress != bridge.selectedAddress { await refresh() }
                else {
                    do {
                        let result = try await bridge.request("/v1/glasses/changes", method: "GET", timeout: 3)
                        for change in result["changes"] as? [[String: Any]] ?? [] {
                            guard let time = change["receivedAt"] as? Double, time > changesAfter.timeIntervalSince1970,
                                  let body = change["body"] as? [String: Any] else { continue }
                            ingestChange(body); changesAfter = Date(timeIntervalSince1970: time)
                        }
                    } catch { if !Task.isCancelled { notice = "设置变化读取失败：\(error.localizedDescription)" } }
                }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    private func ingestStatus(_ value: [String: Any], force: Bool) {
        let previous = status
        if let name = value["deviceName"] as? String, name != previous["deviceName"] as? String, let bridge {
            bridge.cloudDevices.recordDeviceName(address: bridge.selectedAddress, name: name)
        }
        sync(\.deviceName, value["deviceName"] as? String, previous["deviceName"] as? String, force: force)
        sync(\.brightness, value["brightness"] as? Int, previous["brightness"] as? Int, force: force)
        if let flag = flag(value["automaticBrightness"]) { automaticBrightness = flag }
        let focus = value["focusMode"] as? [String: Any] ?? [:], oldFocus = previous["focusMode"] as? [String: Any] ?? [:]
        sync(\.focusEnabled, flag(focus["enable"]), flag(oldFocus["enable"]), force: force)
        sync(\.focusGlassClose, flag(focus["enableGlassClose"]), flag(oldFocus["enableGlassClose"]), force: force)
        let policy = focus["policy"] as? [String: Any] ?? [:], oldPolicy = oldFocus["policy"] as? [String: Any] ?? [:]
        sync(\.focusAutomatic, flag(policy["auto"]), flag(oldPolicy["auto"]), force: force)
        sync(\.focusBegin, policy["begin"] as? String, oldPolicy["begin"] as? String, force: force)
        sync(\.focusEnd, policy["end"] as? String, oldPolicy["end"] as? String, force: force)
        sync(\.focusDays, policy["weekday"] as? [Int], oldPolicy["weekday"] as? [Int], force: force)
        status.merge(value) { _, new in new }
    }

    private func ingestSettings(_ value: [String: Any], force: Bool) {
        let previous = settings
        sync(\.autoLock, value["autoLockTime"] as? Int, previous["autoLockTime"] as? Int, force: force)
        sync(\.language, value["language"] as? String, previous["language"] as? String, force: force)
        let display = value["displayConfig"] as? [String: Any] ?? [:], oldDisplay = previous["displayConfig"] as? [String: Any] ?? [:]
        sync(\.height, display["height"] as? Int, oldDisplay["height"] as? Int, force: force)
        sync(\.distance, display["distance"] as? Int, oldDisplay["distance"] as? Int, force: force)
        let wake = value["wakeupConfig"] as? [String: Any] ?? [:], oldWake = previous["wakeupConfig"] as? [String: Any] ?? [:]
        sync(\.headup, flag(wake["headupSwitch"]), flag(oldWake["headupSwitch"]), force: force)
        sync(\.angle, wake["headupDegree"] as? Int, oldWake["headupDegree"] as? Int, force: force)
        sync(\.crownWake, wake["crownSwitch"] as? Int, oldWake["crownSwitch"] as? Int, force: force)
        let head = value["headGestures"] as? [String: Any] ?? [:], oldHead = previous["headGestures"] as? [String: Any] ?? [:]
        sync(\.headGestures, flag(head["enabled"]), flag(oldHead["enabled"]), force: force)
        sync(\.headMode, head["mode"] as? Int, oldHead["mode"] as? Int, force: force)
        let crown = value["crownConfig"] as? [String: Any] ?? [:], oldCrown = previous["crownConfig"] as? [String: Any] ?? [:]
        sync(\.crownDirection, crown["direction"] as? Int, oldCrown["direction"] as? Int, force: force)
        sync(\.crownDouble, crown["double"] as? Int, oldCrown["double"] as? Int, force: force)
        sync(\.crownLongPress, crown["longPress"] as? Int, oldCrown["longPress"] as? Int, force: force)
        let privacy = value["privacyConfig"] as? [String: Any] ?? [:], oldPrivacy = previous["privacyConfig"] as? [String: Any] ?? [:]
        sync(\.micEnabled, flag(privacy["mic_switch"]), flag(oldPrivacy["mic_switch"]), force: force)
        sync(\.ledEnabled, flag(privacy["led_light"]), flag(oldPrivacy["led_light"]), force: force)
        sync(\.ledAutomatic, flag(privacy["led_auto_light"]), flag(oldPrivacy["led_auto_light"]), force: force)
        sync(\.logsEnabled, flag(privacy["log_switch"]), flag(oldPrivacy["log_switch"]), force: force)
        let units = value["systemUnitsConfig"] as? [String: Any] ?? [:], oldUnits = previous["systemUnitsConfig"] as? [String: Any] ?? [:]
        sync(\.dateFormat, units["date_format"] as? String, oldUnits["date_format"] as? String, force: force)
        sync(\.timeFormat, units["time_format"] as? Int, oldUnits["time_format"] as? Int, force: force)
        sync(\.temperatureUnit, units["temp_unit"] as? Int, oldUnits["temp_unit"] as? Int, force: force)
        sync(\.measurement, units["measurement"] as? Int, oldUnits["measurement"] as? Int, force: force)
        let assistant = value["voiceAssistantConfig"] as? [String: Any] ?? [:]
        let oldAssistant = previous["voiceAssistantConfig"] as? [String: Any] ?? [:]
        sync(\.voiceState, flag(assistant["enabled"]), flag(oldAssistant["enabled"]), force: force)
        sync(\.voiceWake, flag(assistant["voiceWakeup"]), flag(oldAssistant["voiceWakeup"]), force: force)
        sync(\.voiceInterrupt, flag(assistant["workMode"]), flag(oldAssistant["workMode"]), force: force)
        sync(\.voiceWakeWord, assistant["wakeupWord"] as? Int, oldAssistant["wakeupWord"] as? Int, force: force)
        sync(\.voiceModel, assistant["aiModel"] as? String, oldAssistant["aiModel"] as? String, force: force)
        sync(\.voiceLanguage, assistant["language"] as? String, oldAssistant["language"] as? String, force: force)
        for (key, item) in value {
            if let item = item as? [String: Any], let old = settings[key] as? [String: Any] { settings[key] = old.merging(item) { _, new in new } }
            else { settings[key] = item }
        }
    }

    private func ingestChange(_ body: [String: Any], force: Bool = false) {
        if let value = body["generalStatus"] as? [String: Any] { ingestStatus(value, force: force) }
        if let value = body["generalSettings"] as? [String: Any] { ingestSettings(value, force: force) }
        guard let command = body["cmd"] as? String, let payload = body["payload"] as? [String: Any] else { return }
        let text = payload["data"] as? String ?? ""
        let data = payload["data"] as? [String: Any] ??
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        switch command {
        case "brightness_change":
            var changed: [String: Any] = [:]
            if let value = payload["value"] as? Int { changed["brightness"] = value }
            if let mode = payload["mode"] as? Int { changed["automaticBrightness"] = mode == 1 }
            if let lux = data["lux"] { changed["lux"] = lux }
            ingestStatus(changed, force: force)
        case "device_name_change": ingestStatus(["deviceName": text], force: force)
        case "focus_mode":
            var focus: [String: Any] = ["policy": data]
            if let value = payload["value"] { focus["enable"] = value }
            if let mode = payload["mode"] { focus["enableGlassClose"] = mode }
            ingestStatus(["focusMode": focus], force: force)
        case "battery_change", "mic_status", "screen_status", "hall_state", "wear_change":
            let keys = ["battery_change": "battery", "mic_status": "micStatus", "screen_status": "screenStatus", "hall_state": "hallStatus", "wear_change": "wear"]
            if let key = keys[command], let value = payload["value"] { ingestStatus([key: value], force: force) }
        case "auto_lock_time":
            if let value = payload["value"] { ingestSettings(["autoLockTime": value], force: force) }
        case "language_change":
            if let value = data["currentLang"] { ingestSettings(["language": value], force: force) }
        case "display_config": ingestSettings(["displayConfig": data], force: force)
        case "wakeup_config":
            var wake: [String: Any] = [:]
            for (source, destination) in [("headup_switch", "headupSwitch"), ("headup_degree", "headupDegree"), ("crown_switch", "crownSwitch")] {
                if let value = data[source] ?? data[destination] { wake[destination] = value }
            }
            ingestSettings(["wakeupConfig": wake], force: force)
        case "crown_config":
            var crown = data
            if let value = payload["value"] { crown["direction"] = value }
            ingestSettings(["crownConfig": crown], force: force)
        case "head_gestures":
            var head: [String: Any] = [:]
            if let value = payload["value"] { head["enabled"] = value }
            if let mode = payload["mode"] { head["mode"] = mode }
            ingestSettings(["headGestures": head], force: force)
        case "privacy_config": ingestSettings(["privacyConfig": data], force: force)
        case "system_unints_config", "system_units_config": ingestSettings(["systemUnitsConfig": data], force: force)
        case "sync_ai_settings":
            var assistant: [String: Any] = [:]
            for (wire, field) in [("ai_state", "enabled"), ("ai_voice_wakeup", "voiceWakeup"),
                                  ("ai_work_mode", "workMode"), ("ai_timbre", "timbre"),
                                  ("ai_model_str", "aiModel"), ("ai_wakeup_word", "wakeupWord")] {
                if let value = data[wire] { assistant[field] = value }
            }
            if let id = data["ai_lang"] as? Int {
                assistant["language"] = Self.voiceLanguages.first(where: { $0.id == id })?.code ?? "设备值 \(id)"
            }
            ingestSettings(["voiceAssistantConfig": assistant], force: force)
        default: break
        }
    }

    private func sync<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<GlassesSettingsModel, Value>, _ value: Value?, _ previous: Value?, force: Bool) {
        guard let value else { return }
        // Passive readback updates untouched fields while preserving drafts still being edited.
        if force || previous == nil || self[keyPath: keyPath] == previous { self[keyPath: keyPath] = value }
    }

    private func flag(_ value: Any?) -> Bool? {
        if let value = value as? Int { return value == 1 }
        return value as? Bool
    }

    func control(_ command: String, value: Int = 0, mode: Int = 0, data: [String: Any] = [:]) async {
        await apply("control", ["command": command, "value": value, "mode": mode, "data": data.isEmpty ? "" : data as Any])
    }

    func rename() async { await apply("control", ["command": "device_name_change", "data": deviceName]) }
    func assistant(_ name: String, mode: Int = 0, data: String = "") async { await apply("assistant", ["command": name, "mode": mode, "data": data]) }
    func setRelay() async {
        guard let bridge else { return }
        do { _ = try await bridge.request("/v1/network-relay", body: ["enabled": relayEnabled]); notice = "已更新网络转发。" }
        catch { notice = error.localizedDescription }
    }
    func readCapabilities() async {
        guard let bridge else { return }
        do { capabilities = try await bridge.request("/v1/capabilities", body: [:])["peer"] as? [[String]] ?? [] }
        catch { notice = error.localizedDescription }
    }

    func apply(_ section: String, _ body: [String: Any]) async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await bridge.request("/v1/glasses/\(section)", method: "PATCH", body: body)
            if let reply = result["reply"] as? [String: Any] { ingestChange(reply, force: section != "assistant") }
            let message: String
            if result["stateSynchronized"] as? Bool == true {
                message = "设置已发送，已收到眼镜助手状态同步。"
            } else {
                message = result["acknowledged"] as? Bool == true ? "设置已发送，眼镜已回复。" : "设置已发送，未收到确认；可重新读取状态。"
            }
            busy = false
            await refresh(force: false)
            notice = message
        } catch { notice = error.localizedDescription }
    }

    func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
struct GlassesSettingsPanel: View {
    @ObservedObject var model: GlassesSettingsModel
    var openDashboard: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设备状态与设置").font(.title2.weight(.semibold))
                Spacer()
                Button("读取眼镜") { Task { await model.refresh() } }.disabled(!model.connected || model.busy)
            }
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy { ProgressView().controlSize(.small) }
            if model.loaded {
                GroupBox("设备信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.status["deviceName"] as? String ?? "") · \(model.settings["firmwareVersion"] as? String ?? "")")
                        Text("电量 \(model.status["battery"] as? Int ?? 0)% · 电池温度 \(model.status["batt_temp"] as? Int ?? 0)° · \(model.status["isCharging"] as? Bool == true ? "充电中" : "未充电")")
                        Text("型号 \(model.settings["deviceType"] as? String ?? "") · 自动休眠 \(model.settings["autoLockTime"] as? Int ?? 0) 秒")
                        HStack { TextField("设备名称", text: $model.deviceName); Button("重命名") { Task { await model.rename() } } }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("显示") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Stepper("亮度 \(model.brightness)", value: $model.brightness, in: 1...17)
                            Button("应用亮度") { Task { await model.apply("brightness", ["value": model.brightness]) } }
                        }
                        Text(model.automaticBrightness.map { "眼镜自动亮度：\($0 ? "开启" : "关闭")" } ?? "眼镜尚未报告自动亮度状态")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Stepper("高度 \(model.height)", value: $model.height, in: 1...6)
                            Stepper("距离 \(model.distance)", value: $model.distance, in: 1...3)
                            Button("应用位置") { Task { await model.apply("display", ["height": model.height, "distance": model.distance]) } }
                        }
                    }.padding(8)
                }
                GroupBox("唤醒与息屏互动") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("抬头唤醒", isOn: $model.headup)
                        Stepper("抬头角度 \(model.angle)°", value: $model.angle)
                        Toggle("息屏互动", isOn: Binding(get: { model.crownWake != 0 }, set: { enabled in
                            model.crownWake = enabled ? (model.crownWake == 0 ? 3 : model.crownWake) : 0
                        }))
                        if model.crownWake != 0 {
                            Picker("互动样式", selection: $model.crownWake) {
                                Text("弹珠").tag(3)
                                Text("扑克牌").tag(2)
                                if model.crownWake == 1 { Text("陀螺仪（设备保留样式）").tag(1) }
                                if ![1, 2, 3].contains(model.crownWake) { Text("设备值 \(model.crownWake)").tag(model.crownWake) }
                            }
                        }
                        Text("息屏时旋转旋钮，可唤醒所选互动像素动画。").font(.caption).foregroundStyle(.secondary)
                        Button("应用唤醒设置") { Task { await model.apply("wakeup", [
                            "headup_switch": model.headup ? 1 : 0, "headup_degree": model.angle, "crown_switch": model.crownWake
                        ]) } }
                        HStack {
                            Picker("自动休眠", selection: $model.autoLock) {
                                ForEach([5, 10, 15, 25, 40, 60, 120], id: \.self) { seconds in Text("\(seconds) 秒").tag(seconds) }
                                if ![5, 10, 15, 25, 40, 60, 120].contains(model.autoLock) { Text("设备值 \(model.autoLock) 秒").tag(model.autoLock) }
                            }
                            Button("应用休眠时间") { Task { await model.control("auto_lock_time", value: model.autoLock) } }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("头控与旋钮") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("头控开关", isOn: $model.headGestures)
                        Picker("头控模式", selection: $model.headMode) { Text("模式 0").tag(0); Text("模式 1").tag(1) }
                        Button("应用头控") { Task { await model.control("head_gestures", value: model.headGestures ? 1 : 0, mode: model.headMode) } }
                        Stepper("旋钮方向 \(model.crownDirection)", value: $model.crownDirection, in: 0...1)
                        crownAction("双击", selection: $model.crownDouble, longPress: false)
                        crownAction("长按", selection: $model.crownLongPress, longPress: true)
                        Button("应用旋钮") { Task { await model.control("crown_config", value: model.crownDirection, data: ["double": model.crownDouble, "longPress": model.crownLongPress]) } }
                    }.padding(8)
                }
                GroupBox("语言与隐私") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("系统语言", selection: $model.language) {
                            ForEach(model.settings["supportedLanguages"] as? [String] ?? ["zh-CN", "en-US"], id: \.self) { Text($0).tag($0) }
                        }
                        Button("应用语言") { Task { await model.control("language_change", data: ["currentLang": model.language]) } }
                        Toggle("眼镜麦克风", isOn: $model.micEnabled)
                        Toggle("指示灯", isOn: $model.ledEnabled)
                        Toggle("指示灯自动亮度", isOn: $model.ledAutomatic)
                        Toggle("设备日志", isOn: $model.logsEnabled)
                        Button("应用隐私设置") { Task { await model.control("privacy_config", data: ["mic_switch": model.micEnabled ? 1 : 0, "led_light": model.ledEnabled ? 1 : 0, "led_auto_light": model.ledAutomatic ? 1 : 0, "log_switch": model.logsEnabled ? 1 : 0]) } }
                    }.padding(8)
                }
                GroupBox("勿扰模式") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("开启勿扰", isOn: $model.focusEnabled)
                            Button("应用勿扰开关") { Task { await model.apply("focus/enabled", ["enabled": model.focusEnabled]) } }
                        }
                        Toggle("摘下眼镜时关闭勿扰", isOn: $model.focusGlassClose)
                        Toggle("按时段自动启用", isOn: $model.focusAutomatic)
                        HStack { TextField("开始 HH:mm", text: $model.focusBegin); TextField("结束 HH:mm", text: $model.focusEnd) }
                        HStack {
                            ForEach(0...6, id: \.self) { day in
                                Toggle("\(day + 1)", isOn: Binding(get: { model.focusDays.contains(day) }, set: {
                                    if $0 { model.focusDays.append(day) } else { model.focusDays.removeAll { $0 == day } }
                                })).toggleStyle(.checkbox)
                            }
                        }
                        Button("应用勿扰策略") { Task { await model.apply("focus", ["enabled": model.focusEnabled, "enableGlassClose": model.focusGlassClose, "automatic": model.focusAutomatic, "begin": model.focusBegin, "end": model.focusEnd, "weekday": model.focusDays.sorted()]) } }
                        Text("手动开关立即生效；保存自动策略后，眼镜会按所选时段决定当前勿扰状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("日期与单位") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("日期格式", selection: $model.dateFormat) {
                            Text("年／月／日").tag("yyyy/M/d")
                            Text("日／月／年").tag("d/M/yyyy")
                            Text("月／日／年").tag("M/d/yyyy")
                            if !["yyyy/M/d", "d/M/yyyy", "M/d/yyyy"].contains(model.dateFormat) { Text(model.dateFormat).tag(model.dateFormat) }
                        }
                        unitPicker("时间格式", selection: $model.timeFormat, first: "24 小时制", second: "12 小时制")
                        unitPicker("温度单位", selection: $model.temperatureUnit, first: "摄氏度 °C", second: "华氏度 °F")
                        unitPicker("计量单位", selection: $model.measurement, first: "公制", second: "英制")
                        Button("应用日期与单位") { Task { await model.apply("units", ["date_format": model.dateFormat, "time_format": model.timeFormat, "temp_unit": model.temperatureUnit, "measurement": model.measurement]) } }
                    }.padding(8)
                }
                DisclosureGroup("眼镜语音助手") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Toggle("语音唤醒", isOn: $model.voiceWake); Button("应用") { Task { await model.assistant("set_ai_voice_wakeup", mode: model.voiceWake ? 1 : 0) } } }
                        HStack { Toggle("助手开关", isOn: $model.voiceState); Button("应用") { Task { await model.assistant("set_ai_state", mode: model.voiceState ? 1 : 0) } } }
                        HStack { Toggle("对话打断", isOn: $model.voiceInterrupt); Button("应用") { Task { await model.assistant("set_ai_work_mode", mode: model.voiceInterrupt ? 1 : 0) } } }
                        HStack {
                            Picker("唤醒词", selection: $model.voiceWakeWord) {
                                Text("小雷小雷").tag(1)
                                Text("OK RayNeo / Hey RayNeo").tag(2)
                                if ![1, 2].contains(model.voiceWakeWord) { Text("设备值 \(model.voiceWakeWord)").tag(model.voiceWakeWord) }
                            }
                            Button("应用唤醒词") { Task { await model.assistant("set_ai_wakeup_word", mode: model.voiceWakeWord) } }
                                .disabled(![1, 2].contains(model.voiceWakeWord))
                        }
                        HStack {
                            Picker("对话语言", selection: $model.voiceLanguage) {
                                ForEach(GlassesSettingsModel.voiceLanguages, id: \.id) { language in Text(language.name).tag(language.code) }
                                if !GlassesSettingsModel.voiceLanguages.contains(where: { $0.code == model.voiceLanguage }) { Text(model.voiceLanguage).tag(model.voiceLanguage) }
                            }
                            Button("应用对话语言") {
                                if let language = GlassesSettingsModel.voiceLanguages.first(where: { $0.code == model.voiceLanguage }) {
                                    Task { await model.assistant("set_ai_lang", mode: language.id) }
                                }
                            }.disabled(!GlassesSettingsModel.voiceLanguages.contains(where: { $0.code == model.voiceLanguage }))
                        }
                        HStack { TextField("眼镜模型显示名称", text: $model.voiceModel); Button("应用名称") { Task { await model.assistant("set_ai_model_str", data: model.voiceModel) } } }
                        if let timbre = model.assistantSettings["timbre"] as? Int {
                            Text("眼镜回传音色：\(timbre)（只读）").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.assistantSettings.isEmpty ? "尚未收到眼镜助手设置，请读取眼镜。" : "语音唤醒关闭后可延长待机；对话语言与系统语言分别设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                    .disabled(model.assistantSettings.isEmpty)
                }
                GroupBox("网络与设备能力") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("使用 Mac 转发眼镜网络请求", isOn: $model.relayEnabled)
                        Text(model.relayDescription).font(.caption).foregroundStyle(.secondary)
                        Button("应用网络设置") { Task { await model.setRelay() } }
                        Button("查询眼镜能力") { Task { await model.readCapabilities() } }
                        ForEach(Array(model.capabilities.enumerated()), id: \.offset) { _, item in Text(item.joined(separator: " · ")).font(.caption) }
                    }.padding(8)
                }
                GroupBox("首页布局") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("在首页预览中选择样式、配置小组件并拖动调整顺序。")
                            .foregroundStyle(.secondary)
                        if let openDashboard { Button("打开首页预览与布局", action: openDashboard) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup("原始设备状态") { Text(model.json(model.status)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                DisclosureGroup("原始设备设置") { Text(model.json(model.settings)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }
        .disabled(model.busy)
        .task { await model.observeChanges() }
    }

    private func unitPicker(_ title: String, selection: Binding<Int>, first: String, second: String) -> some View {
        Picker(title, selection: selection) {
            Text(first).tag(1); Text(second).tag(2)
            if ![1, 2].contains(selection.wrappedValue) { Text("设备值 \(selection.wrappedValue)").tag(selection.wrappedValue) }
        }
    }

    private func crownAction(_ title: String, selection: Binding<Int>, longPress: Bool) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(["问 AI", "看板", "专注", "录音", "字幕", "提词", "智记", "无", "待办", "实时提示"].enumerated()), id: \.offset) { index, label in
                if !longPress || index != 6 { Text(label).tag(index) }
            }
        }
    }

    private func widgetName(_ id: Int) -> String {
        [1: "天气", 2: "待办", 3: "日程", 4: "股票", 5: "邮件", 6: "世界时钟"][id] ?? "组件 \(id)"
    }
}
