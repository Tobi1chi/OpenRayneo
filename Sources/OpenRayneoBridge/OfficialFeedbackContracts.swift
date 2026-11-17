// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialFeedbackField: Decodable {
    let visible: Bool?
    let required: Bool?
    let displayOrder: String?
    let frequencyOfIssue: String?
    let lastOccurrenceTime: String?
    let PurchaseReceipt: Bool?
    let PurchasePlatform: [String]?

    private enum CodingKeys: String, CodingKey {
        case visible, required, displayOrder, frequencyOfIssue, lastOccurrenceTime, PurchaseReceipt, PurchasePlatform
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible)
        required = try values.decodeIfPresent(Bool.self, forKey: .required)
        PurchaseReceipt = try values.decodeIfPresent(Bool.self, forKey: .PurchaseReceipt)
        PurchasePlatform = try values.decodeIfPresent([String].self, forKey: .PurchasePlatform)
        func text(_ key: CodingKeys) throws -> String? {
            if try values.decodeNil(forKey: key) { return nil }
            if let value = try? values.decode(String.self, forKey: key) { return value }
            if let value = try? values.decode([String].self, forKey: key) { return value.joined(separator: ",") }
            if let value = try? values.decode(Int.self, forKey: key) { return String(value) }
            if let value = try? values.decode(Bool.self, forKey: key) { return String(value) }
            return nil
        }
        displayOrder = values.contains(.displayOrder) ? try text(.displayOrder) : nil
        frequencyOfIssue = values.contains(.frequencyOfIssue) ? try text(.frequencyOfIssue) : nil
        lastOccurrenceTime = values.contains(.lastOccurrenceTime) ? try text(.lastOccurrenceTime) : nil
    }
}

struct OfficialFeedbackCategory: Decodable {
    let treeId: Int?
    let treeName: String?
    let categoryCode: Int?
    let status: Bool?
    let needAppLog: Bool?
    let needGlassesLog: Bool?
    let displayFields: [String: OfficialFeedbackField]?
    let childs: [OfficialFeedbackCategory]?

    private enum CodingKeys: String, CodingKey {
        case treeId, treeName, categoryCode, status, needAppLog, needGlassesLog, displayFields, childs
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        treeId = try values.decodeIfPresent(Int.self, forKey: .treeId)
        treeName = try values.decodeIfPresent(String.self, forKey: .treeName)
        if let code = try? values.decode(Int.self, forKey: .categoryCode) { categoryCode = code }
        else { categoryCode = (try? values.decode(String.self, forKey: .categoryCode)).flatMap(Int.init) }
        status = try values.decodeIfPresent(Bool.self, forKey: .status)
        needAppLog = try values.decodeIfPresent(Bool.self, forKey: .needAppLog)
        needGlassesLog = try values.decodeIfPresent(Bool.self, forKey: .needGlassesLog)
        displayFields = try values.decodeIfPresent([String: OfficialFeedbackField?].self, forKey: .displayFields)?.compactMapValues { $0 }
        childs = try values.decodeIfPresent([OfficialFeedbackCategory].self, forKey: .childs)
    }

    struct Choice: Identifiable {
        let node: OfficialFeedbackCategory
        let path: [String]
        var id: Int { node.treeId! }
        var title: String { path.joined(separator: " › ") }
    }
    func choices(parents: [String] = []) -> [Choice] {
        let path = parents + [treeName ?? "未命名分类"]
        let children = (childs ?? []).flatMap { $0.choices(parents: path) }
        return (treeId.map { _ in [Choice(node: self, path: path)] } ?? []) + children
    }
}

struct OfficialFeedbackTempAK: Decodable {
    let ak: String
    let sk: String
    let st: String
    let endpoint: String
    let bucketName: String
    let reqId: String
    let expiration: String
}

struct OfficialFeedbackAttachment: Codable, Identifiable, Equatable {
    enum Role: String, Codable, CaseIterable { case attachment, purchaseReceipt, glassesLog, appLog }
    var id = UUID()
    let name: String
    let path: String
    let role: Role
}

struct OfficialFeedbackDraft: Codable, Equatable {
    var id = UUID()
    var categoryID: Int?
    var title = ""
    var description = ""
    var sn = ""
    var email = ""
    var phone = ""
    var nickname = ""
    var frequency = ""
    var lastOccurrence = ""
    var purchasePlatform = ""
    var purchaseDate = ""
    var purchaseOrderNumber = ""
    var glassesType = "雷鸟 S3"
    var glassesSystemVersion = ""
    var orderNo: String?
    var bundlePath: String?
    var uploadedBundleKey: String?
    var attachments: [OfficialFeedbackAttachment] = []
    // Written before POST; an interrupted request cannot be silently replayed.
    var submissionState = "draft"
}

struct OfficialFeedbackRequest {
    let draft: OfficialFeedbackDraft
    let levelID: Int

    var jsonBody: [String: Any] {
        let paths = draft.uploadedBundleKey.map { [$0] } ?? []
        func optional(_ value: String) -> Any { value.isEmpty ? NSNull() : value as Any }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "OpenRayneo"
        return [
            "orderNo": draft.orderNo as Any? ?? NSNull(), "questionTitle": draft.title,
            "levelId": levelID, "detail": draft.description, "frequency": draft.frequency,
            "glassesAppVersion": "", "glassesSysVersion": draft.glassesSystemVersion,
            "glassesType": draft.glassesType, "phoneType": "Mac",
            "phoneSysVersion": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            "phoneAppVersion": version, "filePathList": paths, "appType": "AIAPP", "deviceType": "APP",
            "occurrenceTime": draft.lastOccurrence,
            "displayFields": ["SN": optional(draft.sn.trimmingCharacters(in: .whitespacesAndNewlines)), "contactEmail": NSNull(),
                "orderNo": optional(draft.purchaseOrderNumber), "purchasePlatform": optional(draft.purchasePlatform),
                "purchaseDate": optional(draft.purchaseDate), "description": draft.description,
                "frequencyOfIssue": optional(draft.frequency), "lastOccurrenceTime": optional(draft.lastOccurrence)]
        ]
    }
}

extension OfficialMemoryService {
    static var feedbackLanguage: String {
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
        let language = locale.language.languageCode?.identifier ?? "zh"
        if language == "zh", let region = locale.region?.identifier, ["HK", "TW"].contains(region) { return "zh-" + region }
        return language
    }
    private var feedbackHeaders: [String: String] {
        ["user_id": configuration.accountID, "lang": Self.feedbackLanguage]
    }
    func feedbackCategories(glassesTypes: String?) async throws -> [OfficialFeedbackCategory] {
        var query = [URLQueryItem(name: "lang", value: feedbackHeaders["lang"]), URLQueryItem(name: "appType", value: "AIAPP")]
        if let glassesTypes, !glassesTypes.isEmpty { query.append(URLQueryItem(name: "glassesTypes", value: glassesTypes)) }
        let value = try await read(method: "GET", path: "/rmapi/signApi/problem/getProblemTreeList", query: query, unwrap: false)
        return try JSONDecoder().decode([OfficialFeedbackCategory].self, from: JSONSerialization.data(withJSONObject: value))
    }
    func feedbackOrderNumber() async throws -> String {
        let value = try await read(method: "GET", path: "/rmapi/signApi/order/getOrderNo", headers: feedbackHeaders)
        guard let number = value as? String, !number.isEmpty else { throw OfficialMemoryFailure(message: "官方反馈编号为空或类型不正确。") }
        return number
    }
    func feedbackCredentials() async throws -> OfficialFeedbackTempAK {
        let value = try await read(method: "GET", path: "/rmapi/signApi/user/getTempAk", headers: feedbackHeaders)
        return try JSONDecoder().decode(OfficialFeedbackTempAK.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func reportFeedbackContact(_ draft: OfficialFeedbackDraft) async throws {
        _ = try await read(method: "POST", path: "/rmapi/signApi/user/reportInfo", body: [
            "nickName": draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            "userPhone": draft.phone.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": draft.email.trimmingCharacters(in: .whitespacesAndNewlines)], headers: ["user_id": configuration.accountID])
    }
    func submitFeedback(_ request: OfficialFeedbackRequest) async throws {
        _ = try await read(method: "POST", path: "/rmapi/signApi/order/createRepBarOrder", body: request.jsonBody, headers: feedbackHeaders)
    }
}
