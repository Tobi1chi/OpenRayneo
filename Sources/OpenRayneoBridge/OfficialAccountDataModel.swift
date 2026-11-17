// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

struct OfficialUserDataJob: Codable, Identifiable {
    enum Kind: String, Codable { case export, deletion }
    let id: UUID
    let kind: Kind
    let startedAt: Date
    var receipt: OfficialUserDataReceipt?
    var suppliedRequestID: String?
    var submission = "sending"
    var exportStatus: OfficialUserDataExportStatus?
    var deletionStatus: OfficialUserDataDeletionStatus?
    var lastError: String?
    var state: OfficialUserDataState? { exportStatus?.state ?? deletionStatus?.state }
    var title: String { kind == .export ? "导出个人数据" : "删除个人数据" }
    var requestID: String? { receipt?.requestId ?? suppliedRequestID }
}

@MainActor
final class OfficialAccountDataStore {
    let directory: URL
    init(configuration: OfficialFirmwareConfiguration) throws {
        let scope = try OfficialRecordingUploadStore.accountScope(configuration: configuration)
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OfficialAccountData", isDirectory: true)
            .appendingPathComponent(scope.uuidString, isDirectory: true)
    }
    func load() throws -> [OfficialUserDataJob] {
        let file = directory.appendingPathComponent("requests.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([OfficialUserDataJob].self, from: Data(contentsOf: file))
    }
    func save(_ jobs: [OfficialUserDataJob]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent("requests.json")
        try encoder.encode(jobs).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor
final class OfficialAccountDataModel: ObservableObject {
    enum ExportStep { case idle, code, receiver }
    static let shared = OfficialAccountDataModel()
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var notice = "管理当前官方账号的个人数据申请。"
    @Published private(set) var jobs: [OfficialUserDataJob] = []
    @Published private(set) var accountGeneration = UUID()
    @Published var acknowledgeDeletion = false
    @Published var receiverEmail = ""
    @Published var verificationCode = ""
    @Published private(set) var exportStep: ExportStep = .idle
    @Published private(set) var verificationTarget = ""
    @Published private(set) var retryAt: Date?
    private var configuration: OfficialFirmwareConfiguration?
    private var service: OfficialMemoryService?
    private var store: OfficialAccountDataStore?
    private var task: Task<Void, Never>?
    private var followup: Task<Void, Never>?
    private var statusPoll: Task<Void, Never>?
    private var watchingStatus = false
    private var operation = UUID()
    private var subscription: AnyCancellable?
    private let verification = OfficialAccountDataVerificationService()
    private var identity: OfficialAccountDataIdentity?

    private init() {
        reload()
        subscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.task?.cancel(); self.followup?.cancel(); self.statusPoll?.cancel(); self.operation = UUID()
                self.task = nil; self.followup = nil; self.statusPoll = nil
                self.busy = false; self.accountGeneration = UUID(); self.acknowledgeDeletion = false; self.receiverEmail = ""
                self.resetExport()
                self.reload()
                self.startStatusPolling()
            }
        }
    }
    private func reload() {
        configured = false; service = nil; configuration = nil; store = nil; jobs = []
        do {
            let reference = try OfficialFirmwareConfiguration.fromEnvironment()
            guard !reference.accessToken.isEmpty, !reference.accountID.isEmpty else { notice = "登录官方账号后可管理云端个人数据。"; return }
            let storage = try OfficialAccountDataStore(configuration: reference)
            var saved = try storage.load()
            for index in saved.indices where saved[index].submission == "sending" { saved[index].submission = "uncertain" }
            try storage.save(saved)
            configuration = reference; service = OfficialMemoryService(configuration: reference); store = storage; jobs = saved
            configured = true; notice = "申请回执只代表受理；请查看后续处理状态。"
        } catch { notice = error.localizedDescription }
    }
    var canDelete: Bool { configured && !busy && acknowledgeDeletion }
    var exportUnavailableReason: String? {
        guard configured else { return "请先登录官方账号。" }
        guard let profile = try? OfficialAccountSessionStore.selectedSession()?.profile,
              profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "当前会话缺少官方昵称资料，请先登录或更新昵称。"
        }
        return nil
    }
    func beginExportVerification() async {
        guard !busy, exportUnavailableReason == nil, let configuration else { return }
        do {
            guard let profile = try OfficialAccountSessionStore.selectedSession()?.profile,
                  profile.accountID == configuration.accountID else { return }
            let domestic = configuration.region == .domestic
            let target: OfficialAccountDataIdentity
            if domestic {
                guard let phone = profile.phone?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty else {
                    notice = "当前账号资料中没有可验证的绑定手机号。"; return
                }
                target = .phone(phone)
            } else {
                guard let email = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                    notice = "当前账号资料中没有可验证的绑定邮箱。"; return
                }
                target = .email(email, country: configuration.countryCode ?? "us")
            }
            identity = target; verificationTarget = target.label; retryAt = nil
            await sendExportCode()
        } catch { notice = error.localizedDescription }
    }
    func sendExportCode() async {
        guard !busy, let identity, retryAt.map({ $0 <= Date() }) ?? true else { return }
        let first = exportStep == .idle
        let id = UUID(); operation = id; busy = true
        defer { finish(id) }
        do {
            let outcome = try await verification.sendCode(identity)
            try check(id)
            if let seconds = outcome.retryAfter { retryAt = Date().addingTimeInterval(Double(seconds)) }
            else if first || outcome.notice == nil { retryAt = Date().addingTimeInterval(60) }
            exportStep = .code; notice = outcome.notice ?? "导出身份验证码已发送，请完成验证。"
        } catch { if operation == id { notice = error.localizedDescription } }
    }
    func verifyExportCode() async {
        guard !busy, exportStep == .code, let identity else { return }
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { notice = "请输入 6 位身份验证码。"; return }
        let id = UUID(); operation = id; busy = true
        defer { finish(id) }
        do {
            try await verification.verifyCode(identity, code: code)
            try check(id); verificationCode = ""
            switch identity {
            case .phone:
                exportStep = .receiver; notice = "身份已验证，请填写接收个人数据的邮箱。"
            case .email(let address, _):
                receiverEmail = address
                busy = false
                requestExport(identity: identity)
            }
        } catch { if operation == id { notice = error.localizedDescription } }
    }
    func submitVerifiedExport() {
        guard !busy, exportStep == .receiver, let identity else { return }
        requestExport(identity: identity)
    }
    private func requestExport(identity: OfficialAccountDataIdentity) {
        guard let service, let configuration,
              let profile = try? OfficialAccountSessionStore.selectedSession()?.profile,
              profile.accountID == configuration.accountID else { return }
        let email = receiverEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else { notice = "请输入有效的接收邮箱。"; return }
        guard let name = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            notice = "官方账号缺少昵称资料，导出申请未发送。"; return
        }
        let phone = profile.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account: String
        switch identity {
        case .phone(let verified):
            account = phone
            guard OfficialAccountDataVerificationService.normalizedPhone(phone) == OfficialAccountDataVerificationService.normalizedPhone(verified) else {
                resetExport(); notice = "绑定手机号已变更，请重新验证导出身份。"; return
            }
        case .email(let verified, _):
            guard profile.email?.trimmingCharacters(in: .whitespacesAndNewlines) == verified else {
                resetExport(); notice = "绑定邮箱已变更，请重新验证导出身份。"; return
            }
            account = email
        }
        let request = OfficialUserDataExportRequest(email: email, nickname: name, phone: phone, account: account)
        resetExport()
        submit(kind: .export) { try await service.requestUserDataExport(request) }
    }
    func cancelExportVerification() {
        guard !busy else { return }
        resetExport(); notice = "已取消本次导出准备。"
    }
    private func resetExport() {
        exportStep = .idle; identity = nil; verificationTarget = ""
        verificationCode = ""; receiverEmail = ""; retryAt = nil
    }
    func requestDeletion(expectedAccount: UUID) {
        guard canDelete, accountGeneration == expectedAccount, let service else { return }
        resetExport()
        submit(kind: .deletion) { try await service.requestUserDataDeletion() }
    }
    private func submit(kind: OfficialUserDataJob.Kind, request: @escaping () async throws -> OfficialUserDataReceipt) {
        guard !busy, let store else { return }
        let job = OfficialUserDataJob(id: UUID(), kind: kind, startedAt: Date())
        do { try store.save(jobs + [job]); jobs.append(job) }
        catch { notice = "未发送申请，本地回执日志保存失败：" + error.localizedDescription; return }
        let id = UUID(); operation = id; busy = true; acknowledgeDeletion = false
        notice = "正在提交" + job.title + "申请…"
        task = Task {
            defer { finish(id) }
            do {
                let receipt = try await request()
                try check(id)
                update(job.id) { $0.receipt = receipt; $0.submission = "accepted"; $0.lastError = nil }
                try store.save(jobs)
                notice = "官方已受理申请，编号：\(receipt.requestId)。处理尚未完成。"
                if kind == .deletion { scheduleDeletionStatus(job.id) }
                else { startStatusPolling() }
            } catch {
                guard operation == id else { return }
                update(job.id) { $0.submission = $0.receipt == nil ? "uncertain" : "accepted"; $0.lastError = error.localizedDescription }
                try? store.save(jobs)
                notice = jobs.first(where: { $0.id == job.id })?.receipt == nil
                    ? "申请结果未确认，请先核对官方记录，勿连续重复提交。" : "申请已受理，但本地记录保存未完成。"
            }
        }
    }
    func refresh(_ jobID: UUID) {
        guard !busy, let job = jobs.first(where: { $0.id == jobID }), let requestID = job.requestID,
              let service, let configuration, let store else { return }
        let id = UUID(); operation = id; busy = true; notice = "正在读取申请处理状态…"
        task = Task {
            defer { finish(id) }
            do {
                if job.kind == .export {
                    let status = try await service.userDataExportStatus(requestID: requestID)
                    try check(id)
                    guard status.accountId == configuration.accountID else { throw OfficialMemoryFailure(message: "返回的导出申请不属于当前账号。") }
                    update(jobID) { $0.exportStatus = status; $0.lastError = nil }
                } else {
                    let status = try await service.userDataDeletionStatus(requestID: requestID)
                    try check(id); update(jobID) { $0.deletionStatus = status; $0.lastError = nil }
                }
                try store.save(jobs)
                notice = "申请状态已更新。"
            } catch {
                guard operation == id else { return }
                update(jobID) { $0.lastError = error.localizedDescription }; try? store.save(jobs)
                notice = error.localizedDescription
            }
        }
    }
    func rememberExistingRequest(id: String, kind: OfficialUserDataJob.Kind) {
        guard configured, !busy, let store else { return }
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let existing = jobs.first(where: { $0.requestID == value && $0.kind == kind }) { refresh(existing.id); return }
        var job = OfficialUserDataJob(id: UUID(), kind: kind, startedAt: Date())
        job.suppliedRequestID = value; job.submission = "imported"
        do { try store.save(jobs + [job]); jobs.append(job); refresh(job.id) }
        catch { notice = error.localizedDescription }
    }
    private func scheduleDeletionStatus(_ jobID: UUID) {
        followup?.cancel(); let account = accountGeneration
        followup = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard accountGeneration == account else { return }
            refresh(jobID)
        }
    }
    func watchStatus() { watchingStatus = true; startStatusPolling() }
    func stopWatchingStatus() { watchingStatus = false; statusPoll?.cancel(); statusPoll = nil }
    func leavePanel() {
        stopWatchingStatus()
        // A submitted request keeps its journal; an unfinished verification cannot submit after leaving.
        if identity != nil { operation = UUID(); busy = false; resetExport() }
    }
    private func startStatusPolling() {
        guard watchingStatus, configured, statusPoll == nil else { return }
        let account = accountGeneration
        statusPoll = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard watchingStatus, accountGeneration == account else { return }
                if busy { continue }
                if let job = jobs.last(where: { $0.kind == .export && $0.requestID != nil && $0.state != .completed }) { refresh(job.id) }
            }
        }
    }
    func suspendForTermination() async {
        leavePanel(); followup?.cancel(); task?.cancel()
        if let task { await task.value }
    }
    private func update(_ id: UUID, mutation: (inout OfficialUserDataJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { mutation(&jobs[index]) }
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operation == id else { throw CancellationError() }
    }
    private func finish(_ id: UUID) { if operation == id { task = nil; busy = false } }
}
