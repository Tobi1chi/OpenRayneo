// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import Foundation

/// Configures the Mac's existing providers. Android MethodChannel calls are not wireless commands.
final class AssistantRuntimeController {
    private let folder: URL
    private let lock = NSLock()
    init(folder: URL = AssistantProfileFiles.defaultFolder) { self.folder = folder }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path == "/v1/assistant/runtime" else { return nil }
        lock.lock(); defer { lock.unlock() }
        var profile = try AssistantProfileFiles.load(folder: folder)
        if method == "PATCH" {
            let encoder = JSONEncoder()
            var object = try JSONSerialization.jsonObject(with: encoder.encode(profile.runtimeSettings)) as! [String: Any]
            let fields: Set<String> = ["decisionModel", "agentModel", "asrModel", "decisionEndpoint", "agentEndpoint", "asrEndpoint",
                "requestTimeoutSeconds", "asrConnectionTimeoutSeconds", "userName", "deviceSerial", "deviceModel", "latitude", "longitude"]
            guard Set(body.keys).isSubset(of: fields) else { throw BridgeError(status: 400, message: "Unknown runtime field; credentials are managed separately in Keychain or environment") }
            for (key, value) in body { object[key] = value }
            let runtime = try JSONDecoder().decode(AssistantRuntimeSettings.self, from: JSONSerialization.data(withJSONObject: object))
            profile = try AssistantProfileFiles.saveRuntime(runtime, folder: folder)
        } else if method != "GET" { return nil }
        let runtime = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile.runtimeSettings))
        let config = ProviderCredentials.configuration(runtime: profile.runtimeSettings)
        return (200, ["platform": "mac-user-api", "profileRevision": profile.revision, "runtime": runtime,
            "effectiveASREndpoint": config.asrURL?.absoluteString ?? "", "appliesTo": "nextAssistantSession",
            "credentials": ["openAI": !config.openAIKey.isEmpty, "bailian": !config.bailianKey.isEmpty, "deepSeek": !config.deepSeekKey.isEmpty],
            "deviceSynchronized": false])
    }
}
