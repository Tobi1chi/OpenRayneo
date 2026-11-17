// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

enum OfficialTopicStatus: Int {
    case creating = 0, active = 1, paused = 2, deleted = 3, recommended = 9
    var title: String {
        switch self {
        case .creating: return "整理中"
        case .active: return "活跃"
        case .paused: return "已暂停"
        case .deleted: return "已删除"
        case .recommended: return "推荐"
        }
    }
}

struct OfficialTopicCreateRequest {
    let name: String
    let aliases: [String]
    let facts: [String]
    var jsonBody: [String: Any] {
        ["topicName": name, "aliases": aliases.isEmpty ? NSNull() : aliases as Any,
         "facts": facts.isEmpty ? NSNull() : facts as Any]
    }
}

struct OfficialTopicConfirmRequest {
    let topicID: String
    let name: String
    let relatedFactIDs: [String]
    let synonyms: [String]
    var jsonBody: [String: Any] {
        ["topicId": topicID, "topicName": name,
         "relatedFactsId": relatedFactIDs.isEmpty ? NSNull() : relatedFactIDs as Any,
         "synonym": synonyms.isEmpty ? NSNull() : synonyms as Any]
    }
}

struct OfficialTopicEditTarget: Identifiable {
    let id = UUID()
    let account: UUID
    let topicID: String?
    let title: String
    let synonyms: [String]
    let facts: [(id: String, content: String)]
}

struct OfficialTopicItemEditTarget: Identifiable {
    enum Kind { case fact, task }
    let id = UUID()
    let topic: OfficialTopicEditTarget
    let kind: Kind
    let itemID: String?
    let content: String
    var description = ""
    var starred = false
}

extension OfficialMemoryService {
    func createTopic(_ request: OfficialTopicCreateRequest) async throws -> String {
        let value = try await read(method: "POST", path: "/topic/v1/create", body: request.jsonBody)
        guard let data = value as? [String: Any], let rawID = data["topicId"] as? String,
              !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficialMemoryFailure(message: "官方创建响应没有返回 topicId，请先刷新主题列表核对。")
        }
        return rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func confirmTopic(_ request: OfficialTopicConfirmRequest) async throws -> String {
        let value = try await read(method: "POST", path: "/topic/v1/confirm", body: request.jsonBody)
        let rawID: String?
        if let accepted = value as? NSNumber, CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue {
            rawID = request.topicID
        } else { rawID = (value as? [String: Any])?["topicId"] as? String }
        guard let rawID, !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficialMemoryFailure(message: "官方未确认推荐主题 ID，请先刷新主题列表核对。")
        }
        return rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func changeTopicStatus(id: String, status: OfficialTopicStatus) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/changeStatus", body: ["topicId": id, "status": status.rawValue])
    }
    func changeTopicSynonym(id: String, synonym: String, removing: Bool) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/changeTopicSynonym", body: [
            "topicId": id, "operation": removing ? "delete" : "create", "synonym": synonym])
    }
    func updateTopicFavourite(id: String, favourite: Bool) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/updateFavourite", body: ["topicId": id, "favourite": favourite])
    }
    func disableTopicRecommendations() async throws {
        _ = try await read(method: "POST", path: "/topic/v1/updateTopicConfig", body: [
            "topicId": "", "enableTopicFeature": NSNull(), "enableTopicRecommendation": false])
    }
    func createTopicFact(id: String, content: String) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/createFact", body: ["topicId": id, "content": content])
    }
    func updateTopicFact(id: String, content: String) async throws {
        _ = try await read(method: "POST", path: "/factsapi/api/v1/facts/update", body: ["factsId": id, "content": content])
    }
    func createTopicTask(id: String, content: String, starred: Bool) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/createTask", body: [
            "topicId": id, "content": content, "description": NSNull(), "starred": starred, "completed": false])
    }
    func updateTopicTask(id: String, content: String?, description: String?, starred: Bool?, completed: Bool?) async throws {
        _ = try await read(method: "POST", path: "/action/api/v1/tasks/" + id, body: [
            "content": content as Any? ?? NSNull(), "description": description as Any? ?? NSNull(),
            "starred": starred as Any? ?? NSNull(), "completed": completed as Any? ?? NSNull()])
    }
    func deleteTopicTask(id: String) async throws {
        _ = try await read(method: "DELETE", path: "/action/api/v1/tasks/" + id)
    }
    func unlinkTopicContent(id: String, relatedID: String, fact: Bool) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/updateRelationship", body: [
            "topicId": id, "operation": "DELETE", "relatedType": fact ? "FACT" : "EVENT", "relatedId": [relatedID]])
    }
    func markTopicRead(id: String) async throws {
        _ = try await read(method: "POST", path: "/topic/v1/readTopic", body: ["topicId": id])
    }
}
