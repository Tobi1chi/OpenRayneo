// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct HomeTodo: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let important: Bool
    let status: Int
    let owned: Bool
    let syncState: String
}

struct HomeCity: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let timezone: String
    let country: String?
    let admin1: String?
    var label: String { [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ") }
}

struct HomeWeatherBinding: Codable, Identifiable, Sendable {
    let id: String
    var city: HomeCity
}

struct HomeWeatherHour: Codable, Sendable {
    let time: Date
    let temperature: Double
    let code: Int
    let isDay: Bool
}

struct HomeWeatherDay: Codable, Sendable {
    let time: Date
    let minimum: Double
    let maximum: Double
    let code: Int
}

struct HomeWeatherSnapshot: Codable, Sendable {
    let city: HomeCity
    let fetchedAt: Date
    let validAt: Date
    let temperature: Double
    let code: Int
    let isDay: Bool
    let hourly: [HomeWeatherHour]
    let daily: [HomeWeatherDay]

    var summary: String { "\(city.name) \(Int(temperature.rounded()))°C，\(HomeWeatherCodes.description(code))" }
    var upcomingHours: ArraySlice<HomeWeatherHour> {
        hourly[(hourly.lastIndex(where: { $0.time <= validAt }) ?? hourly.startIndex)...]
    }

    func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: city.timezone) ?? .gmt
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    func result(date: String? = nil) -> [String: Any] {
        let days = daily.filter { date == nil || formatted($0.time, pattern: "yyyy-MM-dd") == date }
        let hours = (date == nil ? Array(upcomingHours) : hourly).filter { hour in
            if let date { return formatted(hour.time, pattern: "yyyy-MM-dd") == date }
            return true
        }.prefix(24)
        return ["source": "Open-Meteo", "city": city.label, "timezone": city.timezone,
            "fetchedAt": ISO8601DateFormatter().string(from: fetchedAt),
            "current": ["time": formatted(validAt, pattern: "yyyy-MM-dd HH:mm"), "temperatureC": temperature,
                "description": HomeWeatherCodes.description(code), "weatherCode": code],
            "hourly": hours.map { ["time": formatted($0.time, pattern: "yyyy-MM-dd HH:mm"), "temperatureC": $0.temperature,
                "description": HomeWeatherCodes.description($0.code)] as [String: Any] },
            "daily": days.map { ["date": formatted($0.time, pattern: "yyyy-MM-dd"), "minimumC": $0.minimum,
                "maximumC": $0.maximum, "description": HomeWeatherCodes.description($0.code)] as [String: Any] }]
    }
}

enum HomeWeatherCodes {
    // Open-Meteo WMO codes, documented at https://open-meteo.com/en/docs#weathervariables
    static func description(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57, 66, 67: return "冻雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75, 77: return "大雪或雪粒"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95, 97: return "雷雨"
        case 96, 99: return "雷雨伴冰雹"
        default: return "未知天气（\(code)）"
        }
    }

    static func glassesIcon(_ code: Int, isDay: Bool) -> Int {
        // Vendor code groups recovered from the APK's actual mapper at 0x17be2fc.
        switch code {
        case 0: return isDay ? 100 : 150
        case 1: return isDay ? 103 : 153
        case 2: return isDay ? 101 : 151
        case 3: return 104
        case 45, 48: return 501
        case 51, 53, 55: return 309
        case 56, 57, 66, 67: return 313
        case 61: return 305
        case 63: return 306
        case 65: return 307
        case 71: return 400
        case 73: return 401
        case 75, 77: return 402
        case 80: return isDay ? 300 : 350
        case 81, 82: return isDay ? 301 : 351
        case 85, 86: return isDay ? 407 : 457
        case 95, 97: return 302
        case 96, 99: return 304
        default: return 104
        }
    }
}

struct HomeContentFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct HomeWeatherService: Sendable {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    private func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomeContentFailure("天气服务请求失败，请稍后重试")
        }
        return object
    }

    func search(_ query: String) async throws -> [HomeCity] {
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "zh"), URLQueryItem(name: "format", value: "json")]
        let object = try await get(url.url!)
        let data = try JSONSerialization.data(withJSONObject: object["results"] as? [[String: Any]] ?? [])
        return try JSONDecoder().decode([HomeCity].self, from: data)
    }

    func city(id: Int) async throws -> HomeCity {
        let object = try await get(URL(string: "https://geocoding-api.open-meteo.com/v1/get?id=\(id)")!)
        if let results = object["results"] as? [[String: Any]], let first = results.first {
            return try JSONDecoder().decode(HomeCity.self, from: JSONSerialization.data(withJSONObject: first))
        }
        return try JSONDecoder().decode(HomeCity.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func forecast(_ city: HomeCity) async throws -> HomeWeatherSnapshot {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)), URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "forecast_days", value: "7"), URLQueryItem(name: "timezone", value: city.timezone),
            URLQueryItem(name: "temperature_unit", value: "celsius"), URLQueryItem(name: "timeformat", value: "unixtime")]
        return try parseForecast(await get(url.url!), city: city)
    }

    func parseForecast(_ object: [String: Any], city: HomeCity) throws -> HomeWeatherSnapshot {
        guard let current = object["current"] as? [String: Any], let timestamp = current["time"] as? Double,
              let temperature = current["temperature_2m"] as? Double, let code = current["weather_code"] as? Int,
              let day = current["is_day"] as? Int, let hourly = object["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double], let temperatures = hourly["temperature_2m"] as? [Double],
              let codes = hourly["weather_code"] as? [Int], let daylight = hourly["is_day"] as? [Int],
              let daily = object["daily"] as? [String: Any], let dates = daily["time"] as? [Double],
              let minima = daily["temperature_2m_min"] as? [Double], let maxima = daily["temperature_2m_max"] as? [Double],
              let dayCodes = daily["weather_code"] as? [Int], times.count == temperatures.count,
              times.count == codes.count, times.count == daylight.count, dates.count == minima.count,
              dates.count == maxima.count, dates.count == dayCodes.count else { throw HomeContentFailure("天气数据不完整，未更新眼镜") }
        return HomeWeatherSnapshot(city: city, fetchedAt: Date(), validAt: Date(timeIntervalSince1970: timestamp),
            temperature: temperature, code: code, isDay: day == 1,
            hourly: times.indices.map { HomeWeatherHour(time: Date(timeIntervalSince1970: times[$0]), temperature: temperatures[$0], code: codes[$0], isDay: daylight[$0] == 1) },
            daily: dates.indices.map { HomeWeatherDay(time: Date(timeIntervalSince1970: dates[$0]), minimum: minima[$0], maximum: maxima[$0], code: dayCodes[$0]) })
    }
}
