// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class HomeContentModel: ObservableObject, AssistantToolExecutor {
    @Published private(set) var todos: [HomeTodo] = []
    @Published private(set) var configuredCityIDs: [String] = []
    @Published private(set) var dashboardJSON = "尚未读取首页配置"
    @Published private(set) var cityResults: [HomeCity] = []
    @Published private(set) var bindings: [HomeWeatherBinding] = []
    @Published private(set) var weather: [Int: HomeWeatherSnapshot] = [:]
    @Published private(set) var refreshEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var notice = "连接眼镜后读取现有首页内容"
    @Published var cityQuery = ""
    @Published var selectedSlot = ""
    @Published var newTodoTitle = ""
    @Published var newTodoImportant = false
    @Published var editingTodoID: String?
    @Published var editingTodoTitle = ""
    @Published var editingTodoImportant = false

    private weak var bridge: DesktopBridge?
    private let service: HomeWeatherService
    private let stateURL: URL
    private var saved = SavedState()
    private var deviceTail: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var busyCount = 0
    private var subscriptions = Set<AnyCancellable>()

    private struct WeatherSettings: Codable {
        var bindings: [HomeWeatherBinding] = []
        var refresh = false
        var selectedSlot = ""
    }
    private struct Invocation: Codable {
        let name: String
        let arguments: String
        var result: String?
    }
    private struct SavedState: Codable {
        var devices: [String: WeatherSettings] = [:]
        var invocations: [String: Invocation] = [:]
    }
    private var loadError: String?
    private var currentDevice: String { bridge?.selectedAddress.uppercased().replacingOccurrences(of: ":", with: "-") ?? "" }
    var connected: Bool { bridge?.connected == true }

    init(bridge: DesktopBridge, storageURL: URL? = nil, weatherService: HomeWeatherService = .init()) {
        self.bridge = bridge
        self.service = weatherService
        stateURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/HomeContent/settings-and-calls.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do { saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL)) }
            catch { loadError = "首页管理记录无法读取，已暂停写入，原文件未覆盖"; self.error = loadError }
        }
        applySettings()
        armRefresh()
        bridge.$connected.removeDuplicates().dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                if connected, self.refreshEnabled, !self.bindings.isEmpty { await self.publishWeather() }
            }
        }.store(in: &subscriptions)
        bridge.$selectedAddress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.todos = []; self.configuredCityIDs = []; self.weather = [:]; self.cityResults = []
                self.dashboardJSON = "设备已切换，请读取当前首页配置"
                self.refreshTask?.cancel(); self.refreshTask = nil
                self.applySettings(); self.armRefresh()
            }
        }.store(in: &subscriptions)
    }

    private func applySettings() {
        let settings = saved.devices[currentDevice] ?? WeatherSettings()
        bindings = settings.bindings; selectedSlot = settings.selectedSlot; refreshEnabled = settings.refresh
    }

    private func persist() throws {
        if let loadError { throw HomeContentFailure(loadError) }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: stateURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func saveSettings() throws {
        guard !currentDevice.isEmpty else { throw HomeContentFailure("请先选择眼镜") }
        saved.devices[currentDevice] = WeatherSettings(bindings: bindings, refresh: refreshEnabled, selectedSlot: selectedSlot)
        try persist()
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Task chaining keeps each device operation ordered even though MainActor is reentrant at await.
    private func onDevice<T>(_ operation: @escaping @MainActor (DesktopBridge) async throws -> T) async throws -> T {
        let previous = deviceTail, expected = currentDevice
        let task = Task { @MainActor [weak self] in
            await previous?.value
            try Task.checkCancellation()
            guard let self, let bridge = self.bridge, bridge.connected, !expected.isEmpty, self.currentDevice == expected else {
                throw HomeContentFailure("眼镜未连接或设备已切换，未执行设备操作")
            }
            return try await operation(bridge)
        }
        deviceTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func busy<T>(_ operation: () async throws -> T) async rethrows -> T {
        busyCount += 1; isBusy = true
        defer { busyCount -= 1; isBusy = busyCount > 0 }
        return try await operation()
    }

    func refresh() async {
        await busy {
            do {
                applySettings()
                try await readDashboard()
                try await readTodos()
                armRefresh()
                error = nil; notice = "已读取首页配置与待办；没有改变首页布局"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func readDashboard() async throws {
        let expected = currentDevice
        let response = try await onDevice { try await $0.request("/v1/dashboard", method: "GET") }
        guard currentDevice == expected else { throw HomeContentFailure("设备已切换，已丢弃旧首页配置") }
        guard let config = response["config"] as? [String: Any] else { throw HomeContentFailure("眼镜未返回可解析的首页配置") }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        dashboardJSON = String(decoding: data, as: UTF8.self)
        let widgets = config["widgets_data"] as? [String: Any] ?? [:]
        let source = widgets["weather"] as? [String: Any] ?? [:]
        configuredCityIDs = (source["location_ids"] as? [Any] ?? []).compactMap {
            if let value = $0 as? String { return value }
            return ($0 as? NSNumber)?.stringValue
        }
        if !configuredCityIDs.contains(selectedSlot) { selectedSlot = configuredCityIDs.first ?? "" }
    }

    private func readTodos() async throws {
        let expected = currentDevice
        let response = try await onDevice { try await $0.request("/v1/todos", method: "GET") }
        guard currentDevice == expected else { throw HomeContentFailure("设备已切换，已丢弃旧待办结果") }
        guard let reply = response["reply"] as? [String: Any], let rows = reply["dataList"] as? [[String: Any]] else {
            throw HomeContentFailure("未取得完整待办列表")
        }
        applyTodos(response["localItems"] as? [[String: Any]] ?? rows, owned: Set(response["ownedEventIDs"] as? [String] ?? []))
    }

    func observeTodos() async {
        while !Task.isCancelled {
            if connected, !isBusy, let bridge {
                let expected = currentDevice
                if let response = try? await bridge.request("/v1/todos/local", method: "GET", timeout: 3),
                   !Task.isCancelled, currentDevice == expected, let rows = response["items"] as? [[String: Any]] {
                    applyTodos(rows, owned: Set(response["ownedEventIDs"] as? [String] ?? []))
                }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    private func applyTodos(_ rows: [[String: Any]], owned: Set<String>) {
        let next = rows.compactMap { row -> HomeTodo? in
            guard (row["eventType"] as? Int) == 1, let id = (row["eventID"] as? NSNumber)?.stringValue,
                  let title = row["title"] as? String else { return nil }
            return HomeTodo(id: id, title: title, important: row["isImportant"] as? Bool ?? false,
                status: row["status"] as? Int ?? 0, owned: owned.contains(id), syncState: row["syncState"] as? String ?? "confirmed_by_readback")
        }
        if next != todos { todos = next }
    }

    func definitions() async -> [AssistantToolDefinition] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [], mutating: Bool = false) -> AssistantToolDefinition {
            let schema: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
            return AssistantToolDefinition(name: name, description: description,
                parametersJSON: String(decoding: try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self), isMutating: mutating)
        }
        let string: [String: Any] = ["type": "string"], boolean: [String: Any] = ["type": "boolean"], integer: [String: Any] = ["type": "integer"]
        let recurrence: [String: Any] = ["type": "object", "properties": [
            "frequency": ["type": "string", "enum": ["none", "daily", "weekly", "monthly", "yearly"]],
            "interval": ["type": "integer", "minimum": 1],
            "days_of_week": ["type": "array", "description": "仅周/月/年重复；1=周日…7=周六。工作日用weekly。", "items": ["type": "integer", "minimum": 1, "maximum": 7]],
            "days_of_month": ["type": "array", "description": "仅月重复。", "items": ["type": "integer", "minimum": 1, "maximum": 31]],
            "months_of_year": ["type": "array", "description": "仅年重复。", "items": ["type": "integer", "minimum": 1, "maximum": 12]]
        ], "required": ["frequency"], "additionalProperties": false]
        let scope: [String: Any] = ["type": "string", "enum": ["this", "future"]]
        return [
            tool("home_read", "读取眼镜现有首页配置、已配置天气城市槽和待办，不修改布局。待办sync_state为outcome_unknown时，仅表示本机已发出请求，不能宣称眼镜已确认。", [:]),
            tool("todo_add", "新增待办，保留眼镜已有待办；支持重要标记。", ["title": string, "important": boolean], required: ["title"], mutating: true),
            tool("todo_update", "修改待办标题、重要标记或完成状态；completed=true完成，false撤销完成。event_id必须来自home_read。", ["event_id": string, "title": string, "important": boolean, "completed": boolean], required: ["event_id"], mutating: true),
            tool("todo_delete", "删除待办；event_id必须来自home_read，不能用列表位置替代。", ["event_id": string], required: ["event_id"], mutating: true),
            tool("schedule_read", "读取眼镜独立日程及用户已选择Mac日历今天/明天的事件，提供event_id/source/writable/Unix秒。不读取未选日历；缺系统授权会明确返回。", [:]),
            tool("schedule_add", "按用户已配置来源添加日程：默认仅眼镜，启用系统来源时写所选可写Mac日历。不得自行切来源。Unix秒；系统来源可用location/notes/all_day/recurrence，全天end_time是排他结束日。星期1=周日…7=周六。系统保存成功但眼镜未同步为partial，不能宣称全成功。", ["title": string, "start_time": integer, "end_time": integer, "location": string, "notes": string, "all_day": boolean, "recurrence": recurrence], required: ["title", "start_time", "end_time"], mutating: true),
            tool("schedule_update", "修改schedule_read取得的event_id。系统映射项写回原系统日历；其余只写眼镜。系统项可改location/notes/all_day/recurrence；省略recurrence保留原规则和提醒。scope默认this仅本次，只有用户明确要求时用future修改本次及以后。Unix秒。", ["event_id": string, "title": string, "start_time": integer, "end_time": integer, "location": string, "notes": string, "all_day": boolean, "recurrence": recurrence, "scope": scope], required: ["event_id"], mutating: true),
            tool("schedule_delete", "删除用户明确指定的event_id。系统映射项会删除原系统日历事件，不能因眼镜列表缺项而删除。scope默认this；明确要求才用future删除本次及以后。", ["event_id": string, "scope": scope], required: ["event_id"], mutating: true),
            tool("weather_search_cities", "搜索城市，返回精确city_id、行政区和坐标；重名时据上下文选择。", ["query": string], required: ["query"]),
            tool("weather_get", "从Open-Meteo获取当前、逐小时和未来7日天气。city_id来自城市搜索；省略则用已选择城市。date可指定城市当地YYYY-MM-DD。", ["city_id": integer, "date": string]),
            tool("weather_select_city", "选择要同步的天气城市。city_id来自搜索；glasses_city_id可指定替换已有城市，省略则新增。", ["glasses_city_id": string, "city_id": integer], required: ["city_id"], mutating: true),
            tool("weather_remove_city", "从Mac待同步城市列表移除城市。保留城市时可随后weather_push更新眼镜；移除最后一个城市暂不清空眼镜。", ["glasses_city_id": string], required: ["glasses_city_id"], mutating: true),
            tool("weather_push", "刷新并把Mac所选城市天气推送到眼镜城市卡，替换城市卡列表。当前位置天气由Mac定位独立管理。", [:], mutating: true),
            tool("weather_auto_refresh", "开关Mac运行期间的30分钟天气刷新推送；离线不写眼镜。", ["enabled": boolean], required: ["enabled"], mutating: true)
        ]
    }

    func context() async -> String {
        (try? json(["deviceConnected": connected, "selectedWeatherSlot": selectedSlot,
            "weatherCities": bindings.map { ["glasses_city_id": $0.id, "city_id": $0.city.id, "city": $0.city.label] as [String: Any] },
            "lastAction": notice, "calendar": bridge?.calendarSync.assistantContext ?? [:],
            "dateRule": "天气日期使用城市当地时区，日程输入输出是Unix秒。工具结果才是实际操作事实。" ])) ?? "首页状态暂不可用"
    }

    func execute(_ call: AssistantToolCall) async throws -> String {
        try await busy {
            let definitions = await definitions()
            guard let definition = definitions.first(where: { $0.name == call.name }),
                  let data = call.arguments.data(using: .utf8), let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HomeContentFailure("未知工具或无效JSON参数")
            }
            let canonical = try json(arguments), key = currentDevice + "/" + call.id
            if definition.isMutating {
                if let old = saved.invocations[key] {
                    guard old.name == call.name, old.arguments == canonical else { throw HomeContentFailure("相同工具调用ID不能用于不同操作") }
                    if let result = old.result { return result }
                    return try json(["action": call.name, "status": "pending_or_unknown", "executedAgain": false,
                        "message": "该调用已登记，未重新执行；请先读取状态"])
                }
                saved.invocations[key] = Invocation(name: call.name, arguments: canonical)
                try persist()
            }
            do {
                let result = try await dispatch(call, arguments: arguments)
                if definition.isMutating { saved.invocations[key]?.result = result; try persist() }
                error = nil
                return result
            } catch {
                if definition.isMutating {
                    saved.invocations[key]?.result = try? json(["action": call.name, "status": "failed_or_outcome_unknown",
                        "executedAgain": false, "message": error.localizedDescription, "nextStep": "读取状态，不盲目重试同一写入"])
                    try? persist()
                }
                self.error = error.localizedDescription
                throw error
            }
        }
    }

    private func dispatch(_ call: AssistantToolCall, arguments a: [String: Any]) async throws -> String {
        func text(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HomeContentFailure("缺少\(key)") }
            return value
        }
        switch call.name {
        case "home_read":
            try await readDashboard(); try await readTodos()
            return try json(["action": "read", "status": "read", "configuredCityIDs": configuredCityIDs,
                "todos": todos.map { ["event_id": $0.id, "title": $0.title, "important": $0.important, "status": $0.status,
                    "owned": $0.owned, "sync_state": $0.syncState] as [String: Any] },
                "schedule": "使用schedule_read读取日程"])
        case "schedule_read", "schedule_add", "schedule_update", "schedule_delete":
            guard let bridge else { throw HomeContentFailure("本地服务不可用") }
            let calendar = bridge.calendarSync
            if call.name == "schedule_read" {
                let system = calendar.readForAssistant()
                var items = system["items"] as? [[String: Any]] ?? []
                var glassesState = "disconnected"
                if connected {
                    do {
                        let response = try await onDevice { try await $0.request("/v1/schedules", method: "GET") }
                        for var item in response["items"] as? [[String: Any]] ?? [] {
                            guard let id = (item["eventID"] as? NSNumber)?.stringValue, !calendar.isSystemMapped(id) else { continue }
                            item["event_id"] = id; item["source"] = "glasses"; item["writable"] = true
                            item["start_time"] = item["startTime"]; item["end_time"] = item["endTime"]
                            items.append(item)
                        }
                        glassesState = "read"
                    } catch { glassesState = "failed: " + error.localizedDescription }
                }
                notice = "已读取所选来源日程；系统日历状态：\(system["status"] as? String ?? "unknown")，眼镜：\(glassesState)"
                return try json(["action": call.name, "status": glassesState == "read" && system["status"] as? String == "read" ? "read" : "partial",
                    "items": items, "system_calendar_status": system["status"] as? String ?? "unknown", "glasses_status": glassesState,
                    "calendar_context": calendar.assistantContext, "message": notice])
            }
            let systemMapped = (a["event_id"] as? String).map(calendar.isSystemMapped) == true
            if (call.name == "schedule_add" && calendar.voiceUsesSystemCalendar) || systemMapped {
                let result = try await calendar.executeAssistantSchedule(call.name, arguments: a)
                notice = result["message"] as? String ?? "系统日历操作已处理"
                return try json(result)
            }
            if a["recurrence"] != nil || a["notes"] != nil || a["location"] != nil || a["all_day"] != nil || a["scope"] as? String == "future" {
                return try json(["action": call.name, "status": "unsupported_for_glasses_source", "executed": false, "write_target": "glasses",
                    "message": "仅眼镜来源目前支持标题与起止时间；复杂日程请先在Mac页面明确启用系统日历来源，未自行改投。"])
            }
            var body: [String: Any] = [:]
            let path: String, method: String
            switch call.name {
            case "schedule_read": path = "/v1/schedules"; method = "GET"
            case "schedule_add": path = "/v1/schedules"; method = "POST"
            default:
                path = "/v1/schedules/\(try text("event_id"))"
                method = call.name == "schedule_delete" ? "DELETE" : "PATCH"
            }
            if let title = a["title"] as? String { body["title"] = title }
            if let start = a["start_time"] as? NSNumber { body["startTime"] = start }
            if let end = a["end_time"] as? NSNumber { body["endTime"] = end }
            var result = try await onDevice { try await $0.request(path, method: method, body: body) }
            let id = result["eventID"] as? String ?? a["event_id"] as? String ?? ""
            let rows = result["items"] as? [[String: Any]] ?? []
            let found = rows.first { ($0["eventID"] as? NSNumber)?.stringValue == id }
            let confirmed = call.name == "schedule_delete" ? found == nil : found.map { row in
                body.allSatisfy { key, value in
                    if let value = value as? String { return row[key] as? String == value }
                    return row[key] as? NSNumber == value as? NSNumber
                }
            } == true
            result["event_id"] = id; result["write_target"] = "glasses"; result["system_write_succeeded"] = false
            result["glasses_synced"] = confirmed; result["status"] = confirmed ? "confirmed_by_readback" : "outcome_unknown"
            notice = confirmed ? "眼镜日程已读回核对；未写系统日历" : "眼镜日程已发送，读回尚未确认；未自动重试"
            return try json(result)
        case "todo_add", "todo_update", "todo_delete":
            var body: [String: Any] = ["requestID": call.id]
            let path: String, method: String
            if call.name == "todo_add" { body["title"] = try text("title"); path = "/v1/todos"; method = "POST" }
            else {
                let id = try text("event_id")
                guard Int64(id) != nil else { throw HomeContentFailure("待办ID必须是读取所得的整数") }
                path = "/v1/todos/\(id)"; method = call.name == "todo_update" ? "PATCH" : "DELETE"
                if a["title"] != nil { body["title"] = try text("title") }
            }
            if let important = a["important"] as? Bool { body["important"] = important }
            if let completed = a["completed"] as? Bool { body["completed"] = completed }
            let result = try await onDevice { try await $0.request(path, method: method, body: body) }
            notice = result["readBack"] as? Bool == true ? "待办操作已读回核对" : "待办操作结果未知，请刷新读取，未自动重试"
            try? await readTodos()
            return try json(result)
        case "weather_search_cities":
            cityResults = try await service.search(text("query"))
            return try json(["source": "Open-Meteo / GeoNames", "results": cityResults.map {
                ["city_id": $0.id, "name": $0.label, "latitude": $0.latitude, "longitude": $0.longitude, "timezone": $0.timezone] as [String: Any]
            }])
        case "weather_get":
            let city = try await resolveCity(a["city_id"] as? Int)
            let snapshot = try await service.forecast(city); weather[city.id] = snapshot
            if let date = a["date"] as? String, !snapshot.daily.contains(where: { snapshot.formatted($0.time, pattern: "yyyy-MM-dd") == date }) {
                throw HomeContentFailure("请求日期不在当前7日预报内")
            }
            notice = "已获取\(city.name)天气，尚未推送眼镜"
            return try json(snapshot.result(date: a["date"] as? String))
        case "weather_select_city":
            let expected = currentDevice
            guard let id = a["city_id"] as? Int else { throw HomeContentFailure("缺少城市搜索返回的city_id") }
            let slot = a["glasses_city_id"] as? String ?? String(id)
            let city = try await resolveCity(id)
            guard currentDevice == expected else { throw HomeContentFailure("设备已切换，未保存天气设置") }
            bindings.removeAll { $0.id == slot }; bindings.append(HomeWeatherBinding(id: slot, city: city)); selectedSlot = slot
            try saveSettings()
            notice = "已绑定\(city.label)，尚未更新眼镜天气"
            return try json(["action": "select_weather_city", "status": "configured_locally", "glasses_city_id": slot, "city": city.label])
        case "weather_remove_city":
            let slot = try text("glasses_city_id")
            bindings.removeAll { $0.id == slot }
            if selectedSlot == slot { selectedSlot = bindings.first?.id ?? "" }
            try saveSettings()
            notice = bindings.isEmpty ? "本地城市已移除；眼镜保留原城市卡，待选择新城市后更新" : "本地城市已移除，更新城市卡后同步眼镜"
            return try json(["status": "removed_locally", "glasses_city_id": slot])
        case "weather_push": return try await pushWeather()
        case "weather_auto_refresh":
            guard let enabled = a["enabled"] as? Bool else { throw HomeContentFailure("缺少enabled") }
            refreshEnabled = enabled; try saveSettings(); armRefresh()
            notice = enabled ? "已开启每30分钟天气刷新，Mac需保持运行并连接眼镜" : "已关闭自动天气刷新"
            return try json(["action": "weather_auto_refresh", "status": "configured_locally", "enabled": enabled, "intervalSeconds": 1800])
        default: throw HomeContentFailure("未知工具")
        }
    }

    private func resolveCity(_ id: Int?) async throws -> HomeCity {
        if let id {
            if let city = (cityResults + bindings.map(\.city)).first(where: { $0.id == id }) { return city }
            return try await service.city(id: id)
        }
        guard let binding = bindings.first(where: { $0.id == selectedSlot }) ?? bindings.first else { throw HomeContentFailure("尚未选择天气城市，请先搜索城市") }
        return binding.city
    }

    private func pushWeather() async throws -> String {
        let expected = currentDevice
        guard !bindings.isEmpty else { throw HomeContentFailure("先选择要同步的城市") }
        let selected = bindings
        let chosenSlot = selectedSlot
        var snapshots: [String: HomeWeatherSnapshot] = [:]
        // Fetches happen without holding the device-operation gate or Bluetooth operation lock.
        for binding in selected { snapshots[binding.id] = try await service.forecast(binding.city) }
        guard currentDevice == expected else { throw HomeContentFailure("设备已切换，未推送天气") }
        for value in snapshots.values { weather[value.city.id] = value }
        func icon(_ code: Int, _ day: Bool) -> Int { HomeWeatherCodes.glassesIcon(code, isDay: day) }
        let cards: [[String: Any]] = selected.map { binding in
            let snapshot = snapshots[binding.id]!
            let hours = snapshot.upcomingHours.prefix(5)
            let daily = snapshot.daily.first
            return ["location": snapshot.city.name, "location_id": binding.id, "temp": Int(snapshot.temperature.rounded()),
                "icon": icon(snapshot.code, snapshot.isDay), "des": HomeWeatherCodes.description(snapshot.code),
                "temp_range": daily.map { "\(Int($0.maximum.rounded()))°/\(Int($0.minimum.rounded()))°" } ?? "",
                "hourly": hours.map { ["time": snapshot.formatted($0.time, pattern: "ha").lowercased(),
                    "temp": Int($0.temperature.rounded()), "icon": icon($0.code, $0.isDay)] as [String: Any] }]
        }
        let results = try await onDevice { bridge -> [[String: Any]] in
            guard self.selectedSlot == chosenSlot, self.bindings.count == selected.count,
                  zip(self.bindings, selected).allSatisfy({ $0.id == $1.id && $0.city == $1.city }) else {
                throw HomeContentFailure("天气城市配置在获取期间改变，未推送旧城市结果")
            }
            return [try await bridge.request("/v1/weather/cities", body: ["cities": cards])]
        }
        let acknowledged = results.allSatisfy { $0["acknowledged"] as? Bool == true }
        notice = acknowledged ? "城市天气已写出并收到协议应答，显示仍需核对" : "城市天气已写出，协议应答未收到；未自动重试"
        return try json(["action": "push_weather", "status": acknowledged ? "acknowledged" : "outcome_unknown",
            "readBack": false, "visible": "unverified", "source": "Open-Meteo", "areas": ["cities"], "results": results])
    }

    private func armRefresh() {
        guard refreshEnabled else {
            refreshTask?.cancel(); refreshTask = nil
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_800_000_000_000) } catch { return }
                guard let self else { return }
                if self.connected {
                    do { _ = try await self.execute(AssistantToolCall(id: "timer-\(UUID().uuidString)", name: "weather_push", arguments: "{}")) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func manual(_ name: String, _ arguments: [String: Any]) async {
        do { _ = try await execute(AssistantToolCall(id: "manual-\(UUID().uuidString)", name: name, arguments: json(arguments))) }
        catch { self.error = error.localizedDescription }
    }
    func addTodo() async { await manual("todo_add", ["title": newTodoTitle, "important": newTodoImportant]); if error == nil { newTodoTitle = "" } }
    func edit(_ todo: HomeTodo) { editingTodoID = todo.id; editingTodoTitle = todo.title; editingTodoImportant = todo.important }
    func saveTodo() async {
        guard let id = editingTodoID else { return }
        await manual("todo_update", ["event_id": id, "title": editingTodoTitle, "important": editingTodoImportant])
        if error == nil { editingTodoID = nil }
    }
    func deleteTodo(_ todo: HomeTodo) async { await manual("todo_delete", ["event_id": todo.id]) }
    func toggleTodo(_ todo: HomeTodo) async { await manual("todo_update", ["event_id": todo.id, "completed": todo.status != 1]) }
    func searchCities() async { await manual("weather_search_cities", ["query": cityQuery]) }
    func bind(_ city: HomeCity) async { await manual("weather_select_city", ["glasses_city_id": selectedSlot, "city_id": city.id]) }
    func addCity(_ city: HomeCity) async { await manual("weather_select_city", ["city_id": city.id]) }
    func removeCity(_ id: String) async { await manual("weather_remove_city", ["glasses_city_id": id]) }
    func fetchWeather() async { await manual("weather_get", [:]) }
    func previewWeather(_ city: HomeCity) async { await manual("weather_get", ["city_id": city.id]) }
    func publishWeather() async { await manual("weather_push", [:]) }
    func synchronizeWeatherCard() async throws { _ = try await busy { try await pushWeather() } }
    func setRefresh(_ enabled: Bool) async { await manual("weather_auto_refresh", ["enabled": enabled]) }
}
