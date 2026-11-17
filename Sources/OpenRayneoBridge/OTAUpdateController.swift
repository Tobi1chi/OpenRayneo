// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

private struct OTAPreparedPackage {
    let source: URL
    let root: URL
    let version: String
    let archiveSize: Int
    let manifest: [[String: Any]]
    let manifestData: Data
    let files: [String: URL]
    let sizes: [String: Int]
}

/// Implements the observed 0x09 file-pull flow; installation success requires a fresh version reply.
final class OTAUpdateController {
    private let transport: RFCOMMTransport
    private let operationLock: NSRecursiveLock
    private let queue = DispatchQueue(label: "openrayneo.ota")
    private var sequence: UInt16 = 0xc000
    private var package: OTAPreparedPackage?
    private var state = "idle"
    private var error: String?
    private var firmware: [String: Any] = [:]
    private var lastMessage: [String: Any] = [:]
    private var progress = 0
    private var sentBytes = 0
    private var lastFile = ""
    private var generation = 0
    private var sessionStarted: Date?
    private var installSeen = false
    private var verificationRequested: Date?
    private var servedSlice = false
    private var officialService: OfficialFirmwareService?
    private var officialConfiguration: [String: Any] = [:]
    private let deviceID: String
    private var officialState = "idle"
    private var officialError: String?
    private var officialErrorCode: String?
    private var officialCandidate: OfficialFirmwareCandidate?
    private var officialDownload: OfficialFirmwareDownload?
    private var officialCheck: OfficialFirmwareCheckResult?
    private var officialTask: Task<Void, Never>?
    private var officialGeneration = 0
    private var officialAuthenticationFailure: [String: Any]?
    private var downloadedBytes: Int64 = 0
    private var expectedDownloadBytes: Int64 = 0

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, deviceID: String) {
        self.transport = transport; operationLock = lock
        self.deviceID = deviceID
        reloadOfficialConfiguration()
    }

    func handle(_ message: RemoteMessage) {
        guard message.protocolID == 9 else { return }
        queue.async { [weak self] in self?.receive(message) }
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/ota" || path.hasPrefix("/v1/ota/") else { return nil }
        if method == "GET", path == "/v1/ota" { return (200, queue.sync { status() }) }
        if method == "GET", path == "/v1/ota/official" { return (200, queue.sync { officialStatus() }) }
        if method == "POST", path == "/v1/ota/official/reload-session" {
            return queue.sync {
                officialGeneration += 1
                officialTask?.cancel(); officialTask = nil
                reloadOfficialConfiguration()
                officialCandidate = nil; officialCheck = nil; officialDownload = nil
                officialAuthenticationFailure = nil
                officialState = "idle"; officialError = nil; officialErrorCode = nil
                downloadedBytes = 0; expectedDownloadBytes = 0
                return (200, status())
            }
        }
        guard method == "POST" else { return nil }
        operationLock.lock(); defer { operationLock.unlock() }
        switch path {
        case "/v1/ota/check":
            try queue.sync { try beginOfficialCheck(expectedIdentity: body["identityEpoch"]) }
        case "/v1/ota/download":
            try queue.sync { try beginOfficialDownload(candidateID: body["candidateID"] as? String) }
        case "/v1/ota/official/cancel":
            queue.sync {
                if officialBusy {
                    officialGeneration += 1; officialTask?.cancel(); officialTask = nil
                    officialState = "cancelled"; officialError = nil; officialErrorCode = nil
                }
            }
        case "/v1/ota/prepare":
            guard let path = body["path"] as? String, let version = body["version"] as? String,
                  !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeError(status: 400, message: "Choose a local OTA ZIP and its target version")
            }
            try queue.sync {
                guard !active, !officialBusy else { throw BridgeError(status: 409, message: "An OTA session or official firmware operation is already active") }
                state = "preparing"; error = nil; package = nil
            }
            do {
                let prepared = try prepare(path: path, version: version.trimmingCharacters(in: .whitespacesAndNewlines))
                queue.sync { package = prepared; state = "prepared"; progress = 0; sentBytes = 0; lastFile = ""; installSeen = false }
            } catch {
                queue.sync { fail(error) }; throw error
            }
        case "/v1/ota/start":
            try transport.ensureConnected()
            try queue.sync {
                guard !officialBusy else { throw BridgeError(status: 409, message: "Wait for the official firmware operation to finish") }
                guard package != nil, state == "prepared" || state == "failed" || state == "cancelled" else {
                    throw BridgeError(status: 409, message: "Prepare a complete OTA package before starting")
                }
                generation += 1; sessionStarted = Date(); installSeen = false; verificationRequested = nil
                progress = 0; sentBytes = 0; servedSlice = false; error = nil; state = "checkingSpace"
                do {
                    try send(type: 3, body: ["OtaSize": package!.archiveSize])
                    deadline(for: "checkingSpace", seconds: 15)
                } catch { fail(error); throw error }
            }
        case "/v1/ota/verify":
            try transport.ensureConnected()
            try queue.sync {
                guard installSeen else { throw BridgeError(status: 409, message: "The glasses have not reported entering installation") }
                state = "awaitingVerification"; error = nil; verificationRequested = Date()
                try send(type: 1)
                deadline(for: "awaitingVerification", seconds: 10)
            }
        case "/v1/ota/cancel":
            try queue.sync {
                guard !active else {
                    throw BridgeError(status: 409, message: "No OTA cancel command has been confirmed. An active transfer or installation cannot be cancelled from Mac.")
                }
                generation += 1; package = nil; state = "cancelled"; error = nil
            }
        default: return nil
        }
        return (202, queue.sync { status() })
    }

    private var active: Bool {
        ["preparing", "checkingSpace", "openingTransferPage", "waitingForVersion", "waitingForManifest", "transferring", "awaitingInstallation", "awaitingVerification"].contains(state)
    }

    private var officialBusy: Bool { officialState == "checking" || officialState == "downloading" }

    private func reloadOfficialConfiguration() {
        do {
            let service = OfficialFirmwareService(configuration: try .fromEnvironment())
            officialService = service; officialConfiguration = service.configurationStatus()
        } catch {
            officialService = nil
            officialConfiguration = ["sessionConfigured": false, "configurationError": error.localizedDescription]
        }
    }

    private func beginOfficialCheck(expectedIdentity: Any?) throws {
        guard !active, !officialBusy else { throw BridgeError(status: 409, message: "已有固件操作正在进行。") }
        reloadOfficialConfiguration()
        guard let service = officialService, officialConfiguration["sessionConfigured"] as? Bool == true else {
            throw BridgeError(status: 409, message: officialConfiguration["configurationError"] as? String ??
                "请在官方账号面板保存已有会话并提供账号 ID，或通过启动环境提供 RAYNEO_ACCESS_TOKEN 和 RAYNEO_ACCOUNT_ID。")
        }
        guard service.matchesExpectedIdentity(expectedIdentity) else {
            throw BridgeError(status: 409, message: "官方账号已变化，请重新检查。")
        }
        guard transport.isConnected, let current = firmware["OsVersion"] as? String, !current.isEmpty else {
            throw BridgeError(status: 409, message: "请先连接眼镜并读取当前固件版本。")
        }
        _ = try OfficialFirmwareService.versionCode(current)
        officialGeneration += 1
        let token = officialGeneration
        officialState = "checking"
        officialAuthenticationFailure = nil
        officialError = nil; officialErrorCode = nil; officialCandidate = nil; officialDownload = nil; officialCheck = nil
        downloadedBytes = 0; expectedDownloadBytes = 0
        officialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.check(currentVersion: current, deviceID: self.deviceID)
                self.queue.sync {
                    guard self.officialGeneration == token else { return }
                    guard self.matchesOfficialContext(deviceID: result.candidate?.deviceID ?? self.deviceID, version: current) else {
                        self.failOfficial(OfficialFirmwareFailure(code: "device_context_changed", message: "设备或固件版本已变化，请重新检查官方更新。")); return
                    }
                    self.officialCheck = result; self.officialCandidate = result.candidate
                    self.officialState = result.candidate == nil ? "noUpdate" : "updateAvailable"; self.officialTask = nil
                }
            } catch {
                self.queue.sync {
                    if self.officialGeneration == token {
                        self.failOfficial(error)
                        if (error as? OfficialFirmwareFailure)?.code == "access_token_rejected" {
                            self.officialAuthenticationFailure = service.credentialReference
                            self.officialAuthenticationFailure?["requestGeneration"] = token
                        }
                    }
                }
            }
        }
    }

    private func beginOfficialDownload(candidateID: String?) throws {
        guard !active, !officialBusy else { throw BridgeError(status: 409, message: "已有固件操作正在进行。") }
        guard let service = officialService, let candidate = officialCandidate, candidate.id == candidateID else {
            throw BridgeError(status: 409, message: "请先检查官方更新，并选择当前候选。")
        }
        guard matchesOfficialContext(deviceID: candidate.deviceID, version: candidate.currentVersion) else {
            throw BridgeError(status: 409, message: "设备或固件版本已变化，请重新检查官方更新。")
        }
        officialGeneration += 1
        let token = officialGeneration
        officialState = "downloading"; officialError = nil; officialErrorCode = nil; officialDownload = nil
        downloadedBytes = 0; expectedDownloadBytes = candidate.archiveSize ?? 0
        officialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.download(candidate: candidate) { [weak self] bytes, expected in
                    self?.recordDownloadProgress(bytes: bytes, expected: expected, token: token)
                }
                self.queue.sync {
                    guard self.officialGeneration == token else { return }
                    self.officialDownload = result; self.downloadedBytes = result.bytes
                    self.officialState = "downloaded"; self.officialTask = nil
                }
            } catch {
                self.queue.sync { if self.officialGeneration == token { self.failOfficial(error) } }
            }
        }
    }

    private func recordDownloadProgress(bytes: Int64, expected: Int64, token: Int) {
        queue.async { [weak self] in
            guard let self, self.officialGeneration == token, self.officialState == "downloading" else { return }
            self.downloadedBytes = bytes
            if expected > 0 { self.expectedDownloadBytes = expected }
        }
    }

    private func matchesOfficialContext(deviceID: String, version: String) -> Bool {
        self.deviceID == deviceID &&
            (firmware["OsVersion"] as? String).map { normalizedVersion($0) == normalizedVersion(version) } == true
    }

    private func failOfficial(_ failure: Error) {
        officialTask = nil; officialState = "failed"
        officialError = (failure as? OfficialFirmwareFailure)?.message ?? "官方固件操作失败。"
        officialErrorCode = (failure as? OfficialFirmwareFailure)?.code ?? "official_operation_failed"
    }

    private func officialStatus() -> [String: Any] {
        var result: [String: Any] = ["configuration": officialConfiguration, "state": officialState, "busy": officialBusy,
            "downloadedBytes": downloadedBytes, "expectedBytes": expectedDownloadBytes,
            "error": officialError as Any? ?? NSNull(), "errorCode": officialErrorCode as Any? ?? NSNull()]
        if let officialCheck { result["check"] = officialCheck.metadata }
        if let officialCandidate {
            result["candidate"] = officialCandidate.metadata
            result["candidateUsable"] = matchesOfficialContext(deviceID: officialCandidate.deviceID, version: officialCandidate.currentVersion)
        }
        if let officialDownload { result["download"] = officialDownload.metadata }
        if let officialAuthenticationFailure { result["authenticationFailure"] = officialAuthenticationFailure }
        return result
    }

    private func receive(_ message: RemoteMessage) {
        let type = message.messageType ?? 0
        let json = message.json ?? [:]
        lastMessage = ["type": type, "body": json]
        if type == 1 {
            firmware = json
            if installSeen, let requested = verificationRequested, message.receivedAt >= requested,
               let package, let actual = json["OsVersion"] as? String {
                if normalizedVersion(actual) == normalizedVersion(package.version), json["OtaValidationConfirmed"] as? Bool == true {
                    state = "completed"; error = nil
                } else {
                    state = "verificationUnconfirmed"
                    error = "眼镜报告版本 \(actual)，目标为 \(package.version)；尚未确认升级完成。"
                }
            }
            return
        }
        guard let package, let sessionStarted, message.receivedAt >= sessionStarted, active else { return }
        do {
            switch type {
            case 3 where state == "checkingSpace":
                guard let result = json["Result"] as? Bool else { throw BridgeError(status: 502, message: "OTA space check returned an unknown response") }
                guard result else { throw BridgeError(status: 409, message: "眼镜报告升级空间不足") }
                state = "openingTransferPage"
                try send(type: 4, body: ["Mode": 2]); deadline(for: state, seconds: 15)
            case 4 where state == "openingTransferPage":
                guard json["Result"] as? Bool == true else { throw BridgeError(status: 409, message: "眼镜未允许进入升级传输页面") }
                state = "waitingForVersion"; deadline(for: state, seconds: 30)
            case 5 where ["waitingForVersion", "waitingForManifest", "transferring"].contains(state):
                try send(type: 5, body: ["OtaVersion": package.version])
                if !servedSlice { state = "waitingForManifest"; deadline(for: state, seconds: 30) }
            case 6 where ["waitingForManifest", "transferring"].contains(state):
                guard json["OtaVersion"] as? String == package.version else {
                    throw BridgeError(status: 409, message: "眼镜请求的 OTA 版本与本地准备的包不一致")
                }
                try send(type: 6, message: package.manifestData)
                state = "transferring"; transferDeadline()
            case 7 where state == "transferring" || state == "awaitingInstallation":
                guard let name = json["Name"] as? String, let start = json["Start"] as? Int,
                      let size = json["Size"] as? Int, let file = package.files[name], let total = package.sizes[name],
                      start >= 0, start < total, size > 0, size <= 65_000, size <= total - start else {
                    throw BridgeError(status: 400, message: "眼镜请求了清单外文件或无效 OTA 分片")
                }
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                guard let bytes = try handle.read(upToCount: size), bytes.count == size else {
                    throw BridgeError(status: 422, message: "本地 OTA 文件无法读取完整分片")
                }
                try send(type: 7, body: ["Name": name, "Start": start, "Size": size], data: bytes)
                servedSlice = true; lastFile = name; sentBytes += bytes.count; transferDeadline()
            case 8 where state == "transferring" || state == "awaitingInstallation":
                if let value = json["Progress"] as? Int { progress = min(100, max(0, value)) }
                if progress == 100 { state = "awaitingInstallation" }
                transferDeadline()
            case 9 where (state == "transferring" || state == "awaitingInstallation") && servedSlice:
                installSeen = true; state = "awaitingVerification"; error = nil
                // The observed type 9 is a notification, not a command to echo or an installation success ACK.
            case 10:
                throw BridgeError(status: 502, message: "眼镜 OTA 文件处理失败：\(json["errcode"].map { String(describing: $0) } ?? "未知错误码")")
            default: break
            }
        } catch { fail(error) }
    }

    private func send(type: UInt64, body: [String: Any]? = nil, data: Data = Data()) throws {
        try send(type: type, message: body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data(), data: data)
    }

    private func send(type: UInt64, message: Data, data: Data = Data()) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.transportFrame(protocolID: 9, sequence: sequence, type: type, message: message, data: data))
    }

    private func deadline(for expected: String, seconds: Double) {
        let token = generation
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == token, self.state == expected else { return }
            self.state = expected == "awaitingVerification" ? "verificationUnconfirmed" : "interrupted"
            self.error = expected == "awaitingVerification" ? "未收到重启后的版本确认，可重连后再次核验。" : "OTA 响应超时；未确认设备当前升级状态，请先检查眼镜。"
        }
    }

    private var transferActivity = 0
    private func transferDeadline() {
        transferActivity += 1
        let activity = transferActivity, token = generation
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.generation == token, self.transferActivity == activity,
                  self.state == "transferring" || self.state == "awaitingInstallation" else { return }
            self.state = "interrupted"; self.error = "60 秒未收到 OTA 分片或进度，传输状态未确认。"
        }
    }

    private func fail(_ error: Error) {
        state = "failed"
        self.error = (error as? BridgeError)?.message ?? error.localizedDescription
    }

    private func normalizedVersion(_ value: String) -> String {
        value.replacingOccurrences(of: "Strix OS ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func status() -> [String: Any] {
        var result: [String: Any] = ["state": state, "active": active, "progress": progress, "sentBytes": sentBytes,
            "lastFile": lastFile, "firmware": firmware, "lastMessage": lastMessage, "canCancel": !active,
            "canVerify": installSeen, "error": error as Any? ?? NSNull()]
        result["official"] = officialStatus()
        if let package {
            result["package"] = ["path": package.source.path, "preparedPath": package.root.path, "version": package.version,
                "archiveBytes": package.archiveSize, "totalFileBytes": package.sizes.values.reduce(0, +), "files": package.manifest]
        }
        return result
    }

    private func prepare(path: String, version: String) throws -> OTAPreparedPackage {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard source.pathExtension.lowercased() == "zip" else { throw BridgeError(status: 400, message: "Select an OTA ZIP archive") }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let archiveSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard archiveSize > 0 else { throw BridgeError(status: 422, message: "OTA ZIP is empty") }
        let listing = try run("/usr/bin/zipinfo", arguments: ["-1", source.path])
        for entry in listing.split(separator: "\n") {
            let name = String(entry)
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw BridgeError(status: 422, message: "OTA archive contains an unsafe path")
            }
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OTAPackages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", arguments: ["-x", "-k", source.path, root.path])
        let manifestURL = root.appendingPathComponent("OtaFileInfo.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BridgeError(status: 422, message: "OTA ZIP root must contain the official OtaFileInfo.json manifest")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [[String: Any]], !manifest.isEmpty else {
            throw BridgeError(status: 422, message: "OtaFileInfo.json must contain the observed official file-entry array")
        }
        var files: [String: URL] = [:], sizes: [String: Int] = [:]
        for item in manifest {
            guard let name = item["Name"] as? String, !name.isEmpty, !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(".."), files[name] == nil,
                  let expectedSize = item["Size"] as? Int, expectedSize > 0,
                  let expectedMD5 = item["Md5"] as? String, expectedMD5.count == 32,
                  item["BurnMode"] != nil, item["BurnAddr"] != nil, item["BurnPath"] != nil else {
                throw BridgeError(status: 422, message: "OTA manifest contains an unsupported or incomplete file entry")
            }
            let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { throw BridgeError(status: 422, message: "OTA file is outside the prepared package") }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == expectedSize else {
                throw BridgeError(status: 422, message: "OTA file missing or size mismatch: \(name)")
            }
            // MD5 is required by this vendor manifest and checked by the official package validator.
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var digest = Insecure.MD5()
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { digest.update(data: block) }
            let actualMD5 = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualMD5 == expectedMD5.lowercased() else { throw BridgeError(status: 422, message: "OTA MD5 mismatch: \(name)") }
            files[name] = file; sizes[name] = expectedSize
        }
        guard manifestData.count < 65_000 else { throw BridgeError(status: 413, message: "OTA manifest exceeds one protocol frame") }
        return OTAPreparedPackage(source: source, root: root, version: version, archiveSize: archiveSize,
            manifest: manifest, manifestData: manifestData, files: files, sizes: sizes)
    }

    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw BridgeError(status: 422, message: "OTA archive tool failed: \(text)") }
        return text
    }
}
