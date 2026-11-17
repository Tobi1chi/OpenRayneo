// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialCloudDevice: Codable, Identifiable, Sendable {
    let sn: String?
    let deviceType: String?
    let deviceName: String?
    let mfiSerialNumber: String?
    private let bondKey: String?
    let macAddr: String?
    let glassesDeviceId: String?

    init(sn: String? = nil, deviceType: String? = nil, deviceName: String? = nil,
         mfiSerialNumber: String? = nil, bondKey: String? = nil, macAddr: String? = nil,
         glassesDeviceId: String? = nil) {
        self.sn = sn; self.deviceType = deviceType; self.deviceName = deviceName
        self.mfiSerialNumber = mfiSerialNumber; self.bondKey = bondKey
        self.macAddr = macAddr; self.glassesDeviceId = glassesDeviceId
    }

    var id: String {
        [macAddr.map(normalizedCloudDeviceMAC) ?? "", deviceType ?? "", glassesDeviceId ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    /// Only these fields may be used for raw-record UI; the binding key stays inside this file.
    var metadata: [String: String] {
        ["sn": sn, "deviceType": deviceType, "deviceName": deviceName,
         "mfiSerialNumber": mfiSerialNumber, "macAddr": macAddr,
         "glassesDeviceId": glassesDeviceId].compactMapValues { $0 }
    }

    func mergeCloudFields(into record: inout OfficialCloudDeviceRepository.Record) {
        record.mergeCloudFields(sn: sn, name: deviceName, localMfiSerialNumber: mfiSerialNumber, bondKey: bondKey)
    }

    fileprivate func bindingBody() throws -> [String: Any] {
        guard let deviceType, let deviceName, let macAddr else {
            throw OfficialCloudDeviceFailure(message: "云绑定缺少设备类型、名称或 MAC 地址。", kind: .configuration)
        }
        var body: [String: Any] = ["deviceType": deviceType, "deviceName": deviceName,
                                   "macAddr": normalizedCloudDeviceMAC(macAddr)]
        for (key, value) in [("sn", sn), ("mfiSerialNumber", mfiSerialNumber),
                             ("bondKey", bondKey), ("glassesDeviceId", glassesDeviceId)] {
            if let value { body[key] = value }
        }
        return body
    }
}

struct OfficialDeviceBindingStatus: Decodable, Sendable {
    let status: String?
    let maskedAccount: String?

    var bindingOtherAccount: Bool {
        guard let status, !status.isEmpty else { return false }
        return status != "not_bind" && status != "bind_self"
    }

    var boundToCurrentAccount: Bool { status == "bind_self" }

    var statusDescription: String {
        switch status {
        case "not_bind": return "未绑定账号"
        case "bind_self": return "已绑定当前账号"
        case nil, "": return "绑定状态未确认"
        default:
            return maskedAccount.map { "已绑定其他账号：" + $0 } ?? "已绑定其他账号"
        }
    }
}

struct OfficialCloudDeviceFailure: LocalizedError, Sendable {
    enum Kind: Sendable { case business, authentication, invalidResponse, http, configuration }
    let message: String
    let kind: Kind
    init(message: String, kind: Kind = .business) { self.message = message; self.kind = kind }
    var errorDescription: String? { message }
}

/// Official account device records; local Bluetooth pairing and device erasure are separate operations.
final class OfficialCloudDeviceService {
    private let configuration: OfficialFirmwareConfiguration
    private let network: URLSession
    private let bindingNetwork: URLSession

    init(configuration: OfficialFirmwareConfiguration) {
        self.configuration = configuration
        network = Self.makeSession(timeout: 20)
        bindingNetwork = Self.makeSession(timeout: 8)
    }

    deinit { network.invalidateAndCancel(); bindingNetwork.invalidateAndCancel() }

    func list() async throws -> [OfficialCloudDevice] {
        let value = try await request(method: "GET", path: "/identify/device/list")
        // The official successful-data converter returns [] for any non-List value.
        guard let rows = value as? [Any] else { return [] }
        guard rows.allSatisfy({ $0 is [String: Any] }) else {
            throw OfficialCloudDeviceFailure(message: "官方设备列表不是可识别的数组，已保留原有设备。", kind: .invalidResponse)
        }
        do {
            return try JSONDecoder().decode([OfficialCloudDevice].self,
                from: JSONSerialization.data(withJSONObject: rows))
        } catch { throw OfficialCloudDeviceFailure(message: "官方设备列表包含无法解析的字段，已保留原有设备。", kind: .invalidResponse) }
    }

    func checkBinding(macAddress: String?, glassesDeviceID: String?) async throws -> OfficialDeviceBindingStatus {
        let deadline = OfficialBindingDeadline()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                deadline.start(continuation) { [self] in
                    var query: [URLQueryItem] = []
                    if let macAddress { query.append(URLQueryItem(name: "macAddr", value: normalizedCloudDeviceMAC(macAddress))) }
                    if let glassesDeviceID { query.append(URLQueryItem(name: "glassesDeviceId", value: glassesDeviceID)) }
                    let value = try await request(method: "GET", path: "/identify/v2/device/checkBind", query: query, timeout: 8)
                    guard let record = value as? [String: Any] else {
                        throw OfficialCloudDeviceFailure(message: "官方绑定关系不是可识别的记录，未确认绑定状态。", kind: .invalidResponse)
                    }
                    do {
                        return try JSONDecoder().decode(OfficialDeviceBindingStatus.self,
                            from: JSONSerialization.data(withJSONObject: record))
                    } catch { throw OfficialCloudDeviceFailure(message: "官方绑定关系包含无法解析的字段，未确认绑定状态。", kind: .invalidResponse) }
                }
            }
        } onCancel: {
            deadline.cancel()
        }
    }

    func bind(_ device: OfficialCloudDevice) async throws -> Bool {
        let body = try device.bindingBody()
        let value = try await request(method: "POST", path: "/identify/device/bind", body: body)
        guard let result = value as? NSNumber, CFGetTypeID(result) == CFBooleanGetTypeID() else {
            throw OfficialCloudDeviceFailure(message: "官方绑定响应缺少布尔结果，未确认绑定成功。", kind: .invalidResponse)
        }
        return result.boolValue
    }

    func unbind(_ device: OfficialCloudDevice) async throws {
        let body: [String: Any] = ["macAddr": device.macAddr.map(normalizedCloudDeviceMAC) as Any? ?? NSNull(),
            "deviceType": device.deviceType as Any? ?? NSNull(), "glassesDeviceId": device.glassesDeviceId as Any? ?? NSNull()]
        _ = try await request(method: "POST", path: "/identify/device/unbind", body: body)
    }

    private func request(method: String, path: String, query: [URLQueryItem] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> Any {
        let current = try await OfficialSessionCoordinator.shared.prepare(reference: configuration)
        try Task.checkCancellation()
        guard !current.accessToken.isEmpty else {
            throw OfficialCloudDeviceFailure(message: "未配置官方账号会话，请先登录或导入已有会话。", kind: .configuration)
        }
        var components = URLComponents(url: current.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OfficialCloudDeviceFailure(message: "无法构造官方设备请求地址。", kind: .configuration) }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        current.applySessionHeaders(to: &request)
        request.setValue(current.appVersion, forHTTPHeaderField: "app-version")
        request.setValue(current.appVersion, forHTTPHeaderField: "version")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "time-zone")
        if let value = current.deviceCode { request.setValue(value, forHTTPHeaderField: "device-code") }
        if let value = current.clientDeviceID {
            for name in ["device-id", "device_id", "deviceId"] { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let value = current.accountRouteRegion { request.setValue(value, forHTTPHeaderField: "accountRouteRegion") }
        try current.signingHeaders(method: method, url: url, body: request.httpBody)
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let session = timeout == 8 ? bindingNetwork : network
        try OfficialCloudPolicy.requireEnabled()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfficialCloudDeviceFailure(message: "官方设备请求没有返回 HTTP 响应。", kind: .invalidResponse)
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if OfficialTokenAuthentication.kind(httpStatus: http.statusCode, body: root) != nil {
            try? await OfficialSessionCoordinator.shared.markAccessTokenExpired(current)
            throw OfficialCloudDeviceFailure(message: "官方访问令牌被拒绝；本次设备操作未重试，下一次请求将尝试刷新会话。", kind: .authentication)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OfficialCloudDeviceFailure(message: "官方设备请求失败（HTTP \(http.statusCode)）。", kind: .http)
        }
        guard let root else { throw OfficialCloudDeviceFailure(message: "官方设备响应不是可识别的数据包装。", kind: .invalidResponse) }
        // TclApiResponse succeeds only when both code fields are absent or null; numeric zero is an error here.
        let code = root["errorCode"].flatMap { $0 is NSNull ? nil : $0 }
            ?? root["code"].flatMap { $0 is NSNull ? nil : $0 }
        if code != nil {
            throw OfficialCloudDeviceFailure(message: root["msg"] as? String ?? root["message"] as? String ?? "官方设备请求返回业务错误。", kind: .business)
        }
        return root["data"] ?? NSNull()
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.httpShouldSetCookies = false
        options.urlCredentialStorage = nil; options.urlCache = nil
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        options.timeoutIntervalForRequest = timeout; options.timeoutIntervalForResource = timeout
        return URLSession(configuration: options, delegate: OfficialCloudDeviceRedirectPolicy(), delegateQueue: nil)
    }
}

private func normalizedCloudDeviceMAC(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: ":", with: "")
}

/// The request may still be awaiting a shared refresh after cancellation; callers never wait for that cleanup.
private final class OfficialBindingDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    private var continuation: CheckedContinuation<OfficialDeviceBindingStatus, Error>?
    private var result: Result<OfficialDeviceBindingStatus, Error>?
    private var requestTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<OfficialDeviceBindingStatus, Error>,
               operation: @escaping () async throws -> OfficialDeviceBindingStatus) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        guard ContinuousClock.now < deadline else {
            let expired: Result<OfficialDeviceBindingStatus, Error> = .failure(URLError(.timedOut))
            result = expired
            lock.unlock()
            continuation.resume(with: expired)
            return
        }
        self.continuation = continuation
        requestTask = Task { [self] in
            do {
                try Task.checkCancellation()
                finish(.success(try await operation()))
            }
            catch { finish(.failure(error)) }
        }
        timerTask = Task { [self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            finish(.failure(URLError(.timedOut)))
        }
        lock.unlock()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ value: Result<OfficialDeviceBindingStatus, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let resolved: Result<OfficialDeviceBindingStatus, Error> = ContinuousClock.now >= deadline
            ? .failure(URLError(.timedOut)) : value
        result = resolved
        let continuation = self.continuation
        self.continuation = nil
        let request = requestTask, timer = timerTask
        requestTask = nil; timerTask = nil
        lock.unlock()
        request?.cancel(); timer?.cancel()
        continuation?.resume(with: resolved)
    }
}

private final class OfficialCloudDeviceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
