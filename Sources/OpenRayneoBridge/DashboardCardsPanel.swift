// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import SwiftUI

@MainActor
final class DashboardCardsModel: ObservableObject {
    private weak var bridge: DesktopBridge?
    @Published var notice = "管理世界时钟、股票和邮件卡片内容。"
    @Published var busy = false
    @Published var clockLocation = "北京"
    @Published var clockLocationID = "Asia/Shanghai"
    @Published var clockTimezone = "Asia/Shanghai"
    @Published var clocks: [[String: Any]] = []
    @Published var stockCode = ""
    @Published var stockName = ""
    @Published var stockExchange = ""
    @Published var stockMIC = ""
    @Published var stockPrice = 0.0
    @Published var stockPercent = 0.0
    @Published var stockNameReverse = false
    @Published var stockIsOpen = false
    @Published var stocks: [[String: Any]] = []
    @Published var stockSymbol = "usAAPL"
    @Published private(set) var quoteBusy = false
    @Published private(set) var quoteNotice = "腾讯公开行情；支持美股、沪深 A 股与港股。"
    @Published private(set) var quoteSymbols: [String: String] = [:]
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published var stockAutomatic = false {
        didSet {
            defaults.set(stockAutomatic, forKey: "dashboardStockAutomatic")
            if stockAutomatic { requestAutomaticQuotes(force: true) }
            else { automaticQuoteTask?.cancel(); pendingAutomaticQuotes = false }
        }
    }
    @Published var stockRefreshSeconds = 300 {
        didSet {
            defaults.set(stockRefreshSeconds, forKey: "dashboardStockRefreshSeconds")
            requestAutomaticQuotes()
        }
    }
    @Published var provider = "gmail"
    @Published var providerID = "1"
    @Published var unread = 1
    @Published var sender = ""
    @Published var subject = ""
    @Published var preview = ""
    @Published var mails: [[String: Any]] = []
    @Published private(set) var glassPreview: [String: Any] = [:]
    @Published private(set) var previewBusy = false
    @Published private(set) var previewError: String?
    @Published private(set) var previewStatusError: String?
    private let defaults = UserDefaults.standard
    private let quoteService = StockQuoteService()
    private var subscriptions = Set<AnyCancellable>()
    private var automaticQuoteTask: Task<Void, Never>?
    private var pendingAutomaticQuotes = false
    private var lastQuoteAttempt: Date?
    init(bridge: DesktopBridge) {
        self.bridge = bridge
        if let data = defaults.data(forKey: "dashboardCards"), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            clocks = saved["clocks"] as? [[String: Any]] ?? []
            stocks = saved["stocks"] as? [[String: Any]] ?? []
            mails = saved["mails"] as? [[String: Any]] ?? []
        }
        quoteSymbols = defaults.dictionary(forKey: "dashboardStockSymbols") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "dashboardStockQuotes") {
            quotes = (try? JSONDecoder().decode([String: StockQuote].self, from: data)) ?? [:]
        }
        stockAutomatic = defaults.bool(forKey: "dashboardStockAutomatic")
        let interval = defaults.integer(forKey: "dashboardStockRefreshSeconds")
        if [60, 300, 900].contains(interval) { stockRefreshSeconds = interval }
        bridge.$connected.dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                if connected { self?.requestAutomaticQuotes(force: true) }
                else { self?.automaticQuoteTask?.cancel() }
            }
        }.store(in: &subscriptions)
        bridge.$selectedAddress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.glassPreview = [:]; self?.previewError = nil; self?.previewStatusError = nil
                self?.automaticQuoteTask?.cancel()
                self?.requestAutomaticQuotes(force: true)
            }
        }.store(in: &subscriptions)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestAutomaticQuotes() }
        }.store(in: &subscriptions)
        requestAutomaticQuotes()
    }
    var connected: Bool { bridge?.connected == true }
    func refreshPreview() async {
        guard let bridge, bridge.serviceRunning else { return }
        let expected = bridge.selectedAddress
        do {
            let result = try await bridge.request("/v1/dashboard/preview", method: "GET", timeout: 3)
            guard bridge.selectedAddress == expected else { return }
            glassPreview = result; previewStatusError = nil
        } catch { previewStatusError = error.localizedDescription }
    }

    func readPreviewConfiguration() async {
        guard let bridge, bridge.connected, !previewBusy else { return }
        let expected = bridge.selectedAddress
        previewBusy = true; defer { previewBusy = false }
        do {
            _ = try await bridge.request("/v1/dashboard", method: "GET")
            guard bridge.selectedAddress == expected else { return }
            previewError = nil
            await refreshPreview()
        } catch { previewError = error.localizedDescription }
    }
    func addClock() {
        guard let timezone = TimeZone(identifier: clockTimezone) else { notice = "请选择有效时区。"; return }
        clocks.append(["location": clockLocation, "location_id": clockLocationID, "timezone": timezone.identifier,
                       "offset": timezone.secondsFromGMT()]); save()
    }
    func addStock() {
        let item: [String: Any] = ["code": stockCode, "exchange": stockExchange, "micCode": stockMIC, "name": stockName,
            "percent": stockPercent, "open": stockPrice, "realtime": stockPrice, "realtime_str": String(stockPrice),
            "name_reverse": stockNameReverse, "is_open": stockIsOpen, "total": 0, "last_close": stockPrice, "quarter": []]
        guard !stockCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              stockPrice.isFinite, stockPercent.isFinite else { notice = "请填写股票代码及有效价格。"; return }
        let key = stockKey(item)
        if let index = stocks.firstIndex(where: { stockKey($0) == key }) { stocks[index] = item }
        else {
            guard stocks.count < 6 else { notice = "眼镜最多支持 6 支股票，请先移除一支。"; return }
            stocks.append(item)
        }
        quoteSymbols.removeValue(forKey: key)
        save()
        notice = "已保存手工股票，价格由手动维护。"
    }

    func stockKey(_ item: [String: Any]) -> String {
        ["exchange", "micCode", "code"].map { item[$0] as? String ?? "" }.joined(separator: "|")
    }

    func removeStock(at index: Int) {
        quoteSymbols.removeValue(forKey: stockKey(stocks[index]))
        stocks.remove(at: index)
        save()
    }

    func addQuotedStock() async {
        guard !quoteBusy else { return }
        quoteBusy = true
        defer { finishQuotes() }
        do {
            quoteNotice = "正在查询 \(stockSymbol)…"
            let quote = try await quoteService.fetch(stockSymbol)
            try Task.checkCancellation()
            let key = stockKey(quote.card)
            if let index = stocks.firstIndex(where: { stockKey($0) == key }) { stocks[index] = quote.card }
            else {
                guard stocks.count < 6 else { quoteNotice = "眼镜最多支持 6 支股票，请先移除一支。"; return }
                stocks.append(quote.card)
            }
            quoteSymbols[key] = quote.symbol
            quotes[quote.symbol] = quote
            save()
            quoteNotice = "已保存 \(quote.name) 行情；可手动同步或开启自动刷新。"
            if stockAutomatic { pendingAutomaticQuotes = true }
        } catch { quoteNotice = error.localizedDescription }
    }

    func refreshQuotes(synchronize: Bool = false, automatically: Bool = false) async {
        guard !quoteBusy, !busy else { return }
        let targets = stocks.compactMap { item -> (String, String)? in
            let key = stockKey(item)
            return quoteSymbols[key].map { (key, $0) }
        }
        guard !targets.isEmpty else { quoteNotice = "请先通过行情符号添加一支股票。"; return }
        quoteBusy = true
        lastQuoteAttempt = Date()
        let expectedAddress = bridge?.selectedAddress
        defer { finishQuotes() }
        var failures: [String] = []
        var updated = 0
        for (key, symbol) in targets {
            do {
                try Task.checkCancellation()
                quoteNotice = "正在刷新 \(symbol)…"
                let quote = try await quoteService.fetch(symbol)
                try Task.checkCancellation()
                guard quoteSymbols[key] == symbol, let index = stocks.firstIndex(where: { stockKey($0) == key }) else { continue }
                stocks[index] = quote.card
                // Keep the source subscription keyed by the provider's current exchange identity.
                quoteSymbols.removeValue(forKey: key)
                quoteSymbols[stockKey(quote.card)] = symbol
                quotes[symbol] = quote
                updated += 1
            } catch is CancellationError {
                save()
                quoteNotice = "已取消行情刷新，已取得的结果保留在 Mac。"
                return
            } catch { failures.append("\(symbol)：\(error.localizedDescription)") }
        }
        save()
        if synchronize, updated > 0, connected, bridge?.selectedAddress == expectedAddress,
           !Task.isCancelled, !automatically || stockAutomatic {
            await push("stock_update")
            quoteNotice = "已刷新 \(updated) 支股票。\(notice)"
        } else { quoteNotice = "已刷新 \(updated) 支股票到 Mac。" }
        if !failures.isEmpty { quoteNotice += " 更新失败的股票保留原值：" + failures.joined(separator: "；") }
    }

    private func finishQuotes() {
        quoteBusy = false
        if pendingAutomaticQuotes {
            pendingAutomaticQuotes = false
            requestAutomaticQuotes(force: true)
        }
    }

    private func requestAutomaticQuotes(force: Bool = false) {
        guard stockAutomatic, connected, !quoteSymbols.isEmpty else { return }
        guard force || lastQuoteAttempt == nil || Date().timeIntervalSince(lastQuoteAttempt!) >= Double(stockRefreshSeconds) else { return }
        if quoteBusy || busy {
            if force { pendingAutomaticQuotes = true }
            return
        }
        automaticQuoteTask?.cancel()
        automaticQuoteTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, stockAutomatic, connected else { return }
            await refreshQuotes(synchronize: true, automatically: true)
        }
    }
    func addMail() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        let id = provider == "outlook" ? "2" : "1"
        mails.removeAll { ($0["provider_id"] as? String ?? providerID) == id }
        mails.append(["provider": provider, "provider_id": id, "unread": unread,
                      "sender": sender, "sender_name": sender, "title": subject, "preview": preview,
                      "time": formatter.string(from: Date()) + " " + clock.string(from: Date())]); save()
    }
    func save() {
        if let data = try? JSONSerialization.data(withJSONObject: ["clocks": clocks, "stocks": stocks, "mails": mails]) {
            defaults.set(data, forKey: "dashboardCards")
        }
        defaults.set(quoteSymbols, forKey: "dashboardStockSymbols")
        if let data = try? JSONEncoder().encode(quotes) { defaults.set(data, forKey: "dashboardStockQuotes") }
    }
    func push(_ command: String) async {
        guard !busy else { return }
        guard connected else { notice = "眼镜未连接，卡片内容已保存在 Mac。"; return }
        if command == "stock_update", stocks.count > 6 { notice = "眼镜最多支持 6 支股票，请先移除多余条目。"; return }
        busy = true; defer { busy = false }
        do {
            let result = try await synchronizeForLayout(command)
            notice = result["acknowledged"] as? Bool == true ? "卡片内容已发送，眼镜已回复。" : "已发送卡片内容，未收到回复。"
            save()
        } catch { notice = error.localizedDescription }
    }
    func synchronizeForLayout(_ command: String) async throws -> [String: Any] {
        guard let bridge else { throw HomeContentFailure("眼镜服务未连接") }
        let items: Any
        switch command {
        case "clock_update":
            clocks = clocks.map { entry in
                var updated = entry
                if let identifier = entry["timezone"] as? String, let zone = TimeZone(identifier: identifier) { updated["offset"] = zone.secondsFromGMT() }
                return updated
            }
            items = clocks
        case "stock_update": items = stocks
        default:
            let grouped = Dictionary(grouping: mails) { $0["provider_id"] as? String ?? "1" }
            items = grouped.keys.sorted().map { id -> [String: Any] in
                let messages = grouped[id] ?? []
                return ["provider": id == "2" ? "outlook" : "gmail", "provider_id": id,
                    "unread": messages.first?["unread"] as? Int ?? messages.count,
                    "mails": messages.map { item in item.filter { !["provider", "provider_id", "unread"].contains($0.key) } }]
            }
        }
        let result = try await bridge.request("/v1/glasses/cards", body: ["command": command, "items": items])
        save()
        return result
    }

}

@MainActor
struct DashboardCardsPanel: View {
    @ObservedObject var model: DashboardCardsModel
    var component: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.notice).foregroundStyle(.secondary).textSelection(.enabled)
            if component == nil || component == 0 { glassPreviewSection }
            if component == nil || component == 6 {
            GroupBox("世界时钟") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("城市显示名", text: $model.clockLocation)
                    TextField("城市 ID", text: $model.clockLocationID)
                    Picker("时区", selection: $model.clockTimezone) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
                    Button("添加时钟") { model.addClock() }
                    ForEach(Array(model.clocks.enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text("\(item["location"] as? String ?? "") · \(item["timezone"] as? String ?? "")")
                            Spacer(); Button("移除") { model.clocks.remove(at: index); model.save() }
                        }
                    }
                    Button("同步世界时钟") { Task { await model.push("clock_update") } }.disabled(!model.connected)
                }.padding(8)
            }
            }
            if component == nil || component == 4 {
            GroupBox("股票内容") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("腾讯公开行情符号：美股 usAAPL，沪市 sh600519，深市 sz000001，港股 hk00700。最多 6 支；行情可能延迟。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("行情符号", text: $model.stockSymbol)
                        Button("查询并添加") { Task { await model.addQuotedStock() } }.disabled(model.quoteBusy)
                        if model.quoteBusy { ProgressView().controlSize(.small) }
                    }
                    Toggle("连接眼镜时自动刷新并同步行情", isOn: $model.stockAutomatic)
                    Picker("刷新间隔", selection: $model.stockRefreshSeconds) {
                        Text("1 分钟").tag(60)
                        Text("5 分钟").tag(300)
                        Text("15 分钟").tag(900)
                    }
                    Text(model.quoteNotice).font(.callout).textSelection(.enabled)
                    ForEach(Array(model.stocks.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item["name"] as? String ?? "")
                                Text(item["code"] as? String ?? "")
                                Text(item["realtime_str"] as? String ?? "")
                                if let percent = item["percent"] as? Double { Text(String(format: "%+.2f%%", percent)) }
                                Spacer()
                                Button("移除") { model.removeStock(at: index) }
                            }
                            if let symbol = model.quoteSymbols[model.stockKey(item)], let quote = model.quotes[symbol] {
                                Text("腾讯 · \(symbol) · \(quote.tradingState) · 行情时间 \(quote.quoteTime)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("开盘 \(quote.open.formatted()) · 昨收 \(quote.previousClose.formatted()) · 15 分钟走势 \(quote.quarter.filter { $0 != -10000 }.count)/\(quote.quarter.count) 点 · 获取于 \(quote.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("手工价格").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("刷新行情到 Mac") { Task { await model.refreshQuotes() } }
                            .disabled(model.quoteBusy || model.quoteSymbols.isEmpty)
                        Button("刷新行情并同步") { Task { await model.refreshQuotes(synchronize: true) } }
                            .disabled(!model.connected || model.quoteBusy || model.quoteSymbols.isEmpty)
                        Button("同步当前内容") { Task { await model.push("stock_update") } }
                            .disabled(!model.connected || model.quoteBusy)
                    }
                    DisclosureGroup("手工填写价格") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { TextField("代码", text: $model.stockCode); TextField("名称", text: $model.stockName) }
                            HStack { TextField("交易所", text: $model.stockExchange); TextField("MIC", text: $model.stockMIC) }
                            HStack { TextField("价格", value: $model.stockPrice, format: .number); TextField("涨跌幅 %", value: $model.stockPercent, format: .number) }
                            Toggle("反转股票名称顺序", isOn: $model.stockNameReverse)
                            Toggle("正在交易", isOn: $model.stockIsOpen)
                            Text("手工价格独立维护，不随自动行情刷新变化。开盘、昨收暂用填写价格，走势留空。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("添加手工股票") { model.addStock() }.disabled(model.stockCode.isEmpty || model.quoteBusy)
                        }.padding(.top, 6)
                    }
                }.padding(8)
            }
            }
            if component == nil || component == 5 {
            GroupBox("邮件内容") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("邮箱", selection: $model.provider) { Text("Gmail").tag("gmail"); Text("Outlook").tag("outlook") }
                        TextField("未读数量", value: $model.unread, format: .number)
                    }
                    TextField("发件人", text: $model.sender)
                    TextField("主题", text: $model.subject)
                    TextField("摘要", text: $model.preview)
                    Button("添加邮件摘要") { model.addMail() }.disabled(model.subject.isEmpty)
                    ForEach(Array(model.mails.enumerated()), id: \.offset) { index, item in
                        HStack { Text(item["title"] as? String ?? ""); Spacer(); Button("移除") { model.mails.remove(at: index); model.save() } }
                    }
                    Button("同步邮件内容") { Task { await model.push("mail_update") } }.disabled(!model.connected)
                }.padding(8)
            }
            }
        }.disabled(model.busy)
        .task {
            guard component == nil else { return }
            while !Task.isCancelled {
                await model.refreshPreview()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private var glassPreviewSection: some View {
        let state = model.glassPreview
        let report = state["report"] as? [String: Any] ?? [:]
        let config = state["configuration"] as? [String: Any]
        let freshness = state["freshness"] as? String ?? "not_received"
        return GroupBox("眼镜页面上报") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(report.isEmpty ? "尚未收到眼镜页面上报" : pageTitle(report)).font(.headline)
                    Spacer()
                    Button("读取眼镜布局") { Task { await model.readPreviewConfiguration() } }
                        .disabled(!model.connected || model.previewBusy)
                }
                if !report.isEmpty {
                    Text(freshnessLabel(freshness)).font(.caption).foregroundStyle(.secondary)
                    if let time = state["stateReceivedAt"] as? NSNumber {
                        Text("有效页面上报于 \(Date(timeIntervalSince1970: time.doubleValue).formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.connected ? "已连接，等待眼镜主动上报页面。" : "眼镜未连接；当前没有已确认的页面记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state["lastDisposition"] as? String == "ignored_app_action" {
                    Text("最近 App 状态未更新预览页，继续等待下一条页面上报。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let config {
                    Divider()
                    Text("最近读取的首页布局").font(.subheadline.weight(.semibold))
                    if let mode = config["simple_mode"] as? Int {
                        Text([0: "标准首页", 1: "简洁时钟 · 样式一", 2: "简洁时钟 · 样式二"][mode] ?? "未知样式 \(mode)")
                    }
                    let widgets = (config["widgets"] as? [NSNumber] ?? []).map(\.intValue)
                    ForEach(Array(widgets.enumerated()), id: \.offset) { offset, widget in
                        Text("\(offset + 1). \(widgetTitle(widget))").font(.callout)
                    }
                    if !model.connected || state["configurationFreshness"] as? String != "reported_this_connection" {
                        Text("此布局来自旧连接，连接后可手动重新读取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("尚未读取首页布局。读取布局不会切换眼镜页面。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("页面位置随眼镜上报更新，预览内容来自本机已读取的数据。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.previewError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let error = model.previewStatusError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if model.previewBusy { ProgressView().controlSize(.small) }
                DisclosureGroup("页面上报详情") {
                    Text(previewDetails(state)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(8)
        }
    }

    private func pageTitle(_ report: [String: Any]) -> String {
        let page = report["page"] as? String ?? ""
        let index = (report["focusIndex"] as? NSNumber)?.intValue
        let app = report["app"] as? [String: Any] ?? [:]
        let name = app["name"] as? String ?? ""
        let appNames = ["com.rayneo.liteos.recorder": "录音", "com.rayneo.liteos.aiSubtitle": "实时字幕",
            "com.rayneo.liteos.conversationAssist": "对话助手", "com.rayneo.liteos.todo": "待办",
            "com.rayneo.liteos.prompter": "提词器", "com.rayneo.liteos.ai_memory": "AI 记忆",
            "com.rayneo.liteos.focusmode": "勿扰模式"]
        switch page {
        case "dashboard": return "最近眼镜页面：首页" + (index.map { " · 第 \($0 + 1) 页" } ?? "")
        case "app_list": return "最近眼镜页面：应用列表" + (appNames[name].map { " · " + $0 } ?? "")
        case "embedded_app": return "最近眼镜页面：" + (appNames[name] ?? (name.isEmpty ? "应用详情" : name))
        default: return "最近眼镜页面：未知场景"
        }
    }

    private func freshnessLabel(_ value: String) -> String {
        guard model.connected else { return "眼镜未连接；保留最近记录，页面可能已变化。" }
        if value == "awaiting_report_after_reconnect" { return "已重连，等待本次连接的页面上报；当前为旧记录。" }
        return "来源：眼镜主动上报；查看此页不会控制眼镜。"
    }

    private func widgetTitle(_ value: Int) -> String {
        [1: "天气", 2: "待办", 3: "日程", 4: "股票", 5: "邮件", 6: "世界时钟"][value] ?? "未知卡片 \(value)"
    }

    private func previewDetails(_ value: [String: Any]) -> String {
        guard !value.isEmpty, let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "尚无页面上报。" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
