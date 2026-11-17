// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import Security

struct OfficialAccountFailure: LocalizedError {
    let message: String
    let requiresReauthentication: Bool
    init(message: String, requiresReauthentication: Bool = false) {
        self.message = message; self.requiresReauthentication = requiresReauthentication
    }
    var errorDescription: String? { message }
}

/// Only this application's account session is stored here; tokens are never UI status fields.
struct OfficialAccountSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var accessExpiresAt: Date?
    var refreshExpiresAt: Date?
    var accountID: String?
    var region: OfficialFirmwareRegion
    var businessBaseURL: String
    var accountRouteRegion: String?
    var countryCode: String?
    var clientDeviceID: String?
    var deviceCode: String?
    var savedAt: Date
    var identityEpoch: UUID? = nil
    var credentialRevision: Int? = nil
    var profile: OfficialAccountProfile? = nil
}

extension Notification.Name {
    static let officialAccountSessionChanged = Notification.Name("OpenRayneo.officialAccountSessionChanged")
    static let officialAccountCredentialsRotated = Notification.Name("OpenRayneo.officialAccountCredentialsRotated")
    static let officialAccountCoordinatorStateChanged = Notification.Name("OpenRayneo.officialAccountCoordinatorStateChanged")
}

enum OfficialAccountSessionChange { case identity, credentials, metadata }

enum OfficialAccountSessionStore {
    private static let service = "com.openrayneo.bridge.official-account"
    private static let account = "active-session"
    private static let selectionKey = "officialAccountUseSavedSession"
    private static let signedOutKey = "officialAccountSignedOut"

    static var isSignedOut: Bool {
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.bool(forKey: signedOutKey)
    }

    static var prefersSavedSession: Bool {
        UserDefaults.standard.synchronize()
        return UserDefaults.standard.bool(forKey: selectionKey)
    }

    static func selectedSession(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> OfficialAccountSession? {
        if isSignedOut { return nil }
        if let saved = try load() { return saved }
        if prefersSavedSession {
            throw OfficialAccountFailure(message: "本机选用的官方会话已不存在，请重新登录或清除本机会话选择。")
        }
        func value(_ key: String) -> String? {
            environment[key].flatMap { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        guard let token = value("RAYNEO_ACCESS_TOKEN") else { return nil }
        guard let region = OfficialFirmwareRegion(rawValue: value("RAYNEO_REGION") ?? "domestic") else {
            throw OfficialAccountFailure(message: "RAYNEO_REGION 必须为 domestic 或 overseas。")
        }
        return OfficialAccountSession(accessToken: token, refreshToken: value("RAYNEO_REFRESH_TOKEN"),
            accessExpiresAt: nil, refreshExpiresAt: nil, accountID: value("RAYNEO_ACCOUNT_ID"), region: region,
            businessBaseURL: value("RAYNEO_API_BASE_URL") ?? region.baseURL.absoluteString,
            accountRouteRegion: value("RAYNEO_ACCOUNT_ROUTE_REGION"), countryCode: value("RAYNEO_COUNTRY_CODE"),
            clientDeviceID: value("RAYNEO_CLIENT_DEVICE_ID"), deviceCode: value("RAYNEO_DEVICE_CODE"), savedAt: Date())
    }

    static func load() throws -> OfficialAccountSession? {
        var query = noninteractiveIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OfficialAccountSession.self, from: data)
    }

    static func save(_ session: OfficialAccountSession, change: OfficialAccountSessionChange = .identity) throws {
        guard !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficialAccountFailure(message: "官方会话缺少访问令牌，未保存。")
        }
        _ = try OfficialFirmwareConfiguration.fromSession(session)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let query = noninteractiveIdentity
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OpenRayneo 官方账号会话"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
        UserDefaults.standard.set(true, forKey: selectionKey)
        UserDefaults.standard.set(false, forKey: signedOutKey)
        UserDefaults.standard.synchronize()
        let notification: Notification.Name
        switch change {
        case .identity: notification = .officialAccountSessionChanged
        case .credentials: notification = .officialAccountCredentialsRotated
        case .metadata: notification = .officialAccountCoordinatorStateChanged
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func clear() throws {
        let query = noninteractiveIdentity
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        UserDefaults.standard.set(false, forKey: selectionKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: .officialAccountSessionChanged, object: nil)
    }

    static func signOut() throws {
        UserDefaults.standard.set(true, forKey: signedOutKey)
        UserDefaults.standard.synchronize()
        do { try clear() }
        catch {
            NotificationCenter.default.post(name: .officialAccountSessionChanged, object: nil)
            throw error
        }
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private static var noninteractiveIdentity: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static func failure(_ status: OSStatus) -> OfficialAccountFailure {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态 \(status)"
        return OfficialAccountFailure(message: "本机官方会话钥匙串操作失败：\(detail)")
    }
}
