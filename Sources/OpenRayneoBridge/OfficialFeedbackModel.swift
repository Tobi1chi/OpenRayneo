// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Foundation

@MainActor
final class OfficialFeedbackStore {
    let directory: URL
    init(scope: String) {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/OfficialFeedback", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
    }
    func load() throws -> OfficialFeedbackDraft {
        let file = directory.appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return OfficialFeedbackDraft() }
        return try JSONDecoder().decode(OfficialFeedbackDraft.self, from: Data(contentsOf: file))
    }
    func save(_ draft: OfficialFeedbackDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("draft.json")
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func stage(_ url: URL, draft: OfficialFeedbackDraft, role: OfficialFeedbackAttachment.Role, name: String? = nil) throws -> OfficialFeedbackAttachment {
        let folder = directory.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return OfficialFeedbackAttachment(name: name ?? url.lastPathComponent, path: destination.path, role: role)
    }
}

@MainActor
final class OfficialFeedbackModel: ObservableObject {
    @Published var draft = OfficialFeedbackDraft()
    @Published private(set) var choices: [OfficialFeedbackCategory.Choice] = []
    @Published private(set) var configured = false
    @Published private(set) var localDraftAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var collectingLogs = false
    @Published private(set) var submitting = false
    @Published private(set) var notice = "草稿保存在本机，点击提交后才会上传附件和反馈。"
    @Published private(set) var persistenceNotice = ""
    @Published private(set) var progress: Double = 0
    private weak var bridge: DesktopBridge?
    private var service: OfficialMemoryService?
    private var store: OfficialFeedbackStore?
    private var owner: OfficialOSSTransferQueue.Owner?
    private var task: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var operationID = UUID()
    private var accountSubscription: AnyCancellable?

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        reloadAccount()
        accountSubscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.accountChanged() }
        }
    }
    var selectedCategory: OfficialFeedbackCategory? { choices.first { $0.id == draft.categoryID }?.node }
    var selectedTitle: String { choices.first { $0.id == draft.categoryID }?.title ?? "尚未选择分类" }
    var connected: Bool { bridge?.connected == true }
    var editable: Bool { !busy && !collectingLogs && draft.submissionState == "draft" }
    var canSubmit: Bool { configured && editable && validationMessage == nil }
    var validationMessage: String? {
        guard let category = selectedCategory else { return "请读取官方分类并选择问题类型。" }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写问题标题。" }
        if draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请描述遇到的问题。" }
        // The original SN condition is visible, independently of required.
        if category.displayFields?["SN"]?.visible == true && draft.sn.isEmpty { return "当前分类需要眼镜 SN。" }
        if category.displayFields?["contactEmail"]?.required == true && draft.email.isEmpty { return "当前分类需要联系邮箱。" }
        if category.displayFields?["attachment"]?.required == true && !draft.attachments.contains(where: { $0.role == .attachment }) {
            return "当前分类需要问题附件。"
        }
        if let purchase = category.displayFields?["purchaseConfig"], purchase.required == true {
            if draft.purchasePlatform.isEmpty || draft.purchaseDate.isEmpty || draft.purchaseOrderNumber.isEmpty {
                return "请填写当前分类要求的购买信息。"
            }
            if purchase.PurchaseReceipt == true && !draft.attachments.contains(where: { $0.role == .purchaseReceipt }) { return "请添加购买凭证。" }
        }
        return nil
    }
    func shows(_ name: String) -> Bool { selectedCategory?.displayFields?[name]?.visible == true }
    func selectCategory(_ id: Int?) {
        guard editable else { return }
        draft.categoryID = id
        saveDraft()
    }
    func saveDraft() {
        guard let store else { return }
        do { try store.save(draft); persistenceNotice = "" }
        catch { persistenceNotice = "草稿保存失败：" + error.localizedDescription }
    }
    private func persist() throws {
        guard let store else { throw OfficialMemoryFailure(message: "本地反馈草稿目录不可用。") }
        try store.save(draft); persistenceNotice = ""
    }
    private func reloadAccount() {
        service = nil; configured = false; localDraftAvailable = false; owner = nil; choices = []; store = nil
        draft = OfficialFeedbackDraft(); persistenceNotice = ""
        do {
            let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
            let scope = configuration.accessToken.isEmpty || configuration.accountID.isEmpty
                ? "local-draft" : try OfficialRecordingUploadStore.accountScope(configuration: configuration).uuidString
            let storage = OfficialFeedbackStore(scope: scope)
            draft = try storage.load(); store = storage
            if !configuration.accessToken.isEmpty && !configuration.accountID.isEmpty {
                service = OfficialMemoryService(configuration: configuration)
                owner = .init(scope: scope, generation: UUID(), accountEpoch: configuration.identityEpoch)
                configured = true
                if let local = try? OfficialFeedbackStore(scope: "local-draft").load() {
                    localDraftAvailable = !local.title.isEmpty || !local.description.isEmpty || !local.attachments.isEmpty
                }
            }
            if draft.submissionState == "submitting" { draft.submissionState = "uncertain"; try persist() }
            notice = configured ? "选择官方分类，填写后提交。" : "尚未登录官方账号，可以先填写本地草稿。"
        } catch { notice = error.localizedDescription }
    }
    private func accountChanged() async {
        let previous = task, previousLog = logTask, previousOwner = owner
        let transition = UUID(); operationID = transition
        previous?.cancel(); previousLog?.cancel(); logTask = nil; collectingLogs = false
        task = nil; busy = true; submitting = false
        // Keep all writes on the old store until its interrupted request is journaled.
        if draft.submissionState == "submitting" { draft.submissionState = "uncertain"; saveDraft() }
        if let previousOwner { await OfficialOSSTransferQueue.shared.cancelAll(owner: previousOwner) }
        if let previous { await previous.value }
        if let previousLog { await previousLog.value }
        guard operationID == transition else { return }
        reloadAccount(); busy = false
    }
    func loadCategories() {
        guard !busy, !collectingLogs, let service else { return }
        let id = UUID(); operationID = id; busy = true; notice = "正在读取官方反馈分类…"
        task = Task {
            defer { finish(id) }
            do {
                let categories = try await service.feedbackCategories(glassesTypes: "雷鸟 S3")
                try check(id)
                choices = categories.flatMap { $0.choices() }
                notice = choices.isEmpty ? "官方当前返回空分类，暂时不能提交。" : "已读取 \(choices.count) 个官方问题分类。"
            } catch { if operationID == id { notice = error.localizedDescription } }
        }
    }
    func chooseAttachments(role: OfficialFeedbackAttachment.Role = .attachment) {
        guard editable, let store else { return }
        let operation = operationID, draftID = draft.id
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        guard editable, operationID == operation, draft.id == draftID, self.store === store else { return }
        draft.bundlePath = nil; draft.uploadedBundleKey = nil
        do {
            for url in panel.urls { draft.attachments.append(try store.stage(url, draft: draft, role: role)) }
            try persist()
        } catch { saveDraft(); notice = error.localizedDescription }
    }
    func removeAttachment(_ attachment: OfficialFeedbackAttachment) {
        guard editable else { return }
        let previous = draft
        draft.attachments.removeAll { $0.id == attachment.id }
        draft.bundlePath = nil; draft.uploadedBundleKey = nil
        do {
            try persist()
            try FileManager.default.trashItem(at: URL(fileURLWithPath: attachment.path), resultingItemURL: nil)
        } catch { draft = previous; saveDraft(); notice = error.localizedDescription }
    }
    func collectGlassesLog() {
        guard editable, let bridge, connected, let store else { return }
        collectingLogs = true; notice = "正在请求眼镜压缩日志…"
        let draftID = draft.id, operation = operationID
        logTask = Task {
            defer { if operationID == operation { collectingLogs = false; logTask = nil } }
            do {
                let result = try await bridge.request("/v1/logs/request")
                try check(operation)
                var payload = (result["reply"] as? [String: Any])?["payload"] as? [String: Any] ?? [:]
                var transferID = payload["data"] as? String ?? ""
                let started = Date()
                while Date().timeIntervalSince(started) < 180 {
                    try Task.checkCancellation()
                    guard operationID == operation, draft.id == draftID else { throw CancellationError() }
                    if let code = payload["value"] as? Int, [2, 3, 4].contains(code) { throw OfficialMemoryFailure(message: "眼镜日志压缩或获取失败（\(code)）。") }
                    let files = try await bridge.request("/v1/files", method: "GET")["transfers"] as? [[String: Any]] ?? []
                    try check(operation)
                    if !transferID.isEmpty, let file = files.first(where: { $0["uuid"] as? String == transferID && $0["direction"] as? String == "receive" }) {
                        if file["state"] as? String == "completed", let path = file["path"] as? String {
                            draft.attachments.append(try store.stage(URL(fileURLWithPath: path), draft: draft, role: .glassesLog))
                            draft.bundlePath = nil; draft.uploadedBundleKey = nil
                            try persist(); notice = "眼镜日志已加入草稿，提交时才会上传。"; return
                        }
                        if ["failed", "cancelled"].contains(file["state"] as? String ?? "") { throw OfficialMemoryFailure(message: "眼镜日志文件传输未完成。") }
                    }
                    try await Task.sleep(for: .seconds(1))
                    let state = try await bridge.request("/v1/maintenance", method: "GET")
                    payload = (state["logs"] as? [String: Any])?["payload"] as? [String: Any] ?? [:]
                    if let value = payload["data"] as? String, !value.isEmpty { transferID = value }
                }
                notice = "日志收集尚未完成，可在“文件传输”页查看后手动添加。"
            } catch { if operationID == operation { notice = error.localizedDescription } }
        }
    }
    func cancel() {
        guard !submitting else { return }
        task?.cancel(); logTask?.cancel()
    }
    func prepareBundle() {
        guard editable, !draft.attachments.isEmpty, let store else { return }
        let id = UUID(); operationID = id; busy = true; progress = 0
        notice = "正在本机准备附件包…"
        task = Task {
            defer { finish(id) }
            do {
                if draft.bundlePath == nil {
                    let bundle = try await OfficialFeedbackBundle.create(draft: draft, directory: store.directory)
                    try check(id); draft.bundlePath = bundle.path; try persist()
                }
                progress = 1; notice = "附件包已在本机准备，可查看后提交。"
            } catch { if operationID == id { notice = error.localizedDescription } }
        }
    }
    func submit() {
        guard canSubmit, let service, let owner, let levelID = selectedCategory?.treeId else { return }
        saveDraft()
        let id = UUID(); operationID = id; busy = true; progress = 0; notice = "正在准备反馈编号…"
        task = Task {
            defer { finish(id) }
            do {
                if draft.orderNo == nil {
                    let number = try await service.feedbackOrderNumber()
                    try check(id); draft.orderNo = number; try persist()
                }
                if !draft.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await service.reportFeedbackContact(draft)
                    try check(id)
                }
                let credentials = try await service.feedbackCredentials()
                try check(id)
                if !draft.attachments.isEmpty, draft.uploadedBundleKey == nil {
                    guard let store else { throw OfficialMemoryFailure(message: "本地反馈目录不可用。") }
                    if draft.bundlePath == nil {
                        notice = "正在打包附件和日志…"
                        let url = try await OfficialFeedbackBundle.create(draft: draft, directory: store.directory)
                        try check(id); draft.bundlePath = url.path; try persist()
                    }
                    guard let endpoint = URL(string: credentials.endpoint), let orderNo = draft.orderNo, let path = draft.bundlePath else { throw OfficialMemoryFailure(message: "反馈附件上传地址、总包或编号不可用。") }
                    let url = URL(fileURLWithPath: path)
                    let key = "feedback/\(orderNo)/\(url.lastPathComponent)"
                    let access = OfficialOSSUploader.Credentials(accessKeyID: credentials.ak, secretAccessKey: credentials.sk, securityToken: credentials.st, endpoint: endpoint)
                    let uploader = OfficialOSSUploader()
                    notice = "正在上传附件总包（\(draft.attachments.count) 个文件）…"
                    _ = try await OfficialOSSTransferQueue.shared.run(owner: owner, taskID: orderNo, kind: .upload, priority: .high) { events in
                        try await uploader.upload(fileURL: url, bucketName: credentials.bucketName, objectKey: key, credentials: access, ownerScope: owner.scope) { value in
                            if value.phase == .uploading { events.received() }
                            Task { @MainActor in
                                if self.operationID == id { self.progress = value.fraction }
                            }
                        }
                    }
                    try check(id)
                    draft.uploadedBundleKey = key
                    try persist()
                }
                try check(id)
                draft.submissionState = "submitting"; try persist(); submitting = true; notice = "正在提交官方反馈…"
                try await service.submitFeedback(OfficialFeedbackRequest(draft: draft, levelID: levelID))
                try check(id)
                draft.submissionState = "submitted"; try persist(); progress = 1
                notice = "官方已接受反馈，编号：\(draft.orderNo ?? "")。"
            } catch {
                guard operationID == id else { return }
                if draft.submissionState == "submitting" { draft.submissionState = "uncertain"; saveDraft() }
                notice = draft.submissionState == "uncertain" ? "提交结果尚未确认，已保留编号和草稿。请先核对官方反馈记录。" : error.localizedDescription
            }
        }
    }
    func newDraft(keepContent: Bool) {
        guard !busy && !collectingLogs else { return }
        if keepContent {
            draft.id = UUID(); draft.orderNo = nil; draft.submissionState = "draft"
            draft.bundlePath = nil; draft.uploadedBundleKey = nil
        } else { draft = OfficialFeedbackDraft() }
        saveDraft(); notice = "新草稿已准备。"
    }
    func copyLocalDraft() {
        guard configured, editable, let store else { return }
        do {
            var imported = try OfficialFeedbackStore(scope: "local-draft").load()
            let sources = imported.attachments
            imported.id = UUID(); imported.orderNo = nil; imported.submissionState = "draft"
            imported.categoryID = nil; imported.bundlePath = nil; imported.uploadedBundleKey = nil; imported.attachments = []
            for attachment in sources {
                imported.attachments.append(try store.stage(URL(fileURLWithPath: attachment.path), draft: imported,
                    role: attachment.role, name: attachment.name))
            }
            try store.save(imported); draft = imported
            notice = "已复制登录前草稿，请读取并重新选择当前账号的官方分类。"
        } catch { notice = error.localizedDescription }
    }
    func suspendForTermination() async {
        logTask?.cancel(); task?.cancel()
        if let owner { await OfficialOSSTransferQueue.shared.cancelAll(owner: owner) }
        if let task { await task.value }
        if let logTask { await logTask.value }
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }
    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        busy = false; submitting = false; task = nil
    }
}
