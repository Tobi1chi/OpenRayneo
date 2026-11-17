// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialAccountProfile: Codable, Sendable {
    let accountID: String
    let nickname: String?
    let avatar: String?
    let email: String?
    let phone: String?
    let countryCode: String?
    let language: String?
    let updatedAt: Date

    init(json: [String: Any]) throws {
        guard let account = json["accountId"] as? NSNumber, CFGetTypeID(account) != CFBooleanGetTypeID() else {
            throw OfficialAccountFailure(message: "官方资料响应缺少账号 ID。")
        }
        accountID = String(account.int64Value)
        nickname = json["nickName"] as? String; avatar = json["avatar"] as? String
        email = json["email"] as? String; phone = json["phone"] as? String
        countryCode = json["countryCode"] as? String; language = json["language"] as? String
        updatedAt = Date()
    }
}

extension OfficialPhoneLoginService {
    func updateNickname(_ nickname: String, configuration: OfficialFirmwareConfiguration) async throws -> OfficialAccountProfile {
        var body: [String: Any] = ["nickName": nickname]
        for key in ["birthday", "gender", "weight", "height", "countryAbbr", "province", "city", "avatarUrl"] { body[key] = NSNull() }
        let root = try await request(method: "POST", path: configuration.baseURL.host == "xr-api-p.rayneo.cn"
            ? "/user/v2/updateUserInfo" : "/user/updateUserInfo", body: body, configuration: configuration)
        return try profile(root, configuration: configuration)
    }

    func uploadAvatar(_ jpeg: Data, configuration: OfficialFirmwareConfiguration) async throws -> OfficialAccountProfile {
        let boundary = "OpenRayneo-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(jpeg); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let root = try await request(method: "POST", path: configuration.baseURL.host == "xr-api-p.rayneo.cn"
            ? "/user/v2/uploadAvatar" : "/user/uploadAvatar", configuration: configuration,
            encodedBody: body, contentType: "multipart/form-data; boundary=\(boundary)",
            signingPayload: Data("Instance of 'FormData'".utf8))
        return try profile(root, configuration: configuration)
    }

    func logout(_ session: OfficialAccountSession) async throws {
        let root = try await request(method: "POST", path: "/identify/logout", body: [:], session: session)
        _ = try tclData(root)
    }

    private func profile(_ root: [String: Any], configuration: OfficialFirmwareConfiguration) throws -> OfficialAccountProfile {
        guard let value = try tclData(root) as? [String: Any] else { throw OfficialAccountFailure(message: "官方资料响应不是用户资料。") }
        let profile = try OfficialAccountProfile(json: value)
        guard profile.accountID == configuration.accountID else { throw OfficialAccountFailure(message: "官方返回的资料不属于当前账号。") }
        return profile
    }
}
