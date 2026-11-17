// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

struct OfficialFirmwareFailure: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

enum OfficialFirmwareRegion: String, Codable, Sendable {
    case domestic, overseas

    var baseURL: URL {
        URL(string: self == .domestic ? "https://xr-api-p.rayneo.cn" : "https://xr-api-hw-t.rayneo.com")!
    }

    var path: String {
        self == .domestic ? "/xrlauncherapi/v1/signApi/gray/upgrade" : "/xrlauncherhwapi/v1/signApi/gray/upgrade"
    }

    // APK 1.0.10: ApiSignInterceptor 0x171dc98 / 0x171dc70.
    // These identify the vendor client; they are independent of the user's session.
    fileprivate var appID: String {
        self == .domestic ? "bf16c55936bb4d439c2d7a914a806559" : "d1d9fe515085476bbe0e60a6fa2b0917"
    }

    fileprivate var appKey: String {
        self == .domestic ? "UGuW3frdyM@Ah*oRLSa^3f8C&H47dQ5~" : "^K4Y4cZ#gWn2*uKfvVUBp23aDZ%?QhpK"
    }
}

struct OfficialFirmwareConfiguration: Sendable {
    let region: OfficialFirmwareRegion
    let baseURL: URL
    let appVersion: String
    let deviceCode: String?
    let clientDeviceID: String?
    let accountRouteRegion: String?
    let countryCode: String?
    let accessToken: String
    let accountID: String
    let identityEpoch: UUID?
    let credentialRevision: Int
    let accessExpiresAt: Date?
    let refreshExpiresAt: Date?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try OfficialCloudPolicy.requireEnabled()
        func value(_ key: String) -> String? {
            guard let text = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        if let selected = try OfficialAccountSessionStore.selectedSession(environment: environment) {
            return try fromSession(selected, appVersion: value("RAYNEO_CLIENT_APP_VERSION") ?? "1.0.10")
        }
        let regionText = value("RAYNEO_REGION") ?? "domestic"
        guard let region = OfficialFirmwareRegion(rawValue: regionText) else {
            throw OfficialFirmwareFailure(code: "configuration", message: "RAYNEO_REGION 必须为 domestic 或 overseas。")
        }
        let baseURL = try businessURL(value("RAYNEO_API_BASE_URL"), region: region)
        return Self(region: region, baseURL: baseURL, appVersion: value("RAYNEO_CLIENT_APP_VERSION") ?? "1.0.10",
            deviceCode: value("RAYNEO_DEVICE_CODE"), clientDeviceID: value("RAYNEO_CLIENT_DEVICE_ID"),
            accountRouteRegion: value("RAYNEO_ACCOUNT_ROUTE_REGION"), countryCode: value("RAYNEO_COUNTRY_CODE"), accessToken: OfficialAccountSessionStore.isSignedOut ? "" : value("RAYNEO_ACCESS_TOKEN") ?? "",
            accountID: OfficialAccountSessionStore.isSignedOut ? "" : value("RAYNEO_ACCOUNT_ID") ?? "", identityEpoch: nil, credentialRevision: 0,
            accessExpiresAt: nil, refreshExpiresAt: nil)
    }

    static func fromSession(_ session: OfficialAccountSession, appVersion: String = "1.0.10") throws -> Self {
        Self(region: session.region, baseURL: try businessURL(session.businessBaseURL, region: session.region),
            appVersion: appVersion, deviceCode: session.deviceCode, clientDeviceID: session.clientDeviceID,
            accountRouteRegion: session.accountRouteRegion, countryCode: session.countryCode,
            accessToken: session.accessToken, accountID: session.accountID ?? "", identityEpoch: session.identityEpoch,
            credentialRevision: session.credentialRevision ?? 0, accessExpiresAt: session.accessExpiresAt,
            refreshExpiresAt: session.refreshExpiresAt)
    }

    var sessionNeedsRefresh: Bool {
        let now = Date()
        return accessExpiresAt.map { $0 < now } == true || refreshExpiresAt.map { $0 < now } == true
    }

    func applySessionHeaders(to request: inout URLRequest) {
        request.setValue(accessToken, forHTTPHeaderField: "xtcl-access-token")
        if !accountID.isEmpty {
            for key in ["account_id", "accountId", "xr-account-id"] { request.setValue(accountID, forHTTPHeaderField: key) }
        }
    }

    func hasSameIdentity(as other: Self) -> Bool {
        identityEpoch == other.identityEpoch && accountID == other.accountID &&
            baseURL == other.baseURL && region == other.region
    }

    func signingHeaders(method: String, url: URL, body: Data? = nil,
                        now: Date = Date(), nonce: String = UUID().uuidString) throws -> [String: String] {
        let country = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (region == .domestic ? "cn" : "")
        if OfficialAccountRequestSigning.usesAccountGateway(url), country.isEmpty {
            throw OfficialAccountFailure(message: "账号网关需要会话对应的国家码，请补充国家码后再保存会话。")
        }
        var headers = OfficialAccountRequestSigning.headers(method: method, url: url, body: body,
            region: region, now: now, nonce: nonce, deviceCode: resolvedDeviceCode,
            appVersion: appVersion, countryCode: country)
        // APK HeaderInterceptor 0x279293c..0x27929d4: common to XR and account gateways.
        headers["platform"] = "android"
        headers["env"] = "android"
        headers["app-version"] = appVersion
        headers["version"] = appVersion
        headers["app-build-number"] = ProcessInfo.processInfo.environment["RAYNEO_CLIENT_APP_BUILD_NUMBER"] ?? "258"
        headers["region"] = OfficialAccountRequestSigning.normalizedCountryCode(country.isEmpty ? Locale.current.region?.identifier ?? "cn" : country)
        headers["device-code"] = resolvedDeviceCode
        headers["phone-model"] = "Mac"
        headers["phone-brand"] = "Apple"
        headers["phone-os-version"] = ProcessInfo.processInfo.operatingSystemVersionString
        return headers
    }

    var resolvedDeviceCode: String {
        let configured = deviceCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? Self.installedDeviceCode : configured
    }

    // RnDeviceCode 0x2792b94 persists a UUID on first use; it is an app installation ID, not a glasses ID.
    private static let installedDeviceCode: String = {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "officialClientDeviceCode"), !saved.isEmpty { return saved }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: "officialClientDeviceCode")
        return generated
    }()

    private static func businessURL(_ text: String?, region: OfficialFirmwareRegion) throws -> URL {
        if let text {
            guard let url = URL(string: text), url.scheme == "https", let host = url.host,
                  host.hasSuffix(".rayneo.cn") || host.hasSuffix(".rayneo.com"),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw OfficialFirmwareFailure(code: "configuration", message: "RAYNEO_API_BASE_URL 必须为官方 RayNeo HTTPS 业务域名，不含路径或查询参数。")
            }
            guard (region == .domestic) == host.hasSuffix(".rayneo.cn") else {
                throw OfficialFirmwareFailure(code: "configuration", message: "官方业务域名与 RAYNEO_REGION 的签名区域不一致。")
            }
            return url
        }
        return region.baseURL
    }

    var missingSessionFields: [String] {
        [("RAYNEO_ACCESS_TOKEN", accessToken), ("RAYNEO_ACCOUNT_ID", accountID)].compactMap { $0.1.isEmpty ? $0.0 : nil }
    }
}

/// XR gateway signing is shared by firmware and official content requests.
enum OfficialXRRequestSigning {
    static func headers(method: String, url: URL, body: Data? = nil, region: OfficialFirmwareRegion,
                        now: Date = Date(), nonce: String = UUID().uuidString) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let nonce = nonce.replacingOccurrences(of: "-", with: "").lowercased()
        let timestamp = String(Int64(now.timeIntervalSince1970))
        let canonicalHeaders = "xtcl-nonce:\(nonce);xtcl-timestamp:\(timestamp);"
        let canonical = [method.uppercased(), components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            components.percentEncodedQuery ?? "", canonicalHeaders, digest(body ?? Data())].joined(separator: "\n")
        let stringToSign = ["TCL1-HMAC-SHA256", timestamp, digest(Data(canonical.utf8))].joined(separator: "\n")
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(region.appKey.utf8)))).base64EncodedString()
        return ["xtcl-nonce": nonce, "xtcl-timestamp": timestamp, "xtcl-app": region.appID,
            "xtcl-authorization": "TCL1-HMAC-SHA256 Credential=\(region.appID),SignedHeaders=xtcl-nonce;xtcl-timestamp;,Signature=\(signature)"]
    }

    private static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }
}

/// Deliberately not Codable: a GOTU URL can contain a short-lived authorization query.
struct OfficialFirmwareCandidate: Sendable {
    let id: String
    let deviceID: String
    let currentVersion: String
    let region: OfficialFirmwareRegion
    let taskName: String?
    let appName: String?
    let packageName: String?
    let versionName: String
    let versionCode: String?
    let upgradeType: Int?
    let userScope: String?
    let updateDescription: String?
    let appIcon: String?
    let archiveMD5: String?
    let archiveSize: Int64?
    fileprivate let downloadURL: URL
    var isForceUpdate: Bool { upgradeType == 2 }

    var metadata: [String: Any] {
        var result: [String: Any] = ["id": id, "deviceID": deviceID, "currentVersion": currentVersion,
            "region": region.rawValue, "versionName": versionName, "isForceUpdate": isForceUpdate,
            "downloadHost": downloadURL.host ?? "", "hasDownloadURL": true]
        for (key, value) in [("taskName", taskName), ("appName", appName), ("packageName", packageName),
            ("versionCode", versionCode), ("userScope", userScope), ("updateDesc", updateDescription),
            ("appIcon", appIcon), ("apkMd5", archiveMD5)] {
            if let value { result[key] = value }
        }
        if let archiveSize { result["apkSize"] = archiveSize }
        if let upgradeType { result["upgradeType"] = upgradeType }
        return result
    }
}

struct OfficialFirmwareCheckResult: Sendable {
    let checkedAt: Date
    let currentVersion: String
    let candidate: OfficialFirmwareCandidate?
    var metadata: [String: Any] {
        var result: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: checkedAt),
            "currentVersion": currentVersion, "hasUpdate": candidate != nil, "checkSucceeded": true]
        if let candidate { result["candidate"] = candidate.metadata }
        return result
    }
}

struct OfficialFirmwareDownload: Sendable {
    let candidate: OfficialFirmwareCandidate
    let archiveURL: URL
    let bytes: Int64
    let archiveMD5Verified: Bool
    /// Call the existing OTA prepare route with this body; installation is a separate action.
    var preparationBody: [String: Any] { ["path": archiveURL.path, "version": candidate.versionName] }
    var metadata: [String: Any] {
        ["candidateID": candidate.id, "path": archiveURL.path, "version": candidate.versionName,
         "bytes": bytes, "archiveMD5Verified": archiveMD5Verified, "prepared": false]
    }
}

/// No timer, startup task, or Bluetooth access. Invoke check/download only from explicit user actions.
final class OfficialFirmwareService {
    private let configuration: OfficialFirmwareConfiguration
    private let checkSession: URLSession
    private let downloadSession: URLSession
    private let directory: URL

    init(configuration: OfficialFirmwareConfiguration, directory: URL? = nil) {
        self.configuration = configuration
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OTADownloads", isDirectory: true)
        let check = Self.sessionConfiguration()
        check.timeoutIntervalForRequest = 20
        checkSession = URLSession(configuration: check, delegate: FirmwareCheckRedirectPolicy(), delegateQueue: nil)
        let download = Self.sessionConfiguration()
        download.timeoutIntervalForRequest = 60
        download.timeoutIntervalForResource = 3600
        downloadSession = URLSession(configuration: download)
    }

    deinit { checkSession.invalidateAndCancel(); downloadSession.invalidateAndCancel() }

    func configurationStatus() -> [String: Any] {
        ["region": configuration.region.rawValue, "apiHost": configuration.baseURL.host ?? "",
         "sessionConfigured": configuration.missingSessionFields.isEmpty,
         "missingSessionFields": configuration.missingSessionFields,
         "deviceCodeConfigured": configuration.deviceCode != nil,
         "clientAppVersion": configuration.appVersion, "automatic": false]
    }

    var credentialReference: [String: Any] {
        ["identityEpoch": configuration.identityEpoch?.uuidString as Any? ?? NSNull(),
         "credentialRevision": configuration.credentialRevision]
    }

    func matchesExpectedIdentity(_ expected: Any?) -> Bool {
        guard let expected else { return true }
        if expected is NSNull { return configuration.identityEpoch == nil }
        guard let value = expected as? String, let epoch = UUID(uuidString: value) else { return false }
        return epoch == configuration.identityEpoch
    }

    func check(currentVersion: String, deviceID: String) async throws -> OfficialFirmwareCheckResult {
        guard configuration.missingSessionFields.isEmpty else {
            throw OfficialFirmwareFailure(code: "authentication_required",
                message: "请配置官方账号会话：" + configuration.missingSessionFields.joined(separator: "、") + "。")
        }
        guard !configuration.sessionNeedsRefresh else {
            throw OfficialFirmwareFailure(code: "refresh_required", message: "官方会话需要由 Mac 账号协调器刷新后重新检查。")
        }
        let request = try makeCheckRequest(currentVersion: currentVersion)
        do {
            try OfficialCloudPolicy.requireEnabled()
            let (data, response) = try await checkSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OfficialFirmwareFailure(code: "invalid_response", message: "官方更新检查未返回 HTTP 响应。")
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if OfficialTokenAuthentication.kind(httpStatus: http.statusCode, body: root) != nil {
                throw OfficialFirmwareFailure(code: "access_token_rejected", message: "官方访问令牌被拒绝，下一次检查前需刷新。")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OfficialFirmwareFailure(code: "http_error", message: "官方更新检查失败（HTTP \(http.statusCode)）。")
            }
            return try parseCheck(data, currentVersion: currentVersion, deviceID: deviceID)
        } catch { throw Self.failure(error, operation: "官方版本检查") }
    }

    func download(candidate: OfficialFirmwareCandidate,
                  progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> OfficialFirmwareDownload {
        var request = URLRequest(url: candidate.downloadURL)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A separate bare session intentionally carries no RayNeo/AI credentials or cookies.
        let observer = FirmwareDownloadProgress(progress: progress)
        do {
            try OfficialCloudPolicy.requireEnabled()
            let (temporary, response) = try await downloadSession.download(for: request, delegate: observer)
            do {
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw OfficialFirmwareFailure(code: "download_http_error", message: "官方固件地址下载失败，可能需要重新检查以取得有效地址。")
                }
                try Task.checkCancellation()
                let bytes = ((try FileManager.default.attributesOfItem(atPath: temporary.path))[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0 else { throw OfficialFirmwareFailure(code: "empty_download", message: "固件下载结果为空。") }
                if let expected = candidate.archiveSize, expected > 0, expected != bytes {
                    throw OfficialFirmwareFailure(code: "archive_size_mismatch", message: "下载文件大小与官方候选的 apkSize 不一致。")
                }
                var md5Verified = false
                if let expected = candidate.archiveMD5, !expected.isEmpty {
                    guard try Self.archiveMD5(temporary).caseInsensitiveCompare(expected) == .orderedSame else {
                        throw OfficialFirmwareFailure(code: "archive_md5_mismatch", message: "下载文件与官方候选的 apkMd5 不一致。")
                    }
                    md5Verified = true
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let destination = directory.appendingPathComponent(UUID().uuidString + ".zip")
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return OfficialFirmwareDownload(candidate: candidate, archiveURL: destination,
                    bytes: bytes, archiveMD5Verified: md5Verified)
            } catch {
                try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil)
                throw error
            }
        } catch { throw Self.failure(error, operation: "固件下载") }
    }

    // FotaService 0x285ffd4 and generated _OTAApi 0x26b2b50 / 0x26b2f74.
    func makeCheckRequest(currentVersion: String, now: Date = Date(), nonce: String = UUID().uuidString) throws -> URLRequest {
        let version = try Self.versionCode(currentVersion)
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = configuration.region.path
        components.queryItems = [URLQueryItem(name: "packageName", value: "strix OS"),
            URLQueryItem(name: "versionCode", value: version), URLQueryItem(name: "deviceType", value: "android"),
            URLQueryItem(name: "appType", value: "RayNeoAI"), URLQueryItem(name: "appVersion", value: configuration.appVersion),
            URLQueryItem(name: "glassesType", value: "S3"), URLQueryItem(name: "glassesOsVersion", value: version),
            URLQueryItem(name: "packageType", value: "firmware")]
        guard let url = components.url else { throw OfficialFirmwareFailure(code: "configuration", message: "无法构造官方更新检查地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        configuration.applySessionHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "app-version")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "version")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "time-zone")
        if let deviceCode = configuration.deviceCode { request.setValue(deviceCode, forHTTPHeaderField: "device-code") }
        if let value = configuration.clientDeviceID {
            for name in ["device-id", "device_id", "deviceId"] { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let value = configuration.accountRouteRegion { request.setValue(value, forHTTPHeaderField: "accountRouteRegion") }
        try configuration.signingHeaders(method: "GET", url: url, now: now, nonce: nonce)
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    static func versionCode(_ raw: String) throws -> String {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("Strix OS ") { version = String(version.dropFirst(9)) }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty }) else {
            throw OfficialFirmwareFailure(code: "invalid_current_version", message: "需要眼镜实际的四段固件版本，例如 Strix OS 1.0.5.12。")
        }
        return parts.enumerated().map { index, part in
            String(repeating: "0", count: max(0, (index < 3 ? 2 : 4) - part.count)) + part
        }.joined(separator: ".")
    }

    private func parseCheck(_ data: Data, currentVersion: String, deviceID: String) throws -> OfficialFirmwareCheckResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root.keys.contains("data") else {
            throw OfficialFirmwareFailure(code: "invalid_response", message: "官方更新响应缺少可识别的业务包装，未判定为最新版本。")
        }
        if let rawCode = root["errorCode"] ?? root["code"], !(rawCode is NSNull), String(describing: rawCode) != "0" {
            throw OfficialFirmwareFailure(code: "business_error", message: "官方灰度更新检查返回业务错误，未判定为最新版本。")
        }
        if root["data"] is NSNull {
            return OfficialFirmwareCheckResult(checkedAt: Date(), currentVersion: currentVersion, candidate: nil)
        }
        guard let item = root["data"] as? [String: Any] else {
            throw OfficialFirmwareFailure(code: "invalid_response", message: "官方更新响应中的 data 不是可识别的候选。")
        }
        let rawAddress = item["downloadUrl"]
        if rawAddress == nil || rawAddress is NSNull || (rawAddress as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return OfficialFirmwareCheckResult(checkedAt: Date(), currentVersion: currentVersion, candidate: nil)
        }
        guard let address = rawAddress as? String, let url = URL(string: address), url.scheme == "https", url.host != nil,
              let version = item["versionName"] as? String, !version.isEmpty else {
            throw OfficialFirmwareFailure(code: "invalid_candidate", message: "官方候选缺少完整 HTTPS 下载地址或目标版本。")
        }
        let candidate = OfficialFirmwareCandidate(id: UUID().uuidString, deviceID: deviceID, currentVersion: currentVersion,
            region: configuration.region, taskName: item["taskName"] as? String, appName: item["appName"] as? String,
            packageName: item["packageName"] as? String, versionName: version,
            versionCode: item["versionCode"].flatMap { $0 is NSNull ? nil : String(describing: $0) },
            upgradeType: Self.integer(item["upgradeType"]).flatMap(Int.init(exactly:)),
            userScope: item["userScope"].flatMap { $0 is NSNull ? nil : String(describing: $0) },
            updateDescription: item["updateDesc"] as? String, appIcon: item["appIcon"] as? String,
            archiveMD5: item["apkMd5"] as? String, archiveSize: Self.integer(item["apkSize"]),
            downloadURL: url)
        return OfficialFirmwareCheckResult(checkedAt: Date(), currentVersion: currentVersion, candidate: candidate)
    }

    // Generated GrayUpgradeResponse accepts JSON numbers and integer strings.
    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let session = URLSessionConfiguration.ephemeral
        session.httpCookieStorage = nil; session.httpShouldSetCookies = false; session.urlCache = nil
        return session
    }

    private static func archiveMD5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ error: Error, operation: String) -> Error {
        if error is OfficialFirmwareFailure { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return OfficialFirmwareFailure(code: "cancelled", message: "\(operation)已取消。")
        }
        if let error = error as? URLError {
            return OfficialFirmwareFailure(code: error.code == .timedOut ? "timeout" : "network_error",
                message: "\(operation)网络失败（\(error.code.rawValue)）。")
        }
        return OfficialFirmwareFailure(code: "file_or_response_error", message: "\(operation)文件处理或响应解析失败。")
    }
}

private final class FirmwareCheckRedirectPolicy: NSObject, URLSessionTaskDelegate {
    // Never forward the account token/signature to a redirect target.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class FirmwareDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    init(progress: (@Sendable (Int64, Int64) -> Void)?) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }
}
