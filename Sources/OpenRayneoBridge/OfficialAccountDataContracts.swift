// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialUserDataReceipt: Codable, Sendable {
    let requestId: String
    let createdAt: String
}

enum OfficialUserDataState: String {
    case pending = "PENDING", processing = "PROCESSING", completed = "COMPLETED", failed = "FAILED"
    var title: String {
        switch self {
        case .pending: return "排队中"
        case .processing: return "处理中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

struct OfficialUserDataExportStatus: Codable, Sendable {
    let accountId: String
    let email: String
    let status: String
    let createdAt: String
    let completedAt: String?
    var state: OfficialUserDataState? { .init(rawValue: status.uppercased()) }
}

struct OfficialUserDataDeletionStatus: Codable, Sendable {
    let status: String
    let createdAt: String
    let completedAt: String?
    let hasRemainingData: Bool
    var state: OfficialUserDataState? { .init(rawValue: status.uppercased()) }
}

struct OfficialUserDataExportRequest {
    let email: String?
    let nickname: String?
    let phone: String?
    let account: String?
    var jsonBody: [String: Any] {
        ["email": email as Any? ?? NSNull(), "nickName": nickname as Any? ?? NSNull(),
         "phone": phone as Any? ?? NSNull(), "account": account as Any? ?? NSNull()]
    }
}

extension OfficialMemoryService {
    func requestUserDataExport(_ request: OfficialUserDataExportRequest) async throws -> OfficialUserDataReceipt {
        let value = try await read(method: "POST", path: "/clsapi/user-data/exports", body: request.jsonBody)
        return try decodeUserData(OfficialUserDataReceipt.self, value: value)
    }
    func requestUserDataDeletion() async throws -> OfficialUserDataReceipt {
        let value = try await read(method: "DELETE", path: "/clsapi/user-data")
        return try decodeUserData(OfficialUserDataReceipt.self, value: value)
    }
    func userDataExportStatus(requestID: String) async throws -> OfficialUserDataExportStatus {
        let value = try await read(method: "GET", path: "/clsapi/user-data/exports/" + requestID)
        return try decodeUserData(OfficialUserDataExportStatus.self, value: value)
    }
    func userDataDeletionStatus(requestID: String) async throws -> OfficialUserDataDeletionStatus {
        let value = try await read(method: "GET", path: "/clsapi/user-data/deletions/" + requestID)
        return try decodeUserData(OfficialUserDataDeletionStatus.self, value: value)
    }
    private func decodeUserData<T: Decodable>(_ type: T.Type, value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
