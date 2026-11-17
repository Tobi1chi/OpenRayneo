// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

struct OfficialMemoryFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Official account content queries and explicitly requested Session mutations.
final class OfficialMemoryService {
    let configuration: OfficialFirmwareConfiguration
    private let session: URLSession

    init(configuration: OfficialFirmwareConfiguration) {
        self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCredentialStorage = nil; options.urlCache = nil
        options.timeoutIntervalForRequest = 25
        session = URLSession(configuration: options, delegate: OfficialMemoryRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    var configured: Bool { !configuration.accessToken.isEmpty }

    func timeline(date: String, timezone: String) async throws -> Any {
        try await read(method: "GET", path: "/lifelog/api/v1/events", query: [
            URLQueryItem(name: "date", value: date), URLQueryItem(name: "timezone", value: timezone)])
    }

    func topics() async throws -> Any {
        // The generated method has null data, converted to {} by EmptyBodyInterceptor.
        try await read(method: "POST", path: "/topic/v1/getUserTopics", body: [:])
    }

    func topic(id: String) async throws -> Any {
        try await read(method: "POST", path: "/topic/v1/getTopicDetail", body: ["topicId": id])
    }

    func sessions(deadline: Int64, taskType: String?, pageSize: Int = 20) async throws -> Any {
        try await read(method: "POST", path: "/clsapi/aiTask/v2/selectPage", body: [
            "taskIds": NSNull(), "phoneDeviceId": NSNull(), "taskType": taskType as Any? ?? NSNull(),
            "name": NSNull(), "deadline": deadline, "pageSize": pageSize, "deviceType": "RayNeoS3"])
    }

    func cloudSyncConfiguration() async throws -> OfficialCloudSyncConfiguration {
        let value = try await read(method: "GET", path: "/cloudapi/cloudConfig/getConfigInfo")
        guard let data = value as? [String: Any] else {
            throw OfficialMemoryFailure(message: "官方云同步配置不是记录对象。")
        }
        return OfficialCloudSyncConfiguration(json: data)
    }

    func editCloudSyncConfiguration(_ request: OfficialCloudSyncSettingsRequest) async throws -> String {
        let value = try await read(method: "POST", path: "/cloudapi/cloudConfig/editConfig", body: request.jsonBody)
        guard let result = value as? String else {
            throw OfficialMemoryFailure(message: "官方云同步配置保存响应不是字符串。")
        }
        return result
    }

    func session(taskID: String) async throws -> Any {
        try await read(method: "POST", path: "/clsapi/aiTask/getDataAllByTaskId", body: [
            "taskIds": [taskID], "deviceType": "RayNeoS3"])
    }

    func deleteSessions(taskIDs: [String]) async throws {
        _ = try await read(method: "POST", path: "/clsapi/aiTask/del", body: ["taskIds": taskIDs])
    }

    func createSession(_ request: OfficialSessionCreateRequest) async throws {
        _ = try await read(method: "POST", path: "/clsapi/aiTask/create", body: request.jsonBody,
                           acceptedBusinessCodes: [1001008, 1001009])
    }

    func getBucketInfo() async throws -> OfficialSessionBucketInfo {
        let value = try await read(method: "GET", path: "/cloudapi/cloudFile/getBucketInfo")
        return try JSONDecoder().decode(OfficialSessionBucketInfo.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func getTempAk(bucketName: String) async throws -> OfficialSessionTempAK {
        let value = try await read(method: "GET", path: "/authapi/oss/getTempAk", query: [
            URLQueryItem(name: "bucketName", value: bucketName)])
        return try JSONDecoder().decode(OfficialSessionTempAK.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func uploadCheck(taskID: String, bucketName: String, objectKey: String, fileSize: Int64) async throws -> String {
        let value = try await read(method: "POST", path: "/cloudapi/cloudFile/uploadCheck", body: [
            "relatedType": "aitask", "relatedId": taskID, "bucketName": bucketName,
            "fileName": objectKey, "fileType": "audio", "fileSize": fileSize])
        guard let fileID = value as? String, !fileID.isEmpty else {
            throw OfficialMemoryFailure(message: "官方上传校验未返回有效的 fileId。")
        }
        return fileID
    }

    func uploadRecord(fileID: String) async throws -> String {
        let value = try await read(method: "GET", path: "/cloudapi/cloudFile/uploadRecord", query: [
            URLQueryItem(name: "fileId", value: fileID)])
        guard let result = value as? String else {
            throw OfficialMemoryFailure(message: "官方上传登记响应不是字符串。")
        }
        return result
    }

    func submitTranscription(_ request: OfficialSessionTranscriptionRequest) async throws {
        _ = try await read(method: "POST", path: "/transcription/submitTask", body: request.jsonBody)
    }

    func summaries(ids: [String]) async throws -> [[String: Any]] {
        let value = try await read(method: "POST", path: "/summary-service/summary/list", body: [
            "summaryIds": ids, "runtimeType": "bySummaryIds"])
        guard let data = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方摘要列表不是记录对象。") }
        if data["aiSummaries"] == nil || data["aiSummaries"] is NSNull { return [] }
        guard let summaries = data["aiSummaries"] as? [[String: Any]] else {
            throw OfficialMemoryFailure(message: "官方摘要列表包含无法解析的记录。")
        }
        return summaries
    }

    func summaryTemplates() async throws -> [OfficialSummaryTemplate] {
        let value = try await read(method: "GET", path: "/api/v1/templates", unwrap: false)
        guard let root = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方模板响应不是记录对象。") }
        guard let raw = root["templates"], !(raw is NSNull) else { return [] }
        return try JSONDecoder().decode([OfficialSummaryTemplate].self, from: JSONSerialization.data(withJSONObject: raw))
            .sorted { $0.sort < $1.sort }
    }

    func summaryModels() async throws -> [OfficialSummaryModel] {
        guard !configuration.accountID.isEmpty else { throw OfficialMemoryFailure(message: "读取账号可用摘要模型需要官方账号 ID。") }
        var query = [URLQueryItem(name: "accountId", value: configuration.accountID),
            URLQueryItem(name: "sceneType", value: "SUMMARY"), URLQueryItem(name: "cu", value: "cu1")]
        if let country = configuration.countryCode { query.append(URLQueryItem(name: "countryCode", value: country)) }
        let value = try await read(method: "GET", path: "/profileapi/v1/ai-models/list", query: query)
        guard let data = value as? [String: Any], data["sceneType"] as? String == "SUMMARY", let models = data["models"] else {
            throw OfficialMemoryFailure(message: "官方摘要模型目录缺少 models。")
        }
        return try JSONDecoder().decode([OfficialSummaryModel].self, from: JSONSerialization.data(withJSONObject: models))
    }

    func createSummary(taskID: String, name: String, model: String, templateID: String, source: [String: Any]) async throws -> [String: Any] {
        let value = try await read(method: "POST", path: "/summary-service/summary/create", body: [
            "relatedId": taskID, "relatedType": "aitask", "name": name, "model": model,
            "templateId": templateID, "sourceContent": source, "generateType": "template"])
        guard let summary = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方摘要创建未返回摘要记录。") }
        return summary
    }

    func retrySummary(id: String, model: String, source: [String: Any]) async throws -> [String: Any] {
        let value = try await read(method: "POST", path: "/summary-service/summary/retry", body: [
            "summaryId": id, "model": model, "templateId": NSNull(), "sourceContent": source])
        guard let summary = value as? [String: Any] else { throw OfficialMemoryFailure(message: "官方摘要重试未返回摘要记录。") }
        return summary
    }

    func updateSummaryContent(_ request: OfficialSummaryContentUpdateRequest) async throws -> OfficialSummaryUpdateResult {
        let value = try await read(method: "POST", path: "/summary-service/summary/update", body: request.jsonBody)
        guard let data = value as? [String: Any] else {
            throw OfficialMemoryFailure(message: "官方摘要保存未返回结果对象。")
        }
        let result = try OfficialSummaryUpdateResult(json: data)
        guard result.successfulSummaryIDs?.contains(request.summaryID) == true else {
            throw OfficialMemoryFailure(message: "官方服务未确认当前摘要保存成功，请保留修改后重试。")
        }
        return result
    }

    func deleteSummary(id: String) async throws {
        _ = try await read(method: "POST", path: "/summary-service/summary/delete", body: [
            "summaryId": id, "runtimeType": "bySummaryId"])
    }

    func updateRecordingTranscript(_ request: OfficialRecordingTranscriptUpdateRequest) async throws -> [OfficialTranscriptClip]? {
        let value = try await read(method: "POST", path: "/transcription/updateResult", body: request.jsonBody)
        if value is NSNull { return nil }
        guard let recording = value as? [String: Any] else {
            throw OfficialMemoryFailure(message: "官方转写保存响应不是录音记录。")
        }
        if let taskID = recording["taskId"] as? String, taskID != request.taskID {
            throw OfficialMemoryFailure(message: "官方转写保存响应的会话不匹配，请刷新会话确认。")
        }
        return try OfficialTranscriptClip.parse(recording["clips"])
    }

    func updateCaptionTranscript(_ items: [OfficialCaptionTranscriptUpdateItem]) async throws -> [OfficialCaptionTranscriptUpdateResult] {
        let value = try await read(method: "POST", path: "/translation/message/content/update", body: items.map(\.jsonBody))
        guard let rows = value as? [[String: Any]] else {
            throw OfficialMemoryFailure(message: "官方字幕保存响应不是结果列表，请刷新会话确认。")
        }
        return try JSONDecoder().decode([OfficialCaptionTranscriptUpdateResult].self,
            from: JSONSerialization.data(withJSONObject: rows))
    }

    func read(method: String, path: String, query: [URLQueryItem] = [], body: Any? = nil,
              unwrap: Bool = true, acceptedBusinessCodes: Set<Int> = [], headers: [String: String] = [:]) async throws -> Any {
        guard configured else {
            throw OfficialMemoryFailure(message: "未配置官方账号会话。请在官方账号面板导入已有会话，或通过 App 启动环境提供 RAYNEO_ACCESS_TOKEN。")
        }
        let configuration = try await OfficialSessionCoordinator.shared.prepare(reference: self.configuration)
        try Task.checkCancellation()
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OfficialMemoryFailure(message: "无法构造官方内容地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        configuration.applySessionHeaders(to: &request)
        request.setValue(configuration.appVersion, forHTTPHeaderField: "app-version")
        request.setValue(configuration.appVersion, forHTTPHeaderField: "version")
        request.setValue(Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "time-zone")
        if let value = configuration.deviceCode { request.setValue(value, forHTTPHeaderField: "device-code") }
        if let value = configuration.clientDeviceID {
            for name in ["device-id", "device_id", "deviceId"] { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let value = configuration.accountRouteRegion { request.setValue(value, forHTTPHeaderField: "accountRouteRegion") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try configuration.signingHeaders(method: method, url: url, body: request.httpBody)
            .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try OfficialCloudPolicy.requireEnabled()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OfficialMemoryFailure(message: "官方服务未返回 HTTP 响应。") }
        let payload = try? JSONSerialization.jsonObject(with: data)
        let root = payload as? [String: Any]
        if OfficialTokenAuthentication.kind(httpStatus: http.statusCode, body: root) != nil {
            try? await OfficialSessionCoordinator.shared.markAccessTokenExpired(configuration)
            throw OfficialMemoryFailure(message: "官方访问令牌被拒绝，已标记失效；下一次读取将尝试刷新会话。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OfficialMemoryFailure(message: "官方内容读取失败（HTTP \(http.statusCode)）。")
        }
        if !unwrap, let payload { return payload }
        guard let root else {
            throw OfficialMemoryFailure(message: "官方内容响应不是可识别的数据包装。")
        }
        // ApiResponse 0x148e5a8 uses numeric zero, independently of HTTP success.
        guard let code = root["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(),
              code.doubleValue == 0 || (code.doubleValue == Double(code.intValue) && acceptedBusinessCodes.contains(code.intValue)) else {
            let message = root["userFriendlyTip"] as? String ?? root["msg"] as? String
            throw OfficialMemoryFailure(message: message.flatMap { $0.isEmpty ? nil : "官方内容查询失败：" + $0 }
                ?? "官方内容查询返回业务错误，请核对账号会话和区域。")
        }
        return root["data"] ?? NSNull()
    }
}

private final class OfficialMemoryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
