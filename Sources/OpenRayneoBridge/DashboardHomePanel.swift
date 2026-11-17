// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

private let dashboardWidgetDragType = UTType(exportedAs: "com.openrayneo.dashboard-widget")

struct DashboardWidgetKind: Identifiable {
    let id: Int
    var title: String { [1: "天气", 2: "待办", 3: "日程", 4: "股票", 5: "邮件", 6: "世界时钟"][id] ?? "组件 \(id)" }
    var symbol: String { [1: "cloud.sun", 2: "checklist", 3: "calendar", 4: "chart.xyaxis.line", 5: "envelope", 6: "globe.asia.australia"][id] ?? "square.dashed" }
    static let all = (1...6).map { Self(id: $0) }
}

@MainActor
struct DashboardHomePanel: View {
    @ObservedObject var bridge: DesktopBridge
    @ObservedObject private var layout: DashboardLayoutModel
    @ObservedObject private var cards: DashboardCardsModel
    @ObservedObject private var home: HomeContentModel
    @ObservedObject private var schedules: SchedulesModel
    @ObservedObject private var settings: GlassesSettingsModel
    @ObservedObject private var mail: MailDashboardModel
    @ObservedObject private var locationWeather: CurrentLocationWeatherModel
    @State private var pageIndex = 0
    @State private var followGlasses = true
    @State private var draggedWidget: Int?
    @State private var editingWidget: DashboardWidgetKind?
    @State private var pendingWidget: DashboardWidgetKind?

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        layout = bridge.dashboardLayout; cards = bridge.dashboardCards
        home = bridge.homeContent; schedules = bridge.schedules
        settings = bridge.glassesSettings; mail = bridge.mailDashboard; locationWeather = bridge.currentLocationWeather
    }

    private var reportedPage: Int? {
        let report = cards.glassPreview["report"] as? [String: Any]
        return report?["page"] as? String == "dashboard" ? report?["focusIndex"] as? Int : nil
    }
    private var pageCount: Int { layout.mode == 0 ? max(1, (layout.widgets.count + 2) / 2) : 1 }
    private func pageTitle(_ index: Int) -> String {
        if layout.mode != 0 { return layout.mode == 1 ? "简洁时钟" : "斜分时钟" }
        let ids = [0] + layout.widgets
        return ids.dropFirst(index * 2).prefix(2).map { $0 == 0 ? "时钟" : DashboardWidgetKind(id: $0).title }.joined(separator: " · ")
    }
    private var previewData: DashboardPreviewContent {
        DashboardPreviewContent(home: home, cards: cards, schedules: schedules, settings: settings,
                                currentWeather: locationWeather.snapshot, mail: mail, lifeLogEnabled: bridge.lifeLogEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            previewSection
            Text(layout.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = layout.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            modeSection
            if layout.mode == 0 { componentSection }
            HStack {
                Button("读取眼镜布局") { Task { await layout.read() } }.disabled(!layout.connected || layout.busy)
                Button("撤销布局修改") { layout.resetDraft() }.disabled(!layout.hasChanges || layout.busy)
                Spacer()
                if layout.busy { ProgressView().controlSize(.small) }
                Button("应用到眼镜") { Task { await applyLayout() } }
                    .buttonStyle(.borderedProminent).disabled(!layout.connected || layout.busy || !layout.hasChanges)
            }
            DisclosureGroup("连接与页面状态") { DashboardCardsPanel(model: cards, component: 0) }
        }
        .task(id: bridge.selectedAddress + "|" + String(bridge.connected)) {
            if bridge.connected {
                await layout.read()
                await home.refresh()
                if !home.bindings.isEmpty && home.weather.isEmpty { await home.fetchWeather() }
                await schedules.refresh()
                await settings.refresh(force: false)
            }
            await cards.refreshPreview()
            alignWithGlasses()
        }
        .task {
            while !Task.isCancelled {
                await cards.refreshPreview()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task { await home.observeTodos() }
        .onChange(of: reportedPage) { _ in alignWithGlasses() }
        .onChange(of: layout.mode) { _ in pageIndex = 0 }
        .onChange(of: layout.widgets) { _ in pageIndex = min(pageIndex, pageCount - 1) }
        .onChange(of: bridge.selectedAddress) { _ in pageIndex = 0 }
        .sheet(item: $editingWidget, onDismiss: { pendingWidget = nil }) { widget in widgetSettings(widget) }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("眼镜首页预览").font(.title3.weight(.semibold))
                    Text(layout.hasChanges ? "正在预览未应用的布局" : layout.loaded ? "按眼镜布局与当前内容渲染" : "本机布局草稿")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await home.refresh(); if !home.bindings.isEmpty { await home.fetchWeather() }; await schedules.refresh(); await settings.refresh(force: false) } }
                    label: { Label("刷新内容", systemImage: "arrow.clockwise") }
                    .disabled(!bridge.connected || home.isBusy || schedules.busy || settings.busy)
            }
            DashboardScreenPreview(mode: layout.mode, widgets: layout.widgets, pageIndex: pageIndex, content: previewData)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Button { selectPage(pageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(pageIndex == 0)
                Spacer(minLength: 0)
                ForEach(0..<pageCount, id: \.self) { index in
                    Button { selectPage(index) } label: {
                        Circle().fill(index == pageIndex ? Color.primary : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                    }.buttonStyle(.plain).help(pageTitle(index))
                        .accessibilityLabel("预览第\(index + 1)页：" + pageTitle(index))
                }
                Spacer(minLength: 0)
                Button { selectPage(pageIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(pageIndex >= pageCount - 1)
            }.frame(maxWidth: 400).frame(maxWidth: .infinity)
            HStack {
                Text(pageTitle(pageIndex)).font(.callout)
                Text("\(pageIndex + 1) / \(pageCount)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随眼镜页面", isOn: $followGlasses).toggleStyle(.checkbox)
                    .onChange(of: followGlasses) { _ in alignWithGlasses() }
            }
            if !bridge.connected { Text("眼镜未连接，可先调整布局。连接后应用到眼镜。 ").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("首页样式").font(.headline)
            HStack(spacing: 12) {
                ForEach(0...2, id: \.self) { mode in
                    Button { updateLayout { layout.mode = mode; pageIndex = 0 } } label: {
                        VStack(spacing: 9) {
                            DashboardScreenPreview(mode: mode, widgets: layout.widgets, content: previewData, compact: true)
                            HStack(spacing: 6) {
                                Image(systemName: layout.mode == mode ? "largecircle.fill.circle" : "circle")
                                Text(["标准首页", "简洁样式一", "简洁样式二"][mode]).font(.callout)
                            }.foregroundStyle(layout.mode == mode ? Color.accentColor : Color.primary)
                        }.padding(9).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(layout.mode == mode ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.025)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(layout.mode == mode ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("首页样式：" + ["标准首页", "简洁样式一", "简洁样式二"][mode])
                }
            }
        }.disabled(layout.busy || home.isBusy || schedules.busy || settings.busy)
    }

    private var componentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已添加的小组件（\(layout.widgets.count)/5）").font(.headline)
                Spacer()
                Text("拖动排序 · 连接时自动保存").font(.caption).foregroundStyle(.secondary)
            }
            if layout.widgets.isEmpty {
                Text("添加下方小组件，放在时钟首页之后。").foregroundStyle(.secondary).padding(.vertical, 10)
            }
            VStack(spacing: 0) {
                ForEach(Array(layout.widgets.enumerated()), id: \.element) { index, id in
                    widgetRow(DashboardWidgetKind(id: id), index: index)
                        .onDrag { draggedWidget = id; return NSItemProvider(item: Data(String(id).utf8) as NSData, typeIdentifier: dashboardWidgetDragType.identifier) }
                        .onDrop(of: [dashboardWidgetDragType], delegate: DashboardWidgetDropDelegate(target: id, dragging: $draggedWidget, layout: layout, save: { Task { await applyLayout() } }))
                    if index < layout.widgets.count - 1 { Divider().padding(.leading, 45) }
                }
            }.padding(.horizontal, 12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            let available = DashboardWidgetKind.all.filter { !layout.widgets.contains($0.id) }
            if !available.isEmpty {
                Text("添加小组件").font(.headline).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(available) { widget in
                        Button { addWidget(widget) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: widget.symbol).frame(width: 22)
                                Text(widget.title)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel("添加" + widget.title + "小组件")
                    }
                }
            }
        }.disabled(layout.busy || home.isBusy || schedules.busy || settings.busy)
    }

    private func widgetRow(_ widget: DashboardWidgetKind, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            Image(systemName: widget.symbol).font(.title3).frame(width: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(widget.title).font(.body.weight(.medium))
                Text(sourceDescription(widget.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if (1...6).contains(widget.id) {
                Button("配置") { editingWidget = widget }
            }
            Button { updateLayout { layout.moveWidget(from: index, to: index - 1) } } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("上移" + widget.title).accessibilityLabel("上移" + widget.title)
            Button { updateLayout { layout.moveWidget(from: index, to: index + 1) } } label: { Image(systemName: "chevron.down") }
                .disabled(index == layout.widgets.count - 1).help("下移" + widget.title).accessibilityLabel("下移" + widget.title)
            Button { updateLayout { layout.removeWidget(widget.id) } } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                .buttonStyle(.plain).disabled(layout.widgets.count <= 1).help("移除" + widget.title).accessibilityLabel("移除" + widget.title + "小组件")
        }.padding(.vertical, 12).contentShape(Rectangle())
    }

    private func sourceDescription(_ id: Int) -> String {
        switch id {
        case 1: return home.bindings.first?.city.label ?? "选择城市与天气来源"
        case 2: return "\(home.todos.filter { $0.status != 1 }.count) 条待办 · 管理标题、重要与完成状态"
        case 3: return "\(schedules.items.count) 条日程 · 眼镜或系统日历"
        case 4: return "\(cards.stocks.count) 支股票 · 行情与手工价格"
        case 5: return "邮件来源与未读摘要"
        case 6: return cards.clocks.first?["location"] as? String ?? "选择城市与时区"
        default: return "眼镜上的已有组件"
        }
    }

    private func updateLayout(_ change: () -> Void) {
        change()
        Task {
            if layout.connected && layout.hasChanges { await applyLayout() }
        }
    }

    private func hasSource(_ widget: Int) -> Bool {
        switch widget {
        case 1: return !home.bindings.isEmpty
        case 4: return !cards.stocks.isEmpty
        case 5: return !mail.dashboardItems().isEmpty
        case 6: return !cards.clocks.isEmpty
        default: return true
        }
    }

    private func addWidget(_ widget: DashboardWidgetKind) {
        guard layout.widgets.count < 5 else { layout.addWidget(widget.id); return }
        if hasSource(widget.id) { updateLayout { layout.addWidget(widget.id) } }
        else { pendingWidget = widget; editingWidget = widget }
    }

    private func applyLayout() async {
        await layout.apply { added in
            for widget in added {
                switch widget {
                case 1: try await home.synchronizeWeatherCard()
                case 4: _ = try await cards.synchronizeForLayout("stock_update")
                case 5: _ = try await bridge.request("/v1/glasses/cards", body: ["command": "mail_update", "items": mail.dashboardItems()])
                case 6: _ = try await cards.synchronizeForLayout("clock_update")
                default: break
                }
            }
        }
        await cards.refreshPreview()
    }

    private func selectPage(_ page: Int) { followGlasses = false; pageIndex = max(0, min(page, pageCount - 1)) }
    private func alignWithGlasses() {
        guard followGlasses, !layout.hasChanges, let index = reportedPage else { return }
        pageIndex = max(0, min(index, pageCount - 1))
    }

    private func widgetSettings(_ widget: DashboardWidgetKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(widget.title + "配置").font(.title2.weight(.semibold))
                Spacer()
                if pendingWidget != nil { Button("取消") { pendingWidget = nil; editingWidget = nil } }
                Button(pendingWidget == nil ? "完成" : "添加到首页") {
                    if let pending = pendingWidget { updateLayout { layout.addWidget(pending.id) } }
                    pendingWidget = nil; editingWidget = nil
                }.disabled(pendingWidget != nil && !hasSource(widget.id))
            }
            if pendingWidget != nil { Text("先配置内容来源，再添加到首页。").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if [1, 2, 3].contains(widget.id) {
                        if widget.id == 1 { CurrentLocationWeatherPanel(model: locationWeather) }
                        HomeContentPanel(model: home, schedules: schedules, calendarSync: bridge.calendarSync, component: widget.id)
                    } else {
                        DashboardCardsPanel(model: cards, component: widget.id)
                        if widget.id == 5 { MailDashboardPanel(model: bridge.mailDashboard) }
                    }
                }
            }
        }.padding(22).frame(width: 650, height: 650)
    }
}

@MainActor
private struct DashboardWidgetDropDelegate: DropDelegate {
    let target: Int
    @Binding var dragging: Int?
    let layout: DashboardLayoutModel
    let save: () -> Void
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let source = layout.widgets.firstIndex(of: dragging), let destination = layout.widgets.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.16)) { layout.moveWidget(from: source, to: destination) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        if layout.connected && layout.hasChanges { save() }
        return true
    }
}
