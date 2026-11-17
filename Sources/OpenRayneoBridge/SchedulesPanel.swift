// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct GlassesSchedule: Identifiable {
    let id: String
    let title: String
    let location: String?
    let start: Date
    let end: Date

    init?(_ json: [String: Any]) {
        guard let id = json["eventID"] as? NSNumber, let title = json["title"] as? String,
              let start = json["startTime"] as? NSNumber, let end = json["endTime"] as? NSNumber else { return nil }
        self.id = id.stringValue; self.title = title; self.location = json["location"] as? String
        self.start = Date(timeIntervalSince1970: start.doubleValue)
        self.end = Date(timeIntervalSince1970: end.doubleValue)
    }
}

@MainActor
final class SchedulesModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var items: [GlassesSchedule] = []
    @Published var busy = false
    @Published var notice = "读取眼镜已有日程，或添加一条日程。"
    @Published var editingID: String?
    @Published var title = ""
    @Published var start = Date().addingTimeInterval(3600)
    @Published var end = Date().addingTimeInterval(5400)
    init(bridge: DesktopBridge) { self.bridge = bridge }
    var connected: Bool { bridge?.connected == true }

    func refresh() async { await perform("/v1/schedules", method: "GET") }
    func save() async {
        await perform(editingID.map { "/v1/schedules/\($0)" } ?? "/v1/schedules", method: editingID == nil ? "POST" : "PATCH", body: [
            "title": title, "startTime": Int64(start.timeIntervalSince1970), "endTime": Int64(end.timeIntervalSince1970)
        ])
    }
    func delete(_ item: GlassesSchedule) async { await perform("/v1/schedules/\(item.id)", method: "DELETE") }
    func edit(_ item: GlassesSchedule) { editingID = item.id; title = item.title; start = item.start; end = item.end }
    private func perform(_ path: String, method: String, body: [String: Any]? = nil) async {
        guard let bridge, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await bridge.request(path, method: method, body: body)
            items = (result["items"] as? [[String: Any]] ?? []).compactMap(GlassesSchedule.init)
                .sorted { $0.start < $1.start }
            notice = method == "GET" ? "已读取 \(items.count) 条日程。" : "已发送并重新读取眼镜日程。"
            if method != "GET" { editingID = nil; title = "" }
        } catch { notice = error.localizedDescription }
    }
}

@MainActor
struct SchedulesPanel: View {
    @ObservedObject var model: SchedulesModel
    @ObservedObject var calendarSync: CalendarSyncModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(model.notice).font(.callout).foregroundStyle(.secondary); Spacer()
                Button("读取日程") { Task { await model.refresh() } }.disabled(!model.connected || model.busy)
            }
            ForEach(model.items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                        Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if calendarSync.isSystemMapped(item.id) {
                        Button("在系统日历中编辑") { calendarSync.editGlassesSchedule(item.id) }
                        Text("系统日历来源").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("编辑") { model.edit(item) }
                        Button(role: .destructive) { Task { await model.delete(item) } } label: { Image(systemName: "trash") }
                    }
                }
            }
            Divider()
            TextField("日程标题", text: $model.title)
            DatePicker("开始", selection: $model.start)
            DatePicker("结束", selection: $model.end)
            HStack {
                if model.editingID != nil { Button("取消编辑") { model.editingID = nil; model.title = "" } }
                Button(model.editingID == nil ? "添加到眼镜" : "保存日程") { Task { await model.save() } }
                    .disabled(!model.connected || model.title.isEmpty || model.end <= model.start)
            }
        }.padding(8).disabled(model.busy)
    }
}
