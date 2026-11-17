// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import Darwin
import Foundation

struct NotificationSchemaColumn: Codable, Sendable {
    let name: String
    let type: String
}

struct NotificationSchemaTable: Codable, Sendable {
    let name: String
    let columns: [NotificationSchemaColumn]
}

struct NotificationMirrorSchema: Codable, Sendable {
    let tables: [NotificationSchemaTable]
}

struct NotificationMirrorSourceApp: Identifiable {
    let id: String
    let name: String
    let url: URL?
}

struct NotificationMirrorEvent: Identifiable, Sendable {
    let id: String
    let bundleID: String
    let appName: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
}

private struct NotificationMirrorIdentity: Hashable {
    let bundleID: String
    let notificationID: String
}

struct NotificationMirrorDelivery: Identifiable {
    let id = UUID()
    let event: NotificationMirrorEvent
    let outcome: String
}

/// Establishes a baseline before reading new records from explicitly selected applications.
protocol NotificationMirrorFeed: Sendable {
    var supportsContent: Bool { get }
    func supportsSchema(_ schema: NotificationMirrorSchema) -> Bool
    func inspectSchema() async throws -> NotificationMirrorSchema
    func start(bundleIDs: Set<String>) async throws
    func readNew() async throws -> [NotificationMirrorEvent]
}

private enum NotificationMirrorFailure: LocalizedError {
    case accessDenied
    case unavailable(String)
    case unsupportedSchema
    case invalidRecord(Int64)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "系统拒绝读取通知数据库。请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许当前 OpenRayneo App，退出并重新打开后再检查。"
        case .unavailable(let detail): return detail
        case .unsupportedSchema: return "当前通知数据库结构与已支持的 app/record 结构不一致，请导出结构后再适配。"
        case .invalidRecord(let id): return "新增通知记录 \(id) 无法按已知 plist req 结构解析；镜像已停止，尚未转发该记录。"
        }
    }
}

/// Discovers the database through usernoted's actual open files; never assumes a historical path.
/// Schema checks never read records. Content queries require a selected source and an enable-time baseline.
actor NotificationMirrorDatabaseProbe: NotificationMirrorFeed {
    nonisolated let supportsContent = true
    private var databasePath: String?
    private var selectedBundleIDs: Set<String> = []
    private var cursor: Int64?

    nonisolated func supportsSchema(_ schema: NotificationMirrorSchema) -> Bool {
        let columns = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.name, Set($0.columns.map(\.name))) })
        return Set(["app_id", "identifier"]).isSubset(of: columns["app"] ?? [])
            && Set(["rec_id", "app_id", "uuid", "data", "delivered_date", "request_date"]).isSubset(of: columns["record"] ?? [])
    }

    func inspectSchema() throws -> NotificationMirrorSchema {
        let pidText = try run("/usr/bin/pgrep", arguments: ["-u", String(getuid()), "-x", "usernoted"])
        guard let pid = pidText.split(whereSeparator: \.isNewline).compactMap({ Int($0) }).first else {
            throw NotificationMirrorFailure.unavailable("未找到当前用户的 usernoted，无法定位通知来源。")
        }
        let opened = try run("/usr/sbin/lsof", arguments: ["-n", "-P", "-p", String(pid), "-Fn"])
        let paths = opened.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("n/") else { return nil }
            let path = String(line.dropFirst())
            guard path.contains("/group.com.apple.usernoted/"), path.hasSuffix("/db") else { return nil }
            return path
        }
        guard let path = paths.first else {
            throw NotificationMirrorFailure.unavailable("未在 usernoted 的打开文件中确认通知数据库位置；没有使用猜测路径。")
        }
        databasePath = path
        let names = try query(path: path, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        var tables: [NotificationSchemaTable] = []
        for item in names {
            guard let name = item["name"] as? String else { continue }
            let quoted = name.replacingOccurrences(of: "'", with: "''")
            let columns = try query(path: path, sql: "SELECT name,type FROM pragma_table_info('\(quoted)') ORDER BY cid;")
            tables.append(.init(name: name, columns: columns.compactMap {
                guard let column = $0["name"] as? String else { return nil }
                return .init(name: column, type: $0["type"] as? String ?? "")
            }))
        }
        return .init(tables: tables)
    }

    func start(bundleIDs: Set<String>) throws {
        cursor = nil; selectedBundleIDs = []
        guard !bundleIDs.isEmpty else { throw NotificationMirrorFailure.unavailable("请先选择通知来源应用。") }
        let schema = try inspectSchema()
        guard supportsSchema(schema), let path = databasePath else { throw NotificationMirrorFailure.unsupportedSchema }
        let baseline = try query(path: path, sql: "SELECT COALESCE(MAX(rec_id),0) AS latest FROM record;")
        guard let latest = (baseline.first?["latest"] as? NSNumber)?.int64Value else {
            throw NotificationMirrorFailure.unavailable("无法建立通知新记录基线。")
        }
        selectedBundleIDs = bundleIDs; cursor = latest
    }

    func readNew() throws -> [NotificationMirrorEvent] {
        guard let path = databasePath, let cursor, !selectedBundleIDs.isEmpty else { return [] }
        let sources = selectedBundleIDs.sorted().map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let rows = try query(path: path, sql: """
            SELECT r.rec_id,a.identifier,hex(r.uuid) AS uuid_hex,hex(r.data) AS data_hex,
                   r.delivered_date,r.request_date
            FROM record AS r JOIN app AS a ON a.app_id=r.app_id
            WHERE r.rec_id>\(cursor) AND a.identifier IN (\(sources))
            ORDER BY r.rec_id LIMIT 100;
            """)
        var events: [NotificationMirrorEvent] = []
        for row in rows {
            guard let id = (row["rec_id"] as? NSNumber)?.int64Value,
                  let bundleID = row["identifier"] as? String, selectedBundleIDs.contains(bundleID),
                  let hex = row["data_hex"] as? String, let data = decodeHex(hex) else {
                throw NotificationMirrorFailure.unavailable("通知新记录字段无法读取。")
            }
            // Modern plist keys documented by mac_apt/plugins/notifications.py (Parse_ver_17_Db).
            // Use PropertyListSerialization, not unarchiving arbitrary classes from a private blob.
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let request = plist["req"] as? [String: Any] else { throw NotificationMirrorFailure.invalidRecord(id) }
            let textKeys = ["titl", "subt", "body"]
            guard textKeys.allSatisfy({ request[$0] == nil || request[$0] is String }) else {
                throw NotificationMirrorFailure.invalidRecord(id)
            }
            let uuid = row["uuid_hex"] as? String ?? ""
            let delivered = (row["delivered_date"] as? NSNumber)?.doubleValue ?? 0
            let requested = (row["request_date"] as? NSNumber)?.doubleValue ?? 0
            let date = Date(timeIntervalSinceReferenceDate: delivered > 0 ? delivered : requested)
            events.append(.init(id: uuid.isEmpty ? "mac-record-\(id)" : uuid.lowercased(), bundleID: bundleID, appName: bundleID,
                title: request["titl"] as? String ?? "", subtitle: request["subt"] as? String ?? "",
                body: request["body"] as? String ?? "", date: date))
            self.cursor = id
        }
        return events
    }

    private func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        func digit(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        var data = Data(capacity: bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = digit(bytes[offset]), let low = digit(bytes[offset + 1]) else { return nil }
            data.append(high << 4 | low)
        }
        return data
    }

    private func query(path: String, sql: String) throws -> [[String: Any]] {
        let output = try run("/usr/bin/sqlite3", arguments: ["-readonly", "-json", path, sql])
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else {
            throw NotificationMirrorFailure.unavailable("通知数据库的结构查询结果无法读取。")
        }
        return rows
    }

    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let text = output.lowercased()
            if text.contains("authorization denied") || text.contains("not permitted") || text.contains("permission denied") {
                throw NotificationMirrorFailure.accessDenied
            }
            throw NotificationMirrorFailure.unavailable("无法检查通知来源：\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}

@MainActor
final class NotificationMirrorModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var inspecting = false
    @Published private(set) var starting = false
    @Published private(set) var access = "未检查"
    @Published private(set) var notice = "通知镜像默认关闭。检查来源并选择应用后，手动开启以转发后续新通知。"
    @Published private(set) var schema: NotificationMirrorSchema?
    @Published private(set) var apps: [NotificationMirrorSourceApp] = []
    @Published private(set) var selectedBundleIDs: Set<String>
    @Published private(set) var deliveries: [NotificationMirrorDelivery] = []
    @Published private(set) var deliveredCount = 0
    @Published private(set) var duplicateCount = 0
    @Published var search = ""

    private weak var bridge: DesktopBridge?
    private let feed: any NotificationMirrorFeed
    private let defaults: UserDefaults
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private var seen: Set<NotificationMirrorIdentity> = []
    private var seenOrder: [NotificationMirrorIdentity] = []
    private var subscriptions = Set<AnyCancellable>()

    init(bridge: DesktopBridge, defaults: UserDefaults = .standard, feed: any NotificationMirrorFeed = NotificationMirrorDatabaseProbe()) {
        self.bridge = bridge; self.defaults = defaults; self.feed = feed
        selectedBundleIDs = Set(defaults.stringArray(forKey: "notificationMirrorSelectedApps") ?? [])
        refreshApps()
        bridge.$connected.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var connected: Bool { bridge?.connected == true }
    var contentAdapterAvailable: Bool { schema.map { feed.supportsContent && feed.supportsSchema($0) } ?? false }
    var canEnable: Bool { contentAdapterAvailable && !selectedBundleIDs.isEmpty && connected && !inspecting && !starting }
    var applicationPath: String { Bundle.main.bundleURL.path }
    var filteredApps: [NotificationMirrorSourceApp] {
        apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    func refreshApps() {
        var found: [String: NotificationMirrorSourceApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            found[id] = .init(id: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
        for id in selectedBundleIDs where found[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let bundle = url.flatMap(Bundle.init(url:))
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? id
            found[id] = .init(id: id, name: name, url: url)
        }
        apps = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func select(_ id: String, enabled: Bool) {
        stop()
        if enabled { selectedBundleIDs.insert(id) } else { selectedBundleIDs.remove(id) }
        defaults.set(selectedBundleIDs.sorted(), forKey: "notificationMirrorSelectedApps")
    }

    func inspect() async {
        guard !inspecting else { return }
        inspecting = true; access = "检查中"; defer { inspecting = false }
        do {
            schema = try await feed.inspectSchema()
            access = contentAdapterAvailable ? "来源可用" : "结构已读取，当前结构不受支持"
            notice = contentAdapterAvailable ? "已确认通知来源；选择应用后可手动启用。启用前不会读取通知正文。" : "已读取表与列信息，当前结构不受支持；可导出结构用于适配。"
        } catch {
            schema = nil; access = "来源不可用"; stop(); notice = error.localizedDescription
        }
    }

    func exportSchema() async {
        await inspect()
        guard let schema else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OpenRayneo-notification-schema.json"
        panel.message = "仅导出通知数据库的表名、列名与类型，不包含任何通知行或正文。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(schema).write(to: url, options: .atomic)
            notice = "通知数据结构已导出，不含通知行或正文。"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    func setEnabled(_ requested: Bool) async {
        if !requested { stop(); return }
        guard canEnable else { notice = "请确认通知来源可用、已选择应用且眼镜已连接。"; return }
        generation = UUID(); let token = generation
        starting = true
        do {
            try await feed.start(bundleIDs: selectedBundleIDs)
            guard generation == token else { return }
            starting = false
            seen.removeAll(); seenOrder.removeAll(); deliveries.removeAll(); deliveredCount = 0; duplicateCount = 0
            enabled = true; notice = "仅镜像启用后新出现的所选应用通知。"
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.enabled, self.generation == token else { return }
                    do { try await self.forward(try await self.feed.readNew(), generation: token) }
                    catch { self.stop(); self.notice = "通知镜像已停止：\(error.localizedDescription)"; return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch { stop(); notice = error.localizedDescription }
    }

    func stop() {
        if enabled || starting { notice = "通知镜像已关闭。再次启用时将重新建立基线，跳过历史通知。" }
        generation = UUID(); polling?.cancel(); polling = nil; enabled = false; starting = false
    }

    private func forward(_ events: [NotificationMirrorEvent], generation token: UUID) async throws {
        for event in events {
            guard enabled, generation == token, !Task.isCancelled else { return }
            guard selectedBundleIDs.contains(event.bundleID) else { continue }
            let identity = NotificationMirrorIdentity(bundleID: event.bundleID, notificationID: event.id)
            guard seen.insert(identity).inserted else { duplicateCount += 1; continue }
            seenOrder.append(identity)
            if seenOrder.count > 1_000 { seen.remove(seenOrder.removeFirst()) }
            guard let bridge, bridge.connected else { record(event, outcome: "眼镜未连接，已跳过"); continue }
            let appName = apps.first { $0.id == event.bundleID }?.name ?? event.appName
            do {
                _ = try await bridge.request("/v1/notifications", body: [
                    "title": event.title, "body": event.body, "subtitle": event.subtitle,
                    "appId": event.bundleID, "appName": appName, "notificationUID": event.id,
                    "timestamp": String(Int64(event.date.timeIntervalSince1970 * 1_000))
                ])
                deliveredCount += 1; record(event, outcome: "已交给 Bridge 发送")
            } catch {
                record(event, outcome: "发送结果未确认")
                throw error
            }
        }
    }

    private func record(_ event: NotificationMirrorEvent, outcome: String) {
        let name = apps.first { $0.id == event.bundleID }?.name ?? event.appName
        let displayed = NotificationMirrorEvent(id: event.id, bundleID: event.bundleID, appName: name,
            title: event.title, subtitle: event.subtitle, body: event.body, date: event.date)
        deliveries.insert(.init(event: displayed, outcome: outcome), at: 0)
        if deliveries.count > 30 { deliveries.removeLast(deliveries.count - 30) }
    }
}
