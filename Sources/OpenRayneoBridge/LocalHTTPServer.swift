// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

final class LocalHTTPServer {
    private static let maxHeaderBytes = 32_768
    private static let maxBodyBytes = 1_000_000

    private let port: UInt16
    private let token: String
    private let deviceController: BridgeController?
    private let recordSync = RecordSyncController()
    private let agentInput = AgentInputController()
    private let connectionSlots = DispatchSemaphore(value: 16)

    init(port: UInt16, token: String, controller: BridgeController?) {
        self.port = port
        self.token = token
        self.deviceController = controller
    }

    func run() throws -> Never {
        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw BridgeError(status: 500, message: "Could not create HTTP socket") }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(serverFD, 16) == 0 else {
            Darwin.close(serverFD)
            throw BridgeError(status: 500, message: "Could not bind HTTP API to 127.0.0.1:\(port)")
        }

        print("OpenRayneo Bridge listening at http://127.0.0.1:\(port)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { continue }
                guard self.connectionSlots.wait(timeout: .now()) == .success else {
                    self.configureClientSocket(clientFD, timeoutSeconds: 2)
                    self.writeError(clientFD, status: 503, message: "server busy")
                    Darwin.close(clientFD)
                    continue
                }
                DispatchQueue.global().async { [weak self] in
                    guard let self else { Darwin.close(clientFD); return }
                    defer { self.connectionSlots.signal() }
                    self.handle(clientFD)
                }
            }
        }
        while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)) }
    }

    private func configureClientSocket(_ clientFD: Int32, timeoutSeconds: Int = 15) {
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func handle(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        configureClientSocket(clientFD)
        do {
            let request = try readRequest(clientFD)
            let (status, response) = route(request)
            let body = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
            let reason = Self.reasonPhrase(for: status)
            var payload = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            payload.append(body)
            sendAll(clientFD, payload)
        } catch let error as BridgeError {
            writeError(clientFD, status: error.status, message: error.message)
        } catch {
            writeError(clientFD, status: 400, message: error.localizedDescription)
        }
    }

    private func route(_ request: HTTPRequest) -> (Int, [String: Any]) {
        guard Self.isAllowedHostHeader(request.headers["host"]) else {
            return (403, ["error": "forbidden host header"])
        }
        if request.method == "GET", request.path == "/health" {
            return (200, ["ok": true, "bleReady": deviceController?.isBLEReady ?? false, "rfcommConnected": deviceController?.isConnected ?? false])
        }
        guard Self.isValidBearerHeader(request.headers["authorization"], expectedToken: token) else {
            return (401, ["error": "missing or invalid bearer token"])
        }
        do {
            let object = request.body.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:])
            if let response = try recordSync.route(method: request.method, path: request.path, body: object) { return response }
            if let response = try agentInput.route(method: request.method, path: request.path, body: object) { return response }
        } catch let error as BridgeError { return (error.status, ["error": error.message]) }
        catch { return (400, ["error": error.localizedDescription]) }
        guard let controller = deviceController else {
            if request.method == "GET", request.path == "/v1/device" {
                return (200, ["mode": "local-services-only", "rfcommConnected": false, "ble": ["ready": false]])
            }
            return (409, ["error": "当前为本机记录服务模式；请连接眼镜后使用设备接口"])
        }
        if request.method == "GET", request.path == "/v1/device" {
            return (200, controller.diagnostics)
        }
        if request.method == "GET", request.path == "/v1/device/visibility" {
            return (200, controller.visibilityStatus)
        }
        if request.method == "GET", request.path == "/v1/device/synchronization" {
            return (200, controller.synchronizationStatus)
        }
        do {
            let object = request.body.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:])
            let audioStarts: Set<String> = ["/v1/captions/start", "/v1/prompts/start", "/v1/asr/start",
                "/v1/recording/start", "/v1/virtual-mic/start", "/v1/assistant-audio/start", "/v1/lifelog/observe",
                "/v1/native-recording/start", "/v1/teleprompter"]
            if request.method == "POST", audioStarts.contains(request.path), controller.nativeAssistant.status["capturing"] as? Bool == true {
                throw BridgeError(status: 409, message: "请先停止当前原生助手收音。")
            }
            if let response = try controller.settings.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.schedules.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.nativeRecording.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.files.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.networkRelay.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.capabilities.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.maintenance.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.ota.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if request.method == "POST", request.path == "/v1/assistant/native/start",
               (!controller.displays.canStartNativeAssistant || controller.nativeRecording.isRecording || controller.teleprompterStatus["running"] as? Bool == true) {
                throw BridgeError(status: 409, message: "请先结束当前显示或音频会话。")
            }
            if let response = try controller.nativeAssistant.route(method: request.method, path: request.path, body: object) { return response }
            if let response = try controller.assistantRuntime.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if let response = try controller.speech.route(method: request.method, path: request.path, body: object) {
                return response
            }
            if request.method == "POST", request.path.hasPrefix("/v1/teleprompter"),
               !["/v1/teleprompter/library", "/v1/teleprompter/check-state"].contains(request.path), controller.displays.isSpeechReserved {
                throw BridgeError(status: 409, message: "Stop the audio session before using the teleprompter")
            }
            if let response = try controller.displays.route(method: request.method, path: request.path, body: object) {
                return response
            }
            switch (request.method, request.path) {
            case ("POST", "/v1/device/visibility"):
                guard let foreground = object["isAppForeground"] as? Bool else {
                    throw BridgeError(status: 400, message: "isAppForeground must be Boolean")
                }
                try controller.synchronizeAppVisibility(foreground)
                return (202, controller.visibilityStatus)
            case ("POST", "/v1/device/connect"):
                try controller.connect()
                return (200, controller.diagnostics)
            case ("POST", "/v1/device/pairing/prepare"):
                try controller.prepareSystemPairing()
                return (200, controller.diagnostics)
            case ("POST", "/v1/device/synchronize"):
                return (200, try controller.synchronizeDeviceState())
            case ("POST", "/v1/device/recover-data-channel"):
                controller.interruptDataChannel()
                return (202, controller.diagnostics)
            case ("POST", "/v1/device/recovery/suspend"):
                controller.suspendConnectionRecovery()
                return (200, controller.diagnostics)
            case ("POST", "/v1/notifications"):
                guard let title = object["title"] as? String, let body = object["body"] as? String else {
                    throw BridgeError(status: 400, message: "title and body are required")
                }
                try controller.postNotification(title: title, body: body, source: object)
                return (202, ["ok": true, "sent": "notification"])
            case ("POST", "/v1/teleprompter"):
                guard let text = object["text"] as? String else {
                    throw BridgeError(status: 400, message: "text is required")
                }
                let title = object["title"] as? String ?? "OpenRayneo"
                let speed = object["speed"] as? Int ?? 120
                let documentID = try controller.startTeleprompter(title: title, text: text, speed: speed, documentID: object["did"] as? String, options: object["settings"] as? [String: Any] ?? [:])
                return (202, ["ok": true, "sent": "teleprompter", "did": documentID])
            case ("GET", "/v1/teleprompter"):
                return (200, controller.teleprompterStatus)
            case ("POST", "/v1/teleprompter/check-state"):
                return (200, try controller.synchronizeTeleprompterState())
            case ("POST", "/v1/teleprompter/library"):
                try controller.updateTeleprompterLibrary(object)
                return (202, ["ok": true, "sent": "library_update"])
            case ("POST", "/v1/teleprompter/settings"):
                try controller.updateTeleprompterSettings(object)
                return (202, ["ok": true, "sent": "settings_update"])
            case ("POST", "/v1/teleprompter/progress"):
                try controller.updateTeleprompterProgress(object)
                return (202, ["ok": true, "sent": "progress_update"])
            case ("POST", "/v1/teleprompter/pause"), ("POST", "/v1/teleprompter/resume"), ("POST", "/v1/teleprompter/stop"):
                let action = String(request.path.split(separator: "/").last ?? "")
                try controller.controlTeleprompter(action)
                return (202, ["ok": true, "sent": action])
            default:
                return (404, ["error": "route not found"])
            }
        } catch let error as BridgeError {
            return (error.status, ["error": error.message])
        } catch {
            return (400, ["error": error.localizedDescription])
        }
    }

    private static func parseRequestBuffer(_ data: Data) throws -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes {
                throw BridgeError(status: 431, message: "request headers too large")
            }
            return nil
        }
        let headerBytesCount = data.distance(from: data.startIndex, to: boundary.lowerBound)
        guard headerBytesCount <= maxHeaderBytes else {
            throw BridgeError(status: 431, message: "request headers too large")
        }
        let headerText = String(decoding: data[data.startIndex..<boundary.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { throw BridgeError(status: 400, message: "malformed request line") }
        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count >= 2 else { throw BridgeError(status: 400, message: "malformed request line") }
        let rawTarget = String(requestParts[1])
        let components = URLComponents(string: rawTarget)
        let path = components?.path ?? String(rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !path.isEmpty, path.hasPrefix("/") else { throw BridgeError(status: 400, message: "malformed request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw BridgeError(status: 400, message: "malformed header line") }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { throw BridgeError(status: 400, message: "invalid content-length") }
            guard parsed <= maxBodyBytes else { throw BridgeError(status: 413, message: "request body too large") }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let bodyOffset = data.distance(from: data.startIndex, to: boundary.upperBound)
        let requiredBytes = bodyOffset + contentLength
        guard data.count >= requiredBytes else { return nil }

        let bodyStart = data.index(data.startIndex, offsetBy: bodyOffset)
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        var query: [String: Any] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value { query[item.name] = Int(value).map { $0 as Any } ?? value }
        }
        return HTTPRequest(
            method: String(requestParts[0]),
            path: path,
            headers: headers,
            body: contentLength == 0 && !query.isEmpty ? try JSONSerialization.data(withJSONObject: query) : data.subdata(in: bodyStart..<bodyEnd)
        )
    }

    private static func isAllowedHostHeader(_ rawHost: String?) -> Bool {
        guard let rawHost = rawHost?.trimmingCharacters(in: .whitespaces), !rawHost.isEmpty else { return true }
        let lower = rawHost.lowercased()
        if lower.hasPrefix("[::1]") {
            let rest = lower.dropFirst(5)
            return rest.isEmpty || (rest.first == ":" && UInt16(rest.dropFirst()) != nil)
        }
        let parts = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard UInt16(parts[1]) != nil else { return false }
        }
        let host = String(parts[0])
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func isValidBearerHeader(_ header: String?, expectedToken: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let candidate = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(expectedToken.utf8)
        guard !expected.isEmpty else { return false }
        var diff = candidate.count ^ expected.count
        let count = max(candidate.count, expected.count)
        for index in 0..<count {
            let lhs = index < candidate.count ? candidate[index] : 0
            let rhs = index < expected.count ? expected[index] : 0
            diff |= Int(lhs ^ rhs)
        }
        return diff == 0
    }

    private func readRequest(_ fd: Int32) throws -> HTTPRequest {
        let maxReadLimit = Self.maxHeaderBytes + Self.maxBodyBytes + 4096
        let deadline = Date().addingTimeInterval(15)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maxReadLimit {
            if Date() >= deadline {
                throw BridgeError(status: 408, message: "request timed out")
            }
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if received < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw BridgeError(status: 408, message: "request timed out")
                }
                throw BridgeError(status: 400, message: "socket read failed")
            }
            if received == 0 { break }
            data.append(contentsOf: buffer.prefix(received))
            if let request = try Self.parseRequestBuffer(data) { return request }
        }
        if let request = try Self.parseRequestBuffer(data) { return request }
        throw BridgeError(status: 400, message: data.isEmpty ? "empty request" : "incomplete HTTP request")
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        let deadline = Date().addingTimeInterval(15)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < rawBuffer.count {
                if Date() >= deadline { break }
                let sent = Darwin.send(fd, base.advanced(by: totalSent), rawBuffer.count - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func writeError(_ fd: Int32, status: Int, message: String) {
        let response = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = Self.reasonPhrase(for: status)
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(response.count)\r\n\r\n".utf8)
        bytes.append(response)
        sendAll(fd, bytes)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Internal Server Error"
        }
    }
}

