// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct StockQuote: Codable, Sendable {
    let symbol: String
    let code: String
    let name: String
    let exchange: String
    let mic: String
    let price: Double
    let priceText: String
    let percent: Double
    let open: Double
    let previousClose: Double
    let isOpen: Bool
    let tradingState: String
    let quoteTime: String
    let fetchedAt: Date
    let quarter: [Double]
    let nameReverse: Bool

    var card: [String: Any] {
        ["code": code, "name": name, "exchange": exchange, "micCode": mic,
         "realtime": price, "realtime_str": priceText, "percent": percent,
         "open": open, "last_close": previousClose, "is_open": isOpen,
         "name_reverse": nameReverse, "quarter": quarter, "total": quarter.count]
    }
}

struct StockQuoteFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct StockQuoteService: Sendable {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func normalizedSymbol(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(text.prefix(2)).lowercased()
        let code = String(text.dropFirst(2))
        let supported = ["sh", "sz", "hk", "us"].contains(prefix)
        let validCode = !code.isEmpty && code.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
        }
        guard supported, validCode else {
            throw StockQuoteFailure(message: "请填写腾讯行情符号，例如 usAAPL、sh600519、sz000001 或 hk00700。")
        }
        return prefix + code.uppercased()
    }

    func fetch(_ input: String) async throws -> StockQuote {
        let symbol = try normalizedSymbol(input)
        let endpoint = symbol.hasPrefix("us") ? "usMinute" : "minute"
        var components = URLComponents(string: "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/\(endpoint)/query")!
        components.queryItems = [URLQueryItem(name: "code", value: symbol)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StockQuoteFailure(message: "\(symbol) 行情服务请求失败。")
        }
        return try parse(data, symbol: symbol)
    }

    func parse(_ data: Data, symbol: String) throws -> StockQuote {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["code"] as? Int == 0, let all = root["data"] as? [String: Any],
              let object = all[symbol] as? [String: Any], let qt = object["qt"] as? [String: Any],
              let fields = qt[symbol] as? [String], fields.count > 32,
              let price = Double(fields[3]), let previousClose = Double(fields[4]),
              let open = Double(fields[5]), let percent = Double(fields[32]),
              price > 0, price.isFinite, previousClose.isFinite, open.isFinite, percent.isFinite,
              let chart = object["data"] as? [String: Any], let chartDate = chart["date"] as? String,
              let points = chart["data"] as? [String], !chartDate.isEmpty else {
            throw StockQuoteFailure(message: "\(symbol) 暂无完整行情，已保留原值。")
        }
        let prefix = String(symbol.prefix(2))
        let market = prefix.uppercased()
        let states = (qt["market"] as? [String] ?? []).joined(separator: "|").components(separatedBy: "|")
        guard let state = states.first(where: { $0.hasPrefix(market + "_") }) else {
            throw StockQuoteFailure(message: "\(symbol) 缺少交易状态，已保留原值。")
        }
        let pieces = state.split(separator: "_", maxSplits: 2).map(String.init)
        let quoteDate = String(fields[30].filter(\.isNumber).prefix(8))
        var values: [Int: Double] = [:]
        // Source minute timestamps are exchange-local HHmm. Keep only the same trading date.
        if chartDate == quoteDate {
            for point in points {
                let parts = point.split(separator: " ")
                guard parts.count >= 2, parts[0].count == 4, let time = Int(parts[0]),
                      let value = Double(parts[1]), value.isFinite, value > 0 else { continue }
                let minute = time / 100 * 60 + time % 100
                values[minute] = value
            }
        }
        // APK 0x26150c0 allocates open + 15 min ... close, inclusive, at 15 min steps.
        // Lunch breaks, future points and missing prices use the recovered -10000 sentinel.
        let closeMinute = prefix == "sh" || prefix == "sz" ? 15 * 60 : 16 * 60
        let quarter = stride(from: 9 * 60 + 45, through: closeMinute, by: 15).map { values[$0] ?? -10000.0 }
        let exchange: String, mic: String
        switch prefix {
        case "sh": exchange = "SSE"; mic = "XSHG"
        case "sz": exchange = "SZSE"; mic = "XSHE"
        case "hk": exchange = "HKEX"; mic = "XHKG"
        default:
            if fields[2].hasSuffix(".OQ") { exchange = "NASDAQ"; mic = "XNAS" }
            else if fields[2].hasSuffix(".N") { exchange = "NYSE"; mic = "XNYS" }
            else if fields[2].hasSuffix(".P") { exchange = "ARCA"; mic = "ARCX" }
            else { exchange = "US"; mic = "" }
        }
        return StockQuote(symbol: symbol, code: String(symbol.dropFirst(2)), name: fields[1],
            exchange: exchange, mic: mic, price: price, priceText: fields[3], percent: percent,
            open: open, previousClose: previousClose, isOpen: pieces.count > 1 && pieces[1] == "open",
            tradingState: pieces.count > 2 ? pieces[2] : state, quoteTime: fields[30], fetchedAt: Date(),
            quarter: quarter, nameReverse: prefix != "us")
    }
}
