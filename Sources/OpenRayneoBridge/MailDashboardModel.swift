// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon
import Combine
import Foundation

enum MailDashboardProvider: String, CaseIterable, Identifiable, Codable {
    case gmail, outlook
    var id: String { rawValue }
    var wireID: String { self == .gmail ? "1" : "2" }
    var label: String { self == .gmail ? "Gmail 卡片" : "Outlook 卡片" }
}

struct MailDashboardAccount: Codable, Identifiable {
    let id: String
    let name: String
    let addresses: [String]
    let enabled: Bool
    let mailboxes: [[String]]
    var label: String { name + (addresses.isEmpty ? "" : " · " + addresses.joined(separator: ", ")) }
}

struct MailDashboardSelection: Codable, Equatable {
    var accountID: String
    var mailbox: [String] = []
    var complete: Bool { !accountID.isEmpty && !mailbox.isEmpty }
}

struct MailDashboardSnapshot: Codable {
    let selection: MailDashboardSelection
    let unread: Int
    let sender: String
    let senderName: String
    let subject: String
    let preview: String
    let receivedAt: Date?
    let fetchedAt: Date

    var mail: [String: Any]? {
        guard unread > 0, let receivedAt else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdHm")
        return ["sender": sender, "sender_name": senderName, "title": subject,
                "preview": preview, "time": formatter.string(from: receivedAt)]
    }
}

private struct MailDashboardSaved: Codable {
    var accounts: [MailDashboardAccount]
    var selections: [String: MailDashboardSelection]
    var snapshots: [String: MailDashboardSnapshot]
}

private struct MailDashboardFailure: LocalizedError {
    let message: String
    var code = 0
    var errorDescription: String? { message }
}

@MainActor
final class MailDashboardModel: ObservableObject {
    @Published private(set) var accounts: [MailDashboardAccount] = []
    @Published private(set) var selections: [String: MailDashboardSelection] = [:]
    @Published private(set) var snapshots: [String: MailDashboardSnapshot] = [:]
    @Published private(set) var authorized = false
    @Published private(set) var busy = false
    @Published private(set) var notice = "点击授权按钮读取 Apple Mail 账户目录，再选择要同步的账户和邮箱。"
    @Published var automatic = false {
        didSet {
            defaults.set(automatic, forKey: "mailDashboardAutomatic")
            if automatic { requestAutomaticRefresh(force: true) }
            else { automaticTask?.cancel() }
        }
    }
    @Published var refreshSeconds = 300 {
        didSet {
            defaults.set(refreshSeconds, forKey: "mailDashboardRefreshSeconds")
            requestAutomaticRefresh()
        }
    }

    private weak var bridge: DesktopBridge?
    private let reader = AppleMailDashboardReader()
    private let defaults = UserDefaults.standard
    private var subscriptions = Set<AnyCancellable>()
    private var automaticTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var permissionBlocked = false
    private var accessRequested = false

    init(bridge: DesktopBridge) {
        self.bridge = bridge
        if let data = defaults.data(forKey: "mailDashboardSources"),
           let saved = try? JSONDecoder().decode(MailDashboardSaved.self, from: data) {
            accounts = saved.accounts
            selections = saved.selections
            snapshots = saved.snapshots
        }
        accessRequested = defaults.bool(forKey: "mailDashboardAccessRequested")
        automatic = defaults.bool(forKey: "mailDashboardAutomatic")
        let interval = defaults.integer(forKey: "mailDashboardRefreshSeconds")
        if [60, 300, 900].contains(interval) { refreshSeconds = interval }
        bridge.$connected.dropFirst().sink { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                if connected { self?.requestAutomaticRefresh(force: true) }
                else { self?.automaticTask?.cancel() }
            }
        }.store(in: &subscriptions)
        bridge.$selectedAddress.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.automaticTask?.cancel()
                self?.requestAutomaticRefresh(force: true)
            }
        }.store(in: &subscriptions)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestAutomaticRefresh() }
        }.store(in: &subscriptions)
        requestAutomaticRefresh()
    }

    var connected: Bool { bridge?.connected == true }
    var hasSelection: Bool { selections.values.contains { $0.complete } }
    var hasMatchingPreview: Bool {
        MailDashboardProvider.allCases.contains { provider in
            guard let snapshot = snapshots[provider.rawValue] else { return false }
            return snapshot.selection == selections[provider.rawValue]
        }
    }
    var accessDescription: String {
        if authorized { return "已允许读取 Apple Mail；只读所选邮箱，不更改邮件的已读状态。" }
        if permissionBlocked { return "Apple Mail 自动化权限不可用，后台读取已停止；请通过授权按钮重新检查。" }
        return "尚未确认 Apple Mail 自动化权限；自动刷新不会弹出授权请求。"
    }

    func selection(_ provider: MailDashboardProvider) -> MailDashboardSelection {
        selections[provider.rawValue] ?? MailDashboardSelection(accountID: "")
    }

    func setAccount(_ id: String, for provider: MailDashboardProvider) {
        selections[provider.rawValue] = MailDashboardSelection(accountID: id)
        configurationChanged()
    }

    func setMailbox(_ path: [String], for provider: MailDashboardProvider) {
        var value = selection(provider)
        value.mailbox = path
        selections[provider.rawValue] = value
        configurationChanged()
    }

    private func configurationChanged() {
        automaticTask?.cancel()
        persist()
        requestAutomaticRefresh(force: true)
    }

    // Only this explicit button action launches Mail and requests automation permission.
    func authorizeAndReadAccounts() async {
        guard !busy else { return }
        busy = true
        automaticTask?.cancel()
        defer { busy = false }
        do {
            notice = "正在连接 Apple Mail 并检查授权…"
            if !reader.running {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
                    throw MailDashboardFailure(message: "这台 Mac 未找到 Apple Mail。")
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            accessRequested = true
            defaults.set(true, forKey: "mailDashboardAccessRequested")
            try reader.checkPermission(prompt: true)
            authorized = true
            permissionBlocked = false
            accounts = try reader.readAccounts()
            persist()
            notice = "已读取 \(accounts.count) 个账户的目录。请明确选择来源账户及邮箱文件夹；尚未读取邮件正文。"
        } catch { handle(error) }
    }

    func refresh(synchronize: Bool = false, automatically: Bool = false) async {
        guard !busy, hasSelection else { return }
        guard existingPermission() else { return }
        busy = true
        lastAttempt = Date()
        let expectedAddress = bridge?.selectedAddress
        let expectedSelections = selections
        defer { busy = false }
        do {
            var next = snapshots
            for provider in MailDashboardProvider.allCases {
                guard let selection = expectedSelections[provider.rawValue], selection.complete else { continue }
                try Task.checkCancellation()
                notice = "正在读取 \(provider.label) 所选邮箱的未读摘要…"
                await Task.yield()
                next[provider.rawValue] = try reader.readSnapshot(selection)
            }
            try Task.checkCancellation()
            guard selections == expectedSelections else {
                notice = "来源选择已变化，本次读取结果未采用。"
                return
            }
            snapshots = next
            persist()
            notice = "已更新 Mac 预览，仅保留每个来源最新一封未读邮件的摘要。"
            if synchronize, connected, bridge?.selectedAddress == expectedAddress, !automatically || automatic {
                await pushPreview(expectedAddress: expectedAddress)
            }
        } catch {
            handle(error)
            if !(error is CancellationError) { notice += " 原有手工内容与缓存摘要已保留，未同步到眼镜。" }
        }
    }

    func pushPreview() async {
        guard !busy, connected, hasMatchingPreview else { return }
        busy = true
        defer { busy = false }
        await pushPreview(expectedAddress: bridge?.selectedAddress)
    }

    private func pushPreview(expectedAddress: String?) async {
        guard let bridge, bridge.connected, bridge.selectedAddress == expectedAddress, !Task.isCancelled else { return }
        do {
            let result = try await bridge.request("/v1/glasses/cards", body: ["command": "mail_update",
                "items": dashboardItems()])
            notice = result["acknowledged"] as? Bool == true
                ? "眼镜已确认收到邮件摘要；请在眼镜端查看显示。"
                : "邮件摘要已发送，尚未收到眼镜确认。"
        } catch { notice = "同步失败，Mac 预览已保留：\(error.localizedDescription)" }
    }

    func dashboardItems() -> [[String: Any]] {
        guard let bridge else { return [] }
        // Preserve manually maintained providers; replace only explicitly mapped, matching previews.
        var providers: [String: [String: Any]] = [:]
        for item in bridge.dashboardCards.mails {
            let id = item["provider_id"] as? String ?? "1"
            guard ["1", "2"].contains(id), providers[id] == nil else { continue }
            let mail = item.filter { !["provider", "provider_id", "unread"].contains($0.key) }
            let unread = item["unread"] as? Int ?? 0
            providers[id] = ["provider": id == "2" ? "outlook" : "gmail", "provider_id": id,
                             "unread": unread, "mails": unread > 0 ? [mail] : []]
        }
        for provider in MailDashboardProvider.allCases {
            guard let preview = snapshots[provider.rawValue], preview.selection == selections[provider.rawValue] else { continue }
            providers[provider.wireID] = ["provider": provider.rawValue, "provider_id": provider.wireID,
                                         "unread": preview.unread, "mails": preview.mail.map { [$0] } ?? []]
        }
        return providers.keys.sorted().compactMap { providers[$0] }
    }

    private func existingPermission() -> Bool {
        guard accessRequested, !permissionBlocked else {
            notice = "请先点击“授权并读取 Apple Mail 账户”。"
            return false
        }
        guard reader.running else { notice = "请先打开 Apple Mail；后台不会启动它或请求授权。"; return false }
        do { try reader.checkPermission(prompt: false); authorized = true; return true }
        catch { handle(error); return false }
    }

    private func requestAutomaticRefresh(force: Bool = false) {
        guard automatic, connected, hasSelection, accessRequested, !permissionBlocked, reader.running, !busy else { return }
        guard force || lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) >= Double(refreshSeconds) else { return }
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, automatic, connected else { return }
            await refresh(synchronize: true, automatically: true)
        }
    }

    private func handle(_ error: Error) {
        if error is CancellationError { notice = "已取消邮件读取；原摘要已保留。"; return }
        if let failure = error as? MailDashboardFailure, [-1743, -1744].contains(failure.code) {
            authorized = false
            permissionBlocked = true
            automaticTask?.cancel()
        }
        notice = error.localizedDescription
    }

    private func persist() {
        let saved = MailDashboardSaved(accounts: accounts, selections: selections, snapshots: snapshots)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "mailDashboardSources") }
    }
}

/// Terms and object relationships checked against macOS Mail.app/Contents/Resources/Mail.sdef.
/// Scripts only read account/mailbox/message properties and extract sender name/address.
@MainActor
private final class AppleMailDashboardReader {
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty }

    func checkPermission(prompt: Bool) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), prompt)
        guard status == noErr else {
            throw MailDashboardFailure(message: "无法读取 Apple Mail（自动化权限状态 \(status)）。请在系统设置 → 隐私与安全性 → 自动化中允许 OpenRayneo 访问 Mail。", code: Int(status))
        }
    }

    func readAccounts() throws -> [MailDashboardAccount] {
        let result = try execute(Self.directoryScript, handler: "readaccounts")
        guard result.descriptorType == DescType(typeAEList) else {
            throw MailDashboardFailure(message: "Apple Mail 未返回账户目录列表。")
        }
        return try list(result).map { row in
            guard row.numberOfItems == 5,
                  let id = row.atIndex(1)?.stringValue, let name = row.atIndex(2)?.stringValue else {
                throw MailDashboardFailure(message: "Apple Mail 账户目录返回格式不完整，已保留原目录。")
            }
            let folders = list(row.atIndex(5)).map { list($0).compactMap(\.stringValue) }.filter { !$0.isEmpty }
            return MailDashboardAccount(id: id, name: name, addresses: list(row.atIndex(3)).compactMap(\.stringValue),
                enabled: row.atIndex(4)?.booleanValue == true, mailboxes: folders)
        }
    }

    func readSnapshot(_ selection: MailDashboardSelection) throws -> MailDashboardSnapshot {
        let path = NSAppleEventDescriptor.list()
        for (index, name) in selection.mailbox.enumerated() { path.insert(NSAppleEventDescriptor(string: name), at: index + 1) }
        let result = try execute(Self.summaryScript, handler: "readsummary",
            arguments: [NSAppleEventDescriptor(string: selection.accountID), path])
        guard result.numberOfItems == 6, let count = result.atIndex(1), count.int32Value >= 0 else {
            throw MailDashboardFailure(message: "Apple Mail 摘要返回格式不完整。")
        }
        let unread = Int(count.int32Value)
        var date: Date?
        if unread > 0 {
            let parts = list(result.atIndex(6)).map { Int($0.int32Value) }
            guard parts.count == 6 else { throw MailDashboardFailure(message: "Apple Mail 未提供可用的邮件时间。") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]))
            guard date != nil else { throw MailDashboardFailure(message: "Apple Mail 的邮件时间无法解析。") }
        }
        let text = result.atIndex(5)?.stringValue ?? ""
        var units = Array(text.utf16.prefix(150))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return MailDashboardSnapshot(selection: selection, unread: unread,
            sender: result.atIndex(2)?.stringValue ?? "", senderName: result.atIndex(3)?.stringValue ?? "",
            subject: result.atIndex(4)?.stringValue ?? "", preview: String(decoding: units, as: UTF16.self),
            receivedAt: date, fetchedAt: Date())
    }

    private func list(_ descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
        guard let descriptor, descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    private func execute(_ source: String, handler: String, arguments: [NSAppleEventDescriptor] = []) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw MailDashboardFailure(message: "无法创建 Apple Mail 只读脚本。") }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let params = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { params.insert(argument, at: index + 1) }
        event.setParam(params, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "Apple Mail 读取失败。"
            throw MailDashboardFailure(message: "\(message)（\(code)）", code: code)
        }
        return result
    }

    private static let directoryScript = #"""
    on folderPaths(folderList, prefixPath)
        set outputPaths to {}
        tell application id "com.apple.mail"
            repeat with aFolder in folderList
                set currentPath to prefixPath & {(name of aFolder) as text}
                set end of outputPaths to currentPath
                set outputPaths to outputPaths & my folderPaths((mailboxes of aFolder), currentPath)
            end repeat
        end tell
        return outputPaths
    end folderPaths

    on readAccounts()
        with timeout of 20 seconds
            set outputRows to {}
            tell application id "com.apple.mail"
                repeat with anAccount in accounts
                    set enabledState to enabled of anAccount
                    set accountFolders to {}
                    if enabledState then set accountFolders to my folderPaths((mailboxes of anAccount), {})
                    set end of outputRows to {(id of anAccount) as text, (name of anAccount) as text, email addresses of anAccount, enabledState, accountFolders}
                end repeat
            end tell
            return outputRows
        end timeout
    end readAccounts
    """#

    private static let summaryScript = #"""
    on readSummary(accountID, folderPath)
        with timeout of 20 seconds
            tell application id "com.apple.mail"
                set sourceAccount to first account whose id is accountID
                if not (enabled of sourceAccount) then error "所选 Mail 账户已停用。"
                set sourceBox to sourceAccount
                repeat with folderName in folderPath
                    set requestedName to contents of folderName
                    set sourceBox to first mailbox of sourceBox whose name is requestedName
                end repeat
                set unreadTotal to unread count of sourceBox
                if unreadTotal is 0 then return {0, "", "", "", "", {}}
                set unreadDates to date received of (messages of sourceBox whose read status is false)
                if (count of unreadDates) is 0 then error "Mail 尚未提供所选邮箱的未读邮件。"
                set newestDate to item 1 of unreadDates
                repeat with aDate in unreadDates
                    if (contents of aDate) > newestDate then set newestDate to contents of aDate
                end repeat
                set newestMessage to first message of sourceBox whose read status is false and date received is newestDate
                set senderText to sender of newestMessage
                set senderAddress to extract address from senderText
                set senderName to extract name from senderText
                set subjectText to subject of newestMessage
                set previewText to (content of newestMessage) as text
                if (count of characters of previewText) > 150 then set previewText to text 1 thru 150 of previewText
                set received to date received of newestMessage
                set dateParts to {year of received, (month of received) as integer, day of received, hours of received, minutes of received, seconds of received}
                return {unreadTotal, senderAddress, senderName, subjectText, previewText, dateParts}
            end tell
        end timeout
    end readSummary
    """#
}
