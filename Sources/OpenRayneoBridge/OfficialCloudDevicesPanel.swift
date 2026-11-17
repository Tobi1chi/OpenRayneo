// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import Network
import SwiftUI

@MainActor
final class OfficialCloudDevicesModel: ObservableObject {
    @Published private(set) var items: [OfficialCloudDevice] = []
    @Published private(set) var busy = false
    @Published private(set) var configured = false
    @Published private(set) var accountGeneration = UUID()
    @Published private(set) var notice = "登录官方账号后，读取云端设备和绑定关系。"
    @Published private(set) var bindingStatus: OfficialDeviceBindingStatus?
    @Published private(set) var cloudUnbindState = "尚未执行"
    @Published private(set) var eraseState = "尚未执行"
    @Published private(set) var localUnpairState = "尚未执行"
    @Published private(set) var canResumeLocalUnbind = false
    @Published private(set) var cachedDeviceCount = 0
    @Published private(set) var pendingBindCount = 0
    @Published private(set) var cacheNotice: String?
    @Published var macDraft = ""
    @Published var glassesIDDraft = ""
    @Published var nameDraft = ""
    @Published var typeDraft = "6"
    @Published var serialDraft = ""
    @Published var mfiSerialDraft = ""
    @Published var bondKeyDraft = ""
    private weak var bridge: DesktopBridge?
    private var service: OfficialCloudDeviceService?
    private var serviceConfiguration: OfficialFirmwareConfiguration?
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var subscription: AnyCancellable?
    private var cloudUnboundDevices: Set<String> = []
    private var localUnbindContinuation: (address: String, account: UUID)?
    private let repository = OfficialCloudDeviceRepository()
    private var repositoryResetPending = false
    private var flushRequested = false
    private let networkMonitor = NWPathMonitor()

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        reloadAccount()
        updateRepositoryCounts()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in self?.requestPendingFlush() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "openrayneo.cloud-device-network"))
        subscription = NotificationCenter.default.publisher(for: .officialAccountSessionChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.task?.cancel(); self.operationID = UUID(); self.busy = false
                self.accountGeneration = UUID()
                self.items = []; self.bindingStatus = nil; self.bondKeyDraft = ""
                self.cloudUnboundDevices = []; self.localUnbindContinuation = nil; self.canResumeLocalUnbind = false
                self.flushRequested = false
                self.repositoryResetPending = true
                do { try self.prepareRepository() }
                catch { self.notice = error.localizedDescription }
                self.cloudUnbindState = "尚未执行"; self.eraseState = "尚未执行"; self.localUnpairState = "尚未执行"
                self.reloadAccount()
            }
        }
    }

    deinit { networkMonitor.cancel() }

    private func reloadAccount() {
        do {
            let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
            configured = !configuration.accessToken.isEmpty
            service = OfficialCloudDeviceService(configuration: configuration)
            serviceConfiguration = configuration
            notice = configured ? "读取当前账号的官方云设备列表。" : "尚未配置官方账号，请先登录或导入已有会话。"
        } catch { configured = false; service = nil; serviceConfiguration = nil; notice = error.localizedDescription }
    }

    func useSelectedLocalDevice() {
        guard !busy, let device = bridge?.selectedDevice else { return }
        nameDraft = device.name; macDraft = device.id
        if let type = device.deviceType { typeDraft = type }
        glassesIDDraft = ""; serialDraft = ""; bondKeyDraft = ""
        mfiSerialDraft = OfficialCloudDeviceRepository.Record.normalizedMAC(device.id)
            .map(OfficialCloudDeviceRepository.Record.nativeID(normalizedMAC:)) ?? ""
        bindingStatus = nil
        notice = "已填入 Mac 配对记录中的名称和经典蓝牙 MAC；其余标识需使用真实设备记录。"
    }

    func refresh() {
        guard let service, configured else { return }
        perform("正在读取官方云设备…") {
            let rows = try await service.list()
            try Task.checkCancellation()
            self.items = rows
            do {
                try self.prepareRepository(); try self.repository.mergeCloud(rows); self.updateRepositoryCounts()
                self.notice = "已读取 \(rows.count) 条官方云设备记录并合并同步资料。"
            } catch { self.notice = "云列表已读取，本地同步资料未能更新：" + error.localizedDescription }
        }
    }

    func checkBinding() {
        guard let service, configured else { return }
        let mac = nonempty(macDraft), id = nonempty(glassesIDDraft)
        guard mac != nil || id != nil else { notice = "请提供真实的设备 MAC 或眼镜设备 ID。"; return }
        perform("正在查询官方绑定关系…") {
            let result = try await service.checkBinding(macAddress: mac, glassesDeviceID: id)
            try Task.checkCancellation()
            self.bindingStatus = result; self.notice = result.statusDescription
        }
    }

    func bindDraft(expectedAccount: UUID) {
        guard expectedAccount == accountGeneration else { notice = "官方账号已变化，请重新确认绑定。"; return }
        guard let service, let configuration = serviceConfiguration, configured else { return }
        let device = OfficialCloudDevice(sn: serialDraft.trimmingCharacters(in: .whitespacesAndNewlines), deviceType: typeDraft, deviceName: nameDraft,
            mfiSerialNumber: mfiSerialDraft.trimmingCharacters(in: .whitespacesAndNewlines), bondKey: bondKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            macAddr: macDraft, glassesDeviceId: glassesIDDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        perform("正在绑定到当前官方账号…") {
            try self.repository.suppressAutomaticBinding(mac: device.macAddr ?? "", identity: configuration)
            self.updateRepositoryCounts()
            let accepted = try await service.bind(device)
            try Task.checkCancellation()
            self.replacedUnbindIntent(mac: device.macAddr ?? "")
            self.bondKeyDraft = ""
            self.notice = accepted ? "绑定请求已完成。" : "绑定请求已完成，服务端结果为 false，请以云端列表为准。"
            do {
                try self.prepareRepository(); try self.repository.remove(mac: device.macAddr ?? "")
                try self.repository.allowAutomaticBinding(mac: device.macAddr ?? "", identity: configuration); self.updateRepositoryCounts()
            } catch { self.notice += "本地同步资料未能更新：" + error.localizedDescription; return }
            do {
                let rows = try await service.list()
                try Task.checkCancellation()
                self.items = rows
                try self.prepareRepository(); try self.repository.mergeCloud(rows); self.updateRepositoryCounts()
                self.notice += "已重新读取云端设备列表。"
            } catch { if !Task.isCancelled { self.notice += "列表刷新失败，请稍后重新读取。" } }
        }
    }

    func localAddress(for device: OfficialCloudDevice) -> String? {
        guard let mac = device.macAddr else { return nil }
        return bridge?.devices.first { Self.mac($0.id) == Self.mac(mac) }?.id
    }

    var localOperationAvailable: Bool {
        guard let bridge else { return false }
        return !bridge.busy && !bridge.stopping && !bridge.pairingActive && !bridge.officialDeviceOperationActive
    }

    func unbind(_ device: OfficialCloudDevice, eraseAndUnpair: Bool, expectedAccount: UUID) {
        guard expectedAccount == accountGeneration else { notice = "官方账号已变化，请重新读取设备列表。"; return }
        guard let service, let configuration = serviceConfiguration, configured else { return }
        let address = localAddress(for: device)
        if eraseAndUnpair, address == nil { notice = "这条云记录没有匹配的 Mac 配对，无法对其执行本机清理。"; return }
        if eraseAndUnpair, let continuation = localUnbindContinuation, let address,
           continuation.account == expectedAccount, Self.mac(continuation.address) == Self.mac(address) {
            resumeLocalUnbind(); return
        }
        perform("正在解除官方云绑定…") {
            let bridge = self.bridge
            if eraseAndUnpair, let bridge { try bridge.beginOfficialDeviceOperation() }
            defer { if eraseAndUnpair { bridge?.endOfficialDeviceOperation() } }
            var cacheCleanupIssue: String?
            self.cloudUnbindState = "正在请求"; self.eraseState = "尚未执行"; self.localUnpairState = "尚未执行"
            do {
                if !self.cloudUnboundDevices.contains(self.bindingKey(device)) {
                    if let mac = device.macAddr, OfficialCloudDeviceRepository.Record.normalizedMAC(mac) != nil {
                        try self.repository.suppressAutomaticBinding(mac: mac, identity: configuration)
                        self.updateRepositoryCounts()
                    }
                    try await service.unbind(device)
                    try Task.checkCancellation()
                    self.cloudUnboundDevices.insert(self.bindingKey(device))
                }
                self.cloudUnbindState = "官方云解绑已返回成功"
                if let mac = device.macAddr, OfficialCloudDeviceRepository.Record.normalizedMAC(mac) != nil {
                    do { try self.prepareRepository(); try self.repository.remove(mac: mac); self.updateRepositoryCounts() }
                    catch { cacheCleanupIssue = error.localizedDescription }
                }
            } catch {
                if !Task.isCancelled { self.cloudUnbindState = "云解绑未确认：" + error.localizedDescription }
                throw error
            }
            if eraseAndUnpair, let address, let bridge {
                self.localUnbindContinuation = (address, self.accountGeneration)
                self.canResumeLocalUnbind = true
                if bridge.isConnected(toOfficialMAC: device.macAddr) {
                    do {
                        try await bridge.eraseForOfficialUnbind(address: address)
                        try Task.checkCancellation()
                        self.eraseState = "眼镜已明确确认清除"
                    } catch {
                        if Task.isCancelled { throw error }
                        self.eraseState = "清除未确认：" + error.localizedDescription
                    }
                } else { self.eraseState = "目标眼镜未连接，未发送清除命令" }
                try Task.checkCancellation()
                do {
                    try await bridge.removeOfficialLocalPairing(address: address)
                    try Task.checkCancellation()
                    try self.prepareRepository(); try self.repository.remove(mac: address); self.updateRepositoryCounts()
                    self.localUnpairState = "Mac 配对已移除并独立确认"
                    self.localUnbindContinuation = nil; self.canResumeLocalUnbind = false
                } catch {
                    if Task.isCancelled { throw error }
                    self.localUnpairState = "Mac 清理未完成：" + error.localizedDescription
                }
            }
            self.notice = eraseAndUnpair ? "解绑流程已结束，请分别查看云端、眼镜和 Mac 的结果。" : "官方云解绑已返回成功。"
            if !eraseAndUnpair, let cacheCleanupIssue {
                self.notice += "自动绑定已暂停，本地同步记录尚未清理：" + cacheCleanupIssue
            }
            do {
                let rows = try await service.list()
                try Task.checkCancellation()
                self.items = rows
            } catch { if !Task.isCancelled { self.notice += "云列表刷新失败，原列表保留。" } }
        }
    }

    func resumeLocalUnbind() {
        guard let continuation = localUnbindContinuation, continuation.account == accountGeneration, let bridge else { return }
        perform("正在继续 Mac 配对清理…") {
            try bridge.beginOfficialDeviceOperation()
            defer { bridge.endOfficialDeviceOperation() }
            try await bridge.removeOfficialLocalPairing(address: continuation.address)
            try Task.checkCancellation()
            try self.prepareRepository(); try self.repository.remove(mac: continuation.address); self.updateRepositoryCounts()
            self.localUnpairState = "Mac 配对已移除并独立确认"
            self.localUnbindContinuation = nil; self.canResumeLocalUnbind = false
            self.notice = "本机清理已完成；沿用此前云解绑和眼镜清除结果。"
        }
    }

    func recordPairedDevice(_ device: PairedGlasses) {
        replacedUnbindIntent(mac: device.id)
        do {
            try prepareRepository(); try repository.recordPairing(device)
            updateRepositoryCounts()
            requestPendingFlush()
        } catch { notice = "Mac 配对已完成，云绑定资料尚未保存：" + error.localizedDescription }
    }

    func recordDeviceName(address: String, name: String) {
        do {
            try prepareRepository()
            if try repository.recordName(address: address, name: name) {
                updateRepositoryCounts(); requestPendingFlush()
            }
        } catch { notice = "设备名称同步资料未保存：" + error.localizedDescription }
    }

    func requestPendingFlush() {
        guard configured, !repositoryResetPending, !repository.pending().isEmpty else { return }
        guard let configuration = try? OfficialFirmwareConfiguration.fromEnvironment(), !configuration.accountID.isEmpty else { return }
        flushRequested = true
        if !busy { flushPendingBinds() }
    }

    func flushPendingBinds() {
        guard let service, configured, !busy else { return }
        flushRequested = false
        perform("正在补偿同步已配对设备的云绑定…") {
            try self.prepareRepository()
            var count = 0
            for record in self.repository.pending() where !self.cloudUnboundDevices.contains(Self.mac(record.address)) {
                _ = try await service.bind(record.outbound)
                try Task.checkCancellation()
                // The official caller confirms TclSuccess even when its Boolean data is false.
                try self.repository.confirm(record)
                count += 1
            }
            self.updateRepositoryCounts()
            self.notice = "本次完成 \(count) 条云绑定同步。可重新读取云端列表确认记录。"
        }
    }

    private func prepareRepository() throws {
        if repositoryResetPending {
            try repository.clear(); repositoryResetPending = false
        } else if repository.loadError != nil { try repository.reload() }
        try repository.synchronizeIdentity()
        updateRepositoryCounts()
    }

    private func updateRepositoryCounts() {
        cacheNotice = repositoryResetPending ? "账号已变化，本地设备同步资料等待清理。" : repository.loadError
        cachedDeviceCount = repositoryResetPending ? 0 : repository.records.count
        pendingBindCount = repositoryResetPending ? 0 : repository.pending().filter { !cloudUnboundDevices.contains(Self.mac($0.address)) }.count
    }

    private func bindingKey(_ device: OfficialCloudDevice) -> String {
        device.macAddr.flatMap(OfficialCloudDeviceRepository.Record.normalizedMAC) ?? device.id
    }

    private func replacedUnbindIntent(mac: String) {
        let mac = Self.mac(mac)
        cloudUnboundDevices.remove(mac)
        if localUnbindContinuation.map({ Self.mac($0.address) == mac }) == true {
            localUnbindContinuation = nil; canResumeLocalUnbind = false
        }
    }

    func preflightPairing(_ device: PairedGlasses) async throws {
        let configuration = try OfficialFirmwareConfiguration.fromEnvironment()
        guard !configuration.accessToken.isEmpty else { return }
        let client = OfficialCloudDeviceService(configuration: configuration)
        do {
            let status = try await client.checkBinding(macAddress: device.id, glassesDeviceID: nil)
            try Task.checkCancellation()
            let current = try OfficialFirmwareConfiguration.fromEnvironment()
            guard current.hasSameIdentity(as: configuration) else {
                throw OfficialCloudDeviceFailure(message: "官方账号已变化，请重新开始配对。")
            }
            if status.bindingOtherAccount { throw OfficialCloudDeviceFailure(message: status.statusDescription + "，请先解除原账号绑定。") }
        } catch let error as OfficialAccountFailure { throw error }
        catch let error as OfficialCloudDeviceFailure {
            switch error.kind {
            case .business, .authentication, .configuration: throw error
            case .invalidResponse, .http:
                try requireSamePairingAccount(configuration)
                notice = "官方绑定查询暂不可用，沿用官方异常分支继续本地配对。"
            }
        }
        catch let error as NSError where error.code == NSURLErrorTimedOut {
            throw OfficialCloudDeviceFailure(message: "官方绑定关系查询超时，请稍后重新配对。")
        } catch is CancellationError { throw CancellationError() }
        catch {
            try requireSamePairingAccount(configuration)
            notice = "云绑定关系查询暂不可用，沿用官方异常分支继续本地配对。"
        }
    }

    private func requireSamePairingAccount(_ expected: OfficialFirmwareConfiguration) throws {
        let current = try OfficialFirmwareConfiguration.fromEnvironment()
        guard current.hasSameIdentity(as: expected) else {
            throw OfficialAccountFailure(message: "官方账号已变化，请重新开始配对。")
        }
    }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID(); operationID = id; busy = true; notice = message
        task = Task {
            defer {
                if operationID == id {
                    busy = false; task = nil
                    if flushRequested { requestPendingFlush() }
                }
            }
            do { try Task.checkCancellation(); try await action() }
            catch { if operationID == id { notice = Task.isCancelled ? "操作已取消；已提交的云操作请重新查询确认。" : error.localizedDescription } }
        }
    }

    private func nonempty(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    static func mac(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
    }
}

@MainActor
struct OfficialCloudDevicesPanel: View {
    @ObservedObject var model: OfficialCloudDevicesModel
    @State private var confirmingDevice: OfficialCloudDevice?
    @State private var eraseAndUnpair = false
    @State private var confirmBind = false
    @State private var confirmationAccount = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("官方云端设备") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("读取云端设备列表") { model.refresh() }.disabled(model.busy || !model.configured)
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        if let error = model.cacheNotice {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("本地同步资料 \(model.cachedDeviceCount) 条 · 待绑定 \(model.pendingBindCount) 条")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("重试待绑定同步") { model.flushPendingBinds() }
                            .disabled(model.busy || !model.configured || model.pendingBindCount == 0)
                    }
                    ForEach(Array(model.items.enumerated()), id: \.offset) { _, device in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.deviceName ?? "未命名云设备").font(.headline)
                            Text("MAC：\(device.macAddr ?? "未提供") · 类型：\(device.deviceType ?? "未提供")").font(.caption)
                            if let sn = device.sn { Text("序列号：" + sn).font(.caption) }
                            if let id = device.glassesDeviceId { Text("眼镜设备 ID：" + id).font(.caption).textSelection(.enabled) }
                            Text(model.localAddress(for: device).map { "Mac 配对：" + $0 } ?? "Mac 中没有匹配的配对")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("仅解除云绑定…", role: .destructive) {
                                    confirmationAccount = model.accountGeneration
                                    eraseAndUnpair = false; confirmingDevice = device
                                }.disabled(model.busy)
                                if model.localAddress(for: device) != nil {
                                    Button("解绑、清除眼镜并移除 Mac 配对…", role: .destructive) {
                                        confirmationAccount = model.accountGeneration
                                        eraseAndUnpair = true; confirmingDevice = device
                                    }.disabled(model.busy || !model.localOperationAvailable)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                    if model.items.isEmpty { Text("暂无已读取的云设备记录。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("查询或绑定设备") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("填入当前 Mac 配对设备") { model.useSelectedLocalDevice() }.disabled(model.busy)
                    TextField("经典蓝牙 MAC", text: $model.macDraft)
                    TextField("眼镜设备 ID（如有真实记录）", text: $model.glassesIDDraft)
                    Button("查询官方绑定关系") { model.checkBinding() }.disabled(model.busy || !model.configured)
                    if let result = model.bindingStatus { Text(result.statusDescription).font(.callout) }
                    Divider()
                    TextField("设备名称", text: $model.nameDraft)
                    Picker("眼镜类型", selection: $model.typeDraft) {
                        Text("RayNeo iO（境内）").tag("6")
                        Text("RayNeo iO（国际）").tag("7")
                    }
                    TextField("序列号（可选）", text: $model.serialDraft)
                    DisclosureGroup("其他真实设备标识") {
                        TextField("云端 MFi 标识（可选）", text: $model.mfiSerialDraft)
                        SecureField("已有 bond key（可选）", text: $model.bondKeyDraft)
                    }
                    Button("绑定到当前官方账号…") { confirmationAccount = model.accountGeneration; confirmBind = true }
                        .disabled(model.busy || !model.configured || model.nameDraft.isEmpty || model.macDraft.isEmpty)
                    Text("Mac 的蓝牙 UUID 不能填作眼镜设备 ID。云端绑定与 Mac 本地配对分别记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).disabled(model.busy)
            }
            GroupBox("最近解绑结果") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("云端：" + model.cloudUnbindState)
                    Text("眼镜：" + model.eraseState)
                    Text("Mac：" + model.localUnpairState)
                    if model.canResumeLocalUnbind {
                        Button("继续 Mac 配对清理") { model.resumeLocalUnbind() }
                            .disabled(model.busy || !model.localOperationAvailable)
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .confirmationDialog(eraseAndUnpair ? "解除绑定并清除这个眼镜？" : "仅解除官方云绑定？", isPresented: Binding(
            get: { confirmingDevice != nil }, set: { if !$0 { confirmingDevice = nil } })) {
            if let device = confirmingDevice {
                Button(eraseAndUnpair ? "解绑并清除眼镜" : "解除云绑定", role: .destructive) {
                    model.unbind(device, eraseAndUnpair: eraseAndUnpair, expectedAccount: confirmationAccount); confirmingDevice = nil
                }
            }
        } message: {
            Text(eraseAndUnpair
                 ? "将解绑 \(confirmingDevice?.deviceName ?? "这个设备")（\(confirmingDevice?.macAddr ?? "未知 MAC")）。连接中的目标眼镜会被清除，包括尚未同步的录音、待办、日程和设置；随后移除其 Mac 配对。未连接时无法清除眼镜。此操作不可撤销。"
                 : "将从当前官方账号解除这个设备的云绑定。本次仅提交云解绑请求。")
        }
        .confirmationDialog("将这个设备绑定到当前官方账号？", isPresented: $confirmBind) {
            Button("绑定设备") { model.bindDraft(expectedAccount: confirmationAccount) }
        } message: { Text("将绑定 \(model.nameDraft)（\(model.macDraft)）。设备名称、类型、MAC 和已填写的标识将提交给雷鸟官方服务。") }
        .onReceive(NotificationCenter.default.publisher(for: .officialAccountSessionChanged)) { _ in
            confirmingDevice = nil; confirmBind = false
        }
    }
}
