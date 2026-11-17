// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct OfficialPasswordRecoveryTarget: Identifiable {
    let id = UUID()
    let email: String
    let country: String
    let agreements: [OfficialAgreement]
    let accountGeneration: UUID
}

@MainActor
final class OfficialPasswordRecoveryModel: ObservableObject {
    enum Step { case requestCode, verifyCode, password, loginFailed }
    @Published private(set) var step: Step = .requestCode
    @Published private(set) var busy = false
    @Published private(set) var notice = "向这个邮箱发送找回密码验证码。"
    @Published private(set) var retryAt: Date?
    @Published var code = ""
    @Published var password = ""
    @Published var repeatedPassword = ""
    private let service = OfficialEmailLoginService()
    let target: OfficialPasswordRecoveryTarget
    private var verifiedCode: String?
    private var active = true

    init(target: OfficialPasswordRecoveryTarget) { self.target = target }
    var canReset: Bool {
        active && !busy && step == .password && verifiedCode != nil && passwordsMatch
            && OfficialEmailLoginService.registrationPasswordValidation(password) == nil
    }
    var passwordsMatch: Bool { password.utf8.elementsEqual(repeatedPassword.utf8) }
    func sendCode() async {
        guard active, !busy, step == .requestCode || step == .verifyCode,
              retryAt.map({ $0 <= Date() }) ?? true else { return }
        let first = step == .requestCode
        busy = true; defer { busy = false }
        do {
            let result = try await service.sendRecoveryCode(email: target.email, country: target.country)
            guard active, !Task.isCancelled else { return }
            if let seconds = result.retryAfter { retryAt = Date().addingTimeInterval(Double(seconds)) }
            else if first || result.notice == nil { retryAt = Date().addingTimeInterval(60) }
            step = .verifyCode
            notice = result.notice ?? "验证码已发送，请先验证邮箱。"
        } catch { if active { notice = error.localizedDescription } }
    }
    func verifyCode() async {
        guard active, !busy, step == .verifyCode else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { notice = "请输入 6 位邮箱验证码。"; return }
        busy = true; defer { busy = false }
        do {
            try await service.verifyRecoveryCode(email: target.email, code: value, country: target.country)
            guard active, !Task.isCancelled else { return }
            verifiedCode = value; code = ""; step = .password
            notice = "邮箱已验证，请填写两次新密码。"
        } catch { if active { notice = error.localizedDescription } }
    }
    func reset(completed: (OfficialLoginCandidate) async -> Void) async {
        guard canReset, let verifiedCode else { return }
        busy = true; defer { busy = false }
        notice = "正在重置密码并尝试登录…"
        do {
            let candidate = try await service.resetPasswordAndSignIn(email: target.email, code: verifiedCode,
                password: password, country: target.country)
            guard active, !Task.isCancelled else { return }
            clearSecrets()
            await completed(candidate)
        } catch let failure as PasswordResetAutoLoginFailure {
            guard active else { return }
            clearSecrets(); step = .loginFailed
            notice = "密码已重置，但自动登录未完成。请返回邮箱入口，使用新密码登录。\n" + failure.localizedDescription
        } catch {
            guard active else { return }
            notice = error.localizedDescription + " 如遇网络中断，重置结果可能尚未确认，请先尝试用新密码登录。"
        }
    }
    func clearSecrets() { code = ""; password = ""; repeatedPassword = ""; verifiedCode = nil }
    func invalidate() { active = false; clearSecrets() }
}

@MainActor
struct OfficialPasswordRecoveryPanel: View {
    @ObservedObject var account: OfficialAccountModel
    @StateObject private var model: OfficialPasswordRecoveryModel
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    private let target: OfficialPasswordRecoveryTarget
    init(account: OfficialAccountModel, target: OfficialPasswordRecoveryTarget) {
        self.account = account; self.target = target
        _model = StateObject(wrappedValue: OfficialPasswordRecoveryModel(target: target))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("找回邮箱密码").font(.title2.weight(.semibold))
            Text(target.email).textSelection(.enabled)
            if model.step == .requestCode || model.step == .verifyCode {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Button(model.step == .requestCode ? "发送找回密码验证码" : "重新发送验证码") { operation = Task { await model.sendCode() } }
                            .disabled(model.busy || model.retryAt.map { $0 > context.date } == true)
                        if let until = model.retryAt, until > context.date { Text("\(Int(ceil(until.timeIntervalSince(context.date)))) 秒后可重发").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if model.step == .verifyCode {
                    SecureField("6 位邮箱验证码", text: $model.code).disabled(model.busy)
                    Button("验证邮箱并继续") { operation = Task { await model.verifyCode() } }.disabled(model.busy || model.code.isEmpty)
                }
            }
            if model.step == .password {
                SecureField("新密码", text: $model.password).disabled(model.busy)
                SecureField("再次输入新密码", text: $model.repeatedPassword).disabled(model.busy)
                Text("密码需 8–64 个字符，包含大写、小写、数字和特殊字符。").font(.caption).foregroundStyle(.secondary)
                if !model.repeatedPassword.isEmpty && !model.passwordsMatch {
                    Text("两次密码不一致。").font(.caption).foregroundStyle(.orange)
                }
                Button("重置密码并登录") {
                    operation = Task {
                        await model.reset { candidate in
                            // The account model owns the accepted login continuation, including consent persistence.
                            operation = nil
                            await account.acceptRecoveredEmailCandidate(candidate, target: target)
                            dismiss()
                        }
                    }
                }.disabled(!model.canReset || account.busy || account.hasPendingSave)
            }
            Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(model.step == .loginFailed ? "返回邮箱登录" : "取消") { model.clearSecrets(); dismiss() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
        }.padding(22).frame(width: 520)
        .interactiveDismissDisabled(model.busy)
        .onChange(of: account.accountGeneration) { _ in operation?.cancel(); model.invalidate(); dismiss() }
        .onDisappear { operation?.cancel(); model.invalidate() }
    }
}
