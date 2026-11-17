// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Scoped OSS GET, as used by native downloadFileWithOSSConfig. No official account token belongs here.
/// Native creates a fresh temporary file on each download; it does not enable GetObjectRequest.range.
actor OfficialOSSDownloader {
    struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        fileprivate let accessKeyID: String
        fileprivate let secretAccessKey: String
        fileprivate let securityToken: String?
        fileprivate let endpoint: URL

        init(accessKeyID: String, secretAccessKey: String, securityToken: String?, endpoint: URL) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.securityToken = securityToken
            self.endpoint = endpoint
        }
        var description: String { "OSS download credentials (redacted)" }
        var debugDescription: String { description }
    }

    struct Progress: Sendable {
        let bytesReceived: Int64
        let totalBytes: Int64?
        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
        }
    }

    struct Result: Sendable {
        let fileURL: URL
        let byteCount: Int64
        let eTag: String?
        let contentType: String?
    }

    struct Failure: LocalizedError, Sendable {
        enum Kind: Sendable, Equatable {
            case configuration, destinationExists, downloadInProgress, localFile
            case invalidResponse, incompleteFile, http, credentialRejected, redirect, transport, idleTimeout
        }
        let kind: Kind
        let httpStatus: Int?
        let ossCode: String?
        var isCredentialRejected: Bool { kind == .credentialRejected }

        fileprivate init(_ kind: Kind, httpStatus: Int? = nil, ossCode: String? = nil) {
            self.kind = kind
            self.httpStatus = httpStatus
            self.ossCode = ossCode.flatMap { value in
                !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        || [46, 95, 45].contains($0)
                } ? value : nil
            }
        }
        var errorDescription: String? {
            switch kind {
            case .configuration: return "OSS 下载配置不完整或 endpoint 无法使用。"
            case .destinationExists: return "下载目标文件已存在，请使用独立的暂存路径。"
            case .downloadInProgress: return "同一本地文件已有下载正在进行。"
            case .localFile: return "无法创建或写入下载文件。"
            case .invalidResponse: return "OSS 返回了无法确认下载结果的响应。"
            case .incompleteFile: return "下载文件为空或长度不完整，未发布到本地录音。"
            case .redirect: return "OSS 返回重定向，已停止发送下载凭据。"
            case .transport: return "OSS 下载传输失败，请稍后重试。"
            case .idleTimeout: return "OSS 下载连续 90 秒无进度，已停止传输。"
            case .credentialRejected, .http:
                let details = [httpStatus.map { "HTTP \($0)" }, ossCode].compactMap { $0 }.joined(separator: "，")
                return "OSS 下载失败" + (details.isEmpty ? "。" : "（\(details)）。")
            }
        }
    }

    private var activeDestinations = Set<String>()

    /// The caller supplies a unique staging path, then validates recording identity/deletion state before adoption.
    /// Only pass expectedSize when its API field is known to describe these exact object bytes.
    func download(bucketName: String, objectKey: String, credentials: Credentials,
                  destinationFileURL: URL, expectedSize: Int64? = nil,
                  progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        try OfficialCloudPolicy.requireEnabled()
        try Task.checkCancellation()
        guard destinationFileURL.isFileURL, expectedSize == nil || expectedSize! > 0 else {
            throw Failure(.configuration)
        }
        let destination = destinationFileURL.standardizedFileURL
        let target = try Target(bucketName: bucketName, objectKey: objectKey, credentials: credentials)
        guard !activeDestinations.contains(destination.path) else { throw Failure(.downloadInProgress) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure(.destinationExists) }
        activeDestinations.insert(destination.path)
        defer { activeDestinations.remove(destination.path) }

        let directory = destination.deletingLastPathComponent()
        let partial = directory.appendingPathComponent("." + destination.lastPathComponent + "." + UUID().uuidString + ".download")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(.localFile) }
        defer { Self.trashIfPresent(partial) }
        let network = Network(partial: partial, expectedSize: expectedSize, progress: progress)
        defer { network.close() }
        let clock = SigningClock()

        for attempt in 0...3 {
            try Task.checkCancellation()
            try network.checkActive()
            do {
                let request = try target.request(credentials: credentials, signingDate: clock.now())
                let response = try await network.transfer(request)
                try Task.checkCancellation()
                try network.checkActive()
                let status = response.http.statusCode
                if (300..<400).contains(status) { throw Failure(.redirect, httpStatus: status) }
                if status != 200 {
                    let error = ErrorDocument.read(response.errorBody)
                    if error.isCredentialRejected {
                        throw Failure(.credentialRejected, httpStatus: status, ossCode: error.code)
                    }
                    if attempt < 3 && clock.correct(from: response.http, error: error) { continue }
                    if attempt < 3 && status >= 500 {
                        try await Self.backoff(attempt)
                        continue
                    }
                    throw Failure(.http, httpStatus: status, ossCode: error.code)
                }
                guard response.byteCount > 0,
                      response.http.expectedContentLength < 0 || response.byteCount == response.http.expectedContentLength,
                      expectedSize == nil || response.byteCount == expectedSize else { throw Failure(.incompleteFile) }
                do {
                    let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
                    guard size?.int64Value == response.byteCount else { throw Failure(.incompleteFile) }
                    // Same-directory rename publishes only the fully received file; never overwrite another result.
                    try Task.checkCancellation()
                    try network.checkActive()
                    try FileManager.default.moveItem(at: partial, to: destination)
                } catch is CancellationError { throw CancellationError() }
                catch let error as Failure { throw error }
                catch { throw Failure(.localFile) }
                return Result(fileURL: destination, byteCount: response.byteCount,
                    eTag: response.http.value(forHTTPHeaderField: "ETag"),
                    contentType: response.http.value(forHTTPHeaderField: "Content-Type"))
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                if attempt < 3 && [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code) {
                    try await Self.backoff(attempt)
                    continue
                }
                throw Failure(.transport)
            } catch let error as Failure { throw error }
            catch { throw Failure(.transport) }
        }
        throw Failure(.transport)
    }

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(200_000_000) << attempt)
    }
    private static func trashIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private struct Target {
        let bucketName: String
        let objectKey: String
        let objectURL: URL

        init(bucketName: String, objectKey: String, credentials: Credentials) throws {
            guard let first = bucketName.first, let last = bucketName.last,
                  (3...63).contains(bucketName.utf8.count), first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber,
                  bucketName.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !objectKey.isEmpty, !objectKey.contains("\r"), !objectKey.contains("\n"),
                  !objectKey.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty,
                  [credentials.accessKeyID, credentials.secretAccessKey, credentials.securityToken ?? ""]
                    .allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }),
                  var endpoint = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false),
                  endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
                  endpoint.path.isEmpty || endpoint.path == "/" else { throw Failure(.configuration) }
            self.bucketName = bucketName
            self.objectKey = objectKey
            let isIP = host.contains(":") || (host.split(separator: ".").count == 4
                && host.split(separator: ".").allSatisfy { Int($0) != nil })
            let isOSSHost = ["aliyuncs.com", "aliyun-inc.com", "aliyun.com"].contains {
                host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0)
            }
            if isOSSHost && !host.lowercased().hasPrefix(bucketName + ".") { endpoint.host = bucketName + "." + host }
            let characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
            guard let path = ((isIP ? bucketName + "/" : "") + objectKey)
                .addingPercentEncoding(withAllowedCharacters: characters) else { throw Failure(.configuration) }
            endpoint.percentEncodedPath = "/" + path
            guard let url = endpoint.url else { throw Failure(.configuration) }
            objectURL = url
        }

        func request(credentials: Credentials, signingDate: Date) throws -> URLRequest {
            var request = URLRequest(url: objectURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let date = Self.dateFormatter().string(from: signingDate)
            request.setValue(date, forHTTPHeaderField: "Date")
            var ossHeaders = ""
            if let token = credentials.securityToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-oss-security-token")
                ossHeaders = "x-oss-security-token:" + token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
            let canonical = "GET\n\n\n" + date + "\n" + ossHeaders + "/" + bucketName + "/" + objectKey
            let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(canonical.utf8),
                using: SymmetricKey(data: Data(credentials.secretAccessKey.utf8)))).base64EncodedString()
            request.setValue("OSS " + credentials.accessKeyID + ":" + signature, forHTTPHeaderField: "Authorization")
            return request
        }
        static func dateFormatter() -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return formatter
        }
    }

    private struct AttemptResult: Sendable {
        let http: HTTPURLResponse
        let byteCount: Int64
        let errorBody: Data
    }

    private final class SigningClock {
        private var offset: TimeInterval = 0
        func now() -> Date { Date().addingTimeInterval(offset) }
        func correct(from response: HTTPURLResponse, error: ErrorDocument) -> Bool {
            let skewed = error.code?.caseInsensitiveCompare("RequestTimeTooSkewed") == .orderedSame
            let invalid = error.code?.caseInsensitiveCompare("InvalidArgument") == .orderedSame
                && error.message.caseInsensitiveCompare("Invalid signing date in Authorization header.") == .orderedSame
            guard skewed || invalid, let value = response.value(forHTTPHeaderField: "Date"),
                  let server = Target.dateFormatter().date(from: value) else { return false }
            let local = Date()
            guard skewed || abs(local.addingTimeInterval(offset).timeIntervalSince(server)) > 900 else { return false }
            offset = server.timeIntervalSince(local)
            return true
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func install(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let cancelled = cancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
        func finish() {
            lock.lock()
            task = nil
            lock.unlock()
        }
    }

    private final class Network: @unchecked Sendable {
        private let session: URLSession
        private let delegate: DownloadDelegate
        private let partial: URL
        init(partial: URL, expectedSize: Int64?, progress: @escaping @Sendable (Progress) -> Void) {
            self.partial = partial
            delegate = DownloadDelegate(expectedSize: expectedSize, progress: progress)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            // Native connect=30s cannot be enforced independently with URLSession; connection metrics arrive afterward.
            // Request inactivity=60s approximates its socket timeout. Operation idle=90s is separate below.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 86_400
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
        func checkActive() throws { try delegate.checkActive() }
        func close() { delegate.close(); session.invalidateAndCancel() }

        func transfer(_ request: URLRequest) async throws -> AttemptResult {
            try checkActive()
            let handle: FileHandle
            do {
                if !FileManager.default.fileExists(atPath: partial.path) {
                    guard FileManager.default.createFile(atPath: partial.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw Failure(.localFile) }
                }
                handle = try FileHandle(forWritingTo: partial)
                do { try handle.truncate(atOffset: 0) }
                catch { try? handle.close(); throw error }
            } catch { throw Failure(.localFile) }
            let cancellation = Cancellation()
            do {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try checkActive()
                    return try await withCheckedThrowingContinuation { continuation in
                        let task = session.dataTask(with: request)
                        delegate.register(task, handle: handle) { result in
                            cancellation.finish()
                            continuation.resume(with: result)
                        }
                        cancellation.install(task)
                        task.resume()
                    }
                } onCancel: { cancellation.cancel() }
            } catch {
                // Delegate closes registered handles; this also covers cancellation before registration.
                try? handle.close()
                throw error
            }
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Transfer {
            let task: URLSessionTask
            let handle: FileHandle
            let completion: @Sendable (Swift.Result<AttemptResult, Error>) -> Void
            var http: HTTPURLResponse?
            var byteCount: Int64 = 0
            var errorBody = Data()
            var localFailure: Failure?
        }
        private let lock = NSLock()
        private let watchdog: DispatchSourceTimer
        private let expectedSize: Int64?
        private let progress: @Sendable (Progress) -> Void
        private var transfer: Transfer?
        private var lastProgress = ProcessInfo.processInfo.systemUptime
        private var idleExpired = false

        init(expectedSize: Int64?, progress: @escaping @Sendable (Progress) -> Void) {
            self.expectedSize = expectedSize
            self.progress = progress
            watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "OpenRayneo.OSS.downloadIdle"))
            super.init()
            watchdog.setEventHandler { [weak self] in self?.cancelIdleOperation() }
            watchdog.schedule(deadline: .now() + 5, repeating: 5)
            watchdog.resume()
        }
        func close() { watchdog.cancel() }
        func checkActive() throws {
            lock.lock()
            let expired = idleExpired
            lock.unlock()
            if expired { throw Failure(.idleTimeout) }
        }
        func register(_ task: URLSessionTask, handle: FileHandle,
                      completion: @escaping @Sendable (Swift.Result<AttemptResult, Error>) -> Void) {
            lock.lock()
            transfer = Transfer(task: task, handle: handle, completion: completion)
            let expired = idleExpired
            lock.unlock()
            progress(Progress(bytesReceived: 0, totalBytes: expectedSize))
            if expired { task.cancel() }
        }
        private func cancelIdleOperation() {
            lock.lock()
            guard !idleExpired && ProcessInfo.processInfo.systemUptime - lastProgress >= 90 else {
                lock.unlock()
                return
            }
            idleExpired = true
            let task = transfer?.task
            lock.unlock()
            task?.cancel()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            transfer?.http = response as? HTTPURLResponse
            lock.unlock()
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard var current = transfer, current.task.taskIdentifier == dataTask.taskIdentifier,
                  current.localFailure == nil, !idleExpired else { lock.unlock(); return }
            var value: Progress?
            if current.http?.statusCode == 200 {
                do {
                    try current.handle.write(contentsOf: data)
                    current.byteCount += Int64(data.count)
                    lastProgress = ProcessInfo.processInfo.systemUptime
                    let length = current.http?.expectedContentLength ?? -1
                    value = Progress(bytesReceived: current.byteCount, totalBytes: length >= 0 ? length : expectedSize)
                } catch { current.localFailure = Failure(.localFile) }
            } else if current.errorBody.count < 65_536 {
                current.errorBody.append(data.prefix(65_536 - current.errorBody.count))
            }
            transfer = current
            let shouldCancel = current.localFailure != nil
            lock.unlock()
            if let value { progress(value) }
            if shouldCancel { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            guard let current = transfer, current.task.taskIdentifier == task.taskIdentifier else { lock.unlock(); return }
            transfer = nil
            let expired = idleExpired
            lock.unlock()
            var failure: Error? = expired ? Failure(.idleTimeout) : current.localFailure ?? error
            do { try current.handle.close() }
            catch { if failure == nil { failure = Failure(.localFile) } }
            if let failure { current.completion(.failure(failure)) }
            else if let http = current.http {
                current.completion(.success(AttemptResult(http: http, byteCount: current.byteCount, errorBody: current.errorBody)))
            } else { current.completion(.failure(Failure(.invalidResponse))) }
        }
    }

    private final class ErrorDocument: NSObject, XMLParserDelegate {
        private(set) var code: String?
        private(set) var message = ""
        private var text = ""
        var isCredentialRejected: Bool {
            ["InvalidAccessKeyId", "ExpiredToken", "InvalidSecurityToken", "SecurityTokenExpired"].contains(code ?? "")
                || (message.contains("Access Key Id") && message.contains("does not exist"))
        }
        static func read(_ data: Data) -> ErrorDocument {
            let document = ErrorDocument()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = document
            _ = parser.parse()
            return document
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) { text = "" }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "Code" { code = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "Message" { message = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            text = ""
        }
    }
}
