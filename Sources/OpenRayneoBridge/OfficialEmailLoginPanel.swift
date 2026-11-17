// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialEmailLoginPanel: View {
    @ObservedObject var model: OfficialAccountModel
    @State private var recovery: OfficialPasswordRecoveryTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("海外邮箱注册／登录").font(.headline)
            if model.phoneContinuationActive {
                Text("请先在手机号入口完成或取消当前账号的登录续行。").font(.caption).foregroundStyle(.secondary)
            } else if model.emailContinuationActive {
                OfficialLoginContinuationPanel(model: model)
            } else {
                TextField("国家／地区两位代码，例如 us、sg", text: $model.emailCountryDraft)
                    .disabled(model.busy || model.emailStep != .address)
                    .onChange(of: model.emailCountryDraft) { _ in model.resetEmailEntry(countryChanged: true) }
                Button("读取当前服务协议与隐私政策") { Task { await model.loadEmailAgreements() } }
                    .disabled(model.busy || model.emailStep != .address)
                ForEach(model.emailTerms) { agreement in
                    if let url = agreement.url { Link("\(agreement.agreementTitle) · \(agreement.versionName)", destination: url) }
                }
                Toggle("我已阅读并同意上面的服务协议和隐私政策", isOn: $model.agreedToEmailTerms)
                    .disabled(model.busy || !model.hasEmailTerms)
                TextField("邮箱地址", text: $model.emailDraft).disabled(model.busy || model.emailStep != .address)
                if model.emailStep == .address {
                    Button("使用此邮箱继续") { Task { await model.checkEmail() } }
                        .disabled(model.busy || model.hasPendingSave || !model.hasEmailTerms || !model.agreedToEmailTerms || model.emailDraft.isEmpty)
                } else {
                    SecureField(model.emailRegistered ? "账号密码" : "设置账号密码", text: $model.emailPasswordDraft)
                        .disabled(model.busy || model.emailStep == .code)
                    if !model.emailRegistered {
                        Text("密码需 8–64 个字符，包含大写、小写、数字和特殊字符。").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.emailStep == .password {
                        Button(model.emailRegistered ? "使用密码登录" : "发送注册验证码") { Task { await model.submitEmailPassword() } }
                            .disabled(model.busy || model.hasPendingSave || !model.agreedToEmailTerms || model.emailPasswordDraft.isEmpty
                                || (!model.emailRegistered && OfficialEmailLoginService.registrationPasswordValidation(model.emailPasswordDraft) != nil))
                        if model.emailRegistered {
                            Button("忘记密码…") { recovery = model.passwordRecoveryTarget() }
                                .disabled(model.busy || model.hasPendingSave || !model.agreedToEmailTerms)
                        }
                    } else {
                        SecureField("6 位邮箱验证码", text: $model.emailCodeDraft).disabled(model.busy)
                        HStack {
                            Button("注册并继续") { Task { await model.registerWithEmailCode() } }
                                .disabled(model.busy || model.hasPendingSave || !model.agreedToEmailTerms || model.emailCodeDraft.isEmpty)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Button(model.emailRetryAt.map { $0 > context.date } == true
                                    ? "\(max(0, Int(ceil(model.emailRetryAt!.timeIntervalSince(context.date))))) 秒后重发" : "重新发送验证码") {
                                    Task { await model.resendEmailCode() }
                                }.disabled(model.busy || !model.agreedToEmailTerms || model.emailRetryAt.map { $0 > context.date } == true)
                            }
                        }
                    }
                    Button("返回修改邮箱／地区") { model.resetEmailEntry() }.disabled(model.busy)
                }
                Text("邮箱、密码凭据及注册验证码仅在你点击后发送到雷鸟官方服务。").font(.caption).foregroundStyle(.secondary)
                Text(model.emailNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.loginUsesEmail { Text(model.loginNotice).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .sheet(item: $recovery) { target in OfficialPasswordRecoveryPanel(account: model, target: target) }
        .onChange(of: model.accountGeneration) { _ in recovery = nil }
    }
}
