// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Phone HTTP proxy contract recovered from the official SDK's netproxy-core.
final class NetworkRelayController {
    private let transport: RFCOMMTransport
    private let queue = DispatchQueue(label: "openrayneo.network-relay")
    private var sequence: UInt16 = 0x9000
    private var enabled = false
    private var pending: [RelayRequest] = []
    private var running: [String: RelayDownload] = [:]
    private var completed = 0
    private var failed = 0
    private var lastResult: [String: Any] = [:]

    init(transport: RFCOMMTransport) { self.transport = transport }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/network-relay" else { return nil }
        if method == "GET" { return (200, queue.sync { status() }) }
        guard method == "POST", let enabled = body["enabled"] as? Bool else { return nil }
        guard !enabled || OfficialCloudPolicy.enabled else {
            throw BridgeError(status: 403, message: "此 Beta 停用眼镜网络代理；请通过本机 Agent 或自选模型 API 执行任务。")
        }
        return (200, queue.sync {
            self.enabled = enabled
            if !enabled {
                for request in pending { sendFailure(request.id, code: "REQUEST_CANCELLED", message: "request cancelled") }
                pending.removeAll()
                for download in running.values { download.cancel() }
            }
            return status()
        })
    }

    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 0x19 else { return }
        queue.async { [weak self] in self?.receive(message) }
    }

    private func receive(_ message: RemoteMessage) {
        let body = message.json ?? [:]
        let id = body["requestId"] as? String ?? ""
        if message.messageType == 3 {
            if let download = running[id] { download.cancel() }
            else if let index = pending.firstIndex(where: { $0.id == id }) {
                pending.remove(at: index)
                sendFailure(id, code: "REQUEST_CANCELLED", message: "request cancelled")
            } else { sendFailure(id, code: "INVALID_REQUEST", message: "request not active") }
            return
        }
        guard message.messageType == 1 else {
            sendFailure(id, code: "INVALID_REQUEST", message: "unsupported message type"); return
        }
        guard enabled else {
            sendFailure(id, code: "PHONE_NETWORK_UNAVAILABLE", message: "network relay disabled"); return
        }
        guard !id.isEmpty, let method = body["method"] as? String, let text = body["url"] as? String,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            sendFailure(id, code: "INVALID_REQUEST", message: "invalid request"); return
        }
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method.uppercased()), !isPrivateHost(host) else {
            sendFailure(id, code: "REQUEST_NOT_ALLOWED", message: "request not allowed"); return
        }
        guard !OfficialCloudPolicy.isVendorHost(host) else {
            sendFailure(id, code: "REQUEST_NOT_ALLOWED", message: OfficialCloudPolicy.explanation); return
        }
        guard running[id] == nil, !pending.contains(where: { $0.id == id }) else {
            sendFailure(id, code: "DUPLICATE_REQUEST", message: "duplicate request"); return
        }
        let encoded = body["bodyBase64"] as? String ?? ""
        guard let data = encoded.isEmpty ? Data() : Data(base64Encoded: encoded), data.count <= 65_536 else {
            sendFailure(id, code: "INVALID_REQUEST", message: "invalid request body"); return
        }
        let timeout = min(15_000, max(1_000, body["timeoutMs"] as? Int ?? 10_000))
        let maximum = max(0, body["maxResponseBytes"] as? Int ?? 262_144)
        var request = URLRequest(url: url, timeoutInterval: Double(timeout) / 1000)
        request.httpMethod = method.uppercased()
        request.httpBody = data.isEmpty ? nil : data
        let ignoredHeaders: Set<String> = ["connection", "content-length", "host", "transfer-encoding", "keep-alive", "proxy-connection", "upgrade", "te", "trailer"]
        for (key, value) in body["headers"] as? [String: String] ?? [:] where !ignoredHeaders.contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let job = RelayRequest(id: id, request: request, maxResponseBytes: maximum)
        if running.count < 4 { start(job) }
        else if pending.count < 256 { pending.append(job) }
        else { sendFailure(id, code: "TOO_MANY_REQUESTS", message: "too many requests") }
    }

    private func start(_ job: RelayRequest) {
        let download = RelayDownload(request: job.request, limit: job.maxResponseBytes) { [weak self] data, response, error in
            self?.queue.async { [weak self] in self?.finish(job, data: data, response: response, error: error) }
        }
        running[job.id] = download
        download.start()
    }

    private func finish(_ job: RelayRequest, data: Data, response: HTTPURLResponse?, error: Error?) {
        running.removeValue(forKey: job.id)
        defer {
            if enabled, running.count < 4, !pending.isEmpty { start(pending.removeFirst()) }
        }
        if let error {
            if error is RelayResponseLimitError {
                sendFailure(job.id, code: "RESPONSE_TOO_LARGE", message: "response too large")
            } else {
                let code = (error as NSError).code
                let name: String
                switch code {
                case NSURLErrorCancelled: name = "REQUEST_CANCELLED"
                case NSURLErrorTimedOut: name = "TIMEOUT"
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: name = "PHONE_NETWORK_UNAVAILABLE"
                case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRequired: name = "TLS_FAILED"
                default: name = "CONNECTION_FAILED"
                }
                sendFailure(job.id, code: name, message: error.localizedDescription)
            }
            return
        }
        guard let response else {
            sendFailure(job.id, code: "INTERNAL_ERROR", message: "missing HTTP response"); return
        }
        var headers: [String: [String]] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = [String(describing: value)] }
        let result: [String: Any] = ["type": "http.response", "requestId": job.id, "proxySuccess": true,
                                   "httpStatusCode": response.statusCode, "headers": headers,
                                   "bodyBase64": data.base64EncodedString(), "bodySize": data.count]
        do {
            try send(result)
            completed += 1
            lastResult = ["requestId": job.id, "httpStatusCode": response.statusCode, "bodySize": data.count]
        } catch {
            // Current AA55 framing has a 16-bit frame length. Keep this limitation explicit.
            sendFailure(job.id, code: "RESPONSE_TOO_LARGE", message: error.localizedDescription)
        }
    }

    private func sendFailure(_ id: String, code: String, message: String) {
        failed += 1
        lastResult = ["requestId": id, "proxyErrorCode": code, "proxyErrorMessage": message]
        let result: [String: Any] = ["type": "http.response", "requestId": id, "proxySuccess": false,
                                   "proxyErrorCode": code, "proxyErrorMessage": message,
                                   "headers": [String: [String]](), "bodyBase64": "", "bodySize": 0]
        do { try send(result) }
        catch { lastResult["sendError"] = error.localizedDescription }
    }

    private func send(_ result: [String: Any]) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: 0x19, sequence: sequence, type: 2, body: result))
    }

    private func status() -> [String: Any] {
        ["enabled": enabled, "running": running.count, "queued": pending.count,
         "completed": completed, "failed": failed, "lastResult": lastResult,
         "maxConcurrentRequests": 4, "maxQueuedRequests": 256, "defaultMaxResponseBytes": 262_144,
         "maxRequestBodyBytes": 65_536]
    }

    private func isPrivateHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" ||
            (host.contains(":") && (host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:"))) { return true }
        let octets = host.split(separator: ".")
        let parts = octets.compactMap { Int($0) }
        guard octets.count == 4, parts.count == 4 else { return false }
        return [0, 10, 127].contains(parts[0]) || (parts[0] == 100 && (64..<128).contains(parts[1])) ||
            (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16..<32).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168)
    }
}

private struct RelayRequest {
    let id: String
    let request: URLRequest
    let maxResponseBytes: Int
}

private struct RelayResponseLimitError: Error {}

private final class RelayDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let limit: Int
    private let completion: (Data, HTTPURLResponse?, Error?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var limitExceeded = false

    init(request: URLRequest, limit: Int, completion: @escaping (Data, HTTPURLResponse?, Error?) -> Void) {
        self.request = request; self.limit = limit; self.completion = completion
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(limit) {
            limitExceeded = true; completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Re-evaluating arbitrary redirects can expose requests to vendor or local services. Let the caller handle them.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > limit { limitExceeded = true; dataTask.cancel() }
        else { self.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion(data, response, limitExceeded ? RelayResponseLimitError() : error)
        session.finishTasksAndInvalidate()
    }
}
