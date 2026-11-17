// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import CryptoKit
import Foundation

/// The reset succeeded; retrying login must not repeat the password reset.
struct PasswordResetAutoLoginFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { "密码已重置，但自动登录未完成。" + reason }

    init(error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            reason = "登录已取消，请使用新密码重新登录。"
        } else if let failure = error as? URLError {
            reason = failure.code == .timedOut ? "登录请求超时，请使用新密码重试登录。" : "登录网络请求未完成，请检查网络后使用新密码登录。"
        } else {
            reason = "请使用新密码重新登录；原有本机会话未被本次操作替换。"
        }
    }
}

/// Overseas login is anonymous until the caller completes the shared login gates.
final class OfficialEmailLoginService {
    private let transport = OfficialPhoneLoginService()
    private let environment = ProcessInfo.processInfo.environment
    private let bootstrapURL = "https://global-account.rayneo.com"

    static func registrationPasswordValidation(_ password: String) -> String? {
        let special = Set("!@#$%^&*()_+-=[]{};:\"\\|,.<>/?".unicodeScalars)
        guard (8...64).contains(password.utf16.count),
              ["[A-Z]", "[a-z]", "[0-9]"].allSatisfy({ password.range(of: $0, options: .regularExpression) != nil }),
              password.unicodeScalars.contains(where: { special.contains($0) }) else {
            return "注册密码需 8–64 个字符，并包含大写、小写、数字和特殊字符。"
        }
        return nil
    }

    func checkEmail(email: String, country: String) async throws -> Bool {
        let country = try selectedCountry(country)
        let configuration = try await accountRoute(email: email, country: country)
        let root = try await transport.request(method: "POST", path: "/identify/exist",
            body: identity(email), configuration: configuration)
        guard let status = integer(try transport.tclData(root)), (0...2).contains(status.intValue) else {
            throw OfficialAccountFailure(message: "官方邮箱存在检查未返回可识别的状态。")
        }
        return status.intValue == 1
    }

    func sendRegistrationCode(email: String, country: String) async throws -> OfficialSMSOutcome {
        let country = try selectedCountry(country)
        let configuration = try await countryRoute(country)
        var body = identity(email)
        body["validate"] = NSNull(); body["sceneType"] = 1
        let root = try await transport.request(method: "POST", path: "/identify/common/sendVerifyCode",
            body: body, configuration: configuration)
        return try codeOutcome(root)
    }

    func sendRecoveryCode(email: String, country: String) async throws -> OfficialSMSOutcome {
        let country = try selectedCountry(country)
        let configuration = try await accountRoute(email: email, country: country)
        var body = identity(email)
        body["validate"] = NSNull(); body["sceneType"] = 6
        let root = try await transport.request(method: "POST", path: "/identify/common/sendVerifyCode",
            body: body, configuration: configuration)
        return try codeOutcome(root)
    }

    func verifyRecoveryCode(email: String, code: String, country: String) async throws {
        let country = try selectedCountry(country)
        let configuration = try await accountRoute(email: email, country: country)
        var body = identity(email)
        body["code"] = code; body["sceneType"] = 6
        let root = try await transport.request(method: "POST", path: "/identify/common/checkVerifyCode",
            body: body, configuration: configuration)
        _ = try transport.tclData(root)
    }

    /// The caller carries a successfully verified code from the preceding recovery step.
    func resetPasswordAndSignIn(email: String, code: String, password: String, country: String) async throws -> OfficialLoginCandidate {
        let country = try selectedCountry(country)
        let configuration = try await accountRoute(email: email, country: country)
        var body = identity(email)
        body["code"] = code; body["password"] = passwordDigest(password)
        let root = try await transport.request(method: "POST", path: "/identify/password/find",
            body: body, configuration: configuration)
        _ = try transport.tclData(root)
        do {
            return try await signIn(email: email, password: password, country: country)
        } catch {
            throw PasswordResetAutoLoginFailure(error: error)
        }
    }

    func signIn(email: String, password: String, country: String) async throws -> OfficialLoginCandidate {
        let country = try selectedCountry(country)
        let configuration = try await accountRoute(email: email, country: country)
        var body = identity(email)
        body.merge(metadata(country: configuration.countryCode ?? country)) { _, value in value }
        body["password"] = passwordDigest(password); body["deviceId"] = NSNull()
        let started = Date()
        let root = try await transport.request(method: "POST", path: "/identify/login",
            body: body, configuration: configuration)
        return try await candidate(root, configuration: configuration, started: started, country: country)
    }

    func register(email: String, password: String, code: String, country: String) async throws -> OfficialLoginCandidate {
        let country = try selectedCountry(country)
        let configuration = try await countryRoute(country)
        var body = identity(email)
        body.merge(metadata(country: country)) { _, value in value }
        body["code"] = code; body["password"] = passwordDigest(password)
        let started = Date()
        let root = try await transport.request(method: "POST", path: "/identify/register",
            body: body, configuration: configuration)
        if tclErrorCode(root) == "AccountExist" {
            return try await signIn(email: email, password: password, country: country)
        }
        return try await candidate(root, configuration: configuration, started: started, country: country)
    }

    func agreements(country: String) async throws -> [OfficialAgreement] {
        let country = try selectedCountry(country)
        let configuration = try await countryRoute(country)
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
        let language = locale.language.languageCode?.identifier ?? "zh"
        let region = locale.region?.identifier
        let agreementLanguage = language == "zh" && ["HK", "TW"].contains(region ?? "") ? "zh-" + region! : language
        let root = try await transport.request(method: "GET", path: "/profileapi/v1/user/agreements/preDeposit",
            query: [URLQueryItem(name: "appType", value: "RayNeoAI"),
                    URLQueryItem(name: "agreementLanguage", value: agreementLanguage)], configuration: configuration)
        guard let code = number(root["code"]), code.doubleValue == 0 else {
            throw OfficialAccountFailure(message: root["userFriendlyTip"] as? String ?? root["msg"] as? String ?? "官方协议目录返回业务错误。")
        }
        guard let data = root["data"] as? [[String: Any]] else {
            throw OfficialAccountFailure(message: "官方协议目录未返回协议列表。")
        }
        return try JSONDecoder().decode([OfficialAgreement].self, from: JSONSerialization.data(withJSONObject: data))
            .sorted { $0.priority < $1.priority }
    }

    private func candidate(_ root: [String: Any], configuration: OfficialFirmwareConfiguration,
                           started: Date, country: String) async throws -> OfficialLoginCandidate {
        guard let value = try transport.tclData(root) as? [String: Any],
              let token = value["token"] as? String, let refresh = value["refreshToken"] as? String,
              let accessSeconds = integer(value["expiresIn"]), let refreshSeconds = integer(value["rtExpiresIn"]),
              let user = value["userInfo"] as? [String: Any] else {
            throw OfficialAccountFailure(message: "官方邮箱登录响应缺少完整会话或账号信息，未替换本机会话。")
        }
        let profile = try OfficialAccountProfile(json: user)
        let routedBusiness = try await businessRoute(value, configuration: configuration, country: country)
        let business = try canonicalBusinessConfiguration(routedBusiness)
        var session = OfficialAccountSession(accessToken: token, refreshToken: refresh,
            accessExpiresAt: started.addingTimeInterval(accessSeconds.doubleValue),
            refreshExpiresAt: started.addingTimeInterval(refreshSeconds.doubleValue), accountID: profile.accountID,
            region: business.region, businessBaseURL: business.baseURL.absoluteString,
            accountRouteRegion: business.accountRouteRegion,
            countryCode: nonempty(user["countryCode"])?.lowercased() ?? configuration.countryCode ?? country,
            clientDeviceID: configuration.clientDeviceID, deviceCode: configuration.deviceCode, savedAt: Date())
        session.profile = profile
        _ = try OfficialFirmwareConfiguration.fromSession(session, appVersion: configuration.appVersion)
        return OfficialLoginCandidate(session: session, needsProfile: value["needCompleteUserInfo"] as? Bool != false, userInfo: user)
    }

    func accountRoute(email: String, country: String) async throws -> OfficialFirmwareConfiguration {
        let fallback = try configuration(domain: bootstrapURL, country: country, routeRegion: nil)
        return try await lookupRoute(path: "/route/account", body: identity(email), country: country, fallback: fallback) ?? fallback
    }

    private func countryRoute(_ country: String) async throws -> OfficialFirmwareConfiguration {
        let fallback = try configuration(domain: bootstrapURL, country: country, routeRegion: nil)
        do {
            let root = try await transport.request(method: "POST", path: "/route/country",
                body: ["countryCode": country, "lang": NSNull()], configuration: fallback)
            guard let items = try transport.tclData(root) as? [[String: Any]], !items.isEmpty else { return fallback }
            let item = items.first { nonempty($0["countryCode"])?.lowercased() == country } ?? items[0]
            return try route(item, fallback: fallback) ?? fallback
        } catch {
            try Task.checkCancellation()
            return fallback
        }
    }

    private func lookupRoute(path: String, body: [String: Any], country: String,
                             fallback: OfficialFirmwareConfiguration, inheritRegion: Bool = true) async throws -> OfficialFirmwareConfiguration? {
        let bootstrap = try configuration(domain: bootstrapURL, country: country, routeRegion: nil)
        do {
            let root = try await transport.request(method: "POST", path: path, body: body, configuration: bootstrap)
            guard let data = try transport.tclData(root) as? [String: Any] else { return nil }
            return try route(data, fallback: fallback, inheritRegion: inheritRegion)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func businessRoute(_ data: [String: Any], configuration fallback: OfficialFirmwareConfiguration,
                               country: String) async throws -> OfficialFirmwareConfiguration {
        let fixed = ["xr-api-hw-t.rayneo.com", "xr-api-eu-pre.rayneo.com"]
        if fallback.region == .domestic || fixed.contains(fallback.baseURL.host ?? "") { return fallback }
        if let third = data["thirdUserInfo"] as? [[String: Any]], let first = third.first,
           let unionID = nonempty(first["unionId"]),
           let resolved = try await lookupRoute(path: "/route/unionId", body: ["unionId": unionID], country: country,
               fallback: fallback, inheritRegion: false) {
            return resolved
        }
        if let user = data["userInfo"] as? [String: Any], let email = nonempty(user["email"]),
           let resolved = try await lookupRoute(path: "/route/account", body: identity(email), country: country,
               fallback: fallback, inheritRegion: false) {
            return resolved
        }
        return fallback
    }

    private func route(_ value: [String: Any], fallback: OfficialFirmwareConfiguration,
                       inheritRegion: Bool = true) throws -> OfficialFirmwareConfiguration? {
        guard var domain = nonempty(value["domain"]) else { return nil }
        if domain.hasSuffix("/") { domain.removeLast() }
        return try configuration(domain: domain, country: nonempty(value["countryCode"]) ?? fallback.countryCode!,
            routeRegion: nonempty(value["region"])?.lowercased() ?? (inheritRegion ? fallback.accountRouteRegion : nil))
    }

    private func configuration(domain: String, country: String, routeRegion: String?) throws -> OfficialFirmwareConfiguration {
        let region: OfficialFirmwareRegion = URL(string: domain)?.host?.hasSuffix(".rayneo.cn") == true ? .domestic : .overseas
        let anonymous = OfficialAccountSession(accessToken: "", refreshToken: nil, accessExpiresAt: nil,
            refreshExpiresAt: nil, accountID: nil, region: region, businessBaseURL: domain,
            accountRouteRegion: routeRegion, countryCode: country,
            clientDeviceID: nonempty(environment["RAYNEO_CLIENT_DEVICE_ID"]),
            deviceCode: nonempty(environment["RAYNEO_DEVICE_CODE"]), savedAt: Date())
        return try OfficialFirmwareConfiguration.fromSession(anonymous,
            appVersion: nonempty(environment["RAYNEO_CLIENT_APP_VERSION"]) ?? "1.0.10")
    }

    private func canonicalBusinessConfiguration(_ value: OfficialFirmwareConfiguration) throws -> OfficialFirmwareConfiguration {
        let domain: String
        switch value.baseURL.absoluteString {
        case "https://xr-api-p.rayneo.cn", "https://xr-api-pre.rayneo.cn", "https://xr-api-t.rayneo.cn", "https://xr-api-d.rayneo.cn":
            domain = "https://xr-api-p.rayneo.cn"
        case "https://xr-api-hw-t.rayneo.com", "https://xr-api-eu-pre.rayneo.com":
            domain = "https://xr-api-hw-t.rayneo.com"
        default:
            return value
        }
        return try configuration(domain: domain, country: value.countryCode!, routeRegion: value.accountRouteRegion)
    }

    private func identity(_ email: String) -> [String: Any] {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["sendType": 2, "bindType": 2, "type": 2, "loginName": email, "bindName": email, "runtimeType": "email"]
    }

    private func metadata(country: String) -> [String: Any] {
        ["countryCode": country, "systemVersion": NSNull(), "deviceModel": NSNull(), "language": NSNull()]
    }

    private func selectedCountry(_ value: String) throws -> String {
        let country = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard country.utf8.count == 2, country.utf8.allSatisfy({ (97...122).contains($0) }), country != "cn" else {
            throw OfficialAccountFailure(message: "海外邮箱登录需要明确选择两位国家码；中国大陆请使用手机号入口。")
        }
        return country
    }

    private func passwordDigest(_ password: String) -> String {
        Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func tclErrorCode(_ root: [String: Any]) -> String? {
        let code = root["errorCode"].flatMap { $0 is NSNull ? nil : $0 } ?? root["code"].flatMap { $0 is NSNull ? nil : $0 }
        return code.map { String(describing: $0) }
    }

    private func codeOutcome(_ root: [String: Any]) throws -> OfficialSMSOutcome {
        if tclErrorCode(root) == "PeriodValidCode" {
            let message = root["msg"] as? String ?? root["message"] as? String ?? "此前发送的邮箱验证码仍有效。"
            return OfficialSMSOutcome(retryAfter: cooldownSeconds(message), notice: message)
        }
        _ = try transport.tclData(root)
        return OfficialSMSOutcome(retryAfter: nil, notice: nil)
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value
    }

    private func integer(_ value: Any?) -> NSNumber? {
        guard let value = number(value), !["f", "d"].contains(String(cString: value.objCType)) else { return nil }
        return value
    }

    private func cooldownSeconds(_ message: String) -> Int? {
        for pattern in ["(\\d+)\\s*s\\b", "(\\d+)"] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message), let seconds = Int(message[range]) else { continue }
            return min(63_072_000, max(0, seconds))
        }
        return nil
    }
}
