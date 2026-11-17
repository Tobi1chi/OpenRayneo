// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

struct OfficialMemoryRow: Identifiable {
    let id: String
    let data: [String: Any]

    init(_ data: [String: Any], identity: String) {
        self.data = data
        id = Self.text(data[identity]) ?? Self.text(data["id"]) ?? UUID().uuidString
    }

    var title: String { Self.text(data["title"]) ?? Self.text(data["topicName"]) ?? Self.text(data["name"]) ?? "未命名记录" }
    var taskID: String? { Self.text(data["taskId"]) }
    var topicID: String? { Self.text(data["topicId"]) }
    var createdAt: Date? { Self.date(data["createTime"]) }
    static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    static func date(_ value: Any?) -> Date? {
        milliseconds(value).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
    static func milliseconds(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

@MainActor
final class OfficialMemoryModel: ObservableObject {
    static let shared = OfficialMemoryModel()
    @Published var section = "timeline"
    @Published var day = Date()
    @Published var timezone = TimeZone.current.identifier
    @Published var taskType = "all"
    @Published private(set) var busy = false
    @Published private(set) var canCancel = false
    @Published private(set) var notice = "选择内容后手动读取官方账号已有记录。"
    @Published private(set) var configurationNotice = ""
    @Published private(set) var configured = false
    @Published private(set) var timeline: [OfficialMemoryRow] = []
    @Published private(set) var topics: [OfficialMemoryRow] = []
    @Published private(set) var timelineScope = "尚未读取日期"
    @Published private(set) var topicLimit: Int?
    @Published private(set) var activeTopicCount: Int?
    @Published private(set) var topicMutationNotice = ""
    @Published private(set) var sessions: [OfficialMemoryRow] = []
    @Published private(set) var sessionTotal: Int?
    @Published private(set) var nextDeadline: Int64?
    @Published private(set) var selectedTitle = ""
    @Published private(set) var selectedData: [String: Any]?
    @Published private(set) var selectedKind = ""
    @Published private(set) var selectedCloudTaskID: String?
    @Published private(set) var selectedTopicID: String?
    @Published private(set) var accountGeneration = UUID()
    @Published private(set) var cacheNotice = ""
    @Published private(set) var contentSource = "尚未读取"
    @Published private(set) var summaryTemplates: [OfficialSummaryTemplate] = []
    @Published private(set) var summaryModels: [OfficialSummaryModel] = []
    @Published var selectedSummaryModel = ""
    @Published var selectedSummaryTemplate = ""
    private var service: OfficialMemoryService?
    private var cache: OfficialMemoryCache?
    private var task: Task<Void, Never>?
    private var loadedSessionType: String?
    private var accountSubscription: AnyCancellable?
    private var operationID = UUID()
    private var sessionCycles: [String: OfficialSessionListCycle] = [:]
    private var deletedSessionIDs = Set<String>()
    private var invalidatedTopicIDs = Set<String>()

    private init() {
        reloadAccount()
        accountSubscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.accountChanged() }
        }
    }

    private func reloadAccount() {
        do {
            let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
            let service = OfficialMemoryService(configuration: configuration)
            self.service = service; configured = service.configured
            if configured {
                do { cache = try OfficialMemoryCache(configuration: configuration); cacheNotice = "" }
                catch { cache = nil; cacheNotice = error.localizedDescription }
            } else { cache = nil; cacheNotice = "" }
            deletedSessionIDs = cache?.deletedSessionIDs ?? []
            selectedSummaryModel = cache?.snapshot("summaryModel")?.value as? String ?? ""
            configurationNotice = service.configured ? "官方账号会话已配置 · \(configuration.region == .domestic ? "境内" : "海外")"
                : "尚未配置官方账号会话，可展开上方会话设置。AI 服务密钥不能替代官方会话。"
            restoreCachedList()
        } catch { service = nil; cache = nil; configured = false; configurationNotice = error.localizedDescription }
    }

    private func accountChanged() {
        task?.cancel(); task = nil; operationID = UUID(); busy = false; canCancel = false
        sessionCycles = [:]; deletedSessionIDs = []; invalidatedTopicIDs = []
        summaryTemplates = []; summaryModels = []; selectedSummaryModel = ""; selectedSummaryTemplate = ""
        accountGeneration = UUID()
        timeline = []; topics = []; sessions = []; selectedData = nil; selectedTitle = ""; selectedKind = ""
        selectedCloudTaskID = nil; selectedTopicID = nil
        timelineScope = "尚未读取日期"; sessionTotal = nil; nextDeadline = nil; loadedSessionType = nil
        topicLimit = nil; activeTopicCount = nil
        topicMutationNotice = ""
        reloadAccount()
        notice = "官方会话已变化，请重新读取账号内容。"
    }

    var canLoadNext: Bool { nextDeadline != nil && loadedSessionType == taskType && !busy }
    var accountReference: OfficialFirmwareConfiguration? { service?.configuration }
    var selectedAudioItem: OfficialCloudAudioItem? {
        guard let taskID = selectedCloudTaskID, let detail = selectedData else { return nil }
        let task = detail["aiTask"] as? [String: Any] ?? [:]
        let recording = detail["recording"] as? [String: Any] ?? [:]
        return OfficialCloudAudioItem(taskID: taskID, title: selectedTitle, taskType: task["taskType"] as? String,
            createdAtMilliseconds: OfficialMemoryRow.milliseconds(task["createTime"]),
            bucketName: task["bucketName"] as? String ?? recording["bucketName"] as? String,
            objectKey: task["objectKey"] as? String ?? recording["objectKey"] as? String)
    }

    func restoreCachedList() {
        guard !busy else { return }
        selectedData = nil; selectedTitle = ""; selectedKind = ""
        selectedCloudTaskID = nil; selectedTopicID = nil
        let key: String
        switch section {
        case "sessions": key = "sessions:" + taskType
        case "topics": key = "topics"
        default: key = timelineCacheKey
        }
        let snapshot = cache?.snapshot(key) ?? (section == "sessions" ? cache?.snapshot("sessions:all") : nil)
        guard let snapshot, let value = snapshot.value as? [String: Any] else {
            if section == "sessions", let rows = cache?.sessionRows(taskType: taskType), !rows.isEmpty {
                sessions = rows.map { OfficialMemoryRow($0, identity: "taskId") }
                sessionTotal = nil; nextDeadline = nil; loadedSessionType = nil
                contentSource = "本地缓存 · 当前类型尚未单独同步"
                return
            }
            switch section {
            case "sessions": sessions = []; sessionTotal = nil; nextDeadline = nil; loadedSessionType = nil
            case "topics": topics = []; topicLimit = nil; activeTopicCount = nil
            default: timeline = []; timelineScope = "这个日期／时区尚无缓存"
            }
            contentSource = "尚无本地缓存"
            return
        }
        let rows = value["rows"] as? [[String: Any]] ?? []
        switch section {
        case "sessions":
            sessions = (cache?.sessionRows(taskType: taskType) ?? rows).map { OfficialMemoryRow($0, identity: "taskId") }
            sessionTotal = (value["total"] as? NSNumber)?.intValue
            let matchingScope = cache?.snapshot(key) != nil
            nextDeadline = matchingScope ? OfficialMemoryRow.milliseconds(value["deadline"]) : nil
            loadedSessionType = matchingScope ? taskType : nil
        case "topics":
            topics = rows.map { OfficialMemoryRow($0, identity: "topicId") }
            topicLimit = (value["limit"] as? NSNumber)?.intValue
            activeTopicCount = (value["active"] as? NSNumber)?.intValue
        default:
            timeline = rows.map { OfficialMemoryRow($0, identity: "id") }
            timelineScope = value["scope"] as? String ?? "本地缓存"
        }
        contentSource = "本地缓存 · " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func clearCachedContent() {
        guard !busy, let cache else { return }
        do {
            try cache.clear()
            deletedSessionIDs = []; sessionCycles = [:]
            cacheNotice = "这个账号的本地缓存已移到废纸篓。"
            notice = "本地缓存已清理，当前窗口内容保留。"
        } catch { cacheNotice = error.localizedDescription }
    }

    func loadTimeline() {
        guard let service else { notice = configurationNotice; return }
        guard let zone = TimeZone(identifier: timezone) else { notice = "请选择有效的时区，例如 Asia/Shanghai。"; return }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: day)
        perform("正在读取官方时间线…") {
            let value = try await service.timeline(date: date, timezone: zone.identifier)
            let rows: [[String: Any]]
            if value is NSNull { rows = [] }
            else if let data = value as? [String: Any] {
                if data["events"] == nil || data["events"] is NSNull { rows = [] }
                else if let events = data["events"] as? [[String: Any]] { rows = events }
                else { throw OfficialMemoryFailure(message: "官方时间线 events 不是可识别的列表。") }
            } else { throw OfficialMemoryFailure(message: "官方时间线不是日期记录对象。") }
            try Task.checkCancellation()
            self.timeline = rows.map { OfficialMemoryRow($0, identity: "id") }
            self.timelineScope = "\(date) · \(zone.identifier)"
            self.notice = "已读取这一天的 \(rows.count) 条官方时间线记录。"
            self.contentSource = "官方服务 · 刚刚读取"
            self.saveCache(["rows": rows, "scope": self.timelineScope], key: "timeline:" + date + ":" + zone.identifier)
        }
    }

    func loadTopics() {
        guard let service else { notice = configurationNotice; return }
        perform("正在读取官方主题…") {
            try await self.readTopics(using: service)
            self.notice = "已读取 \(self.topics.count) 个官方主题。"
        }
    }

    private func readTopics(using service: OfficialMemoryService) async throws {
        let value = try await service.topics()
        guard let data = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方主题列表不是记录对象。") }
        let rows: [[String: Any]]
        if data["topics"] == nil || data["topics"] is NSNull { rows = [] }
        else if let topics = data["topics"] as? [[String: Any]] { rows = topics }
        else { throw OfficialMemoryFailure(message: "官方主题 topics 不是可识别的列表。") }
        try Task.checkCancellation()
        topics = rows.map { OfficialMemoryRow($0, identity: "topicId") }
        topicLimit = (data["maxTopicAmount"] as? NSNumber)?.intValue ?? (data["maxTopicAmout"] as? NSNumber)?.intValue
        activeTopicCount = (data["activeTopicCount"] as? NSNumber)?.intValue
        contentSource = "官方服务 · 刚刚读取"
        saveTopicListCache()
    }

    private func saveTopicListCache() {
        saveCache(["rows": topics.map(\.data), "limit": topicLimit as Any? ?? NSNull(),
                   "active": activeTopicCount as Any? ?? NSNull()], key: "topics")
    }

    func topicEditorTarget(new: Bool = false) -> OfficialTopicEditTarget? {
        guard configured else { return nil }
        if new { return .init(account: accountGeneration, topicID: nil, title: "", synonyms: [], facts: []) }
        guard selectedKind == "topic", let topicID = selectedTopicID, let data = selectedData else { return nil }
        let facts = (data["relatedFacts"] as? [[String: Any]] ?? []).compactMap { fact -> (id: String, content: String)? in
            guard let id = fact["factsId"] as? String ?? fact["factIds"] as? String ?? fact["factId"] as? String else { return nil }
            return (id, fact["content"] as? String ?? "")
        }
        return .init(account: accountGeneration, topicID: topicID, title: data["topicName"] as? String ?? selectedTitle,
                     synonyms: data["synonyms"] as? [String] ?? [], facts: facts)
    }

    var selectedTopicStatus: OfficialTopicStatus? {
        (selectedData?["status"] as? Int).flatMap(OfficialTopicStatus.init(rawValue:))
    }
    var selectedTopicFavourite: Bool? { topics.first { $0.topicID == selectedTopicID }?.data["favourite"] as? Bool }

    func createTopic(_ request: OfficialTopicCreateRequest, target: OfficialTopicEditTarget, completed: @escaping () -> Void) {
        guard target.topicID == nil, !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutateTopic("正在创建官方主题…", target: target, completed: completed) { service in try await service.createTopic(request) }
    }

    func confirmTopic(_ request: OfficialTopicConfirmRequest, target: OfficialTopicEditTarget, completed: @escaping () -> Void) {
        guard target.topicID == request.topicID, selectedTopicStatus == .recommended else { return }
        mutateTopic("正在确认推荐主题…", target: target, completed: completed) { service in
            try await service.confirmTopic(request)
        }
    }

    func changeTopicStatus(_ status: OfficialTopicStatus, target: OfficialTopicEditTarget) {
        guard let id = target.topicID, [.active, .paused, .deleted].contains(status) else { return }
        mutateTopic("正在更新主题状态…", target: target, deleting: status == .deleted) { service in
            try await service.changeTopicStatus(id: id, status: status); return id
        }
    }

    func changeTopicSynonym(_ synonym: String, removing: Bool, target: OfficialTopicEditTarget, completed: @escaping () -> Void = {}) {
        guard let id = target.topicID, !synonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutateTopic(removing ? "正在移除主题关键词…" : "正在添加主题关键词…", target: target, completed: completed) { service in
            try await service.changeTopicSynonym(id: id, synonym: synonym, removing: removing); return id
        }
    }

    func changeTopicFavourite(_ favourite: Bool, target: OfficialTopicEditTarget) {
        guard let id = target.topicID else { return }
        mutateTopic("正在更新主题收藏…", target: target) { service in
            try await service.updateTopicFavourite(id: id, favourite: favourite); return id
        }
    }

    func disableTopicRecommendations(expectedAccount: UUID) {
        guard configured, !busy, accountGeneration == expectedAccount, let service else { return }
        perform("正在关闭官方主题推荐…", cancellable: false) {
            try await service.disableTopicRecommendations()
            try Task.checkCancellation()
            self.notice = "官方服务已接受关闭主题推荐；已有主题保留。"
        }
    }

    func saveTopicItem(_ target: OfficialTopicItemEditTarget, content: String, description: String,
                       starred: Bool, completed: Bool?, finished: @escaping () -> Void) {
        guard let id = target.topic.topicID, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              target.itemID?.hasPrefix("local_") != true else { return }
        mutateTopic("正在保存主题内容…", target: target.topic, completed: finished) { service in
            switch (target.kind, target.itemID) {
            case (.fact, .none): try await service.createTopicFact(id: id, content: content)
            case (.fact, .some(let factID)): try await service.updateTopicFact(id: factID, content: content)
            case (.task, .none): try await service.createTopicTask(id: id, content: content, starred: starred)
            case (.task, .some(let taskID)):
                try await service.updateTopicTask(id: taskID,
                    content: content == target.content ? nil : content,
                    description: description == target.description ? nil : description,
                    starred: starred == target.starred ? nil : starred, completed: completed)
            }
            return id
        }
    }

    func completeTopicTask(id: String, target: OfficialTopicEditTarget) {
        guard let topicID = target.topicID, !id.hasPrefix("local_") else { return }
        mutateTopic("正在标记官方任务完成…", target: target) { service in
            try await service.updateTopicTask(id: id, content: nil, description: nil, starred: nil, completed: true)
            return topicID
        }
    }

    func deleteTopicTask(id: String, target: OfficialTopicEditTarget) {
        guard let topicID = target.topicID, !id.hasPrefix("local_") else { return }
        mutateTopic("正在删除官方任务…", target: target) { service in
            try await service.deleteTopicTask(id: id); return topicID
        }
    }

    func unlinkTopicContent(id: String, fact: Bool, target: OfficialTopicEditTarget) {
        guard let topicID = target.topicID else { return }
        mutateTopic("正在移除主题关联…", target: target) { service in
            try await service.unlinkTopicContent(id: topicID, relatedID: id, fact: fact); return topicID
        }
    }

    func markSelectedTopicRead(target: OfficialTopicEditTarget) {
        guard let id = target.topicID else { return }
        mutateTopic("正在标记主题已读…", target: target) { service in
            try await service.markTopicRead(id: id); return id
        }
    }

    private func mutateTopic(_ message: String, target: OfficialTopicEditTarget, deleting: Bool = false,
                             completed: @escaping () -> Void = {},
                             operation: @escaping (OfficialMemoryService) async throws -> String) {
        guard configured, !busy, accountGeneration == target.account, let service,
              target.topicID == nil || (selectedKind == "topic" && selectedTopicID == target.topicID) else { return }
        perform(message, cancellable: false) {
            let id = try await operation(service)
            try Task.checkCancellation()
            self.topicMutationNotice = "官方已受理主题修改（\(id)）；正在读取更新后的内容。"
            self.saveCache(["topicId": id, "at": Date().timeIntervalSince1970], key: "lastTopicMutation")
            completed()
            if deleting {
                self.topics.removeAll { $0.topicID == id }; self.saveTopicListCache()
                self.saveCache(["deleted": true], key: "topic:" + id)
                self.selectedData = nil; self.selectedTopicID = nil; self.selectedKind = ""; self.selectedTitle = ""
            } else {
                self.invalidatedTopicIDs.insert(id)
                self.saveCache(["pendingRefresh": true], key: "topic:" + id)
                self.selectedData = nil; self.selectedTitle = target.title
                self.selectedTopicID = id; self.selectedCloudTaskID = nil; self.selectedKind = "topic"
            }
            do {
                try await self.readTopics(using: service)
                if !deleting {
                    let value = try await service.topic(id: id)
                    try Task.checkCancellation()
                    guard let data = value as? [String: Any] else { throw OfficialMemoryFailure(message: "主题详情尚未就绪，请稍后刷新。") }
                    self.selectedData = data
                    self.invalidatedTopicIDs.remove(id)
                    self.selectedTitle = data["topicName"] as? String ?? self.topics.first(where: { $0.topicID == id })?.title ?? target.title
                    self.saveCache(["data": data, "title": self.selectedTitle], key: "topic:" + id)
                }
                self.topicMutationNotice = "官方已受理，主题内容已重新读取。"
                self.notice = self.topicMutationNotice
            } catch {
                try Task.checkCancellation()
                self.notice = "官方已受理主题修改（\(id)），但内容刷新未完成：" + error.localizedDescription
                self.topicMutationNotice = self.notice
            }
        }
    }

    func loadTopic(_ row: OfficialMemoryRow) {
        guard let service, let id = row.topicID else { notice = "这条主题未提供可读取详情的 topicId。"; return }
        if selectedTopicID != id { selectedData = nil }
        selectedTopicID = id; selectedCloudTaskID = nil
        if !invalidatedTopicIDs.contains(id), let snapshot = cache?.snapshot("topic:" + id), let value = snapshot.value as? [String: Any],
           let data = value["data"] as? [String: Any] {
            selectedData = data; selectedTitle = value["title"] as? String ?? row.title; selectedKind = "topic"
            contentSource = "本地缓存 · " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
        }
        perform("正在读取主题详情…") {
            let value = try await service.topic(id: id)
            guard let data = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方主题详情不是记录对象。") }
            try Task.checkCancellation()
            self.selectedData = data; self.selectedTitle = row.title; self.selectedKind = "topic"
            self.invalidatedTopicIDs.remove(id)
            self.notice = "已读取所选主题详情。"
            self.saveCache(["data": data, "title": row.title], key: "topic:" + id)
        }
    }

    func refreshSelectedTopic() {
        guard let id = selectedTopicID else { return }
        loadTopic(OfficialMemoryRow(["topicId": id, "topicName": selectedTitle], identity: "topicId"))
    }

    func loadSessions(next: Bool = false) {
        guard !busy else { return }
        guard let service else { notice = configurationNotice; return }
        let kind = taskType
        guard !next || canLoadNext else { return }
        let deadline = next ? nextDeadline! : 9_999_999_999_999
        if !next { sessionCycles[kind] = OfficialSessionListCycle(taskType: kind) }
        perform("正在读取官方会话…") {
            let value = try await service.sessions(deadline: deadline, taskType: kind == "all" ? nil : kind)
            guard let data = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方会话列表不是记录对象。") }
            let rows: [[String: Any]]
            if data["pageList"] == nil || data["pageList"] is NSNull { rows = [] }
            else if let page = data["pageList"] as? [[String: Any]] { rows = page }
            else { throw OfficialMemoryFailure(message: "官方会话 pageList 不是可识别的列表。") }
            try Task.checkCancellation()
            let total = (data["total"] as? NSNumber)?.intValue
            var cycle = self.sessionCycles[kind]
            let cursor = cycle?.accept(rows: rows, total: total, deadline: deadline,
                explicitPage: data["pageList"] is [[String: Any]])
            self.sessionCycles[kind] = cycle
            let incoming = rows.compactMap { row -> OfficialMemoryRow? in
                guard let id = OfficialMemoryRow.text(row["taskId"]), !self.deletedSessionIDs.contains(id) else { return nil }
                return OfficialMemoryRow(row, identity: "taskId")
            }
            do { try self.cache?.upsertSessionRows(incoming.map(\.data)) }
            catch { self.cacheNotice = "云列表已读取，缓存更新未完成：" + error.localizedDescription }
            if !next {
                self.sessions = (self.cache?.sessionRows(taskType: kind) ?? self.sessions.map(\.data))
                    .map { OfficialMemoryRow($0, identity: "taskId") }
            }
            for row in incoming {
                if let index = self.sessions.firstIndex(where: { $0.id == row.id }) { self.sessions[index] = row }
                else { self.sessions.append(row) }
            }
            if let cycle, cycle.complete {
                let candidates = (self.cache?.sessionRows(taskType: kind) ?? []) + self.sessions.map(\.data)
                let removed = Set(candidates.filter { cycle.includes($0) }.compactMap { OfficialMemoryRow.text($0["taskId"]) })
                    .subtracting(cycle.seenIDs)
                self.sessions.removeAll { removed.contains($0.id) }
                if let selected = self.selectedCloudTaskID, removed.contains(selected) {
                    self.selectedCloudTaskID = nil; self.selectedData = nil; self.selectedTitle = ""; self.selectedKind = ""
                }
                do { if !removed.isEmpty { try self.cache?.removeSessions(removed) } }
                catch { self.cacheNotice = "云列表已同步，本地旧详情清理未完成：" + error.localizedDescription }
            }
            self.sessions.sort { (OfficialMemoryRow.milliseconds($0.data["createTime"]) ?? 0) > (OfficialMemoryRow.milliseconds($1.data["createTime"]) ?? 0) }
            self.sessionTotal = total
            self.loadedSessionType = kind
            // A resumed disk cursor has no active cycle and may only upsert.
            self.nextDeadline = cycle == nil
                ? rows.compactMap { OfficialMemoryRow.milliseconds($0["createTime"]) }.min().flatMap { $0 < deadline ? $0 : nil }
                : cursor
            self.notice = "已读取 \(self.sessions.count) 个官方会话。" +
                (cycle?.paginationBlocked == true ? "时间游标未继续推进，已停止加载更多。" : "")
            self.contentSource = cycle?.complete == true ? "官方服务 · 本轮完整同步完成" : "官方读取与已保存缓存合并 · 尚未确认全量"
            self.saveCache(["rows": self.sessions.map(\.data), "total": self.sessionTotal as Any? ?? NSNull(),
                "deadline": self.nextDeadline as Any? ?? NSNull(), "reachedEnd": cycle?.reachedEnd ?? false,
                "syncedCount": cycle?.seenIDs.count as Any? ?? NSNull(),
                "paginationBlocked": cycle?.paginationBlocked ?? false], key: "sessions:" + kind)
        }
    }

    func loadSession(_ row: OfficialMemoryRow) {
        guard !busy else { return }
        guard let service, let taskID = row.taskID else { notice = "这条记录未提供可读取详情的 taskId。"; return }
        guard !deletedSessionIDs.contains(taskID) else { notice = "这条会话已删除，请重新读取列表。"; return }
        if selectedCloudTaskID != taskID { selectedData = nil }
        selectedCloudTaskID = taskID; selectedTopicID = nil
        if let snapshot = cache?.snapshot("session:" + taskID), let value = snapshot.value as? [String: Any],
           let data = value["data"] as? [String: Any] {
            selectedData = data; selectedTitle = value["title"] as? String ?? row.title; selectedKind = "session"
            contentSource = "本地缓存 · " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
        }
        perform("正在读取会话转写与摘要…") {
            let value = try await service.session(taskID: taskID)
            let record = try self.sessionRecord(value, taskID: taskID)
            try Task.checkCancellation()
            self.selectedData = record; self.selectedTitle = row.title; self.selectedKind = "session"
            self.notice = "已读取所选会话详情。"
            self.contentSource = "官方服务 · 刚刚读取"
            self.saveCache(["data": record, "title": row.title], key: "session:" + taskID)
        }
    }

    func refreshSelectedSession() {
        guard !busy, selectedKind == "session", let taskID = selectedCloudTaskID else { return }
        loadSession(sessions.first(where: { $0.taskID == taskID })
            ?? OfficialMemoryRow(["taskId": taskID, "name": selectedTitle], identity: "taskId"))
    }

    var selectedTranscriptKind: OfficialTranscriptKind? {
        guard selectedKind == "session", let detail = selectedData else { return nil }
        return OfficialTranscriptKind.from(detail)
    }

    var canEditTranscript: Bool {
        guard let detail = selectedData, let kind = selectedTranscriptKind,
              let clips = kind.rawClips(in: detail) as? [[String: Any]] else { return false }
        return !clips.isEmpty
    }

    var selectedSpeakerIdentities: [OfficialSpeakerIdentity] {
        guard let detail = selectedData, let kind = selectedTranscriptKind,
              let clips = try? OfficialTranscriptClip.parse(kind.rawClips(in: detail)),
              let snapshot = try? OfficialSpeakerNormalization.normalize(clips: clips,
                sessionID: selectedCloudTaskID ?? "", srcType: kind == .recording ? "recording" : "cc") else { return [] }
        return snapshot.identities
    }

    func transcriptEditorTarget() -> OfficialTranscriptEditTarget? {
        guard !busy, canEditTranscript, let taskID = selectedCloudTaskID,
              let detail = selectedData, let kind = selectedTranscriptKind else { return nil }
        do {
            let clips = try OfficialTranscriptClip.parse(kind.rawClips(in: detail)) ?? []
            let target = OfficialTranscriptEditTarget(taskID: taskID, account: accountGeneration,
                title: selectedTitle, kind: kind, clips: clips)
            guard !target.editableIndices.isEmpty else {
                notice = "转写片段缺少可定位的身份信息，请刷新会话后再编辑。"; return nil
            }
            return target
        } catch { notice = error.localizedDescription; return nil }
    }

    func saveTranscript(_ clips: [OfficialTranscriptClip], target: OfficialTranscriptEditTarget,
                                 completed: @escaping () -> Void) {
        guard !busy, accountGeneration == target.account, selectedCloudTaskID == target.taskID,
              canEditTranscript, selectedTranscriptKind == target.kind, let detail = selectedData, let service else { return }
        do {
            let current = try OfficialTranscriptClip.parse(target.kind.rawClips(in: detail))
            guard current == target.clips else {
                notice = "转写内容已变化，请关闭编辑器并重新打开，当前草稿未提交。"; return
            }
        } catch { notice = error.localizedDescription; return }
        guard clips != target.clips else { return }
        let changedClips = clips.enumerated().filter { target.clips[$0.offset] != $0.element }.map(\.element)
        perform("正在保存\(target.kind.title)…", cancellable: false) {
            switch target.kind {
            case .recording:
                _ = try await service.updateRecordingTranscript(.init(taskID: target.taskID, clips: clips))
            case .caption:
                _ = try await service.updateCaptionTranscript(changedClips.map { .init(taskID: target.taskID, clip: $0) })
            }
            try Task.checkCancellation()
            guard self.accountGeneration == target.account, self.selectedCloudTaskID == target.taskID else { return }
            do {
                let value = try await service.session(taskID: target.taskID)
                try Task.checkCancellation()
                let detail = try self.sessionRecord(value, taskID: target.taskID)
                guard let confirmed = try OfficialTranscriptClip.parse(target.kind.rawClips(in: detail)) else {
                    throw OfficialMemoryFailure(message: "会话尚未返回转写片段。")
                }
                self.selectedData = detail; self.contentSource = "官方服务 · 刚刚读取"
                self.saveCache(["data": detail, "title": self.selectedTitle], key: "session:" + target.taskID)
                let matches = target.kind == .recording ? confirmed == clips : changedClips.allSatisfy { wanted in
                    guard let actual = confirmed.first(where: { $0.clipID == wanted.clipID }) else { return false }
                    return actual.content == wanted.content && actual.translateContent == wanted.translateContent
                        && actual.speakerID == wanted.speakerID && actual.speakerName == wanted.speakerName
                        && (actual.speakerType ?? "others") == (wanted.speakerType ?? "others")
                }
                self.notice = matches ? "\(target.kind.title)已保存并读回确认。"
                    : "转写保存请求已受理；读回内容与提交不同，当前显示服务端内容。"
            } catch {
                try Task.checkCancellation()
                self.notice = "转写保存请求已受理，读回暂未确认。请刷新会话内容：" + error.localizedDescription
            }
            completed()
        }
    }

    func speakerEditorTarget() -> OfficialSpeakerEditTarget? {
        guard !busy, canEditTranscript, let taskID = selectedCloudTaskID,
              let detail = selectedData, let kind = selectedTranscriptKind else { return nil }
        do {
            let clips = try OfficialTranscriptClip.parse(kind.rawClips(in: detail)) ?? []
            var snapshot = try OfficialSpeakerNormalization.normalize(clips: clips, sessionID: taskID,
                srcType: kind == .recording ? "recording" : "cc")
            snapshot.visibleDisplayNames = OfficialSpeakerNormalization.displayNames(for: snapshot.identities)
            return .init(transcript: .init(taskID: taskID, account: accountGeneration, title: selectedTitle,
                kind: kind, clips: clips), snapshot: snapshot)
        } catch { notice = error.localizedDescription; return nil }
    }

    func saveSpeakerNames(_ plan: OfficialSpeakerNamingPlan, target: OfficialSpeakerEditTarget,
                          completed: @escaping () -> Void) {
        guard plan.source == target.snapshot else { return }
        do { saveTranscript(try plan.project(onto: target.transcript.clips), target: target.transcript, completed: completed) }
        catch { notice = error.localizedDescription }
    }

    private func sessionRecord(_ value: Any, taskID: String) throws -> [String: Any] {
        guard let records = value as? [[String: Any]] else { throw OfficialMemoryFailure(message: "官方会话详情不是记录数组。") }
        if let matching = records.first(where: { record in
            ["aiTask", "recording", "cc"].contains { OfficialMemoryRow.text((record[$0] as? [String: Any])?["taskId"]) == taskID }
        }) { return matching }
        if records.count == 1, let record = records.first,
           ["aiTask", "recording", "cc"].allSatisfy({ OfficialMemoryRow.text((record[$0] as? [String: Any])?["taskId"]) == nil }) { return record }
        throw OfficialMemoryFailure(message: "官方服务未返回这条会话的详情，原有详情保留。")
    }

    func showTimeline(_ row: OfficialMemoryRow) {
        selectedData = row.data; selectedTitle = row.title; selectedKind = "timeline"
        selectedCloudTaskID = nil; selectedTopicID = nil
    }

    func cancel() {
        guard canCancel else { return }
        task?.cancel(); task = nil; operationID = UUID(); busy = false; canCancel = false
        notice = "已取消当前请求，已读取和缓存的内容保留。"
    }

    func deleteSession(taskID: String, expectedAccount: UUID) {
        guard !busy, accountGeneration == expectedAccount, selectedCloudTaskID == taskID, let service else { return }
        let audio = OfficialCloudAudioModel.shared
        let ticket = audio.beginCloudDeletion(taskID: taskID, configuration: service.configuration)
        perform("正在删除选中的官方云会话…", cancellable: false) {
            do { try await service.deleteSessions(taskIDs: [taskID]) }
            catch { if let ticket { audio.finishCloudDeletion(ticket: ticket, success: false) }; throw error }
            if let ticket { audio.finishCloudDeletion(ticket: ticket, success: true) }
            try Task.checkCancellation()
            self.sessions.removeAll { $0.taskID == taskID }
            self.sessionTotal = nil; self.selectedData = nil; self.selectedTitle = ""; self.selectedKind = ""
            self.selectedCloudTaskID = nil
            self.deletedSessionIDs.insert(taskID)
            self.sessionCycles = [:]; self.nextDeadline = nil
            do { try self.cache?.removeSession(taskID: taskID) }
            catch { self.cacheNotice = "云会话已删除，但本地云缓存清理未完成：" + error.localizedDescription }
            self.notice = "官方云会话已删除。本地录音资料库中的独立文件保留。"
        }
    }

    func refreshSelectedSummaries() {
        guard !busy, let service, let taskID = selectedCloudTaskID, let detail = selectedData else { return }
        let ids = (detail["summary"] as? [[String: Any]] ?? []).compactMap { OfficialMemoryRow.text($0["summaryId"]) }
        guard !ids.isEmpty else { notice = "所选会话还没有可查询的摘要 ID。"; return }
        perform("正在读取摘要任务状态…") {
            let summaries = try await service.summaries(ids: ids)
            try Task.checkCancellation()
            guard self.selectedCloudTaskID == taskID else { return }
            var updated = self.selectedData ?? detail
            var merged = updated["summary"] as? [[String: Any]] ?? []
            for summary in summaries {
                if let id = OfficialMemoryRow.text(summary["summaryId"]),
                   let index = merged.firstIndex(where: { OfficialMemoryRow.text($0["summaryId"]) == id }) { merged[index] = summary }
                else { merged.append(summary) }
            }
            updated["summary"] = merged; self.selectedData = updated
            self.saveCache(["data": updated, "title": self.selectedTitle], key: "session:" + taskID)
            self.notice = "已读取 \(summaries.count) 条摘要任务结果。"
        }
    }

    func canDeleteSummary(id: String) -> Bool {
        let summaries = selectedData?["summary"] as? [[String: Any]] ?? []
        return selectedKind == "session" && summaries.count > 1 && isStoredSummary(id)
            && summaries.contains { OfficialMemoryRow.text($0["summaryId"]) == id }
    }

    func isStoredSummary(_ id: String) -> Bool {
        !id.isEmpty && id != "_$captionDefaultSummaryPlaceholderId"
    }

    func saveSummaryContent(id: String, markdown: String, expectedTaskID: String, expectedAccount: UUID,
                            completed: @escaping () -> Void) {
        guard !busy, accountGeneration == expectedAccount, selectedKind == "session",
              selectedCloudTaskID == expectedTaskID, isStoredSummary(id), let service,
              let summary = (selectedData?["summary"] as? [[String: Any]])?.first(where: {
                  OfficialMemoryRow.text($0["summaryId"]) == id
              }) else { return }
        let request: OfficialSummaryContentUpdateRequest
        do {
            request = try OfficialSummaryContentUpdateRequest(summaryID: id, markdown: markdown,
                existingContent: summary["content"] as? [String: Any] ?? [:])
        } catch { notice = error.localizedDescription; return }
        perform("正在保存摘要正文…", cancellable: false) {
            _ = try await service.updateSummaryContent(request)
            try Task.checkCancellation()
            guard self.accountGeneration == expectedAccount, self.selectedCloudTaskID == expectedTaskID else { return }
            do {
                let values = try await service.summaries(ids: [id])
                try Task.checkCancellation()
                guard let confirmed = values.first(where: { OfficialMemoryRow.text($0["summaryId"]) == id }) else {
                    throw OfficialMemoryFailure(message: "服务端尚未返回这条摘要。")
                }
                self.installSummary(confirmed, taskID: expectedTaskID)
                let body = (confirmed["content"] as? [String: Any])?["content"] as? String
                self.notice = body == markdown ? "摘要正文已保存并读回确认。"
                    : "摘要保存成功；读回正文与提交内容不同，当前显示服务端内容。"
            } catch {
                try Task.checkCancellation()
                self.notice = "摘要保存成功，正文读回暂未确认。请刷新摘要状态：" + error.localizedDescription
            }
            completed()
        }
    }

    func deleteSummary(id: String, expectedTaskID: String, expectedAccount: UUID) {
        guard !busy, accountGeneration == expectedAccount, selectedCloudTaskID == expectedTaskID,
              canDeleteSummary(id: id), let service else { return }
        perform("正在删除所选摘要…", cancellable: false) {
            try await service.deleteSummary(id: id)
            try Task.checkCancellation()
            guard self.accountGeneration == expectedAccount, self.selectedCloudTaskID == expectedTaskID,
                  var detail = self.selectedData else { return }
            var summaries = detail["summary"] as? [[String: Any]] ?? []
            summaries.removeAll { OfficialMemoryRow.text($0["summaryId"]) == id }
            detail["summary"] = summaries; self.selectedData = detail
            self.saveCache(["data": detail, "title": self.selectedTitle], key: "session:" + expectedTaskID)
            self.notice = "所选摘要已删除。"
        }
    }

    var usableSummaryModel: OfficialSummaryModel? {
        summaryModels.first { $0.id == selectedSummaryModel && $0.usable }
    }

    var summarySourceNotice: String? {
        guard let detail = selectedData else { return "请先读取会话详情。" }
        do { _ = try OfficialSummarySource.make(detail: detail); return nil }
        catch { return error.localizedDescription }
    }

    func loadSummaryCatalog() {
        guard !busy, let service else { return }
        perform("正在读取官方摘要模板和可用模型…") {
            let templates = try await service.summaryTemplates()
            try Task.checkCancellation()
            let models = try await service.summaryModels()
            try Task.checkCancellation()
            self.summaryTemplates = templates; self.summaryModels = models
            if !models.contains(where: { $0.id == self.selectedSummaryModel && $0.usable }) {
                let usable = models.filter(\.usable)
                self.selectedSummaryModel = (usable.first(where: \.selected)
                    ?? usable.first(where: \.isDefaultModel) ?? usable.first(where: \.isFreeModel))?.id ?? ""
            }
            if !templates.contains(where: { $0.id == self.selectedSummaryTemplate }) {
                self.selectedSummaryTemplate = templates.first?.id ?? ""
            }
            self.notice = "已读取 \(templates.count) 个模板、\(models.count) 个模型。"
            if self.usableSummaryModel == nil { self.notice += "请选择账号可用的摘要模型。" }
        }
    }

    func createSelectedSummary() {
        guard !busy, let service, let taskID = selectedCloudTaskID, let detail = selectedData,
              let model = usableSummaryModel,
              let template = summaryTemplates.first(where: { $0.id == selectedSummaryTemplate }) else { return }
        let source: [String: Any]
        do { source = try OfficialSummarySource.make(detail: detail) }
        catch { notice = error.localizedDescription; return }
        perform("正在提交模板摘要…", cancellable: false) {
            let summary = try await service.createSummary(taskID: taskID, name: template.displayName,
                model: model.id, templateID: template.id, source: source)
            try Task.checkCancellation()
            self.installSummary(summary, taskID: taskID)
            self.saveCache(model.id, key: "summaryModel")
            self.notice = "摘要请求已受理，当前状态以返回记录为准。可点击“刷新摘要状态”获取后续结果。"
        }
    }

    func retrySelectedSummary(id: String) {
        guard !busy, let service, let taskID = selectedCloudTaskID, let detail = selectedData,
              let model = usableSummaryModel,
              (detail["summary"] as? [[String: Any]] ?? []).contains(where: {
                  OfficialMemoryRow.text($0["summaryId"]) == id && ($0["status"] as? NSNumber)?.intValue == 3
              }) else { return }
        let source: [String: Any]
        do { source = try OfficialSummarySource.make(detail: detail) }
        catch { notice = error.localizedDescription; return }
        perform("正在重试所选摘要…", cancellable: false) {
            let summary = try await service.retrySummary(id: id, model: model.id, source: source)
            try Task.checkCancellation()
            self.installSummary(summary, taskID: taskID)
            self.saveCache(model.id, key: "summaryModel")
            self.notice = "摘要重试已受理。可点击“刷新摘要状态”读取后续结果。"
        }
    }

    private func installSummary(_ summary: [String: Any], taskID: String) {
        guard selectedCloudTaskID == taskID, var detail = selectedData else { return }
        var summaries = detail["summary"] as? [[String: Any]] ?? []
        if let id = OfficialMemoryRow.text(summary["summaryId"]),
           let index = summaries.firstIndex(where: { OfficialMemoryRow.text($0["summaryId"]) == id }) { summaries[index] = summary }
        else { summaries.append(summary) }
        detail["summary"] = summaries; selectedData = detail
        saveCache(["data": detail, "title": selectedTitle], key: "session:" + taskID)
    }

    private var timelineCacheKey: String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        return "timeline:" + formatter.string(from: day) + ":" + timezone
    }

    private func saveCache(_ value: Any, key: String) {
        guard let cache else { return }
        do { try cache.store(value, for: key); cacheNotice = "" }
        catch { cacheNotice = "云内容已读取，但本地缓存未能保存：" + error.localizedDescription }
    }

    private func perform(_ message: String, cancellable: Bool = true, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID(); operationID = id
        busy = true; canCancel = cancellable; notice = message
        task = Task {
            defer { if operationID == id { busy = false; canCancel = false; task = nil } }
            do { try await operation() }
            catch {
                if operationID == id {
                    notice = Task.isCancelled ? "已取消读取，已加载内容保留。" : error.localizedDescription
                    if !cancellable { notice += " 操作结果未确认，请先刷新云记录再决定是否重试。" }
                }
            }
        }
    }
}
