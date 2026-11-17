// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Audio bytes only. Official account authentication, uploadCheck and uploadRecord belong to the caller.
actor OfficialOSSUploader {
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

        var description: String { "OSS credentials (redacted)" }
        var debugDescription: String { description }
    }

    struct Progress: Sendable {
        enum Phase: Sendable { case preparing, uploading, completing, completed }
        let bytesSent: Int64
        let totalBytes: Int64
        let phase: Phase
        var fraction: Double {
            totalBytes > 0 ? min(1, max(0, Double(bytesSent) / Double(totalBytes))) : 0
        }
    }

    struct Result: Sendable {
        let bucketName: String
        let objectKey: String
        let eTag: String?
    }

    struct Failure: LocalizedError, Sendable {
        enum Kind: Sendable, Equatable {
            case configuration, localFile, sourceChanged, resumeState, uploadInProgress
            case invalidResponse, http, credentialRejected, redirect, transport, idleTimeout
        }
        let kind: Kind
        let httpStatus: Int?
        let ossCode: String?
        var isCredentialRejected: Bool { kind == .credentialRejected }

        fileprivate init(_ kind: Kind, httpStatus: Int? = nil, ossCode: String? = nil) {
            self.kind = kind
            self.httpStatus = httpStatus
            self.ossCode = Self.safeCode(ossCode)
        }

        var errorDescription: String? {
            switch kind {
            case .configuration: return "OSS 上传配置不完整或 endpoint 无法使用。"
            case .localFile: return "无法读取上传文件或准备上传分片。"
            case .sourceChanged: return "上传源文件已变化，请重新准备稳定的音频文件。"
            case .resumeState: return "无法读取或保存分片恢复记录，或记录与当前上传不匹配。"
            case .uploadInProgress: return "同一音频目标已有上传正在进行。"
            case .invalidResponse: return "OSS 返回了无法确认上传结果的响应。"
            case .redirect: return "OSS 返回重定向，已停止发送上传凭据。"
            case .transport: return "OSS 网络传输失败，已保留可用的分片恢复记录。"
            case .idleTimeout: return "OSS 上传连续 90 秒无进度，已停止传输并保留恢复记录。"
            case .credentialRejected, .http:
                let details = [httpStatus.map { "HTTP \($0)" }, ossCode].compactMap { $0 }.joined(separator: "，")
                return "OSS 上传失败" + (details.isEmpty ? "。" : "（\(details)）。")
            }
        }

        fileprivate static func safeCode(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 80,
                  value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || [46, 95, 45].contains($0) })
            else { return nil }
            return value
        }
    }

    private struct Source: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let modifiedAt: Double

        static func read(_ url: URL) throws -> Source {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.int64Value > 0,
                      let modified = attributes[.modificationDate] as? Date else {
                    throw Failure(.localFile)
                }
                return Source(path: url.standardizedFileURL.path, size: size.int64Value,
                              modifiedAt: modified.timeIntervalSince1970)
            } catch let error as Failure { throw error }
            catch { throw Failure(.localFile) }
        }

        func check(_ url: URL) throws {
            guard try Self.read(url) == self else { throw Failure(.sourceChanged) }
        }
    }

    private struct Part: Codable, Sendable {
        let number: Int
        let size: Int64
        let eTag: String
    }

    private struct ResumeState: Codable {
        let version: Int
        let ownerScope: String
        let endpoint: String
        let bucketName: String
        let objectKey: String
        let source: Source
        let uploadID: String
        let partSize: Int64
        var parts: [Part]
        var completed: Bool
        var eTag: String?
    }

    private enum PartOutcome: @unchecked Sendable {
        case success(slot: Int, part: Part)
        case failure(Error)
    }

    private var activeTargets = Set<String>()
    private var activeResumePaths = Set<String>()
    private static let singlePutLimit: Int64 = 524_288

    /// `fileURL` must be a frozen staging file. Task cancellation cancels URLSession work and keeps remote parts.
    /// `resumeStateURL` must be stable for this account/task/destination, and must not be shared by other uploads.
    func upload(fileURL: URL, bucketName: String, objectKey: String, credentials: Credentials,
                ownerScope: String, resumeStateURL: URL? = nil,
                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        try OfficialCloudPolicy.requireEnabled()
        try Task.checkCancellation()
        let target = try Target(bucketName: bucketName, objectKey: objectKey, credentials: credentials)
        guard !ownerScope.isEmpty, fileURL.isFileURL,
              resumeStateURL == nil || resumeStateURL?.isFileURL == true,
              resumeStateURL?.standardizedFileURL != fileURL.standardizedFileURL else {
            throw Failure(.configuration)
        }
        let targetKey = target.objectURL.absoluteString
        let resumePath = resumeStateURL?.standardizedFileURL.path
        guard !activeTargets.contains(targetKey), resumePath.map({ !activeResumePaths.contains($0) }) ?? true else {
            throw Failure(.uploadInProgress)
        }
        activeTargets.insert(targetKey)
        if let resumePath { activeResumePaths.insert(resumePath) }
        defer {
            activeTargets.remove(targetKey)
            if let resumePath { activeResumePaths.remove(resumePath) }
        }

        let source = try Source.read(fileURL)
        progress(Progress(bytesSent: 0, totalBytes: source.size, phase: .preparing))
        let network = Network()
        defer { network.close() }
        let uploadProgress: @Sendable (Progress) -> Void = { value in
            if value.phase == .uploading { network.noteProgress() }
            progress(value)
        }

        let result: Result
        if source.size <= Self.singlePutLimit {
            result = try await put(fileURL: fileURL, source: source, target: target,
                                   credentials: credentials, network: network, progress: uploadProgress)
        } else {
            do {
                result = try await multipart(fileURL: fileURL, source: source, target: target,
                    credentials: credentials, ownerScope: ownerScope, resumeStateURL: resumeStateURL,
                    network: network, progress: uploadProgress)
            } catch let error as Failure where !error.isCredentialRejected
                && (error.httpStatus == 403 || error.ossCode == "AccessDenied") {
                // The Android SDK also falls back when STS does not permit multipart operations.
                try Task.checkCancellation()
                try network.checkActive()
                result = try await put(fileURL: fileURL, source: source, target: target,
                                       credentials: credentials, network: network, progress: uploadProgress)
            }
        }
        if let resumeStateURL { Self.trashIfPresent(resumeStateURL) }
        progress(Progress(bytesSent: source.size, totalBytes: source.size, phase: .completed))
        return result
    }

    private func put(fileURL: URL, source: Source, target: Target, credentials: Credentials,
                     network: Network, progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        try source.check(fileURL)
        let response = try await network.perform(method: "PUT", target: target, credentials: credentials,
            contentType: Self.contentType(target.objectKey), fileURL: fileURL, length: source.size) { sent in
                progress(Progress(bytesSent: min(source.size, sent), totalBytes: source.size, phase: .uploading))
            }
        try source.check(fileURL)
        return Result(bucketName: target.bucketName, objectKey: target.objectKey,
                      eTag: response.http.value(forHTTPHeaderField: "ETag"))
    }

    private func multipart(fileURL: URL, source: Source, target: Target, credentials: Credentials,
                           ownerScope: String, resumeStateURL: URL?, network: Network,
                           progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        var state = try Self.readState(resumeStateURL)
        if let saved = state {
            guard saved.version == 1, saved.ownerScope == ownerScope,
                  saved.endpoint == credentials.endpoint.absoluteString,
                  saved.bucketName == target.bucketName, saved.objectKey == target.objectKey,
                  saved.source == source, saved.partSize == Self.partSize(for: source.size),
                  !saved.uploadID.isEmpty else { throw Failure(.resumeState) }
            if saved.completed {
                return Result(bucketName: target.bucketName, objectKey: target.objectKey, eTag: saved.eTag)
            }
        }

        var serverParts: [Int: Part] = [:]
        if let saved = state {
            do {
                serverParts = try await listParts(state: saved, target: target, credentials: credentials, network: network)
            } catch let error as Failure where error.ossCode == "NoSuchUpload" {
                // Expired or already settled upload IDs are never treated as proof that the object exists.
                // Re-uploading the same frozen source to the same key safely re-establishes its contents.
                state = nil
            }
        }
        if state == nil {
            let response = try await network.perform(method: "POST", target: target, credentials: credentials,
                query: [URLQueryItem(name: "uploads", value: nil)], contentType: Self.contentType(target.objectKey))
            let document = try XML.read(response.data)
            guard document.root == "InitiateMultipartUploadResult",
                  let uploadID = document.values["UploadId"], !uploadID.isEmpty else { throw Failure(.invalidResponse) }
            let newState = ResumeState(version: 1, ownerScope: ownerScope, endpoint: credentials.endpoint.absoluteString,
                bucketName: target.bucketName, objectKey: target.objectKey, source: source, uploadID: uploadID,
                partSize: Self.partSize(for: source.size), parts: [], completed: false, eTag: nil)
            try Self.saveState(newState, to: resumeStateURL)
            state = newState
        }
        guard var upload = state else { throw Failure(.resumeState) }
        let count = Int((source.size - 1) / upload.partSize + 1)
        for part in serverParts.values {
            guard part.number > 0, part.number <= count,
                  part.size == min(upload.partSize, source.size - Int64(part.number - 1) * upload.partSize),
                  !part.eTag.isEmpty else { throw Failure(.resumeState) }
        }
        upload.parts = serverParts.values.sorted { $0.number < $1.number }
        try Self.saveState(upload, to: resumeStateURL)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRayneo-OSS-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(.localFile) }
        defer { Self.trashIfPresent(temporaryDirectory) }
        let aggregate = AggregateProgress(totalBytes: source.size, accepted: serverParts, progress: progress)
        defer { aggregate.close() }
        aggregate.publish()
        let pending = (1...count).filter { serverParts[$0] == nil }
        let partSize = upload.partSize
        let uploadID = upload.uploadID
        let failure = await withTaskGroup(of: PartOutcome.self, returning: Error?.self) { group in
            var nextIndex = 0
            var firstError: Error?
            for slot in 0..<min(5, pending.count) {
                let number = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    await Self.uploadPart(number: number, slot: slot, partSize: partSize, uploadID: uploadID,
                        fileURL: fileURL, source: source, temporaryDirectory: temporaryDirectory, target: target,
                        credentials: credentials, network: network, aggregate: aggregate)
                }
            }
            // Drain cancelled children too: another part may already have succeeded on the server.
            while let outcome = await group.next() {
                switch outcome {
                case let .success(slot, part):
                    serverParts[part.number] = part
                    upload.parts = serverParts.values.sorted { $0.number < $1.number }
                    do { try Self.saveState(upload, to: resumeStateURL) }
                    catch {
                        if firstError == nil { firstError = error; group.cancelAll() }
                    }
                    aggregate.accept(part)
                    if firstError == nil, !Task.isCancelled, nextIndex < pending.count {
                        let number = pending[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            await Self.uploadPart(number: number, slot: slot, partSize: partSize, uploadID: uploadID,
                                fileURL: fileURL, source: source, temporaryDirectory: temporaryDirectory, target: target,
                                credentials: credentials, network: network, aggregate: aggregate)
                        }
                    }
                case let .failure(error):
                    // Credential rejection must reach the caller even if a sibling failed first.
                    if firstError == nil || (error as? Failure)?.isCredentialRejected == true {
                        firstError = error
                        group.cancelAll()
                    }
                }
            }
            return firstError
        }
        aggregate.close()
        try Task.checkCancellation()
        if let failure { throw failure }
        try source.check(fileURL)
        progress(Progress(bytesSent: source.size, totalBytes: source.size, phase: .completing))
        let partsXML = upload.parts.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.escapeXML($0.eTag))</ETag></Part>"
        }.joined()
        let body = Data(("<CompleteMultipartUpload>" + partsXML + "</CompleteMultipartUpload>").utf8)
        // A failed response can be ambiguous; retain the upload ID so a later attempt checks ListParts first.
        let response = try await network.perform(method: "POST", target: target, credentials: credentials,
            query: [URLQueryItem(name: "uploadId", value: upload.uploadID)], contentType: "application/xml", body: body)
        let document = try XML.read(response.data)
        guard document.root == "CompleteMultipartUploadResult" else { throw Failure(.invalidResponse) }
        upload.completed = true
        upload.eTag = document.values["ETag"] ?? response.http.value(forHTTPHeaderField: "ETag")
        try Self.saveState(upload, to: resumeStateURL)
        return Result(bucketName: target.bucketName, objectKey: target.objectKey, eTag: upload.eTag)
    }

    private static func uploadPart(number: Int, slot: Int, partSize: Int64, uploadID: String,
                                   fileURL: URL, source: Source, temporaryDirectory: URL, target: Target,
                                   credentials: Credentials, network: Network,
                                   aggregate: AggregateProgress) async -> PartOutcome {
        do {
            try Task.checkCancellation()
            try source.check(fileURL)
            let offset = Int64(number - 1) * partSize
            let size = min(partSize, source.size - offset)
            let partURL = temporaryDirectory.appendingPathComponent("part-\(slot).audio")
            try copyRange(fileURL, to: partURL, offset: offset, length: size)
            let response = try await network.perform(method: "PUT", target: target, credentials: credentials,
                query: [URLQueryItem(name: "partNumber", value: String(number)),
                        URLQueryItem(name: "uploadId", value: uploadID)],
                contentType: "application/octet-stream", fileURL: partURL, length: size) { sent in
                    aggregate.update(number: number, sent: min(size, sent))
                }
            guard let eTag = response.http.value(forHTTPHeaderField: "ETag"), !eTag.isEmpty else {
                throw Failure(.invalidResponse)
            }
            return .success(slot: slot, part: Part(number: number, size: size, eTag: eTag))
        } catch { return .failure(error) }
    }

    /// URLSession delegates call this concurrently. Only the actor writes the durable resume record.
    private final class AggregateProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let callbacks = DispatchQueue(label: "OpenRayneo.OSS.progress")
        private let totalBytes: Int64
        private let progress: @Sendable (Progress) -> Void
        private var accepted: [Int: Int64]
        private var inFlight: [Int: Int64] = [:]
        private var closed = false

        init(totalBytes: Int64, accepted: [Int: Part], progress: @escaping @Sendable (Progress) -> Void) {
            self.totalBytes = totalBytes
            self.accepted = accepted.mapValues(\.size)
            self.progress = progress
        }
        func update(number: Int, sent: Int64) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed, accepted[number] == nil else { return }
            inFlight[number] = max(0, sent)
            enqueueLocked()
        }
        func accept(_ part: Part) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            accepted[part.number] = part.size
            inFlight.removeValue(forKey: part.number)
            enqueueLocked()
        }
        func publish() {
            lock.lock()
            defer { lock.unlock() }
            if !closed { enqueueLocked() }
        }
        func close() {
            lock.lock()
            closed = true
            lock.unlock()
            // No uploading callback can arrive after the actor announces completing/completed or starts fallback PUT.
            callbacks.sync {}
        }
        private func enqueueLocked() {
            let sent = min(totalBytes, accepted.values.reduce(0, +) + inFlight.values.reduce(0, +))
            let value = Progress(bytesSent: sent, totalBytes: totalBytes, phase: .uploading)
            let callback = progress
            callbacks.async { callback(value) }
        }
    }

    private func listParts(state: ResumeState, target: Target, credentials: Credentials,
                           network: Network) async throws -> [Int: Part] {
        var marker = 0
        var parts: [Int: Part] = [:]
        while true {
            try Task.checkCancellation()
            let response = try await network.perform(method: "GET", target: target, credentials: credentials,
                query: [URLQueryItem(name: "uploadId", value: state.uploadID),
                        URLQueryItem(name: "max-parts", value: "1000"),
                        URLQueryItem(name: "part-number-marker", value: String(marker))])
            let document = try XML.read(response.data)
            guard document.root == "ListPartsResult",
                  document.values["UploadId"] == state.uploadID,
                  document.values["Bucket"] == target.bucketName,
                  document.values["Key"] == target.objectKey else { throw Failure(.invalidResponse) }
            for part in document.parts {
                guard parts[part.number] == nil else { throw Failure(.invalidResponse) }
                parts[part.number] = part
            }
            if document.values["IsTruncated"] == "false" { return parts }
            guard document.values["IsTruncated"] == "true",
                  let next = document.values["NextPartNumberMarker"].flatMap(Int.init), next > marker,
                  next <= 5000 else { throw Failure(.invalidResponse) }
            marker = next
        }
    }

    // MultipartUploadRequest defaults to 256 KiB; the SDK increases it at 5000 parts, rounded to 4 KiB.
    private static func partSize(for length: Int64) -> Int64 {
        let normal: Int64 = 262_144
        guard (length - 1) / normal + 1 > 5000 else { return normal }
        return ((length / 4999 + 4095) / 4096) * 4096
    }

    private static func contentType(_ objectKey: String) -> String {
        switch (objectKey as NSString).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "pcm": return "audio/pcm"
        case "wav": return "audio/wav"
        case "opus": return "audio/opus"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private static func readState(_ url: URL?) throws -> ResumeState? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(ResumeState.self, from: Data(contentsOf: url)) }
        catch { throw Failure(.resumeState) }
    }

    private static func saveState(_ state: ResumeState, to url: URL?) throws {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw Failure(.resumeState) }
    }

    private static func copyRange(_ source: URL, to destination: URL, offset: Int64, length: Int64) throws {
        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { throw Failure(.localFile) }
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(offset))
            try output.truncate(atOffset: 0)
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else {
                    throw Failure(.sourceChanged)
                }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure(.localFile) }
    }

    private static func trashIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private struct Target: Sendable {
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
            let isIP = host.contains(":") || (host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0) != nil })
            let isOSSHost = ["aliyuncs.com", "aliyun-inc.com", "aliyun.com"].contains {
                host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0)
            }
            if isOSSHost && !host.lowercased().hasPrefix(bucketName + ".") {
                endpoint.host = bucketName + "." + host
            }
            let keyPath = (isIP ? bucketName + "/" : "") + objectKey
            let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
            guard let path = keyPath.addingPercentEncoding(withAllowedCharacters: pathCharacters) else {
                throw Failure(.configuration)
            }
            endpoint.percentEncodedPath = "/" + path
            guard let url = endpoint.url else { throw Failure(.configuration) }
            objectURL = url
        }

        func request(method: String, credentials: Credentials, query: [URLQueryItem], contentType: String?,
                     body: Data?, length: Int64?, signingDate: Date) throws -> URLRequest {
            guard var components = URLComponents(url: objectURL, resolvingAgainstBaseURL: false) else {
                throw Failure(.configuration)
            }
            let queryCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let sorted = query.sorted { $0.name < $1.name }
            if !sorted.isEmpty {
                components.percentEncodedQuery = sorted.map {
                    let key = $0.name.addingPercentEncoding(withAllowedCharacters: queryCharacters)!
                    return $0.value.map { key + "=" + $0.addingPercentEncoding(withAllowedCharacters: queryCharacters)! } ?? key
                }.joined(separator: "&")
            }
            guard let url = components.url else { throw Failure(.configuration) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if let length = length ?? body.map({ Int64($0.count) }) {
                request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            let date = formatter.string(from: signingDate)
            request.setValue(date, forHTTPHeaderField: "Date")
            var ossHeaders = ""
            if let token = credentials.securityToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-oss-security-token")
                ossHeaders = "x-oss-security-token:" + token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
            let resourceQuery = sorted.filter { ["uploads", "uploadId", "partNumber"].contains($0.name) }
                .map { item in
                    guard let value = item.value, !value.isEmpty else { return item.name }
                    return item.name + "=" + value
                }
                .joined(separator: "&")
            let resource = "/" + bucketName + "/" + objectKey + (resourceQuery.isEmpty ? "" : "?" + resourceQuery)
            let canonical = method + "\n\n" + (contentType ?? "") + "\n" + date + "\n" + ossHeaders + resource
            let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(canonical.utf8),
                using: SymmetricKey(data: Data(credentials.secretAccessKey.utf8)))).base64EncodedString()
            request.setValue("OSS " + credentials.accessKeyID + ":" + signature, forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Transfer {
            let task: URLSessionTask
            let progress: (@Sendable (Int64) -> Void)?
            let completion: @Sendable (Data?, URLResponse?, Error?) -> Void
            var data = Data()
            var response: URLResponse?
        }
        private let lock = NSLock()
        private var transfers: [Int: Transfer] = [:]
        private var lastProgress = ProcessInfo.processInfo.systemUptime
        private var idleExpired = false
        private let watchdog: DispatchSourceTimer

        override init() {
            watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "OpenRayneo.OSS.idle"))
            super.init()
            watchdog.setEventHandler { [weak self] in self?.cancelIdleOperation() }
            watchdog.schedule(deadline: .now() + 5, repeating: 5)
            watchdog.resume()
        }
        func close() { watchdog.cancel() }
        func noteProgress() {
            lock.lock()
            if !idleExpired { lastProgress = ProcessInfo.processInfo.systemUptime }
            lock.unlock()
        }
        func checkActive() throws {
            lock.lock()
            let expired = idleExpired
            lock.unlock()
            if expired { throw Failure(.idleTimeout) }
        }

        func register(_ task: URLSessionTask, progress: (@Sendable (Int64) -> Void)?,
                      completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
            lock.lock()
            transfers[task.taskIdentifier] = Transfer(task: task, progress: progress, completion: completion)
            let shouldCancel = idleExpired
            lock.unlock()
            if shouldCancel { task.cancel() }
        }
        private func cancelIdleOperation() {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            guard !idleExpired && now - lastProgress >= 90 else {
                lock.unlock()
                return
            }
            idleExpired = true
            let tasks = transfers.values.map(\.task)
            lock.unlock()
            // Native B8.a/B8.o watches the complete upload operation, independently of socket timeout.
            for task in tasks { task.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            lock.lock()
            if !idleExpired { lastProgress = ProcessInfo.processInfo.systemUptime }
            let progress = transfers[task.taskIdentifier]?.progress
            lock.unlock()
            progress?(totalBytesSent)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            transfers[dataTask.taskIdentifier]?.response = response
            lock.unlock()
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            transfers[dataTask.taskIdentifier]?.data.append(data)
            lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let transfer = transfers.removeValue(forKey: task.taskIdentifier)
            let expired = idleExpired
            lock.unlock()
            guard let transfer else { return }
            let failure: Error? = expired ? Failure(.idleTimeout) : error
            transfer.completion(transfer.data, transfer.response, failure)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Signatures bind the original resource. Never forward credentials to a redirect, even on the same host.
            completionHandler(nil)
        }
    }

    /// Correct only OSS request signing dates; never change the host clock.
    private final class SigningClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return Date().addingTimeInterval(offset)
        }
        func correct(from response: HTTPURLResponse, code: String?, message: String) -> Bool {
            let skewed = code?.caseInsensitiveCompare("RequestTimeTooSkewed") == .orderedSame
            let invalidDate = code?.caseInsensitiveCompare("InvalidArgument") == .orderedSame
                && message.caseInsensitiveCompare("Invalid signing date in Authorization header.") == .orderedSame
            guard skewed || invalidDate, let value = response.value(forHTTPHeaderField: "Date") else { return false }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            guard let serverDate = formatter.date(from: value) else { return false }
            lock.lock()
            defer { lock.unlock() }
            let localDate = Date()
            guard skewed || abs(localDate.addingTimeInterval(offset).timeIntervalSince(serverDate)) > 900 else {
                return false
            }
            offset = serverDate.timeIntervalSince(localDate)
            return true
        }
    }

    /// A request can be cancelled before URLSession has created its task.
    private final class TransferCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func install(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
        func finish() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            let identifier = task?.taskIdentifier
            task = nil
            return identifier
        }
    }

    /// Session configuration is immutable; the shared delegate and request cancellation state are locked.
    private final class Network: @unchecked Sendable {
        struct Response: Sendable { let data: Data; let http: HTTPURLResponse }
        private let session: URLSession
        private let delegate: TransferDelegate
        private let clock = SigningClock()
        init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            // Native config: connect=30s, socket=60s. URLSession exposes no independent connect deadline;
            // its 60s request inactivity timeout approximates socket idle, not a separate connect timeout.
            // connectStart/End metrics are delivered after the transaction, so cannot enforce native 30s.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 86_400
            configuration.httpMaximumConnectionsPerHost = 5
            let delegate = TransferDelegate()
            self.delegate = delegate
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
        func close() { delegate.close(); session.invalidateAndCancel() }
        func noteProgress() { delegate.noteProgress() }
        func checkActive() throws { try delegate.checkActive() }

        private func transfer(_ request: URLRequest, fileURL: URL?,
                              progress: (@Sendable (Int64) -> Void)?) async throws -> Response {
            let cancellation = TransferCancellation()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try checkActive()
                return try await withCheckedThrowingContinuation { continuation in
                    let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                        _ = cancellation.finish()
                        if let error { continuation.resume(throwing: error) }
                        else if let http = response as? HTTPURLResponse {
                            continuation.resume(returning: Response(data: data ?? Data(), http: http))
                        } else { continuation.resume(throwing: Failure(.invalidResponse)) }
                    }
                    let task: URLSessionTask
                    if let fileURL {
                        task = session.uploadTask(with: request, fromFile: fileURL)
                    } else {
                        task = session.dataTask(with: request)
                    }
                    delegate.register(task, progress: progress, completion: completion)
                    cancellation.install(task)
                    task.resume()
                }
            } onCancel: {
                cancellation.cancel()
            }
        }

        func perform(method: String, target: Target, credentials: Credentials, query: [URLQueryItem] = [],
                     contentType: String? = nil, body: Data? = nil, fileURL: URL? = nil, length: Int64? = nil,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Response {
            for attempt in 0...3 {
                try Task.checkCancellation()
                try checkActive()
                do {
                    let request = try target.request(method: method, credentials: credentials, query: query,
                        contentType: contentType, body: body, length: length, signingDate: clock.now())
                    progress?(0)
                    let response = try await transfer(request, fileURL: fileURL, progress: progress)
                    try checkActive()
                    let data = response.data
                    let http = response.http
                    if (300..<400).contains(http.statusCode) { throw Failure(.redirect, httpStatus: http.statusCode) }
                    let document = try? XML.read(data)
                    if !(200..<300).contains(http.statusCode) || document?.root == "Error" {
                        let code = document?.values["Code"]
                        let message = document?.values["Message"] ?? ""
                        let credentialsRejected = ["InvalidAccessKeyId", "ExpiredToken", "InvalidSecurityToken",
                            "SecurityTokenExpired"].contains(code ?? "")
                            || (message.contains("Access Key Id") && message.contains("does not exist"))
                        if credentialsRejected {
                            throw Failure(.credentialRejected, httpStatus: http.statusCode, ossCode: code)
                        }
                        // SDK clock-skew retries share maxErrorRetry, but do not use the normal backoff.
                        if attempt < 3 && clock.correct(from: http, code: code, message: message) { continue }
                        if attempt < 3 && http.statusCode >= 500 {
                            try await Self.backoff(attempt)
                            continue
                        }
                        throw Failure(.http, httpStatus: http.statusCode, ossCode: code)
                    }
                    return Response(data: data, http: http)
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
    }

    private final class XML: NSObject, XMLParserDelegate {
        var root = ""
        var values: [String: String] = [:]
        var parts: [Part] = []
        private var text = ""
        private var part: [String: String]?
        private var invalidPart = false

        static func read(_ data: Data) throws -> XML {
            let document = XML()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = document
            guard parser.parse(), !document.root.isEmpty, !document.invalidPart else {
                throw Failure(.invalidResponse)
            }
            return document
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if root.isEmpty { root = name }
            if name == "Part" { part = [:] }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "Part" {
                if let number = part?["PartNumber"].flatMap(Int.init),
                   let size = part?["Size"].flatMap(Int64.init), let eTag = part?["ETag"], !eTag.isEmpty {
                    parts.append(Part(number: number, size: size, eTag: eTag))
                } else { invalidPart = true }
                part = nil
            } else if part != nil { part?[name] = value }
            else { values[name] = value }
            text = ""
        }
    }
}
