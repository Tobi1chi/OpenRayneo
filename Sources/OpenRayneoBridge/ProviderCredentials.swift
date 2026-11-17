// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AssistantCore
import Foundation
import Security
import LocalAuthentication
import SwiftUI

enum ProviderCredentials {
    static let names = ["OPENAI_API_KEY", "DEEPSEEK_API_KEY", "BAILIAN_API_KEY"]
    private static var identity: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.openrayneo.bridge.model-providers",
         kSecAttrAccount as String: "api-keys",
         kSecUseAuthenticationContext as String: context]
    }

    static func load() throws -> [String: String] {
        var query = identity
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = value as? Data else {
            throw AssistantFailure("无法读取模型密钥（Keychain \(status)）。")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    static func save(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        let query = identity
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.removeValue(forKey: kSecUseAuthenticationContext as String)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantFailure("无法保存模型密钥（Keychain \(status)）。") }
    }

    static func configuration(runtime: AssistantRuntimeSettings) -> AssistantConfiguration {
        var environment = ProcessInfo.processInfo.environment
        // A locked Keychain must not prevent an explicitly configured environment from working.
        if let stored = try? load() {
            environment.merge(stored.filter { !$0.value.isEmpty }) { _, saved in saved }
        }
        return AssistantConfiguration(environment: environment, runtime: runtime)
    }
}

@MainActor
struct ProviderCredentialsPanel: View {
    @State private var values: [String: String] = [:]
    @State private var configured: Set<String> = []
    @State private var notice = ""

    var body: some View {
        GroupBox("模型 API 密钥") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ProviderCredentials.names, id: \.self) { name in
                    HStack {
                        SecureField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        Text(configured.contains(name) ? "已保存在钥匙串" : "未保存").font(.caption).foregroundStyle(.secondary)
                        if configured.contains(name) {
                            Button("移除") { update(removing: name) }
                        }
                    }
                }
                Button("保存填写的密钥") { update(removing: nil) }
                Text("留空保留已保存的密钥；钥匙串配置优先于启动环境变量。修改后重新启动助手会话。密钥不会写入提示词、数据集或接口状态。")
                    .font(.caption).foregroundStyle(.secondary)
                if !notice.isEmpty { Text(notice).font(.callout).textSelection(.enabled) }
            }.padding(8)
        }.task { refresh() }
    }

    private func refresh() {
        do { configured = Set(try ProviderCredentials.load().keys); notice = "" }
        catch { notice = error.localizedDescription }
    }

    private func update(removing name: String?) {
        do {
            var stored = try ProviderCredentials.load()
            for (key, value) in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stored[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let name { stored.removeValue(forKey: name) }
            try ProviderCredentials.save(stored)
            configured = Set(stored.keys); values = [:]
            notice = "密钥配置已保存。"
        } catch { notice = error.localizedDescription }
    }
}
