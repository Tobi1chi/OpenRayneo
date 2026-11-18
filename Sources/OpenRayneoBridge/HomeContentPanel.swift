// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct HomeContentPanel: View {
    @ObservedObject var model: HomeContentModel
    @ObservedObject var schedules: SchedulesModel
    @ObservedObject var calendarSync: CalendarSyncModel
    var component: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(component.map { DashboardWidgetKind(id: $0).title + "内容" } ?? "眼镜首页").font(.title2.weight(.semibold))
                    Text(component == nil ? "管理待办和天气内容，沿用眼镜当前的首页布局。" : "管理这张首页卡片的内容与来源。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("读取眼镜", systemImage: "arrow.clockwise") }
                    .disabled(!model.connected || model.isBusy)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }

            if component == nil || component == 2 {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("新增待办", text: $model.newTodoTitle)
                        Toggle("重要", isOn: $model.newTodoImportant).toggleStyle(.checkbox)
                        Button("添加") { Task { await model.addTodo() } }
                            .disabled(!model.connected || model.isBusy || model.newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if model.todos.isEmpty { Text("读取后在这里查看眼镜已有待办").foregroundStyle(.secondary) }
                    ForEach(model.todos) { todo in
                        HStack(alignment: .top, spacing: 10) {
                            Button { Task { await model.toggleTodo(todo) } } label: {
                                Image(systemName: todo.syncState == "outcome_unknown" ? "questionmark.circle" : (todo.status == 1 ? "checkmark.circle.fill" : "circle"))
                            }.buttonStyle(.plain).disabled(!model.connected || model.isBusy)
                                .help(todo.status == 1 ? "撤销完成" : "完成待办")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(todo.title).textSelection(.enabled)
                                Text("ID \(todo.id) · \(todo.important ? "重要 · " : "")\(todo.syncState == "outcome_unknown" ? "待眼镜确认" : (todo.status == 1 ? "已完成" : "未完成"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                                Button("编辑") { model.edit(todo) }.disabled(model.isBusy)
                                Button(role: .destructive) { Task { await model.deleteTodo(todo) } } label: { Image(systemName: "trash") }
                                    .disabled(!model.connected || model.isBusy).help("删除这条待办")
                        }.padding(.vertical, 3)
                    }
                    if model.editingTodoID != nil {
                        Divider()
                        TextField("待办标题", text: $model.editingTodoTitle)
                        HStack {
                            Toggle("重要", isOn: $model.editingTodoImportant).toggleStyle(.checkbox)
                            Spacer()
                            Button("取消编辑") { model.editingTodoID = nil }
                            Button("保存") { Task { await model.saveTodo() } }.disabled(!model.connected || model.isBusy)
                        }
                    }
                    Text("支持完成、撤销完成、编辑和删除；每次操作读取并保留其他待办。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            } label: { Label("待办", systemImage: "checklist") }
            }

            if component == nil || component == 1 {

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if model.configuredCityIDs.isEmpty {
                        Text("搜索并添加城市。同步时将用 Mac 所选城市更新眼镜的天气卡列表。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("眼镜城市槽", selection: $model.selectedSlot) {
                            ForEach(model.configuredCityIDs, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        TextField("城市名，如 天津", text: $model.cityQuery)
                        Button("搜索城市") { Task { await model.searchCities() } }
                            .disabled(model.isBusy || model.cityQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(model.cityResults) { city in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(city.label)
                                Text("\(city.timezone) · \(city.latitude, specifier: "%.3f"), \(city.longitude, specifier: "%.3f")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let weather = model.weather[city.id] { weatherDetails(weather) }
                            }
                            Spacer()
                            Button("查看预报") { Task { await model.previewWeather(city) } }.disabled(model.isBusy)
                            Button("添加城市") { Task { await model.addCity(city) } }.disabled(model.isBusy)
                            Button("绑定到所选槽") { Task { await model.bind(city) } }
                                .disabled(!model.connected || model.selectedSlot.isEmpty || model.isBusy)
                        }
                    }
                    ForEach(model.bindings) { binding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(binding.city.label) → \(binding.id)").font(.subheadline.weight(.medium))
                                Spacer()
                                Button("移除") { Task { await model.removeCity(binding.id) } }.disabled(model.isBusy)
                            }
                            if let weather = model.weather[binding.city.id] {
                                weatherDetails(weather)
                            }
                        }.padding(.vertical, 3)
                    }
                    HStack {
                        Button("获取天气") { Task { await model.fetchWeather() } }.disabled(model.bindings.isEmpty || model.isBusy)
                        Button("更新眼镜城市卡") { Task { await model.publishWeather() } }
                            .disabled(!model.connected || model.bindings.isEmpty || model.isBusy)
                        Spacer()
                        Toggle("每30分钟更新", isOn: Binding(get: { model.refreshEnabled }, set: { enabled in Task { await model.setRefresh(enabled) } }))
                            .toggleStyle(.checkbox).disabled(model.bindings.isEmpty || model.isBusy)
                    }
                    Text("天气来自 Open-Meteo，地点来自 GeoNames。自动更新要求 Mac 正在运行且眼镜已连接。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("天气数据说明", destination: URL(string: "https://open-meteo.com/en/docs")!).font(.caption)
                }.padding(8)
            } label: { Label("城市天气卡", systemImage: "cloud.sun") }
            }

            if component == nil || component == 3 {

            GroupBox { SchedulesPanel(model: schedules, calendarSync: calendarSync).padding(10) }
                label: { Label("日程", systemImage: "calendar") }
            GroupBox { CalendarSyncPanel(model: calendarSync).padding(10) }
                label: { Label("系统日历同步", systemImage: "calendar.badge.clock") }
            }

            DisclosureGroup("当前首页配置") {
                Text(model.dashboardJSON).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { if model.connected { await model.refresh() } }
        .task { if component == nil || component == 2 { await model.observeTodos() } }
    }

    private func weatherDetails(_ weather: HomeWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weather.summary)
            Text("获取于 \(weather.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · 城市时区 \(weather.city.timezone)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(weather.daily.prefix(3).enumerated()), id: \.offset) { _, day in
                Text("\(weather.formatted(day.time, pattern: "MM-dd")) \(Int(day.minimum.rounded()))～\(Int(day.maximum.rounded()))° \(HomeWeatherCodes.description(day.code))")
                    .font(.caption)
            }
        }
    }
}
