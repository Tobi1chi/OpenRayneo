// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Mac provider configuration lives in the same versioned document as prompts and ASR hints.
/// API credentials remain in the process environment and are never included here.
public struct AssistantRuntimeSettings: Codable, Equatable, Sendable {
    public var decisionModel = "gpt-6-luna"
    public var agentModel = "deepseek-flash"
    public var asrModel = "qwen-audio-3.1-asr-flash-message"
    public var decisionEndpoint = "https://api.openai.com/v1/decisions"
    public var agentEndpoint = "https://api.deepseek.com/chat/completions"
    public var asrEndpoint = ""
    public var requestTimeoutSeconds = 60.0
    public var asrConnectionTimeoutSeconds = 20.0
    public var userName = ""
    public var deviceSerial = ""
    public var deviceModel = ""
    public var latitude: Double?
    public var longitude: Double?

    public init() {}

    public func validate() throws {
        guard !decisionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !agentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantFailure("模型名称不能为空")
        }
        for address in [decisionEndpoint, agentEndpoint] {
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil else {
                throw AssistantFailure("模型服务地址应为完整的 HTTP 或 HTTPS URL")
            }
        }
        if !asrEndpoint.isEmpty {
            guard let url = URL(string: asrEndpoint), url.scheme == "wss", url.host != nil else {
                throw AssistantFailure("ASR 地址应为完整的 WSS URL")
            }
        }
        guard requestTimeoutSeconds.isFinite, (1...600).contains(requestTimeoutSeconds),
              asrConnectionTimeoutSeconds.isFinite, (1...120).contains(asrConnectionTimeoutSeconds) else {
            throw AssistantFailure("模型请求超时应为 1–600 秒，ASR 建连超时应为 1–120 秒")
        }
        if let latitude { guard latitude.isFinite, (-90...90).contains(latitude) else { throw AssistantFailure("纬度无效") } }
        if let longitude { guard longitude.isFinite, (-180...180).contains(longitude) else { throw AssistantFailure("经度无效") } }
        guard (latitude == nil) == (longitude == nil) else { throw AssistantFailure("经纬度需要一起填写或清空") }
    }

    public var contextJSON: String {
        var context: [String: Any] = [:]
        if !userName.isEmpty { context["userName"] = userName }
        if !deviceSerial.isEmpty { context["deviceSerial"] = deviceSerial }
        if !deviceModel.isEmpty { context["deviceModel"] = deviceModel }
        if let latitude, let longitude { context["latitude"] = latitude; context["longitude"] = longitude }
        guard !context.isEmpty, let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum AssistantProfileFiles {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/PromptProfiles")
    }

    public static func load(folder: URL = defaultFolder) throws -> PromptProfile {
        let url = folder.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaultProfile }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(PromptProfile.self, from: Data(contentsOf: url))
        try profile.validate()
        return profile
    }

    public static func saveRuntime(_ runtime: AssistantRuntimeSettings, folder: URL = defaultFolder) throws -> PromptProfile {
        var profile = try load(folder: folder)
        profile.runtime = runtime; try profile.validate()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let revisions = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .compactMap { url -> Int? in
                let name = url.deletingPathExtension().lastPathComponent
                return name.hasPrefix("revision-") ? Int(name.dropFirst("revision-".count)) : nil
            }
        profile.revision = max(profile.revision, revisions.max() ?? 0) + 1; profile.savedAt = Date()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: folder.appendingPathComponent("revision-\(profile.revision).json"), options: .atomic)
        try data.write(to: folder.appendingPathComponent("active.json"), options: .atomic)
        return profile
    }
}
