// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum OfficialAccountDataIdentity {
    case email(String, country: String)
    case phone(String)

    var label: String {
        switch self {
        case .email(let address, _): return "邮箱：" + address
        case .phone(let number): return "手机号：" + number
        }
    }
}

/// Scene 8 verifies the chosen account's bound contact without using its access token.
final class OfficialAccountDataVerificationService {
    private let transport = OfficialPhoneLoginService()
    private let emailService = OfficialEmailLoginService()

    func sendCode(_ identity: OfficialAccountDataIdentity) async throws -> OfficialSMSOutcome {
        let context = try await requestContext(identity)
        var body = context.body
        body["validate"] = NSNull(); body["sceneType"] = 8
        let root = try await transport.request(method: "POST", path: "/identify/common/sendVerifyCode",
            body: body, configuration: context.configuration)
        if errorCode(root) == "PeriodValidCode" {
            let message = root["msg"] as? String ?? root["message"] as? String ?? "此前发送的验证码仍有效。"
            return OfficialSMSOutcome(retryAfter: cooldownSeconds(message), notice: message)
        }
        _ = try transport.tclData(root)
        return OfficialSMSOutcome(retryAfter: nil, notice: nil)
    }

    func verifyCode(_ identity: OfficialAccountDataIdentity, code: String) async throws {
        let context = try await requestContext(identity)
        var body = context.body
        body["code"] = code; body["sceneType"] = 8
        let root = try await transport.request(method: "POST", path: "/identify/common/checkVerifyCode",
            body: body, configuration: context.configuration)
        _ = try transport.tclData(root)
    }

    private func requestContext(_ identity: OfficialAccountDataIdentity) async throws ->
        (body: [String: Any], configuration: OfficialFirmwareConfiguration?) {
        switch identity {
        case .email(let address, let country):
            let email = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = try await emailService.accountRoute(email: email,
                country: country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            return (["sendType": 2, "bindType": 2, "type": 2, "loginName": email,
                     "bindName": email, "runtimeType": "email"], configuration)
        case .phone(let value):
            let phone = Self.normalizedPhone(value)
            // The transport's default is its token-free mainland production configuration.
            return (["sendType": 3, "bindType": 3, "type": 3, "loginName": phone,
                     "bindName": phone, "areaCode": "+86", "runtimeType": "phone"], nil)
        }
    }

    static func normalizedPhone(_ value: String) -> String {
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

    private func errorCode(_ root: [String: Any]) -> String? {
        let code = root["errorCode"].flatMap { $0 is NSNull ? nil : $0 } ?? root["code"].flatMap { $0 is NSNull ? nil : $0 }
        return code.map { String(describing: $0) }
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
