// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct OfficialSessionCoordinatorState: Sendable {
    let hasPendingPersistence: Bool
    let refreshing: Bool
    let requiresReauthentication: Bool
    let message: String?
}

/// GUI-owned session writer. The device worker reads saved credentials and never refreshes an RT.
actor OfficialSessionCoordinator {
    static let shared = OfficialSessionCoordinator()
    private let service = OfficialAccountService()
    private let accountService = OfficialPhoneLoginService()
    private var inFlight: Task<OfficialAccountSession, Error>?
    private var pending: (session: OfficialAccountSession, change: OfficialAccountSessionChange)?
    private var requiresReauthentication = false
    private var message: String?
    private var invalidAccessToken: String?
    private var signingOut = false

    func state() -> OfficialSessionCoordinatorState {
        OfficialSessionCoordinatorState(hasPendingPersistence: pending != nil, refreshing: inFlight != nil,
            requiresReauthentication: requiresReauthentication, message: message)
    }

    func prepare(reference: OfficialFirmwareConfiguration? = nil) async throws -> OfficialFirmwareConfiguration {
        guard !signingOut else { throw OfficialAccountFailure(message: "官方账号正在退出，请稍后操作。") }
        let current = try selected()
        let version = reference?.appVersion ?? ProcessInfo.processInfo.environment["RAYNEO_CLIENT_APP_VERSION"] ?? "1.0.10"
        let configuration = try OfficialFirmwareConfiguration.fromSession(current, appVersion: version)
        if let reference, !configuration.hasSameIdentity(as: reference) { throw identityChanged() }
        guard pending == nil else { throw persistenceRequired() }
        guard !requiresReauthentication else {
            throw OfficialAccountFailure(message: "官方会话需要重新登录。", requiresReauthentication: true)
        }
        if inFlight != nil || configuration.sessionNeedsRefresh || invalidAccessToken == current.accessToken {
            _ = try await refresh()
            try Task.checkCancellation()
            let latest = try OfficialFirmwareConfiguration.fromSession(selected(), appVersion: version)
            guard latest.hasSameIdentity(as: configuration) else { throw identityChanged() }
            return latest
        }
        return configuration
    }

    func refresh() async throws -> OfficialAccountSession {
        guard !signingOut else { throw OfficialAccountFailure(message: "官方账号正在退出。") }
        if let inFlight { return try await inFlight.value }
        guard pending == nil else { throw persistenceRequired() }
        guard !requiresReauthentication else {
            throw OfficialAccountFailure(message: "官方会话需要重新登录。", requiresReauthentication: true)
        }
        let previous = try selected()
        let task = Task { [self] in
            do {
                var updated = try await service.refresh(previous)
                updated.credentialRevision = (previous.credentialRevision ?? 0) + 1
                // Replacement and clearing await this task; retain rotation before any Keychain operation can fail.
                pending = (updated, .credentials)
                let saved = try persistPending()
                inFlight = nil; requiresReauthentication = false; invalidAccessToken = nil; message = nil
                publishState()
                return saved
            } catch {
                inFlight = nil
                if let failure = error as? OfficialAccountFailure, failure.requiresReauthentication {
                    requiresReauthentication = true
                }
                message = pending == nil ? error.localizedDescription : "已收到轮换后的会话，但钥匙串保存失败。请重试保存，暂停使用旧刷新令牌。"
                publishState()
                throw error
            }
        }
        inFlight = task; message = nil; publishState()
        return try await task.value
    }

    func replace(_ session: OfficialAccountSession) async throws -> OfficialAccountSession {
        guard !signingOut else { throw OfficialAccountFailure(message: "请等待当前账号退出完成。") }
        // Complete an already-sent refresh before replacing it, so a failed Keychain write cannot lose its rotated RT.
        if let inFlight { _ = try? await inFlight.value }
        guard pending == nil else { throw persistenceRequired() }
        var replacement = session
        replacement.identityEpoch = UUID(); replacement.credentialRevision = 0; replacement.savedAt = Date()
        pending = (replacement, .identity)
        do {
            let saved = try persistPending()
            requiresReauthentication = false; invalidAccessToken = nil; message = nil; publishState()
            return saved
        } catch {
            message = "会话尚未存入钥匙串，请重试保存。"; publishState(); throw error
        }
    }

    func clear() async throws {
        guard !signingOut else { throw OfficialAccountFailure(message: "官方账号正在退出。") }
        if let inFlight { _ = try? await inFlight.value }
        try OfficialAccountSessionStore.clear()
        pending = nil; requiresReauthentication = false; invalidAccessToken = nil; message = nil
        publishState()
    }

    func retryPersistence() throws -> OfficialAccountSession? {
        guard !signingOut else { throw OfficialAccountFailure(message: "官方账号正在退出。") }
        guard pending != nil else { return nil }
        do {
            let result = try persistPending()
            requiresReauthentication = false; invalidAccessToken = nil; message = nil; publishState()
            return result
        } catch { message = error.localizedDescription; publishState(); throw error }
    }

    func markAccessTokenExpired(_ request: OfficialFirmwareConfiguration) throws {
        guard pending == nil else { return }
        var current = try selected()
        let configuration = try OfficialFirmwareConfiguration.fromSession(current)
        guard configuration.hasSameIdentity(as: request), current.accessToken == request.accessToken else { return }
        invalidAccessToken = current.accessToken
        current.accessExpiresAt = Date().addingTimeInterval(-1)
        do { try OfficialAccountSessionStore.save(current, change: .metadata) }
        catch { message = "访问令牌已在本进程标记过期，但状态未能写入钥匙串。"; publishState(); throw error }
    }

    func markWorkerAccessTokenExpired(identityEpoch: UUID?, credentialRevision: Int) throws {
        let current = try OfficialFirmwareConfiguration.fromSession(selected())
        guard current.identityEpoch == identityEpoch, current.credentialRevision == credentialRevision else { return }
        try markAccessTokenExpired(current)
    }

    func saveProfile(_ profile: OfficialAccountProfile, reference: OfficialFirmwareConfiguration) async throws -> OfficialAccountSession {
        if let inFlight { _ = try? await inFlight.value }
        guard !signingOut, pending == nil else { throw persistenceRequired() }
        var current = try selected()
        let configuration = try OfficialFirmwareConfiguration.fromSession(current)
        guard configuration.hasSameIdentity(as: reference), profile.accountID == configuration.accountID else { throw identityChanged() }
        current.profile = profile
        try OfficialAccountSessionStore.save(current, change: .metadata)
        return current
    }

    func signOut() async throws -> String {
        guard !signingOut else { throw OfficialAccountFailure(message: "官方账号正在退出。") }
        signingOut = true
        defer { signingOut = false; publishState() }
        if let inFlight { _ = try? await inFlight.value }
        let selected = try? selected()
        let snapshot: OfficialAccountSession?
        if let candidate = pending?.session,
           selected == nil || (candidate.identityEpoch == selected?.identityEpoch && candidate.accountID == selected?.accountID) {
            snapshot = candidate
        } else { snapshot = selected }
        pending = nil
        let remote: String
        if let snapshot, !snapshot.accessToken.isEmpty, snapshot.accountID?.isEmpty == false {
            do { try await accountService.logout(snapshot); remote = "官方已接受当前会话退出。" }
            catch { remote = "服务端退出结果未确认：" + error.localizedDescription }
        } else { remote = "缺少完整会话快照，未向服务端发送退出请求。" }
        if let snapshot, let current = try? self.selected(),
           current.identityEpoch != snapshot.identityEpoch || current.accountID != snapshot.accountID
            || current.businessBaseURL != snapshot.businessBaseURL || current.region != snapshot.region {
            return remote + " 新选用的账号会话保留。"
        }
        try OfficialAccountSessionStore.signOut()
        requiresReauthentication = false; invalidAccessToken = nil; message = nil
        return remote + " 本机已退出，启动环境中的旧会话不会自动重新启用。"
    }

    private func persistPending() throws -> OfficialAccountSession {
        let value = pending!
        try OfficialAccountSessionStore.save(value.session, change: value.change)
        pending = nil
        return value.session
    }

    private func selected() throws -> OfficialAccountSession {
        guard let selected = try OfficialAccountSessionStore.selectedSession() else {
            throw OfficialAccountFailure(message: "未配置官方账号会话，请先登录或导入已有会话。")
        }
        return selected
    }

    private func identityChanged() -> OfficialAccountFailure {
        OfficialAccountFailure(message: "官方账号已变化，请重新读取当前账号内容。")
    }
    private func persistenceRequired() -> OfficialAccountFailure {
        OfficialAccountFailure(message: "有尚未保存的新会话，请先在官方账号面板重试保存或清除本机会话。")
    }
    private func publishState() {
        NotificationCenter.default.post(name: .officialAccountCoordinatorStateChanged, object: nil)
    }
}
