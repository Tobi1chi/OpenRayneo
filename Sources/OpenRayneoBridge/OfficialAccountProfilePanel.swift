// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct OfficialAccountProfilePanel: View {
    @ObservedObject var model: OfficialAccountModel
    @State private var avatar: AvatarSelection?
    @State private var imageNotice = ""
    private struct AvatarSelection: Identifiable { let id = UUID(); let image: NSImage; let account: UUID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile = model.profile {
                if let name = profile.nickname { LabeledContent("昵称", value: name) }
                if let email = profile.email { LabeledContent("邮箱", value: email) }
                if let phone = profile.phone { LabeledContent("手机号", value: phone) }
                if let country = profile.countryCode { LabeledContent("国家／地区", value: country.uppercased()) }
                if let address = profile.avatar, let url = URL(string: address), url.scheme == "https" {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                        placeholder: { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary) }
                        .frame(width: 68, height: 68).clipShape(Circle())
                }
                Text("资料保存于 " + profile.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("尚无可显示的账号资料。登录或更新资料后会显示。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("新昵称", text: $model.profileNicknameDraft)
                Button("保存昵称") { Task { await model.saveNickname() } }
                    .disabled(model.busy || !model.canManageProfile || model.profileNicknameDraft.isEmpty)
            }
            HStack {
                Button("选择并裁剪头像…") { chooseAvatar() }.disabled(model.busy)
                if model.hasPendingProfile {
                    Button("重试保存已更新的资料") { Task { await model.retryProfileSave() } }.disabled(model.busy)
                }
            }
            if !model.canManageProfile { Text("登录官方账号后可以保存昵称与头像。").font(.caption).foregroundStyle(.secondary) }
            if !imageNotice.isEmpty { Text(imageNotice).font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 8)
        .sheet(item: $avatar) { selection in OfficialAvatarEditor(model: model, source: selection.image, account: selection.account) }
        .onChange(of: model.accountGeneration) { _ in avatar = nil; imageNotice = "" }
    }
    private func chooseAvatar() {
        let account = model.accountGeneration
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif, .icns]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard model.accountGeneration == account else { return }
        guard let image = NSImage(contentsOf: url) else { imageNotice = "无法读取这张图片。"; return }
        imageNotice = ""; avatar = AvatarSelection(image: image, account: account)
    }
}

enum OfficialAvatarCrop {
    static func jpeg(_ source: NSImage, zoom: Double, x: Double, y: Double, quarterTurns: Int) throws -> Data {
        guard let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OfficialAccountFailure(message: "无法准备头像图片。")
        }
        let width = Double(image.width), height = Double(image.height)
        let rotatedWidth = quarterTurns % 2 == 0 ? width : height
        let rotatedHeight = quarterTurns % 2 == 0 ? height : width
        let scale = max(512 / rotatedWidth, 512 / rotatedHeight) * zoom
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.interpolationQuality = .high
        context.translateBy(x: 256 - (rotatedWidth * scale - 512) * (x - 0.5),
                            y: 256 - (rotatedHeight * scale - 512) * (y - 0.5))
        context.rotate(by: Double(quarterTurns) * .pi / 2)
        context.scaleBy(x: scale, y: scale)
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        guard let result = context.makeImage(), let jpeg = NSBitmapImageRep(cgImage: result)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw OfficialAccountFailure(message: "无法导出头像 JPEG。")
        }
        return jpeg
    }
}

@MainActor
private struct OfficialAvatarEditor: View {
    @ObservedObject var model: OfficialAccountModel
    let source: NSImage
    let account: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var turns = 0
    @State private var notice = ""
    private var preview: NSImage? {
        (try? OfficialAvatarCrop.jpeg(source, zoom: zoom, x: x, y: y, quarterTurns: turns)).flatMap(NSImage.init(data:))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("裁剪头像").font(.title2.weight(.semibold))
            if let preview { Image(nsImage: preview).resizable().frame(width: 230, height: 230).clipShape(Circle()).frame(maxWidth: .infinity) }
            LabeledContent("缩放") { Slider(value: $zoom, in: 1...3) }
            LabeledContent("水平位置") { Slider(value: $x, in: 0...1) }
            LabeledContent("垂直位置") { Slider(value: $y, in: 0...1) }
            Button("旋转 90°") { turns = (turns + 1) % 4 }
            Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("保存为官方头像") {
                    do {
                        let jpeg = try OfficialAvatarCrop.jpeg(source, zoom: zoom, x: x, y: y, quarterTurns: turns)
                        Task { if await model.uploadAvatar(jpeg, expectedAccount: account) { dismiss() } }
                    } catch { notice = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(model.busy || !model.canManageProfile)
            }
        }.padding(22).frame(width: 440)
    }
}
