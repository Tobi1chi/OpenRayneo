// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialAgreement: Codable, Identifiable {
    let agreementCuid: Int64
    let agreementCode: Int
    let versionCode: Int
    let versionName: String
    let agreementTitle: String
    let contentUrl: String
    let isMandatory: Int
    let priority: Int
    var id: Int64 { agreementCuid }
    var url: URL? {
        guard let url = URL(string: contentUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct OfficialLoginCandidate {
    var session: OfficialAccountSession
    var needsProfile: Bool
    var userInfo: [String: Any]
}

enum OfficialIdentityStatus {
    case notRequired, verified, verificationRequired, appUnavailable, bypassedOnQueryFailure
}

struct OfficialSMSOutcome {
    let retryAfter: Int?
    let notice: String?
}

struct OfficialIdentityResultFailure: LocalizedError {
    var errorDescription: String? { "官方未确认实名验证成功，请检查资料或稍后查询实名状态。" }
}

private struct OfficialTclFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Mainland SMS uses the XR production domain, independently of an existing imported account.
final class OfficialPhoneLoginService {
    private let network: URLSession
    private let anonymous: OfficialFirmwareConfiguration

    init() {
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCredentialStorage = nil; options.urlCache = nil
        options.timeoutIntervalForRequest = 20; options.timeoutIntervalForResource = 30
        network = URLSession(configuration: options, delegate: OfficialLoginRedirectPolicy(), delegateQueue: nil)
        let environment = ProcessInfo.processInfo.environment
        anonymous = OfficialFirmwareConfiguration(region: .domestic, baseURL: OfficialFirmwareRegion.domestic.baseURL,
            appVersion: environment["RAYNEO_CLIENT_APP_VERSION"] ?? "1.0.10",
            deviceCode: environment["RAYNEO_DEVICE_CODE"], clientDeviceID: environment["RAYNEO_CLIENT_DEVICE_ID"],
            accountRouteRegion: nil, countryCode: "cn", accessToken: "", accountID: "",
            identityEpoch: nil, credentialRevision: 0, accessExpiresAt: nil, refreshExpiresAt: nil)
    }

    deinit { network.invalidateAndCancel() }

    func agreements() async throws -> [OfficialAgreement] {
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
        let language = locale.language.languageCode?.identifier ?? "zh"
        let region = locale.region?.identifier
        let agreementLanguage = language == "zh" ? (["HK", "TW"].contains(region ?? "") ? "zh-" + region! : "zh") : language
        let root = try await request(method: "GET", path: "/profileapi/v1/user/agreements/preDeposit", query: [
            URLQueryItem(name: "appType", value: "RayNeoAI"), URLQueryItem(name: "agreementLanguage", value: agreementLanguage)])
        let data = try standardData(root)
        return try JSONDecoder().decode([OfficialAgreement].self, from: JSONSerialization.data(withJSONObject: data))
            .sorted { $0.priority < $1.priority }
    }

    func sendCode(phone: String) async throws -> OfficialSMSOutcome {
        var body = phoneIdentity(phone)
        body["validate"] = NSNull(); body["sceneType"] = 2
        let root = try await request(method: "POST", path: "/identify/common/sendVerifyCode", body: body)
        do {
            _ = try tclData(root)
            return OfficialSMSOutcome(retryAfter: nil, notice: nil)
        } catch let failure as OfficialTclFailure where failure.code == "PeriodValidCode" {
            return OfficialSMSOutcome(retryAfter: Self.cooldownSeconds(failure.message), notice: failure.message)
        }
    }

    func signIn(phone: String, code: String) async throws -> OfficialLoginCandidate {
        var body = phoneIdentity(phone)
        body["code"] = code; body["deviceId"] = NSNull(); body["countryCode"] = "cn"
        for key in ["systemVersion", "deviceModel", "language", "source", "ageCheck"] { body[key] = NSNull() }
        let started = Date()
        let root = try await request(method: "POST", path: "/identify/quickLogin", body: body)
        guard let value = try tclData(root) as? [String: Any],
              let token = value["token"] as? String, let refresh = value["refreshToken"] as? String,
              let accessSeconds = number(value["expiresIn"]), let refreshSeconds = number(value["rtExpiresIn"]),
              let user = value["userInfo"] as? [String: Any], let accountID = number(user["accountId"]) else {
            throw OfficialAccountFailure(message: "官方登录响应缺少完整会话或账号信息，未替换本机会话。")
        }
        var session = OfficialAccountSession(accessToken: token, refreshToken: refresh,
            accessExpiresAt: started.addingTimeInterval(accessSeconds.doubleValue),
            refreshExpiresAt: started.addingTimeInterval(refreshSeconds.doubleValue), accountID: String(accountID.int64Value),
            region: .domestic, businessBaseURL: anonymous.baseURL.absoluteString, accountRouteRegion: nil,
            countryCode: (user["countryCode"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "cn",
            clientDeviceID: anonymous.clientDeviceID, deviceCode: anonymous.deviceCode, savedAt: Date())
        session.profile = try OfficialAccountProfile(json: user)
        return OfficialLoginCandidate(session: session, needsProfile: value["needCompleteUserInfo"] as? Bool != false, userInfo: user)
    }

    func identityStatus(_ candidate: OfficialLoginCandidate) async throws -> OfficialIdentityStatus {
        let data = try await identityData(candidate)
        if matches(data["realNameAuthEnable"], 0) { return .notRequired }
        guard matches(data["verifyStatus"], 1) else { return .verificationRequired }
        return matches(data["appRightFlag"], 0) ? .appUnavailable : .verified
    }

    func completeProfile(_ candidate: OfficialLoginCandidate, nickname: String, birthday: String? = nil) async throws -> OfficialLoginCandidate {
        var body: [String: Any] = ["nickName": nickname]
        for key in ["birthday", "gender", "weight", "height", "countryAbbr", "province", "city", "avatarUrl"] { body[key] = NSNull() }
        body["birthday"] = birthday as Any? ?? NSNull()
        let host = URL(string: candidate.session.businessBaseURL)?.host
        let root = try await request(method: "POST", path: host == "xr-api-p.rayneo.cn" ? "/user/v2/updateUserInfo" : "/user/updateUserInfo", body: body, session: candidate.session)
        guard let user = try tclData(root) as? [String: Any], let account = number(user["accountId"]) else {
            throw OfficialAccountFailure(message: "官方补资料响应未返回账号资料。")
        }
        var updated = candidate
        updated.userInfo = user; updated.needsProfile = false
        updated.session.accountID = String(account.int64Value)
        updated.session.profile = try OfficialAccountProfile(json: user)
        return updated
    }

    func verifyIdentity(_ candidate: OfficialLoginCandidate, name: String, identityNumber: String, type: Int) async throws -> Bool {
        let root = try await request(method: "POST", path: "/profileapi/v1/user/verify/identityAgeRight", body: [
            "countryCode": (candidate.session.countryCode ?? "cn").uppercased(), "appType": "RayNeoAI",
            "nameMasked": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "phoneMasked": Self.identityPhone(candidate.userInfo["phone"] as? String ?? ""),
            "idType": type, "idCardMasked": identityNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        ], session: candidate.session)
        guard let data = try standardData(root) as? [String: Any] else {
            throw OfficialAccountFailure(message: "官方实名验证未返回结果对象。")
        }
        let parsedStatus = number(data["verifyStatus"])?.intValue ?? (data["verifyStatus"] as? String).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard matches(data["verifyStatus"], 1) || matches(data["verifyResult"], 1) ||
              parsedStatus == 4 || matches(data["detailCode"], 1) else {
            throw OfficialIdentityResultFailure()
        }
        return !matches(data["appRightFlag"], 0)
    }

    func recoverIdentitySubmission(_ candidate: OfficialLoginCandidate) async -> Bool? {
        guard let data = try? await identityData(candidate, timeout: 5), matches(data["verifyStatus"], 1) else { return nil }
        return !matches(data["appRightFlag"], 0)
    }

    private func identityData(_ candidate: OfficialLoginCandidate, timeout: TimeInterval = 20) async throws -> [String: Any] {
        let root = try await request(method: "GET", path: "/profileapi/v1/user/verify/ivStatusAndDfList",
            query: [URLQueryItem(name: "appType", value: "RayNeoAI"),
                    URLQueryItem(name: "countryCode", value: (candidate.session.countryCode ?? "cn").uppercased())],
            session: candidate.session, timeout: timeout)
        guard let data = try standardData(root) as? [String: Any] else {
            throw OfficialAccountFailure(message: "官方身份状态不是可识别的记录。")
        }
        return data
    }

    func accountStatus(_ candidate: OfficialLoginCandidate) async throws -> Int {
        let root = try await request(method: "GET", path: "/identify/account/getStatus", session: candidate.session)
        guard let value = number(try tclData(root)) else {
            throw OfficialAccountFailure(message: "官方账号状态不是可识别的整数。")
        }
        return value.intValue
    }

    func restoreCoolingAccount(_ candidate: OfficialLoginCandidate) async throws {
        let root = try await request(method: "POST", path: "/identify/account/repealDelete", body: [:], session: candidate.session)
        _ = try tclData(root)
    }

    func reportAgreement(_ agreement: OfficialAgreement, session: OfficialAccountSession) async throws {
        let root = try await request(method: "POST", path: "/profileapi/v1/user/agreements/operation", body: [
            "agreementCuid": agreement.agreementCuid, "agreementCode": agreement.agreementCode,
            "isMandatory": agreement.isMandatory, "operateScene": 1, "operateResult": 0,
            "traceId": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()], session: session)
        _ = try standardData(root)
    }

    private func phoneIdentity(_ phone: String) -> [String: Any] {
        ["sendType": 3, "bindType": 3, "type": 3, "loginName": phone, "bindName": phone, "areaCode": "+86", "runtimeType": "phone"]
    }

    func request(method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                 session: OfficialAccountSession? = nil, timeout: TimeInterval = 20,
                 configuration explicit: OfficialFirmwareConfiguration? = nil, encodedBody: Data? = nil,
                 contentType: String? = nil, signingPayload: Data? = nil) async throws -> [String: Any] {
        let configuration = try explicit ?? session.map { try OfficialFirmwareConfiguration.fromSession($0) } ?? anonymous
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path; components.queryItems = query.isEmpty ? nil : query
        let url = components.url!
        var request = URLRequest(url: url)
        request.httpMethod = method; request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = timeout
        var body = body
        // The domestic HeaderInterceptor fills an existing null/blank deviceId before signing.
        if configuration.region == .domestic, body?["deviceId"] is NSNull || body?["deviceId"] as? String == "" {
            body?["deviceId"] = configuration.resolvedDeviceCode
        }
        request.httpBody = try encodedBody ?? body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !configuration.accessToken.isEmpty { request.setValue(configuration.accessToken, forHTTPHeaderField: "xtcl-access-token") }
        if !configuration.accountID.isEmpty { request.setValue(configuration.accountID, forHTTPHeaderField: "xr-account-id") }
        request.setValue(configuration.appVersion, forHTTPHeaderField: "app-version")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "version")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "time-zone")
        if let value = configuration.deviceCode { request.setValue(value, forHTTPHeaderField: "device-code") }
        if let value = configuration.clientDeviceID {
            for key in ["device-id", "device_id", "deviceId"] { request.setValue(value, forHTTPHeaderField: key) }
        }
        if let value = configuration.accountRouteRegion { request.setValue(value, forHTTPHeaderField: "accountRouteRegion") }
        try configuration.signingHeaders(method: method, url: url, body: signingPayload ?? request.httpBody)
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try OfficialCloudPolicy.requireEnabled()
        let (bytes, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OfficialAccountFailure(message: "官方账号服务未返回 HTTP 响应。") }
        let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        if explicit != nil, !configuration.accessToken.isEmpty,
           OfficialTokenAuthentication.kind(httpStatus: http.statusCode, body: root) != nil {
            try? await OfficialSessionCoordinator.shared.markAccessTokenExpired(configuration)
            throw OfficialAccountFailure(message: "官方拒绝了当前访问令牌；下次操作将先尝试共享会话刷新。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OfficialAccountFailure(message: "官方账号请求失败（HTTP \(http.statusCode)）。", requiresReauthentication: http.statusCode == 401)
        }
        guard let root else {
            throw OfficialAccountFailure(message: "官方账号响应不是记录对象。")
        }
        return root
    }

    private func standardData(_ root: [String: Any]) throws -> Any {
        guard let code = number(root["code"]), code.doubleValue == 0 else {
            throw OfficialAccountFailure(message: root["userFriendlyTip"] as? String ?? root["msg"] as? String ?? "官方账号请求返回业务错误。")
        }
        return root["data"] ?? NSNull()
    }

    func tclData(_ root: [String: Any]) throws -> Any {
        let code = root["errorCode"].flatMap { $0 is NSNull ? nil : $0 } ?? root["code"].flatMap { $0 is NSNull ? nil : $0 }
        if let code {
            throw OfficialTclFailure(code: String(describing: code),
                message: root["msg"] as? String ?? root["message"] as? String ?? "官方注册／登录请求返回业务错误。")
        }
        return root["data"] ?? NSNull()
    }

    private func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value
    }
    private func matches(_ value: Any?, _ expected: Int) -> Bool {
        if let text = value as? String { return text == String(expected) }
        return number(value)?.doubleValue == Double(expected)
    }
    private static func cooldownSeconds(_ message: String) -> Int? {
        for pattern in ["(\\d+)\\s*s\\b", "(\\d+)"] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message), let seconds = Int(message[range]) else { continue }
            return min(63_072_000, max(0, seconds))
        }
        return nil
    }

    private static func identityPhone(_ value: String) -> String {
        let original = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var national = original
        if national.hasPrefix("+86-") { national = String(national.dropFirst(4)) }
        else if national.hasPrefix("+86") {
            national = String(national.dropFirst(3))
            if national.hasPrefix("-") { national = String(national.dropFirst()) }
        }
        let digits = national.filter { $0.isASCII && $0.isNumber }
        if digits.range(of: "^1[3-9][0-9]{9}$", options: .regularExpression) != nil { return digits }
        return original.filter { $0.isASCII && $0.isNumber }
    }

    static func nicknameValidation(_ value: String) -> String? {
        let weightedLength = value.reduce(0) { count, character in
            count + (character.unicodeScalars.contains { $0.value > 127 && !(0xff61...0xff9f).contains($0.value) } ? 2 : 1)
        }
        guard weightedLength >= 3 else { return "昵称至少需要 3 个计数字符，中文按 2 个计算。" }
        guard value.utf16.count <= 20 else { return "昵称过长，请缩短至 20 字符以内。" }
        let pattern = "^[\\p{L}\\p{M}\\p{Nd}]+$|^[ _.\\-\\u00B7]$"
        guard value.allSatisfy({ String($0).range(of: pattern, options: .regularExpression) != nil }) else {
            return "昵称可使用文字、数字、空格及 _ . - ·，不支持表情。"
        }
        return nil
    }

    static func isDomesticCandidate(_ candidate: OfficialLoginCandidate) -> Bool {
        let host = URL(string: candidate.session.businessBaseURL)?.host ?? ""
        return ["xr-api-p.rayneo.cn", "xr-api-pre.rayneo.cn", "xr-api-t.rayneo.cn", "xr-api-d.rayneo.cn"].contains(host)
    }

    static func birthdayValidation(_ value: String, today: Date = Date()) -> String? {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard let date = format.date(from: value), format.string(from: date) == value else { return "请按 yyyy-MM-dd 填写有效生日。" }
        let calendar = Calendar(identifier: .gregorian)
        let birth = calendar.dateComponents([.year, .month, .day], from: date)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        let sixteenth = (birth.year! + 16) * 10_000 + birth.month! * 100 + birth.day!
        let current = now.year! * 10_000 + now.month! * 100 + now.day!
        return sixteenth <= current ? nil : "海外账号补资料要求年满 16 周岁。"
    }

    static func identityValidation(name: String, number: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[\\u4E00-\\u9FFF·]+$", options: .regularExpression) != nil else {
            return "请按证件填写中文姓名，可包含中点。"
        }
        guard number.range(of: "^[0-9]{17}[0-9Xx]$", options: .regularExpression) != nil else {
            return "请填写 18 位证件号码，末位可为 X。"
        }
        let characters = Array(number.uppercased())
        let provinces = Set([11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37,
                             41, 42, 43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64, 65, 81, 82, 83])
        guard let province = Int(String(characters[0..<2])), provinces.contains(province),
              let year = Int(String(characters[6..<10])), let month = Int(String(characters[10..<12])),
              let day = Int(String(characters[12..<14])) else { return "证件号码地区码或生日格式不正确。" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let birthday = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return "证件号码中的生日无效。"
        }
        let components = calendar.dateComponents([.year, .month, .day], from: birthday)
        guard components.year == year, components.month == month, components.day == day else {
            return "证件号码中的生日无效。"
        }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = zip(characters.prefix(17), weights).reduce(0) { $0 + $1.0.wholeNumberValue! * $1.1 }
        let check = Array("10X98765432")[sum % 11]
        return characters.last == check ? nil : "证件号码校验位不正确，请核对后重试。"
    }
}

private final class OfficialLoginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
