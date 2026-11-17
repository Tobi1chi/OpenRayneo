// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import AppKit
import EventKit
import SwiftUI

struct MacCalendarEvent: Identifiable {
    let id: String
    let title: String
    let calendarTitle: String
    let start: Date
    let end: Date
    let allDay: Bool
    let writable: Bool
    let repeating: Bool
}

enum CalendarRepeatChoice: String, CaseIterable, Identifiable {
    case keep, none, daily, weekly, monthly, yearly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: return "保留现有重复规则"
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }
    var frequency: EKRecurrenceFrequency? {
        switch self {
        case .keep, .none: return nil
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }
}

struct CalendarGlassesSyncOutcome {
    let state: String
    let count: Int
    let message: String
    var confirmed: Bool { state == "confirmed_by_readback" }
}

@MainActor
final class CalendarSyncModel: ObservableObject {
    private let store = EKEventStore()
    private weak var bridge: DesktopBridge?
    private var subscriptions = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    @Published var calendars: [EKCalendar] = []
    @Published var selected = Set<String>() {
        didSet { defaults.set(Array(selected), forKey: "calendarSelection"); requestAutomaticSync() }
    }
    @Published var automatic = false {
        didSet {
            defaults.set(automatic, forKey: "calendarAutomaticSync")
            if automatic { requestAutomaticSync() }
            else { automaticTask?.cancel(); automaticTask = nil; pendingAutomaticSync = false }
        }
    }
    @Published var busy = false
    @Published var notice = "选择 Mac 日历，将今天及明天的日程同步到眼镜。"
    @Published var events: [MacCalendarEvent] = []
    @Published var writeCalendarID = "" {
        didSet { defaults.set(writeCalendarID, forKey: "calendarWriteTarget") }
    }
    @Published var editingEventID: String?
    @Published var eventTitle = ""
    @Published var eventLocation = ""
    @Published var eventNotes = ""
    @Published var eventStart = Date().addingTimeInterval(3600)
    @Published var eventEnd = Date().addingTimeInterval(7200)
    @Published var eventAllDay = false
    @Published var repeatChoice = CalendarRepeatChoice.none
    @Published var repeatInterval = 1
    @Published var repeatWeekdays = Set<Int>()
    @Published var repeatMonthDays = Set<Int>()
    @Published var repeatMonths = Set<Int>()
    @Published var voiceUsesSystemCalendar = false {
        didSet { defaults.set(voiceUsesSystemCalendar, forKey: "calendarVoiceUsesSystemCalendar") }
    }
    @Published var futureOccurrences = false
    @Published var deleteTarget: MacCalendarEvent?
    private var eventObjects: [String: EKEvent] = [:]
    private var mapping: [String: String]
    private var automaticTask: Task<Void, Never>?
    private var pendingAutomaticSync = false
    private var windowStart = Calendar.current.startOfDay(for: Date())
    private var windowTimeZone = TimeZone.current.identifier
    private var windowOffset = TimeZone.current.secondsFromGMT()
    init(bridge: DesktopBridge) {
        self.bridge = bridge
        mapping = defaults.dictionary(forKey: "calendarEventMapping") as? [String: String] ?? [:]
        selected = Set(defaults.stringArray(forKey: "calendarSelection") ?? [])
        automatic = defaults.bool(forKey: "calendarAutomaticSync")
        writeCalendarID = defaults.string(forKey: "calendarWriteTarget") ?? ""
        voiceUsesSystemCalendar = defaults.bool(forKey: "calendarVoiceUsesSystemCalendar")
        if canReadEvents { calendars = store.calendars(for: .event) }
        NotificationCenter.default.publisher(for: .EKEventStoreChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if canReadEvents { calendars = store.calendars(for: .event) }
                requestAutomaticSync()
            }
        }.store(in: &subscriptions)
        bridge.$connected.dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in if connected { self?.requestAutomaticSync() } }
        }.store(in: &subscriptions)
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkSyncWindow() }
            }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSyncWindow() }
        }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSyncWindow() }
        }.store(in: &subscriptions)
        requestAutomaticSync()
    }
    var connected: Bool { bridge?.connected == true }
    var writableCalendars: [EKCalendar] { calendars.filter { selected.contains($0.calendarIdentifier) && $0.allowsContentModifications } }
    var canSelectVoiceSystemCalendar: Bool { writableCalendars.contains { $0.calendarIdentifier == writeCalendarID } }
    var editingEvent: MacCalendarEvent? { events.first { $0.id == editingEventID } }
    var canSaveEvent: Bool {
        canReadEvents && !busy && !eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (eventAllDay ? Calendar.current.startOfDay(for: eventEnd) >= Calendar.current.startOfDay(for: eventStart) : eventEnd > eventStart) &&
            (editingEventID == nil ? writableCalendars.contains { $0.calendarIdentifier == writeCalendarID } :
                editingEventID.flatMap { eventObjects[$0] }.map { $0.calendar.allowsContentModifications && selected.contains($0.calendar.calendarIdentifier) } == true)
    }

    func authorize() async {
        do {
            let granted: Bool
            if #available(macOS 14, *) { granted = try await store.requestFullAccessToEvents() }
            else { granted = try await store.requestAccess(to: .event) }
            if granted { calendars = store.calendars(for: .event); notice = "选择要同步的日历。"; requestAutomaticSync() }
            else { notice = "请在系统设置中允许日历访问。" }
        } catch { notice = error.localizedDescription }
    }

    @discardableResult
    func synchronize() async -> CalendarGlassesSyncOutcome {
        guard let bridge, connected else { return .init(state: "disconnected", count: 0, message: "眼镜未连接") }
        guard !busy else { return .init(state: "busy", count: 0, message: "日历操作正在进行") }
        guard canReadEvents else {
            notice = "请先读取 Mac 日历并允许完整日历访问。"
            return .init(state: "authorization_required", count: 0, message: notice)
        }
        busy = true
        defer {
            busy = false
            if pendingAutomaticSync { pendingAutomaticSync = false; requestAutomaticSync() }
        }
        do {
            calendars = store.calendars(for: .event)
            let events = selectedEvents()
            publishEvents(events)
            let device = bridge.selectedAddress
            let previous = defaults.stringArray(forKey: "calendarImportedIDs.\(device)") ?? []
            var nextID = Int64(Date().timeIntervalSince1970 * 1000)
            let used = Set(mapping.values)
            var items: [[String: Any]] = []
            for event in events {
                let key = mappingKey(for: event)
                if mapping[key] == nil {
                    while used.contains(String(nextID)) { nextID += 1 }
                    mapping[key] = String(nextID); nextID += 1
                }
                var item: [String: Any] = ["eventID": Int64(mapping[key]!)!, "title": event.title ?? "无标题日程",
                    "startTime": Int64(event.startDate.timeIntervalSince1970), "endTime": Int64(event.endDate.timeIntervalSince1970),
                    "localTimeOffset": (event.timeZone ?? TimeZone.current).secondsFromGMT(for: event.startDate)]
                if let location = event.location { item["location"] = location }
                items.append(item)
            }
            defaults.set(mapping, forKey: "calendarEventMapping")
            defaults.set(Array(selected), forKey: "calendarSelection")
            let ids = items.compactMap { ($0["eventID"] as? Int64).map(String.init) }
            // Keep intended IDs before sending so a later refresh reconciles a lost response.
            defaults.set(Array(Set(previous + ids)), forKey: "calendarImportedIDs.\(device)")
            let response = try await bridge.request("/v1/schedules/import", body: ["replaceEventIDs": previous, "items": items])
            guard bridge.selectedAddress == device else { throw calendarError("同步期间眼镜目标已变化，请读取对应设备状态；未自动重试。") }
            let readBack = response["items"] as? [[String: Any]] ?? []
            let observedIDs = Set(readBack.compactMap { ($0["eventID"] as? NSNumber)?.stringValue })
            let confirmed = response["items"] is [[String: Any]] && items.allSatisfy { expected in
                readBack.contains { actual in
                    (actual["eventID"] as? NSNumber) == (expected["eventID"] as? NSNumber) &&
                    (actual["title"] as? String) == (expected["title"] as? String) &&
                    (actual["startTime"] as? NSNumber) == (expected["startTime"] as? NSNumber) &&
                    (actual["endTime"] as? NSNumber) == (expected["endTime"] as? NSNumber)
                }
            } && Set(previous).subtracting(ids).isDisjoint(with: observedIDs)
            if confirmed { defaults.set(ids, forKey: "calendarImportedIDs.\(device)") }
            await bridge.schedules.refresh()
            notice = confirmed ? "已同步 \(items.count) 个日程，保留其他眼镜日程。" : "已发送日历同步，眼镜读回尚未完全确认；未自动重试。"
            return .init(state: confirmed ? "confirmed_by_readback" : "outcome_unknown", count: items.count, message: notice)
        } catch {
            notice = error.localizedDescription
            return .init(state: "failed_or_outcome_unknown", count: 0, message: notice)
        }
    }

    func reloadEvents() {
        guard canReadEvents else { notice = "请先点击“读取 Mac 日历”并允许完整日历访问。"; return }
        calendars = store.calendars(for: .event)
        publishEvents(selectedEvents())
        notice = "已读取所选日历今天及明天的 \(events.count) 个日程。"
    }

    func beginNewEvent() {
        editingEventID = nil; eventTitle = ""; eventLocation = ""; eventNotes = ""
        eventStart = Date().addingTimeInterval(3600); eventEnd = eventStart.addingTimeInterval(3600)
        eventAllDay = false; repeatChoice = .none; repeatInterval = 1; futureOccurrences = false
        repeatWeekdays = []; repeatMonthDays = []; repeatMonths = []
    }

    func editEvent(_ row: MacCalendarEvent) {
        guard row.writable, let event = eventObjects[row.id] else { return }
        editingEventID = row.id; eventTitle = event.title ?? ""; eventLocation = event.location ?? ""; eventNotes = event.notes ?? ""
        eventStart = event.startDate
        eventEnd = event.isAllDay ? Calendar.current.date(byAdding: .day, value: -1, to: event.endDate)! : event.endDate
        eventAllDay = event.isAllDay
        repeatChoice = .keep; repeatInterval = event.recurrenceRules?.first?.interval ?? 1; futureOccurrences = false
        let rule = event.recurrenceRules?.first
        repeatWeekdays = Set(rule?.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } ?? [])
        repeatMonthDays = Set(rule?.daysOfTheMonth?.map(\.intValue) ?? [])
        repeatMonths = Set(rule?.monthsOfTheYear?.map(\.intValue) ?? [])
    }

    func isSystemMapped(_ glassesID: String) -> Bool { mapping.values.contains(glassesID) }

    func editGlassesSchedule(_ glassesID: String) {
        reloadEvents()
        guard let row = events.first(where: { row in
            eventObjects[row.id].map { mapping[mappingKey(for: $0)] == glassesID } == true
        }) else { notice = "该项目来自系统日历；请在所选来源或 Mac 日历 App 中找到原日程后编辑。"; return }
        if row.writable { editEvent(row); notice = "请在系统日历编辑区修改“\(row.title)”。" }
        else { notice = "“\(row.calendarTitle)”为只读日历，无法修改这条日程。" }
    }

    func saveEvent() async {
        guard canSaveEvent else { return }
        busy = true
        var modifiedEvent: EKEvent?
        do {
            let event: EKEvent
            let previousKey: String?
            if let editingEventID {
                guard let existing = eventObjects[editingEventID], existing.refresh(), existing.calendar.allowsContentModifications,
                      selected.contains(existing.calendar.calendarIdentifier) else { throw calendarError("原日历不再可写或已取消选择，请重新读取。") }
                event = existing; previousKey = mappingKey(for: existing)
            } else {
                guard let calendar = writableCalendars.first(where: { $0.calendarIdentifier == writeCalendarID }) else {
                    throw calendarError("请选择一个可写的 Mac 日历。")
                }
                event = EKEvent(eventStore: store); event.calendar = calendar; previousKey = nil
            }
            modifiedEvent = event
            event.title = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            event.location = eventLocation; event.notes = eventNotes
            event.isAllDay = eventAllDay
            event.startDate = eventAllDay ? Calendar.current.startOfDay(for: eventStart) : eventStart
            if eventAllDay {
                let lastDay = Calendar.current.startOfDay(for: eventEnd)
                event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: lastDay)!
            } else { event.endDate = eventEnd }
            if event.timeZone == nil { event.timeZone = .current }
            if repeatChoice != .keep {
                event.recurrenceRules = repeatChoice.frequency.map {
                    [recurrenceRule(frequency: $0, interval: repeatInterval, weekdays: repeatWeekdays,
                        monthDays: repeatMonthDays, months: repeatMonths)]
                } ?? []
            }
            // Alarms, attendees and unedited recurrence rules remain on the original EKEvent.
            try store.save(event, span: futureOccurrences ? .futureEvents : .thisEvent, commit: true)
            if let previousKey, let mappedID = mapping[previousKey] { mapping[mappingKey(for: event)] = mappedID }
            defaults.set(mapping, forKey: "calendarEventMapping")
            busy = false; beginNewEvent()
            await synchronizeAfterWrite("已写入 Mac 日历")
        } catch { modifiedEvent?.rollback(); busy = false; notice = "系统日历保存失败：\(error.localizedDescription)" }
    }

    func deleteEvent(_ row: MacCalendarEvent) async {
        guard canReadEvents, !busy, row.writable, let event = eventObjects[row.id],
              selected.contains(event.calendar.calendarIdentifier), event.calendar.allowsContentModifications else { return }
        busy = true
        do {
            guard event.refresh() else { throw calendarError("原日历事件已失效，请重新读取后再删除。") }
            try store.remove(event, span: futureOccurrences ? .futureEvents : .thisEvent, commit: true)
            deleteTarget = nil; busy = false; beginNewEvent()
            await synchronizeAfterWrite("已从 Mac 日历删除")
        } catch { busy = false; notice = "系统日历删除失败：\(error.localizedDescription)" }
    }

    private func synchronizeAfterWrite(_ message: String) async {
        publishEvents(selectedEvents())
        if connected { await synchronize(); notice = message + "。" + notice }
        else { notice = message + "；眼镜未连接，连接后请同步日历。" }
    }

    private func selectedEvents() -> [EKEvent] {
        let sources = calendars.filter { selected.contains($0.calendarIdentifier) }
        guard !sources.isEmpty else { return [] }
        let day = Calendar.current.startOfDay(for: Date())
        let until = Calendar.current.date(byAdding: .day, value: 2, to: day)!
        return store.events(matching: store.predicateForEvents(withStart: day, end: until, calendars: sources)).sorted { $0.startDate < $1.startDate }
    }

    private func publishEvents(_ source: [EKEvent]) {
        eventObjects = [:]
        events = source.map { event in
            let key = mappingKey(for: event)
            eventObjects[key] = event
            return MacCalendarEvent(id: key, title: event.title ?? "无标题日程", calendarTitle: event.calendar.title,
                start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                writable: event.calendar.allowsContentModifications, repeating: event.hasRecurrenceRules || event.isDetached)
        }
    }

    private func mappingKey(for event: EKEvent) -> String {
        let prefix = "\(event.calendar.calendarIdentifier):\(event.calendarItemIdentifier):"
        let legacy = prefix + String(Int(event.startDate.timeIntervalSince1970))
        let key = prefix + ((event.hasRecurrenceRules || event.isDetached) ? String(Int((event.occurrenceDate ?? event.startDate).timeIntervalSince1970)) : "single")
        if mapping[key] == nil, let existing = mapping[legacy] { mapping[key] = existing }
        return key
    }

    private func recurrenceRule(frequency: EKRecurrenceFrequency, interval: Int, weekdays: Set<Int>, monthDays: Set<Int>, months: Set<Int>) -> EKRecurrenceRule {
        let days = weekdays.sorted().compactMap(EKWeekday.init(rawValue:)).map { EKRecurrenceDayOfWeek($0) }
        let dates = monthDays.sorted().map(NSNumber.init(value:))
        let yearMonths = months.sorted().map(NSNumber.init(value:))
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
            daysOfTheWeek: frequency == .daily || days.isEmpty ? nil : days,
            daysOfTheMonth: frequency == .monthly ? (dates.isEmpty ? nil : dates) : nil,
            monthsOfTheYear: frequency == .yearly ? (yearMonths.isEmpty ? nil : yearMonths) : nil,
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
    }

    private func glassesID(for event: EKEvent) -> String {
        let key = mappingKey(for: event)
        if let id = mapping[key] { return id }
        var next = Int64(Date().timeIntervalSince1970 * 1000)
        let used = Set(mapping.values)
        while used.contains(String(next)) { next += 1 }
        let id = String(next); mapping[key] = id
        return id
    }

    var assistantContext: [String: Any] {
        let target = writableCalendars.first { $0.calendarIdentifier == writeCalendarID }
        return ["new_schedule_source": voiceUsesSystemCalendar ? "system_calendar" : "glasses",
            "system_calendar_access": canReadEvents ? "full_access" : "authorization_required",
            "selected_calendars": calendars.filter { selected.contains($0.calendarIdentifier) }.map {
                ["id": $0.calendarIdentifier, "title": $0.title, "writable": $0.allowsContentModifications] as [String: Any]
            },
            "write_calendar": target.map { ["id": $0.calendarIdentifier, "title": $0.title] } as Any? ?? NSNull(),
            "sync_window": "今天及明天；仅已选择来源。眼镜缺项不授权删除系统事件。"]
    }

    func readForAssistant() -> [String: Any] {
        guard canReadEvents else {
            return ["status": "authorization_required", "items": [], "message": "系统日历需要用户在Mac页面点击读取并授予完整访问；未弹出授权。"]
        }
        calendars = store.calendars(for: .event)
        let source = selectedEvents()
        publishEvents(source)
        let items: [[String: Any]] = source.map { event in
            ["event_id": glassesID(for: event), "title": event.title ?? "无标题日程", "source": "system_calendar",
             "calendar": event.calendar.title, "calendar_id": event.calendar.calendarIdentifier,
             "start_time": Int64(event.startDate.timeIntervalSince1970), "end_time": Int64(event.endDate.timeIntervalSince1970),
             "all_day": event.isAllDay, "repeating": event.hasRecurrenceRules || event.isDetached,
             "writable": event.calendar.allowsContentModifications, "glasses_sync_state": "unverified"]
        }
        defaults.set(mapping, forKey: "calendarEventMapping")
        return ["status": "read", "items": items, "window": "today_and_tomorrow", "selected_sources_only": true]
    }

    /// Called only through HomeContentModel's existing persisted call.id journal.
    func executeAssistantSchedule(_ action: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard canReadEvents else {
            return ["status": "authorization_required", "executed": false, "write_target": "system_calendar",
                "message": "请由用户点击Mac页面的读取日历并授予完整访问；未写入或改投眼镜。"]
        }
        guard !busy else { throw calendarError("系统日历操作正在进行，未执行本次写入。") }
        calendars = store.calendars(for: .event)
        let event: EKEvent
        let oldKey: String?
        if action == "schedule_add" {
            guard let calendar = writableCalendars.first(where: { $0.calendarIdentifier == writeCalendarID }) else {
                return ["status": "configuration_required", "executed": false, "write_target": "system_calendar",
                    "message": "请先明确选择一个可写且已勾选同步的Mac日历；未改投其他来源。"]
            }
            event = EKEvent(eventStore: store); event.calendar = calendar; oldKey = nil
        } else {
            let source = selectedEvents()
            guard let id = arguments["event_id"] as? String,
                  let existing = source.first(where: { mapping[mappingKey(for: $0)] == id }) else {
                return ["status": "not_found_in_selected_sources", "executed": false, "write_target": "system_calendar",
                    "message": "该系统映射事件不在所选日历的今天/明天窗口；请在Mac日历中核对，不会根据眼镜缺项删除系统日历。"]
            }
            guard existing.calendar.allowsContentModifications else {
                return ["status": "read_only", "executed": false, "write_target": "system_calendar", "message": "原日历为只读，未改投其他来源。"]
            }
            event = existing; oldKey = mappingKey(for: existing)
        }
        busy = true
        let calendarTitle = event.calendar.title, calendarID = event.calendar.calendarIdentifier
        let id: String
        do {
            let span: EKSpan = arguments["scope"] as? String == "future" ? .futureEvents : .thisEvent
            if action == "schedule_delete" {
                id = glassesID(for: event)
                try store.remove(event, span: span, commit: true)
            } else {
                if let title = arguments["title"] as? String { event.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let start = arguments["start_time"] as? NSNumber { event.startDate = Date(timeIntervalSince1970: start.doubleValue) }
                if let end = arguments["end_time"] as? NSNumber { event.endDate = Date(timeIntervalSince1970: end.doubleValue) }
                if let location = arguments["location"] as? String { event.location = location }
                if let notes = arguments["notes"] as? String { event.notes = notes }
                if let allDay = arguments["all_day"] as? Bool { event.isAllDay = allDay }
                guard let title = event.title, !title.isEmpty, let start = event.startDate, let end = event.endDate, end > start else {
                    throw calendarError("系统日程需要标题、开始时间和晚于开始的结束时间。")
                }
                if event.timeZone == nil { event.timeZone = .current }
                if let rule = arguments["recurrence"] as? [String: Any] {
                    guard let text = rule["frequency"] as? String, let choice = CalendarRepeatChoice(rawValue: text), choice != .keep else {
                        throw calendarError("重复frequency必须为none/daily/weekly/monthly/yearly。")
                    }
                    let interval = rule["interval"] as? Int ?? 1
                    let weekdays = Set(rule["days_of_week"] as? [Int] ?? [])
                    let monthDays = Set(rule["days_of_month"] as? [Int] ?? [])
                    let months = Set(rule["months_of_year"] as? [Int] ?? [])
                    guard interval > 0, weekdays.allSatisfy({ (1...7).contains($0) }),
                          monthDays.allSatisfy({ (1...31).contains($0) }), months.allSatisfy({ (1...12).contains($0) }) else {
                        throw calendarError("重复间隔与星期/月日/月份超出范围。")
                    }
                    guard (weekdays.isEmpty || [.weekly, .monthly, .yearly].contains(choice)),
                          (monthDays.isEmpty || choice == .monthly), (months.isEmpty || choice == .yearly) else {
                        throw calendarError("Mac日历的星期筛选用于周/月/年重复，月日用于月重复，月份用于年重复；本次未写入，未静默忽略筛选。")
                    }
                    event.recurrenceRules = choice.frequency.map {
                        [recurrenceRule(frequency: $0, interval: interval, weekdays: weekdays, monthDays: monthDays, months: months)]
                    } ?? []
                }
                try store.save(event, span: span, commit: true)
                if let oldKey, let oldID = mapping[oldKey] { mapping[mappingKey(for: event)] = oldID }
                id = glassesID(for: event)
            }
            defaults.set(mapping, forKey: "calendarEventMapping")
        } catch { event.rollback(); busy = false; throw error }
        busy = false
        let source = selectedEvents()
        publishEvents(source)
        let inWindow = action == "schedule_delete" || source.contains { mapping[mappingKey(for: $0)] == id }
        let outcome = await synchronize()
        let synced = outcome.confirmed && inWindow
        notice = "已\(action == "schedule_delete" ? "删除" : "保存")Mac日历“\(calendarTitle)”中的日程；" +
            (synced ? "眼镜已读回确认。" : "眼镜尚未确认同步。")
        return ["action": action, "status": synced ? "completed" : "partial", "event_id": id,
            "write_target": "system_calendar", "calendar": calendarTitle, "calendar_id": calendarID,
            "system_write_succeeded": true, "system_write": action == "schedule_delete" ? "deleted" : "saved",
            "glasses_synced": synced, "glasses_sync_state": inWindow ? outcome.state : "outside_sync_window",
            "message": notice, "sync_message": outcome.message]
    }

    private func calendarError(_ message: String) -> NSError { NSError(domain: "OpenRayneo.Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    private var canReadEvents: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) { return status == .fullAccess }
        return status == .authorized
    }

    private func checkSyncWindow() {
        let start = Calendar.current.startOfDay(for: Date())
        let zone = TimeZone.current.identifier, offset = TimeZone.current.secondsFromGMT()
        guard start != windowStart || zone != windowTimeZone || offset != windowOffset else { return }
        windowStart = start; windowTimeZone = zone; windowOffset = offset
        requestAutomaticSync()
    }

    private func requestAutomaticSync() {
        guard automatic else { return }
        if busy { pendingAutomaticSync = true; return }
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, automatic, connected else { return }
            await synchronize()
        }
    }
}

@MainActor
struct CalendarSyncPanel: View {
    @ObservedObject var model: CalendarSyncModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.notice).font(.callout).foregroundStyle(.secondary)
            Button("读取 Mac 日历") { Task { await model.authorize() } }
            ForEach(model.calendars, id: \.calendarIdentifier) { calendar in
                Toggle("\(calendar.title)（\(calendar.source.title)）\(calendar.allowsContentModifications ? "" : " · 只读")", isOn: Binding(get: { model.selected.contains(calendar.calendarIdentifier) }, set: {
                    if $0 { model.selected.insert(calendar.calendarIdentifier) } else { model.selected.remove(calendar.calendarIdentifier) }
                }))
            }
            if !model.calendars.isEmpty {
                HStack {
                    Toggle("自动同步日历变化与日期切换", isOn: $model.automatic)
                    Button("立即同步") { Task { await model.synchronize() } }.disabled(!model.connected || model.busy)
                }
                HStack {
                    Button("读取所选日历事件") { model.reloadEvents() }.disabled(model.busy)
                    Button("新建系统日历日程") { model.beginNewEvent() }.disabled(model.busy)
                }
                ForEach(model.events) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                            Text("\(event.calendarTitle) · \(event.start.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened))\(event.allDay ? " · 全天" : "")\(event.repeating ? " · 重复日程" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑系统日历") { model.editEvent(event) }.disabled(!event.writable || model.busy)
                        Button(role: .destructive) { model.deleteTarget = event } label: { Image(systemName: "trash") }
                            .disabled(!event.writable || model.busy).help("从 Mac 系统日历删除")
                    }
                }
                Divider()
                Text(model.editingEventID == nil ? "新建到 Mac 日历" : "编辑 Mac 日历日程").font(.headline)
                if let event = model.editingEvent {
                    Text("原日历：\(event.calendarTitle)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("写入日历", selection: $model.writeCalendarID) {
                        Text("请选择可写日历").tag("")
                        ForEach(model.writableCalendars, id: \.calendarIdentifier) { calendar in
                            Text("\(calendar.title)（\(calendar.source.title)）").tag(calendar.calendarIdentifier)
                        }
                    }
                    if model.writableCalendars.isEmpty { Text("先勾选一个可写日历作为同步来源。 ").font(.caption).foregroundStyle(.secondary) }
                }
                TextField("标题", text: $model.eventTitle)
                TextField("地点", text: $model.eventLocation)
                TextField("备注", text: $model.eventNotes, axis: .vertical).lineLimit(2...4)
                Toggle("全天", isOn: $model.eventAllDay)
                DatePicker("开始", selection: $model.eventStart, displayedComponents: model.eventAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker(model.eventAllDay ? "结束日（含当天）" : "结束", selection: $model.eventEnd, displayedComponents: model.eventAllDay ? [.date] : [.date, .hourAndMinute])
                Picker("重复", selection: $model.repeatChoice) {
                    ForEach(CalendarRepeatChoice.allCases.filter { model.editingEventID != nil || $0 != .keep }) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                if model.repeatChoice.frequency != nil {
                    Stepper("重复间隔：\(model.repeatInterval)", value: $model.repeatInterval, in: 1...99)
                    DisclosureGroup("重复日期筛选") {
                        if model.repeatChoice != .daily {
                            repeatSelection("星期（留空按开始日期）", values: Array(1...7), labels: ["日", "一", "二", "三", "四", "五", "六"], selection: $model.repeatWeekdays)
                        }
                        if model.repeatChoice == .monthly {
                            repeatSelection("每月日期（留空按开始日期）", values: Array(1...31), selection: $model.repeatMonthDays)
                        }
                        if model.repeatChoice == .yearly {
                            repeatSelection("月份（留空按开始月份）", values: Array(1...12), selection: $model.repeatMonths)
                        }
                        Text("选择新规则会替换现有重复设置，并按所选间隔持续重复；保留现有规则时不改动原来的结束条件或复杂规则。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.editingEvent?.repeating == true {
                    Toggle("同时修改本次及以后的日程", isOn: $model.futureOccurrences)
                    Text("关闭时只修改当前这一条；原有复杂重复规则默认保留。 ").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.connected ? "写入 Mac 日历并同步眼镜" : "写入 Mac 日历") { Task { await model.saveEvent() } }
                        .disabled(!model.canSaveEvent)
                    if model.editingEventID != nil { Button("取消编辑") { model.beginNewEvent() }.disabled(model.busy) }
                }
                Text("只写入明确选择的日历；系统事件原有提醒会保留。眼镜同步失败时，已保存的系统事件仍保留。 ")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("AI 新增语音日程写入所选 Mac 日历", isOn: $model.voiceUsesSystemCalendar)
                    .disabled(!model.voiceUsesSystemCalendar && !model.canSelectVoiceSystemCalendar)
                Text(model.voiceUsesSystemCalendar ? "AI 新增使用上面明确选择的写入日历；目标失效或缺授权时暂停，不改投其他来源。已有系统映射项目始终修改原日历。" :
                    "AI 新增默认仅写眼镜；已有系统映射项目的修改和删除仍写回原日历。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8)
        .confirmationDialog("从 Mac 系统日历删除“\(model.deleteTarget?.title ?? "")”？",
            isPresented: Binding(get: { model.deleteTarget != nil }, set: { if !$0 { model.deleteTarget = nil } }), titleVisibility: .visible) {
                if let target = model.deleteTarget {
                    Button(target.repeating ? "仅删除本次" : "删除系统日历日程", role: .destructive) {
                        model.futureOccurrences = false; Task { await model.deleteEvent(target) }
                    }
                    if target.repeating {
                        Button("删除本次及以后", role: .destructive) {
                            model.futureOccurrences = true; Task { await model.deleteEvent(target) }
                        }
                    }
                }
                Button("取消", role: .cancel) { model.deleteTarget = nil }
            }
    }

    private func repeatSelection(_ title: String, values: [Int], labels: [String]? = nil, selection: Binding<Set<Int>>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                ForEach(values, id: \.self) { value in
                    Toggle(labels.map { $0[value - 1] } ?? String(value), isOn: Binding(get: {
                        selection.wrappedValue.contains(value)
                    }, set: {
                        if $0 { selection.wrappedValue.insert(value) } else { selection.wrappedValue.remove(value) }
                    })).toggleStyle(.button)
                }
            }
        }.padding(.vertical, 4)
    }
}
