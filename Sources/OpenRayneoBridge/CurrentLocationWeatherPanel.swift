// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct CurrentLocationWeatherPanel: View {
    @ObservedObject var model: CurrentLocationWeatherModel

    var body: some View {
        GroupBox("首页温度 · 当前位置天气") {
            VStack(alignment: .leading, spacing: 10) {
                Text("更新首页电量旁的温度（—°）和天气图标，使用这台 Mac 的当前位置。下方城市天气卡单独同步。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.authorization == .notDetermined ? "允许定位并更新首页温度" : "更新首页温度") {
                        model.updateNow()
                    }.disabled(model.busy)
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Button("取消") { model.cancel() }
                    }
                }
                Toggle("连接眼镜后自动更新，每 30 分钟刷新", isOn: $model.automatic)
                Text(model.authorizationDescription).font(.caption).foregroundStyle(.secondary)
                if let weather = model.snapshot {
                    Text(weather.summary).font(.headline)
                    Text("获取时间：\(weather.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · Open-Meteo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.notice).font(.callout).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
