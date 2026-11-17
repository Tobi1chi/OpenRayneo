// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

enum OfficialTokenAuthKind: String {
    case invalidToken, accessTokenExpired, refreshTokenExpired
}

enum OfficialTokenAuthentication {
    static func kind(httpStatus: Int, body: [String: Any]?, refreshing: Bool = false) -> OfficialTokenAuthKind? {
        if let body {
            if let code = number(body["code"]), code.doubleValue == 401,
               body["errorDomain"] as? String == "auth", let value = body["tokenAuthKind"] as? String,
               let kind = OfficialTokenAuthKind(rawValue: value) { return kind }
            if let legacy = body["errorCode"] as? String {
                switch legacy {
                case "Unauthorized": return .invalidToken
                case "TokenExpire": return .accessTokenExpired
                case "RefreshTokenExpire", "ServiceTokenExpire": return .refreshTokenExpired
                default: break
                }
            } else if integer(body["code"]) == 401 { return .accessTokenExpired }
        }
        return httpStatus == 401 ? (refreshing ? .invalidToken : .accessTokenExpired) : nil
    }

    static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value
    }
    private static func integer(_ value: Any?) -> Int? {
        if let number = number(value) { return number.intValue }
        return (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
