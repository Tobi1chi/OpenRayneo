// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension DashboardPreviewContent {
    init(home: HomeContentModel, cards: DashboardCardsModel, schedules: SchedulesModel,
         settings: GlassesSettingsModel, currentWeather: HomeWeatherSnapshot?, mail: MailDashboardModel? = nil,
         lifeLogEnabled: Bool? = nil) {
        DashboardPreviewFonts.register()
        self.currentWeather = currentWeather
        let selectedBinding = home.bindings.first { $0.id == home.selectedSlot } ?? home.bindings.first
        var weather = selectedBinding.flatMap { home.weather[$0.city.id] }
        if weather == nil {
            for id in home.configuredCityIDs {
                if let cityID = Int(id), let snapshot = home.weather[cityID] { weather = snapshot; break }
            }
        }
        self.weather = weather
        todos = home.todos.filter { $0.status != 1 }
        self.schedules = schedules.items
        clocks = cards.clocks
        stocks = cards.stocks.map { item in
            if let symbol = cards.quoteSymbols[cards.stockKey(item)], let quote = cards.quotes[symbol] { return quote.card }
            return item
        }
        var messages = cards.mails
        if let mail {
            for provider in MailDashboardProvider.allCases {
                guard let snapshot = mail.snapshots[provider.rawValue],
                      snapshot.selection == mail.selections[provider.rawValue] else { continue }
                messages.removeAll { $0["provider_id"] as? String == provider.wireID }
                if var item = snapshot.mail {
                    item["unread"] = snapshot.unread
                    item["provider"] = provider.rawValue
                    item["provider_id"] = provider.wireID
                    messages.append(item)
                }
            }
        }
        mails = messages.filter { ($0["unread"] as? Int ?? 0) > 0 }
        battery = settings.status["battery"] as? Int
        charging = settings.status["isCharging"] as? Bool == true
        dateFormat = settings.dateFormat
        language = settings.language; timeFormat = settings.timeFormat; temperatureUnit = settings.temperatureUnit
        self.lifeLogEnabled = lifeLogEnabled
        configuredWidgets = [2, 3]
        if !home.bindings.isEmpty { configuredWidgets.insert(1) }
        if !stocks.isEmpty { configuredWidgets.insert(4) }
        if !messages.isEmpty || mail?.selections.isEmpty == false { configuredWidgets.insert(5) }
        if !clocks.isEmpty { configuredWidgets.insert(6) }
        if home.isBusy { loadingWidgets.formUnion([1, 2]) }
        if schedules.busy { loadingWidgets.insert(3) }
        if cards.quoteBusy { loadingWidgets.insert(4) }
        if mail?.busy == true { loadingWidgets.insert(5) }
    }
}
