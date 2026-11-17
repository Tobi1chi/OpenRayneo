// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import SwiftUI

enum OfficialPhoneLoginStep {
    case phone, code, profile, identity, cooling, ready
}
enum OfficialEmailLoginStep { case address, password, code }

@MainActor
final class OfficialAccountModel: ObservableObject {
    static let shared = OfficialAccountModel()
    @Published private(set) var source = "未配置官方会话"
    @Published private(set) var notice = "可导入你已有的官方会话，保存到本应用专属钥匙串项。"
    @Published private(set) var busy = false
    @Published private(set) var canRefresh = false
    @Published private(set) var canClear = false
    @Published private(set) var hasPendingSave = false
    @Published private(set) var requiresReauthentication = false
    @Published private(set) var accessExpiresAt: Date?
    @Published private(set) var refreshExpiresAt: Date?
    @Published private(set) var accountDescription = ""
    @Published private(set) var profile: OfficialAccountProfile?
    @Published private(set) var accountGeneration = UUID()
    @Published private(set) var canSignOut = false
    @Published private(set) var hasPendingProfile = false
    @Published var profileNicknameDraft = ""
    var prepareSignOut: (() async -> Bool)?
    @Published var accessTokenDraft = ""
    @Published var refreshTokenDraft = ""
    @Published var accountIDDraft = ""
    @Published var regionDraft = OfficialFirmwareRegion.domestic
    @Published var businessURLDraft = OfficialFirmwareRegion.domestic.baseURL.absoluteString
    @Published var countryCodeDraft = "cn"
    @Published var routeRegionDraft = ""
    @Published var clientDeviceIDDraft = ""
    @Published var deviceCodeDraft = ""
    @Published var phoneDraft = ""
    @Published var smsCodeDraft = ""
    @Published var nicknameDraft = ""
    @Published var identityNameDraft = ""
    @Published var identityNumberDraft = ""
    @Published var identityTypeDraft = 0
    @Published var agreedToLoginTerms = false
    @Published private(set) var loginAgreements: [OfficialAgreement] = []
    @Published private(set) var loginStep = OfficialPhoneLoginStep.phone
    @Published private(set) var smsRetryAt: Date?
    @Published private(set) var loginNotice = "读取服务协议和隐私政策后，使用中国大陆手机号注册／登录。"
    @Published var emailDraft = ""
    @Published var emailPasswordDraft = ""
    @Published var emailCodeDraft = ""
    @Published var emailCountryDraft = "us"
    @Published var agreedToEmailTerms = false
    @Published var loginBirthdayDraft = ""
    @Published private(set) var emailAgreements: [OfficialAgreement] = []
    @Published private(set) var emailStep = OfficialEmailLoginStep.address
    @Published private(set) var emailRegistered = false
    @Published private(set) var emailRetryAt: Date?
    @Published private(set) var emailNotice = "选择国家／地区并读取当前协议后，使用邮箱继续。"
    @Published private(set) var loginUsesEmail = false
    private var activeSession: OfficialAccountSession?
    private let coordinator = OfficialSessionCoordinator.shared
    private var coordinatorRefreshing = false
    private var coordinatorStateReadRevision = 0
    private var accountSubscriptions = Set<AnyCancellable>()
    private let loginService = OfficialPhoneLoginService()
    private let emailService = OfficialEmailLoginService()
    private var loginCandidate: OfficialLoginCandidate?
    private var sentPhone: String?
    private var acceptedAgreements: [OfficialAgreement] = []
    private var consentSession: OfficialAccountSession?
    private var identityQueryUnconfirmed = false
    private var pendingProfile: (profile: OfficialAccountProfile, reference: OfficialFirmwareConfiguration, account: UUID)?

    private init() {
        reload()
        NotificationCenter.default.publisher(for: .officialAccountCoordinatorStateChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.synchronizeCoordinatorState() }
            }.store(in: &accountSubscriptions)
        NotificationCenter.default.publisher(for: .officialAccountCredentialsRotated)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reloadSession()
                    await self.synchronizeCoordinatorState()
                }
            }.store(in: &accountSubscriptions)
        NotificationCenter.default.publisher(for: .officialAccountSessionChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reloadSession()
                    await self.synchronizeCoordinatorState()
                }
            }.store(in: &accountSubscriptions)
    }

    func reload() {
        reloadSession()
        Task { await synchronizeCoordinatorState() }
    }

    private func reloadSession() {
        let previous = activeSession
        do {
            let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
            let saved = try OfficialAccountSessionStore.load()
            let environment = ProcessInfo.processInfo.environment
            let useSaved = OfficialAccountSessionStore.prefersSavedSession ||
                (environment["RAYNEO_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            canClear = saved != nil || OfficialAccountSessionStore.prefersSavedSession
            if OfficialAccountSessionStore.isSignedOut {
                activeSession = nil; source = "已退出官方账号"
            } else if useSaved, let saved {
                activeSession = saved; source = "会话来源：本应用钥匙串"
            } else if !configuration.accessToken.isEmpty {
                activeSession = OfficialAccountSession(accessToken: configuration.accessToken,
                    refreshToken: nonempty(environment["RAYNEO_REFRESH_TOKEN"]), accessExpiresAt: nil, refreshExpiresAt: nil,
                    accountID: nonempty(configuration.accountID), region: configuration.region,
                    businessBaseURL: configuration.baseURL.absoluteString, accountRouteRegion: configuration.accountRouteRegion,
                    countryCode: nonempty(environment["RAYNEO_COUNTRY_CODE"]), clientDeviceID: configuration.clientDeviceID,
                    deviceCode: configuration.deviceCode, savedAt: Date())
                source = "会话来源：App 启动环境"
            } else { activeSession = nil; source = "未配置官方会话" }
            if previous?.identityEpoch != activeSession?.identityEpoch || previous?.accountID != activeSession?.accountID
                || previous?.businessBaseURL != activeSession?.businessBaseURL || previous?.region != activeSession?.region {
                accountGeneration = UUID()
                pendingProfile = nil; hasPendingProfile = false
            }
            if previous?.accountID != activeSession?.accountID || previous?.profile?.nickname != activeSession?.profile?.nickname {
                profileNicknameDraft = activeSession?.profile?.nickname ?? ""
            }
            publishSession()
        } catch {
            activeSession = nil; profile = nil; canSignOut = false; canRefresh = false
            pendingProfile = nil; hasPendingProfile = false; profileNicknameDraft = ""; accountGeneration = UUID()
            notice = error.localizedDescription; source = "本机会话暂不可用"
        }
    }

    private func synchronizeCoordinatorState() async {
        coordinatorStateReadRevision += 1
        let revision = coordinatorStateReadRevision
        let state = await coordinator.state()
        guard revision == coordinatorStateReadRevision else { return }
        hasPendingSave = state.hasPendingPersistence
        canClear = canClear || state.hasPendingPersistence
        coordinatorRefreshing = state.refreshing
        requiresReauthentication = state.requiresReauthentication
        if let message = state.message, !busy { notice = message }
        publishSession()
    }

    func saveImported() {
        guard !busy, !hasPendingSave, let access = nonempty(accessTokenDraft) else { return }
        let imported = OfficialAccountSession(accessToken: access, refreshToken: nonempty(refreshTokenDraft),
            accessExpiresAt: nil, refreshExpiresAt: nil, accountID: nonempty(accountIDDraft), region: regionDraft,
            businessBaseURL: businessURLDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            accountRouteRegion: nonempty(routeRegionDraft), countryCode: nonempty(countryCodeDraft),
            clientDeviceID: nonempty(clientDeviceIDDraft), deviceCode: nonempty(deviceCodeDraft), savedAt: Date())
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await coordinator.replace(imported)
                accessTokenDraft = ""; refreshTokenDraft = ""
                resetLogin()
                reloadSession()
                await synchronizeCoordinatorState()
                notice = "已有会话已保存并选用；尚未通过云请求验证。"
            } catch {
                await synchronizeCoordinatorState()
                notice = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard !busy, !hasPendingSave, activeSession != nil else { return }
        busy = true; defer { busy = false }
        notice = "正在刷新官方会话…"
        do {
            _ = try await coordinator.refresh()
            reloadSession()
            await synchronizeCoordinatorState()
            notice = "官方刷新已返回，新会话已完整保存。"
        } catch {
            await synchronizeCoordinatorState()
            notice = hasPendingSave ? "已收到新会话但钥匙串保存失败；解锁后请重试保存，避免丢失已轮换的会话。\n" + error.localizedDescription : error.localizedDescription
        }
    }

    func retrySave() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let saved = try await coordinator.retryPersistence()
                let savedLogin = saved.map { matchesLoginConsent($0) } ?? false
                if savedLogin, let saved {
                    consentSession = saved
                    loginCandidate = nil; loginStep = .phone
                }
                reloadSession()
                await synchronizeCoordinatorState()
                notice = saved == nil ? "当前没有待保存的新会话。" : "新会话已保存并选用。"
                if savedLogin { await reportLoginConsent() }
                else if loginStep == .ready { loginNotice = "此前的待保存会话已处理，可以继续保存本次登录。" }
            } catch {
                await synchronizeCoordinatorState()
                notice = error.localizedDescription
            }
        }
    }

    func clearSaved() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await coordinator.clear()
                resetLogin()
                reloadSession()
                await synchronizeCoordinatorState()
                notice = activeSession == nil ? "本机保存的官方会话已清除。" : "本机保存会话已清除；启动环境仍提供会话。"
            } catch {
                await synchronizeCoordinatorState()
                notice = error.localizedDescription
            }
        }
    }

    var canManageProfile: Bool { canSignOut && activeSession?.accountID?.isEmpty == false && !hasPendingSave && !requiresReauthentication }

    func saveNickname() async {
        guard !busy, canManageProfile, let session = activeSession else { return }
        let name = profileNicknameDraft
        let account = accountGeneration
        if let message = OfficialPhoneLoginService.nicknameValidation(name) { notice = message; return }
        busy = true; defer { busy = false }
        do {
            let reference = try OfficialFirmwareConfiguration.fromSession(session)
            let configuration = try await coordinator.prepare(reference: reference)
            let received = try await loginService.updateNickname(name, configuration: configuration)
            await saveReceivedProfile(received, reference: configuration, account: account)
        } catch { notice = error.localizedDescription }
    }

    func uploadAvatar(_ jpeg: Data, expectedAccount: UUID) async -> Bool {
        guard !busy, canManageProfile, accountGeneration == expectedAccount, let session = activeSession else { return false }
        busy = true; defer { busy = false }
        do {
            let configuration = try await coordinator.prepare(reference: OfficialFirmwareConfiguration.fromSession(session))
            let received = try await loginService.uploadAvatar(jpeg, configuration: configuration)
            await saveReceivedProfile(received, reference: configuration, account: expectedAccount)
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    private func saveReceivedProfile(_ received: OfficialAccountProfile, reference: OfficialFirmwareConfiguration, account: UUID) async {
        guard accountGeneration == account else { return }
        do {
            _ = try await coordinator.saveProfile(received, reference: reference)
            guard accountGeneration == account else { return }
            pendingProfile = nil; hasPendingProfile = false
            reloadSession(); notice = "官方资料已更新并保存到本机会话。"
        } catch {
            guard accountGeneration == account else { return }
            pendingProfile = (received, reference, account); hasPendingProfile = true
            notice = "官方已更新资料，但本机保存未完成。可重试保存，无需再次上传。\n" + error.localizedDescription
        }
    }

    func retryProfileSave() async {
        guard !busy, let pendingProfile else { return }
        busy = true; defer { busy = false }
        await saveReceivedProfile(pendingProfile.profile, reference: pendingProfile.reference, account: pendingProfile.account)
    }

    func signOut(expectedAccount: UUID) async {
        guard !busy, canSignOut, accountGeneration == expectedAccount else { return }
        busy = true; defer { busy = false }
        notice = "正在停止当前功能并退出官方账号…"
        let connectionStopped = await prepareSignOut?() ?? true
        guard accountGeneration == expectedAccount else { notice = "账号已变化，未退出新选用的会话。"; return }
        do {
            let result = try await coordinator.signOut()
            resetLogin(); reloadSession(); await synchronizeCoordinatorState()
            notice = result + (connectionStopped ? "" : " 本机连接服务未确认停止，请检查设备页。")
        } catch {
            reloadSession(); await synchronizeCoordinatorState(); notice = error.localizedDescription
        }
    }

    var loginTerms: [OfficialAgreement] { loginAgreements.filter { [0, 1].contains($0.agreementCode) } }
    var hasLoginTerms: Bool {
        [0, 1].allSatisfy { code in loginTerms.contains { $0.agreementCode == code && $0.url != nil } }
    }
    func canSendSMS(at date: Date) -> Bool {
        !busy && !hasPendingSave && agreedToLoginTerms && hasLoginTerms && (smsRetryAt.map { $0 <= date } ?? true)
    }

    func loadLoginAgreements() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        agreedToLoginTerms = false; loginAgreements = []
        do {
            loginAgreements = try await loginService.agreements()
            loginNotice = hasLoginTerms ? "请阅读当前版本的服务协议与隐私政策，再选择是否同意并继续。" : "官方未返回完整的服务协议和隐私政策链接，请稍后重试。"
        } catch { loginNotice = error.localizedDescription }
    }

    func sendSMS() async {
        guard canSendSMS(at: Date()) else { return }
        let phone = normalizedPhone
        guard phone.range(of: "^1[3-9][0-9]{9}$", options: .regularExpression) != nil else {
            loginNotice = "请输入 11 位中国大陆手机号，不带 +86。"; return
        }
        busy = true; defer { busy = false }
        let first = sentPhone != phone || loginStep == .phone
        do {
            let outcome = try await loginService.sendCode(phone: phone)
            if let seconds = outcome.retryAfter { smsRetryAt = Date().addingTimeInterval(Double(seconds)) }
            else if first || outcome.notice == nil { smsRetryAt = Date().addingTimeInterval(60) }
            if first { smsCodeDraft = "" }
            phoneDraft = phone; sentPhone = phone; loginStep = .code
            loginNotice = outcome.notice ?? "验证码已发送，请输入短信中的 6 位验证码。"
        } catch { loginNotice = error.localizedDescription }
    }

    func signInWithSMS() async {
        guard !busy, !hasPendingSave, agreedToLoginTerms, hasLoginTerms else { return }
        guard sentPhone == normalizedPhone else { loginNotice = "手机号已修改，请先为这个号码重新获取验证码。"; return }
        let code = smsCodeDraft.filter { $0.isASCII && $0.isNumber }
        guard code.count == 6, let phone = sentPhone else { loginNotice = "请输入 6 位短信验证码。"; return }
        busy = true; defer { busy = false }
        loginNotice = "正在注册／登录并检查账号状态…"
        do {
            let candidate = try await loginService.signIn(phone: phone, code: code)
            loginUsesEmail = false
            smsCodeDraft = ""; loginCandidate = candidate; acceptedAgreements = loginTerms
            if candidate.needsProfile {
                loginStep = .profile
                nicknameDraft = candidate.userInfo["nickName"] as? String ?? ""
                loginNotice = "官方账号要求补充资料，完成后继续验证。"
            } else { try await continueLogin() }
        } catch { loginNotice = error.localizedDescription }
    }

    func submitLoginProfile() async {
        guard !busy, !hasPendingSave, let candidate = loginCandidate, loginStep == .profile else { return }
        if let error = OfficialPhoneLoginService.nicknameValidation(nicknameDraft) { loginNotice = error; return }
        if needsLoginBirthday, let error = OfficialPhoneLoginService.birthdayValidation(loginBirthdayDraft) { loginNotice = error; return }
        busy = true; defer { busy = false }
        do {
            loginCandidate = try await loginService.completeProfile(candidate, nickname: nicknameDraft,
                birthday: needsLoginBirthday ? loginBirthdayDraft : nil)
            try await continueLogin()
        } catch { loginNotice = error.localizedDescription }
    }

    var needsLoginBirthday: Bool { loginCandidate.map { !OfficialPhoneLoginService.isDomesticCandidate($0) } ?? false }
    var phoneContinuationActive: Bool { !loginUsesEmail && loginCandidate != nil }
    var emailContinuationActive: Bool { loginUsesEmail && loginCandidate != nil }
    var emailTerms: [OfficialAgreement] { emailAgreements.filter { [0, 1].contains($0.agreementCode) } }
    var hasEmailTerms: Bool { [0, 1].allSatisfy { code in emailTerms.contains { $0.agreementCode == code && $0.url != nil } } }

    func resetEmailEntry(countryChanged: Bool = false) {
        guard !busy else { return }
        emailStep = .address; emailPasswordDraft = ""; emailCodeDraft = ""; emailRetryAt = nil
        if countryChanged { agreedToEmailTerms = false; emailAgreements = [] }
        emailNotice = "选择国家／地区并读取当前协议后，使用邮箱继续。"
    }

    func loadEmailAgreements() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        agreedToEmailTerms = false; emailAgreements = []
        do {
            emailAgreements = try await emailService.agreements(country: emailCountryDraft)
            emailNotice = hasEmailTerms ? "请阅读协议并自行选择是否同意后继续。" : "官方未返回完整的服务协议和隐私政策。"
        } catch { emailNotice = error.localizedDescription }
    }

    func checkEmail() async {
        guard !busy, loginCandidate == nil, !hasPendingSave, hasEmailTerms, agreedToEmailTerms else { return }
        let email = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else { emailNotice = "请输入有效邮箱地址。"; return }
        busy = true; defer { busy = false }
        do {
            emailRegistered = try await emailService.checkEmail(email: email, country: emailCountryDraft)
            emailDraft = email; emailStep = .password; emailPasswordDraft = ""
            emailNotice = emailRegistered ? "邮箱已注册，请输入账号密码。" : "此邮箱可注册，请设置密码并获取邮箱验证码。"
        } catch { emailNotice = error.localizedDescription }
    }

    func submitEmailPassword() async {
        guard !busy, !hasPendingSave, hasEmailTerms, agreedToEmailTerms, !emailPasswordDraft.isEmpty else { return }
        if !emailRegistered, let error = OfficialEmailLoginService.registrationPasswordValidation(emailPasswordDraft) { emailNotice = error; return }
        busy = true; defer { busy = false }
        do {
            if emailRegistered {
                let candidate = try await emailService.signIn(email: emailDraft, password: emailPasswordDraft, country: emailCountryDraft)
                emailPasswordDraft = ""; try await acceptEmailCandidate(candidate)
            } else {
                let outcome = try await emailService.sendRegistrationCode(email: emailDraft, country: emailCountryDraft)
                emailRetryAt = Date().addingTimeInterval(Double(outcome.retryAfter ?? 60))
                emailCodeDraft = ""; emailStep = .code
                emailNotice = outcome.notice ?? "注册验证码已发送到邮箱。"
            }
        } catch { emailNotice = error.localizedDescription }
    }

    func resendEmailCode() async {
        guard !busy, emailStep == .code, agreedToEmailTerms, hasEmailTerms, emailRetryAt.map({ $0 <= Date() }) ?? true else { return }
        busy = true; defer { busy = false }
        do {
            let outcome = try await emailService.sendRegistrationCode(email: emailDraft, country: emailCountryDraft)
            if let seconds = outcome.retryAfter { emailRetryAt = Date().addingTimeInterval(Double(seconds)) }
            else if outcome.notice == nil { emailRetryAt = Date().addingTimeInterval(60) }
            emailNotice = outcome.notice ?? "注册验证码已发送到邮箱。"
        } catch { emailNotice = error.localizedDescription }
    }

    func registerWithEmailCode() async {
        guard !busy, !hasPendingSave, emailStep == .code, agreedToEmailTerms, hasEmailTerms else { return }
        let code = emailCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { emailNotice = "请输入 6 位邮箱验证码。"; return }
        busy = true; defer { busy = false }
        do {
            let candidate = try await emailService.register(email: emailDraft, password: emailPasswordDraft, code: code, country: emailCountryDraft)
            emailPasswordDraft = ""; emailCodeDraft = ""; try await acceptEmailCandidate(candidate)
        } catch { emailNotice = error.localizedDescription }
    }

    private func acceptEmailCandidate(_ candidate: OfficialLoginCandidate) async throws {
        loginUsesEmail = true; loginCandidate = candidate; acceptedAgreements = emailTerms
        if candidate.needsProfile {
            loginStep = .profile; nicknameDraft = candidate.userInfo["nickName"] as? String ?? ""
            loginBirthdayDraft = candidate.userInfo["birthday"] as? String ?? ""
            loginNotice = "官方账号要求补充资料，完成后继续。"
        } else { try await continueLogin() }
    }

    func passwordRecoveryTarget() -> OfficialPasswordRecoveryTarget? {
        guard !busy, loginCandidate == nil, emailStep == .password, emailRegistered,
              hasEmailTerms, agreedToEmailTerms else { return nil }
        return .init(email: emailDraft, country: emailCountryDraft, agreements: emailTerms, accountGeneration: accountGeneration)
    }

    func acceptRecoveredEmailCandidate(_ candidate: OfficialLoginCandidate, target: OfficialPasswordRecoveryTarget) async {
        guard !busy, !hasPendingSave, loginCandidate == nil, accountGeneration == target.accountGeneration else { return }
        busy = true; defer { busy = false }
        emailPasswordDraft = ""; emailCodeDraft = ""
        loginUsesEmail = true; loginCandidate = candidate; acceptedAgreements = target.agreements
        do {
            if candidate.needsProfile {
                loginStep = .profile; nicknameDraft = candidate.userInfo["nickName"] as? String ?? ""
                loginBirthdayDraft = candidate.userInfo["birthday"] as? String ?? ""
                loginNotice = "密码已重置，官方账号要求补充资料后继续。"
            } else { try await continueLogin() }
        } catch { loginNotice = "密码已重置，登录续行尚未完成：" + error.localizedDescription }
    }

    func submitLoginIdentity() async {
        guard !busy, !hasPendingSave, let candidate = loginCandidate, loginStep == .identity else { return }
        if let error = OfficialPhoneLoginService.identityValidation(name: identityNameDraft, number: identityNumberDraft) {
            loginNotice = error; return
        }
        busy = true; defer { busy = false }
        let allowed: Bool
        do {
            allowed = try await loginService.verifyIdentity(candidate, name: identityNameDraft,
                identityNumber: identityNumberDraft, type: identityTypeDraft)
        } catch let failure as OfficialIdentityResultFailure {
            loginNotice = failure.localizedDescription; return
        } catch {
            guard let recovered = await loginService.recoverIdentitySubmission(candidate) else {
                loginNotice = error.localizedDescription; return
            }
            allowed = recovered
        }
        identityNameDraft = ""; identityNumberDraft = ""
        guard allowed else {
            resetLogin(); loginNotice = "官方账号年龄权限未放行，本次会话未保存。"; return
        }
        do {
            try await continueLogin(verifiedIdentity: true)
        } catch { loginNotice = error.localizedDescription }
    }

    func retryLoginVerification() async {
        guard !busy, loginCandidate != nil else { return }
        busy = true; defer { busy = false }
        do { try await continueLogin() }
        catch { loginNotice = error.localizedDescription }
    }

    func restoreCoolingAccount() async {
        guard !busy, loginStep == .cooling, let candidate = loginCandidate else { return }
        busy = true; defer { busy = false }
        do {
            try await loginService.restoreCoolingAccount(candidate)
            try await completeLogin(candidate)
        } catch { loginNotice = error.localizedDescription }
    }

    func saveReadyLogin() async {
        guard !busy, !hasPendingSave, loginStep == .ready, let candidate = loginCandidate else { return }
        busy = true; defer { busy = false }
        do { try await completeLogin(candidate) }
        catch { loginNotice = error.localizedDescription }
    }

    func cancelPhoneLogin() {
        guard !busy, !hasPendingSave else { return }
        resetLogin()
        loginNotice = "已取消本次注册／登录，当前已保存会话保留。"
    }

    private var normalizedPhone: String { phoneDraft.filter { $0.isASCII && $0.isNumber } }

    private func continueLogin(verifiedIdentity: Bool = false) async throws {
        guard let candidate = loginCandidate else { return }
        let identity: OfficialIdentityStatus
        do {
            if !OfficialPhoneLoginService.isDomesticCandidate(candidate) { identity = .notRequired }
            else if verifiedIdentity { identity = .verified }
            else { identity = try await loginService.identityStatus(candidate) }
            identityQueryUnconfirmed = false
        }
        catch {
            // APK IdentityVerificationGate has an explicit, commit-eligible query-failure state.
            identity = .bypassedOnQueryFailure
            identityQueryUnconfirmed = true
            loginNotice = "身份状态查询未成功；按官方流程继续，尚未确认实名状态。"
        }
        switch identity {
        case .verificationRequired:
            loginStep = .identity; loginNotice = "官方账号要求实名验证。"; return
        case .appUnavailable:
            resetLogin(); loginNotice = "官方账号年龄权限未放行，本次会话未保存。"; return
        case .notRequired, .verified, .bypassedOnQueryFailure: break
        }
        let status: Int?
        do { status = try await loginService.accountStatus(candidate) }
        catch { status = nil }
        if status == 4 {
            loginStep = .cooling
            loginNotice = "账号处于注销冷静期。可以取消本次登录，或明确选择恢复账号。"
        } else { try await completeLogin(candidate) }
    }

    private func completeLogin(_ candidate: OfficialLoginCandidate) async throws {
        canRefresh = false
        consentSession = candidate.session
        do {
            consentSession = try await coordinator.replace(candidate.session)
            reloadSession()
            await synchronizeCoordinatorState()
        }
        catch {
            await synchronizeCoordinatorState()
            loginStep = .ready
            notice = hasPendingSave ? "有会话尚未保存，请先重试保存，再继续本次登录。" : error.localizedDescription
            throw error
        }
        loginCandidate = nil; loginStep = .phone
        emailStep = .address
        loginNotice = "官方会话已保存并选用。" + (identityQueryUnconfirmed ? "身份状态查询未确认，使用了官方流程的查询失败续行分支。" : "")
        notice = loginNotice
        await reportLoginConsent()
    }

    private func reportLoginConsent() async {
        guard let session = consentSession else { return }
        let agreements = acceptedAgreements
        consentSession = nil; acceptedAgreements = []
        var failures = 0
        for agreement in agreements {
            do { try await loginService.reportAgreement(agreement, session: session) }
            catch { failures += 1 }
        }
        if failures > 0 { notice = "会话已保存；有 \(failures) 份协议同意记录未能上报，未回滚登录。" }
    }

    private func matchesLoginConsent(_ saved: OfficialAccountSession) -> Bool {
        guard let consentSession else { return false }
        return saved.accessToken == consentSession.accessToken && saved.refreshToken == consentSession.refreshToken &&
            saved.accountID == consentSession.accountID && saved.businessBaseURL == consentSession.businessBaseURL
    }

    private func resetLogin() {
        loginCandidate = nil; consentSession = nil; acceptedAgreements = []
        loginStep = .phone; sentPhone = nil; smsCodeDraft = ""
        identityNameDraft = ""; identityNumberDraft = ""; identityQueryUnconfirmed = false
        loginBirthdayDraft = ""; loginUsesEmail = false
        emailStep = .address; emailPasswordDraft = ""; emailCodeDraft = ""
    }

    private func publishSession() {
        canRefresh = activeSession?.refreshToken?.isEmpty == false && !hasPendingSave && !coordinatorRefreshing && !requiresReauthentication
        accessExpiresAt = activeSession?.accessExpiresAt; refreshExpiresAt = activeSession?.refreshExpiresAt
        accountDescription = activeSession?.accountID.map { "账号 ID：" + $0 } ?? "尚未提供账号 ID；固件检查需要该字段。"
        profile = activeSession?.profile; canSignOut = activeSession != nil
    }

    private func nonempty(_ value: String?) -> String? {
        value.flatMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

@MainActor
struct OfficialAccountPanel: View {
    @ObservedObject private var model = OfficialAccountModel.shared
    @State private var confirmSignOut = false
    @State private var signOutAccount: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.source).font(.headline)
            Text(model.accountDescription).font(.caption).foregroundStyle(.secondary)
            if let date = model.accessExpiresAt { Text("访问令牌有效期：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption) }
            if let date = model.refreshExpiresAt { Text("刷新令牌有效期：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption) }
            HStack {
                Button("重新读取本机会话") { model.reload() }.disabled(model.busy)
                Button("刷新官方会话") { Task { await model.refresh() } }.disabled(!model.canRefresh || model.busy)
                if model.hasPendingSave { Button("重试保存新会话") { model.retrySave() }.disabled(model.busy) }
                Button("清除本机保存会话", role: .destructive) { model.clearSaved() }.disabled(!model.canClear || model.busy)
                Button("退出官方账号…") { signOutAccount = model.accountGeneration; confirmSignOut = true }.disabled(!model.canSignOut || model.busy)
            }
            if model.requiresReauthentication { Text("官方会话需要重新登录。网络错误不会自动清除本机保存的会话。").foregroundStyle(.orange) }
            Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy { ProgressView().controlSize(.small) }
            DisclosureGroup("账号资料与头像") { OfficialAccountProfilePanel(model: model) }
            DisclosureGroup("个人数据管理") { OfficialAccountDataPanel() }
            DisclosureGroup("手机号注册／登录") {
                OfficialPhoneLoginPanel(model: model).padding(.vertical, 6)
            }
            DisclosureGroup("海外邮箱注册／登录") { OfficialEmailLoginPanel(model: model).padding(.vertical, 6) }
            DisclosureGroup("导入已有官方会话") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("访问令牌", text: $model.accessTokenDraft)
                    SecureField("刷新令牌（可选）", text: $model.refreshTokenDraft)
                    TextField("账号 ID（固件检查需要）", text: $model.accountIDDraft)
                    Picker("会话区域", selection: $model.regionDraft) {
                        Text("境内").tag(OfficialFirmwareRegion.domestic); Text("海外").tag(OfficialFirmwareRegion.overseas)
                    }.onChange(of: model.regionDraft) { region in
                        model.businessURLDraft = region.baseURL.absoluteString
                        model.countryCodeDraft = region == .domestic ? "cn" : ""
                    }
                    TextField("实际业务域名", text: $model.businessURLDraft)
                    TextField("国家码，如 cn / sg / us", text: $model.countryCodeDraft)
                    DisclosureGroup("已有客户端路由上下文") {
                        TextField("accountRouteRegion（可选）", text: $model.routeRegionDraft)
                        TextField("客户端设备 ID（可选）", text: $model.clientDeviceIDDraft)
                        TextField("device-code（可选）", text: $model.deviceCodeDraft)
                    }
                    Button("保存并选用已有会话") { model.saveImported() }
                        .disabled(model.busy || model.hasPendingSave || model.accessTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("会话存入本应用钥匙串。保存本身不验证登录；刷新需要有效的刷新令牌。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6).disabled(model.busy)
            }
        }.padding(.vertical, 6)
        .confirmationDialog("退出当前官方账号？", isPresented: $confirmSignOut) {
            Button("退出账号并断开眼镜") {
                if let account = signOutAccount { Task { await model.signOut(expectedAccount: account) } }
            }
        } message: { Text("将退出当前官方会话并断开本机眼镜连接。本地录音、已保存文件和系统配对信息保留。") }
        .onChange(of: model.accountGeneration) { _ in signOutAccount = nil; confirmSignOut = false }
    }
}
