// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@MainActor
struct OfficialPhoneLoginPanel: View {
    @ObservedObject var model: OfficialAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("中国大陆手机号注册／登录").font(.headline)
            Button("读取当前服务协议与隐私政策") { Task { await model.loadLoginAgreements() } }
                .disabled(model.busy)
            ForEach(model.loginTerms) { agreement in
                if let url = agreement.url {
                    Link("\(agreement.agreementTitle) · \(agreement.versionName)", destination: url)
                }
            }
            Toggle("我已阅读并同意上面的服务协议和隐私政策", isOn: $model.agreedToLoginTerms)
                .disabled(model.busy || !model.hasLoginTerms)
            Text("未注册的手机号可能进入注册或补资料流程。验证码及资料将提交给雷鸟官方账号服务。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.emailContinuationActive && (model.loginStep == .phone || model.loginStep == .code) {
                TextField("11 位中国大陆手机号（不带 +86）", text: $model.phoneDraft)
                    .disabled(model.busy)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Button(model.loginStep == .phone ? "发送短信验证码" : "重新发送验证码") {
                            Task { await model.sendSMS() }
                        }.disabled(!model.canSendSMS(at: context.date))
                        if let until = model.smsRetryAt, until > context.date {
                            Text("\(Int(ceil(until.timeIntervalSince(context.date)))) 秒后可重发")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.loginStep == .code {
                    SecureField("6 位短信验证码", text: $model.smsCodeDraft).disabled(model.busy)
                    Button("使用验证码注册／登录") { Task { await model.signInWithSMS() } }
                        .disabled(model.busy || model.hasPendingSave || !model.agreedToLoginTerms || !model.hasLoginTerms)
                }
            }
            if model.emailContinuationActive {
                Text("请在海外邮箱入口继续完成当前账号的资料与验证。").font(.caption).foregroundStyle(.secondary)
            } else { OfficialLoginContinuationPanel(model: model) }
        }
    }
}

@MainActor
struct OfficialLoginContinuationPanel: View {
    @ObservedObject var model: OfficialAccountModel
    @State private var confirmRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.loginStep == .profile {
                TextField("账号昵称", text: $model.nicknameDraft).disabled(model.busy)
                if model.needsLoginBirthday {
                    TextField("生日 yyyy-MM-dd", text: $model.loginBirthdayDraft).disabled(model.busy)
                    Text("海外账号补充资料要求年满 16 周岁。").font(.caption).foregroundStyle(.secondary)
                }
                Button("保存资料并继续") { Task { await model.submitLoginProfile() } }
                    .disabled(model.busy || model.hasPendingSave || model.nicknameDraft.isEmpty)
            }
            if model.loginStep == .identity {
                Picker("证件类型", selection: $model.identityTypeDraft) {
                    Text("居民身份证").tag(0)
                    Text("港澳居民居住证").tag(1)
                }.disabled(model.busy)
                TextField("姓名", text: $model.identityNameDraft).disabled(model.busy)
                SecureField("证件号码", text: $model.identityNumberDraft).disabled(model.busy)
                Text("点击提交会将姓名、证件号码和账号手机号发送给雷鸟官方实名服务；这些资料不写入本地会话。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("提交实名资料并继续") { Task { await model.submitLoginIdentity() } }
                    .disabled(model.busy || model.hasPendingSave || model.identityNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.identityNumberDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("重新查询实名状态") { Task { await model.retryLoginVerification() } }.disabled(model.busy)
            }
            if model.loginStep == .cooling {
                Button("取消注销并恢复账号") { confirmRestore = true }.disabled(model.busy)
            }
            if model.loginStep == .ready {
                Button("继续保存本次登录") { Task { await model.saveReadyLogin() } }
                    .disabled(model.busy || model.hasPendingSave)
            }
            if model.loginStep != .phone {
                Button("取消本次注册／登录") { model.cancelPhoneLogin() }.disabled(model.busy || model.hasPendingSave)
                if model.hasPendingSave { Text("本次会话等待钥匙串保存，请先在上方重试保存或明确清除本机会话。").font(.caption).foregroundStyle(.secondary) }
            }
            Text(model.loginNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .alert("取消注销并恢复这个账号？", isPresented: $confirmRestore) {
            Button("返回", role: .cancel) { }
            Button("恢复账号") { Task { await model.restoreCoolingAccount() } }
        } message: {
            Text("这会向雷鸟官方服务撤销当前账号的注销申请，然后继续本次登录。")
        }
    }
}
