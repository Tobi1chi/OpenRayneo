// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

final class OfficialAccountService {
    private let session: URLSession

    init() {
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCredentialStorage = nil; options.urlCache = nil
        options.timeoutIntervalForRequest = 15; options.timeoutIntervalForResource = 15
        session = URLSession(configuration: options, delegate: OfficialAccountRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func refresh(_ previous: OfficialAccountSession) async throws -> OfficialAccountSession {
        guard let refreshToken = previous.refreshToken, !refreshToken.isEmpty else {
            throw OfficialAccountFailure(message: "当前会话没有 refresh token，请重新登录或配置完整会话。")
        }
        let configuration = try OfficialFirmwareConfiguration.fromSession(previous,
            appVersion: ProcessInfo.processInfo.environment["RAYNEO_CLIENT_APP_VERSION"] ?? "1.0.10")
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/authapi/token/refresh"
        let url = components.url!
        let startedAt = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken], options: [.sortedKeys, .withoutEscapingSlashes])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The original refresh caller supplies its RT in both places, avoiding token-interceptor recursion.
        request.setValue(refreshToken, forHTTPHeaderField: "xtcl-access-token")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "app-version")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "version")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "time-zone")
        if let value = configuration.deviceCode { request.setValue(value, forHTTPHeaderField: "device-code") }
        if let value = configuration.clientDeviceID {
            for header in ["device-id", "device_id", "deviceId"] { request.setValue(value, forHTTPHeaderField: header) }
        }
        if let value = configuration.accountRouteRegion { request.setValue(value, forHTTPHeaderField: "accountRouteRegion") }
        try configuration.signingHeaders(method: "POST", url: url, body: request.httpBody)
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try OfficialCloudPolicy.requireEnabled()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OfficialAccountFailure(message: "官方会话刷新没有返回 HTTP 响应。") }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if OfficialTokenAuthentication.kind(httpStatus: http.statusCode, body: root, refreshing: true) != nil {
            throw OfficialAccountFailure(message: "官方会话已失效，需要重新登录。", requiresReauthentication: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OfficialAccountFailure(message: "官方会话刷新失败（HTTP \(http.statusCode)），本地旧会话保留。")
        }
        guard let root else {
            throw OfficialAccountFailure(message: "官方会话刷新响应不是记录对象。")
        }
        guard let code = number(root["code"]), code.doubleValue == 0 else {
            let message = root["userFriendlyTip"] as? String ?? root["msg"] as? String ?? "官方会话刷新返回业务错误。"
            throw OfficialAccountFailure(message: message)
        }
        guard let value = root["data"] as? [String: Any], let seconds = number(value["expiresIn"]) else {
            throw OfficialAccountFailure(message: "官方刷新响应缺少 expiresIn，未替换旧会话。")
        }
        var next = previous
        if let token = value["token"] as? String { next.accessToken = token }
        if let token = value["refreshToken"] as? String { next.refreshToken = token }
        next.accessExpiresAt = startedAt.addingTimeInterval(seconds.doubleValue)
        if let seconds = number(value["rtExpiresIn"]) {
            next.refreshExpiresAt = startedAt.addingTimeInterval(seconds.doubleValue)
        } else if previous.refreshExpiresAt.map({ $0 < Date() }) != false {
            next.refreshExpiresAt = next.accessExpiresAt
        }
        next.savedAt = Date()
        return next
    }

    private func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value
    }
}

private final class OfficialAccountRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
