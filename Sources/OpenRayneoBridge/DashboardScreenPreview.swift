// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// A snapshot of existing local content; constructing a preview never fetches or authorizes a source.
@MainActor
struct DashboardPreviewContent {
    let currentWeather: HomeWeatherSnapshot?
    let weather: HomeWeatherSnapshot?
    let todos: [HomeTodo]
    let schedules: [GlassesSchedule]
    let clocks: [[String: Any]]
    let stocks: [[String: Any]]
    let mails: [[String: Any]]
    let battery: Int?
    let charging: Bool
    let dateFormat: String
    let language: String
    let timeFormat: Int
    let temperatureUnit: Int
    var loadingWidgets: Set<Int> = []
    var configuredWidgets: Set<Int> = []
    var lifeLogEnabled: Bool? = nil


}

/// APK DashboardPreview, green configuration scene. Measurements are logical units.
@MainActor
struct DashboardScreenPreview: View {
    let mode: Int
    let widgets: [Int]
    let pageIndex: Int
    let content: DashboardPreviewContent
    let compact: Bool
    private let green = Color(red: 68 / 255, green: 1, blue: 102 / 255)
    private let logicalSize = CGSize(width: 522, height: 196)

    init(mode: Int, widgets: [Int], pageIndex: Int = 0, content: DashboardPreviewContent, compact: Bool = false) {
        self.mode = mode; self.widgets = widgets; self.pageIndex = pageIndex
        self.content = content; self.compact = compact
    }

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60), by: 60)) { timeline in
            GeometryReader { proxy in
                let scale = min(proxy.size.width / logicalSize.width, proxy.size.height / logicalSize.height)
                ZStack {
                    dotGrid
                    if mode == 0 { classic(date: timeline.date) }
                    else if mode == 1 { minimalTime(date: timeline.date) }
                    else if mode == 2 { diagonalTime(date: timeline.date) }
                }
                .frame(width: logicalSize.width, height: logicalSize.height).background(Color.black)
                .clipped().scaleEffect(scale, anchor: .topLeading)
                .frame(width: logicalSize.width * scale, height: logicalSize.height * scale, alignment: .topLeading)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }.aspectRatio(logicalSize.width / logicalSize.height, contentMode: .fit)
            .accessibilityElement(children: .combine)
    }

    private var dotGrid: some View {
        Canvas(rendersAsynchronously: !compact) { context, size in
            for y in stride(from: CGFloat(2.5), through: size.height, by: 5) {
                for x in stride(from: CGFloat(2.5), through: size.width, by: 5) {
                    context.fill(Path(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(0.1)))
                }
            }
        }
    }

    private func classic(date: Date) -> some View {
        let ids = [0] + widgets
        let page = min(max(pageIndex, 0), (ids.count - 1) / 2)
        return HStack(spacing: 6) {
            ForEach(0..<2) { column in
                let index = page * 2 + column
                if index < ids.count {
                    if ids[index] == 0 { clock(date: date).frame(width: 256, height: 196) }
                    else { cardFrame(id: ids[index]) { widget(ids[index], date: date) } }
                } else { Color.clear.frame(width: 256, height: 196) }
            }
        }.padding(.horizontal, 2)
    }

    private func cardFrame<Content: View>(id: Int, @ViewBuilder content: () -> Content) -> some View {
        let horizontal: CGFloat = id == 6 ? 7 : id == 2 ? 11 : 12
        let vertical: CGFloat = id == 6 ? 6 : id == 1 ? 14 : 12
        return content().frame(width: 256 - 2 * horizontal, height: 196 - 2 * vertical)
            .clipped().padding(.horizontal, horizontal).padding(.vertical, vertical)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(green.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder private func widget(_ id: Int, date: Date) -> some View {
        switch id {
        case 1: weatherCard
        case 2: todoCard
        case 3: scheduleCard(date: date)
        case 4: stockCard
        case 5: mailCard
        case 6: worldClockCard(date: date)
        default: message("组件 \(id)", icon: "icon_empty_error")
        }
    }

    private func label(_ text: String, _ size: CGFloat = 18, opacity: CGFloat = 1, lines: Int = 1,
                       face: DashboardPreviewText.Face = .light, tracking: CGFloat = -0.4,
                       height: CGFloat = 1.2, alignment: NSTextAlignment = .left) -> DashboardPreviewText {
        DashboardPreviewText(text: text, size: size, face: face, tracking: tracking, height: height,
                             lines: lines, opacity: opacity, alignment: alignment)
    }

    private func clock(date: Date) -> some View {
        VStack(spacing: 0) {
            label(dateLine(date), face: .regular, tracking: -0.48, height: 1.3, alignment: .center)
            label(formatted(date, "HH:mm"), 90, face: .regular, tracking: 0, height: 1, alignment: .center)
            statusRow
        }
    }

    private func minimalTime(date: Date) -> some View {
        VStack(spacing: 0) {
            label(formatted(date, "HH:mm"), 66, face: .medium, tracking: 0, height: 1, alignment: .center)
            HStack(spacing: 9) {
                label(dateLine(date), face: .regular, tracking: -0.48, height: 1.3)
                batteryRow(size: 18, iconSize: 12)
                currentWeatherRow(size: 18)
                lifeLogIcon
            }
        }.padding(.horizontal, 10).padding(.vertical, 12)
    }

    private func diagonalTime(date: Date) -> some View {
        HStack(spacing: 10) {
            ZStack {
                label(formatted(date, "HH"), 66, face: .medium, tracking: 0, height: 1)
                    .frame(width: 121, height: 99, alignment: .topLeading).clipShape(DashboardDiagonalMask(upper: true))
                label(formatted(date, "mm"), 66, face: .medium, tracking: 0, height: 1)
                    .frame(width: 121, height: 99, alignment: .bottomTrailing).clipShape(DashboardDiagonalMask(upper: false))
                Canvas { context, size in
                    var path = Path(); path.move(to: CGPoint(x: 0, y: size.height)); path.addLine(to: CGPoint(x: size.width, y: 0))
                    context.stroke(path, with: .color(green.opacity(0.5)), lineWidth: 1)
                }
            }.frame(width: 121, height: 99)
            VStack(alignment: .leading, spacing: 4) {
                label(dateLine(date), face: .regular, tracking: -0.48, height: 1.3)
                batteryRow(size: 18, iconSize: 12)
                currentWeatherRow(size: 18)
                lifeLogIcon
            }
        }.padding(.horizontal, 6).padding(.vertical, 4)
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            batteryRow(size: 20, iconSize: 16)
            HStack(spacing: 0) { currentWeatherRow(size: 20); lifeLogIcon }
        }
    }

    private func currentWeatherRow(size: CGFloat) -> some View {
        HStack(spacing: 4) {
            if let weather = content.currentWeather {
                weatherIcon(weather.code, day: weather.isDay).frame(width: 12, height: 12)
                label(temperature(weather.temperature), size, face: .regular, tracking: -0.48, height: 1.3)
            } else { label("--" + temperatureSuffix, size, face: .regular, tracking: -0.48, height: 1.3) }
        }
    }

    private func batteryRow(size: CGFloat, iconSize: CGFloat) -> some View {
        HStack(spacing: 4) {
            if let battery = content.battery {
                if content.charging {
                    label("\u{e6c2}", iconSize, face: .icons, tracking: 0, height: 1).frame(width: iconSize, height: iconSize)
                } else {
                    let level = battery > 80 ? 100 : battery > 60 ? 80 : battery > 40 ? 60 : battery > 20 ? 40 : 20
                    DashboardPreviewIcon(name: "icon_battery_\(level)").frame(width: iconSize, height: iconSize)
                }
                label("\(battery)%", size, face: .regular, tracking: -0.48, height: 1.3)
            }
        }
    }

    @ViewBuilder private var lifeLogIcon: some View {
        if content.lifeLogEnabled == true {
            label("\u{e6fb}", 12, face: .icons, tracking: 0, height: 1).frame(width: 12, height: 12)
        }
    }

    @ViewBuilder private var weatherCard: some View {
        if let weather = content.weather {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    DashboardPreviewIcon(name: "icon_board_location").frame(width: 16, height: 16)
                    label(weather.city.name).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer().frame(height: 4)
                HStack(spacing: 20) {
                    label(temperature(weather.temperature), 60, face: .regular, tracking: 0, height: 1).fixedSize()
                    VStack(alignment: .trailing, spacing: 2) {
                        label(HomeWeatherCodes.description(weather.code), 20, tracking: -0.44, alignment: .right)
                        if let day = weather.daily.first {
                            label(temperature(day.maximum) + "/" + temperature(day.minimum), 20, tracking: -0.44, alignment: .right)
                        }
                    }.frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 0) {
                    let hours = Array(weather.upcomingHours.prefix(5))
                    ForEach(0..<5) { index in
                        if index < hours.count {
                            let hour = hours[index]
                            VStack(spacing: 4) {
                                label(weather.formatted(hour.time, pattern: "ha").lowercased(), opacity: 0.5, alignment: .center)
                                weatherIcon(hour.code, day: hour.isDay).frame(width: 20, height: 20)
                                label(temperature(hour.temperature), alignment: .center)
                            }.frame(maxWidth: .infinity)
                        } else { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        } else { missingData(1, configured: "请连接手机 App 以更新天气数据") }
    }

    @ViewBuilder private var todoCard: some View {
        if content.todos.isEmpty {
            if content.loadingWidgets.contains(2) { loadingCard }
            else {
                VStack(spacing: 4) {
                    DashboardPreviewIcon(name: "icon_empty_to").frame(width: 21, height: 16)
                    label("真棒", 20, face: .regular, tracking: 0, height: 22 / 18, alignment: .center)
                    label("已完成所有重要待办", face: .regular, tracking: 0, height: 22 / 18, alignment: .center)
                }
            }
        } else {
            let heights = content.todos.map { DashboardPreviewText.measuredHeight($0.title, width: 208, size: 18, lines: 2) }
            let wrapped = heights.filter { $0 > 22 }.count
            let gap: CGFloat = wrapped == 0 ? 8 : wrapped == 1 ? 10 : wrapped == 2 ? 13 : 20
            let total = heights.reduce(0, +) + CGFloat(heights.count - 1) * gap
            let scale = min(1, 172 / total)
            VStack(alignment: .leading, spacing: gap * scale) {
                ForEach(Array(content.todos.enumerated()), id: \.element.id) { index, todo in
                    HStack(alignment: .top, spacing: 10 * scale) {
                        DashboardPreviewIcon(name: "radio_nor").frame(width: 16 * scale, height: 16 * scale).padding(.vertical, 3 * scale)
                        DashboardPreviewText(text: todo.title, size: 18 * scale, face: .regular, tracking: 0, height: 22 / 18,
                                             lines: 2, asciiEllipsis: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: heights[index] * scale, alignment: .top)
                }
            }.frame(width: 234, height: 172, alignment: .topLeading)
        }
    }

    @ViewBuilder private func scheduleCard(date: Date) -> some View {
        let items = fittingSchedules(date: date)
        if items.isEmpty {
            if content.loadingWidgets.contains(3) { loadingCard }
            else { message("暂无日程", icon: "icon_empty_calendar", gap: 2) }
        } else {
            VStack(alignment: .leading, spacing: items.count == 3 ? 0 : 16) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 0) {
                        scheduleLine("icon_app_calendar", item.title, lines: item.location?.isEmpty == false ? 1 : 2)
                        Spacer().frame(height: items.count == 3 ? 4 : 6)
                        scheduleLine("icon_calendar_time", scheduleTime(item, now: date), secondary: true)
                        if let location = item.location, !location.isEmpty {
                            Spacer().frame(height: items.count == 3 ? 2 : 4)
                            scheduleLine("icon_board_location", location, secondary: true)
                        }
                    }
                    if items.count == 3 && index < 2 { Spacer(minLength: 0) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func scheduleLine(_ icon: String, _ text: String, lines: Int = 1, secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            DashboardPreviewIcon(name: icon).frame(width: 16, height: 16).padding(.top, 2)
            label(text, opacity: secondary ? 0.5 : 1, lines: lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fittingSchedules(date: Date) -> [GlassesSchedule] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: date))!
        let items = content.schedules.filter { $0.end >= date && $0.start < tomorrow }.sorted { $0.start < $1.start }
        var selected: [GlassesSchedule] = [], expandedCount = 0
        for item in items.prefix(3) {
            let title = DashboardPreviewText(text: item.title, size: 18, face: .regular, tracking: -0.44, height: 1.3, lines: 2)
            let expanded = item.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || title.layout(width: 206).count > 1
            if selected.count >= 2 && (expandedCount > 1 || (expanded && expandedCount == 1)) { break }
            selected.append(item)
            if expanded { expandedCount += 1 }
        }
        return selected
    }

    @ViewBuilder private var stockCard: some View {
        if content.stocks.isEmpty { missingData(4, configured: "请连接手机 App 以更新股票数据") }
        else {
            VStack(spacing: 0) {
                ForEach(0..<3) { index in
                    if index < content.stocks.count { stockRow(content.stocks[index]).frame(height: 172 * 48 / 146, alignment: .top) }
                    else { Color.clear.frame(height: 172 * 48 / 146) }
                    if index < 2 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func stockRow(_ item: [String: Any]) -> some View {
        let name = item["name"] as? String ?? ""
        let code = item["code"] as? String ?? ""
        let reversed = item["name_reverse"] as? Bool == true
        return HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    label(reversed ? code : name, face: .regular, tracking: -0.44, height: 1.3)
                    if item["is_open"] as? Bool == false { DashboardPreviewIcon(name: "icon_market_close").frame(width: 16, height: 16) }
                }
                label(reversed ? name : code, opacity: 0.5)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                label(item["realtime_str"] as? String ?? (item["realtime"] as? NSNumber)?.stringValue ?? "--", face: .regular, tracking: -0.44, height: 1.3, alignment: .right)
                if let percent = item["percent"] as? Double {
                    HStack(spacing: 4) {
                        label(String(format: "%+.2f%%", percent), opacity: 0.5, alignment: .right)
                        DashboardPreviewIcon(name: percent >= 0 ? "icon_stock_up" : "icon_stock_down").frame(width: 16, height: 16)
                    }
                }
            }
        }
    }

    @ViewBuilder private var mailCard: some View {
        if let mail = content.mails.first {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 30) {
                    label(mail["sender_name"] as? String ?? mail["sender"] as? String ?? "", 20, face: .regular, tracking: -0.48, height: 1.3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) {
                        DashboardPreviewIcon(name: mail["provider"] as? String == "outlook" ? "icon_outlook_mail" : "icon_gmail").frame(width: 12, height: 12)
                        Spacer().frame(width: 3)
                        label("\(mail["unread"] as? Int ?? 0)")
                        Spacer().frame(width: 6)
                    }.fixedSize().frame(minWidth: 18, minHeight: 13).background(green.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                }
                Spacer().frame(height: 6)
                if let title = mail["title"] as? String, !title.isEmpty { label(title, 20, tracking: -0.44).padding(.bottom, 0) }
                label(mail["preview"] as? String ?? "", opacity: 0.5, lines: 4).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                label(mail["time"] as? String ?? "", opacity: 0.5, tracking: -0.44).padding(.top, 4)
            }
        } else if content.configuredWidgets.contains(5) { message("暂无未读邮件", icon: "icon_empty_email", gap: 4) }
        else { missingData(5, configured: "请前往手机 App 检查邮件设置") }
    }

    @ViewBuilder private func worldClockCard(date: Date) -> some View {
        if let clock = content.clocks.first {
            let zone = (clock["timezone"] as? String).flatMap(TimeZone.init(identifier:))
                ?? (clock["offset"] as? Int).flatMap(TimeZone.init(secondsFromGMT:))
            VStack(spacing: 0) {
                label(clock["location"] as? String ?? "", 20, face: .regular, tracking: -0.48, height: 1.3, alignment: .center)
                Spacer().frame(height: 4)
                label(zone.map { formatted(date, "HH:mm", zone: $0) } ?? "--:--", 60, face: .regular, tracking: 0, height: 1, alignment: .center)
                Spacer().frame(height: 6)
                label(zone.map { timeDifference($0, date: date) } ?? "—", 20, opacity: 0.5, tracking: -0.44, alignment: .center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { missingData(6, configured: "连接手机 App 以同步世界时钟数据。") }
    }

    @ViewBuilder private func missingData(_ id: Int, configured: String) -> some View {
        if content.loadingWidgets.contains(id) { loadingCard }
        else { message(configured, icon: id == 5 ? "icon_empty_app_seetings" : "icon_empty_app_connect", gap: 2) }
    }

    private var loadingCard: some View {
        VStack(spacing: 2) {
            label("\u{e6bb}", 24, face: .icons, tracking: 0, height: 1).frame(width: 24, height: 24)
            label("加载中…", alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, icon: String?, gap: CGFloat = 2) -> some View {
        VStack(spacing: gap) {
            if let icon { DashboardPreviewIcon(name: icon).frame(width: 22, height: 22) }
            label(text, lines: 3, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var temperatureSuffix: String { content.temperatureUnit == 2 ? "°F" : "°C" }
    private func temperature(_ value: Double, unit: Bool = true) -> String {
        "\(Int((content.temperatureUnit == 2 ? value * 9 / 5 + 32 : value).rounded()))" + (unit ? temperatureSuffix : "°")
    }
    private func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: content.language); formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMEd")
        if content.language.hasPrefix("zh") { formatter.dateFormat = "M月d日EEE" }
        return formatter.string(from: date).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
    }
    private func formatted(_ date: Date, _ pattern: String, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: content.language); formatter.timeZone = zone
        formatter.dateFormat = content.timeFormat == 2 ? pattern.replacingOccurrences(of: "HH", with: "hh") : pattern
        return formatter.string(from: date)
    }
    private func scheduleTime(_ item: GlassesSchedule, now: Date) -> String {
        let prefix = Calendar.current.isDate(item.start, inSameDayAs: now) ? "" : content.language.hasPrefix("zh") ? "明天, " : "Tomorrow, "
        return prefix + formatted(item.start, "HH:mm") + " - " + formatted(item.end, "HH:mm")
    }
    private func timeDifference(_ zone: TimeZone, date: Date) -> String {
        let hours = Double(zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
        let number = abs(hours).truncatingRemainder(dividingBy: 1) == 0 ? String(Int(abs(hours))) : String(format: "%.1f", abs(hours))
        return (hours >= 0 ? "+" : "-") + number + (content.language.hasPrefix("zh") ? " 小时" : abs(hours) == 1 ? " hour" : " hours")
    }
    private func weatherIcon(_ code: Int, day: Bool) -> some View {
        let name: String
        // The APK mapper at 0x17be2fc consumes vendor codes, as does the outgoing weather payload.
        switch HomeWeatherCodes.glassesIcon(code, isDay: day) {
        case 100: name = "sun"
        case 150: name = "clear_night"
        case 151...153: name = "cloudy_night"
        case 300, 301, 305...307, 309, 314, 315, 350, 351, 399: name = "rain"
        case 302...304: name = "thunder"
        case 308, 310...313, 316...318: name = "heavy_downpour"
        case 400...410, 456, 457, 499: name = "snow"
        case 500...504, 507...515: name = "fog"
        default: name = "cloudy"
        }
        return DashboardPreviewIcon(name: "icon_weather_" + name)
    }
}

private struct DashboardDiagonalMask: Shape {
    let upper: Bool
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: upper ? rect.origin : CGPoint(x: rect.maxX, y: rect.maxY)); path.closeSubpath()
        }
    }
}
