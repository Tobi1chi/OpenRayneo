// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation

/// A page report from the glasses, not a screenshot or a command to change pages.
struct DashboardPreviewReport {
    let scene: Int
    let page: String
    let rawIndex: Int?
    let focusIndex: Int?
    let app: [String: Any]?
    let data: [String: Any]
    let timestamp: String?

    var metadata: [String: Any] {
        var result: [String: Any] = ["scene": scene, "page": page, "rawData": data]
        if let rawIndex { result["index"] = rawIndex }
        if let focusIndex { result["focusIndex"] = focusIndex }
        if let app { result["app"] = app }
        if let timestamp { result["ts"] = timestamp }
        return result
    }

    // APK 1.0.10: handler 0x2a84b60, parser 0x2a84d34, index mapper 0x23bf0a8.
    static func decode(_ message: [String: Any]) -> (report: Self?, disposition: String) {
        guard message["cmd"] as? String == "glass_preview" else { return (nil, "unexpected_command") }
        guard let payload = message["payload"] as? [String: Any], let text = payload["data"] as? String,
              let bytes = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return (nil, "invalid_data")
        }
        // The misspelling is on the wire; the original falls back only when scence is null/missing.
        let rawScene = data["scence"] == nil || data["scence"] is NSNull ? data["scene"] : data["scence"]
        guard let scene = integer(rawScene) else { return (nil, "missing_scene") }
        let index = integer(data["index"])
        let app = data["app"] as? [String: Any]
        let page: String
        let focus: Int?
        switch scene {
        case 0:
            page = "dashboard"; focus = index.map { $0 > 0 ? $0 - 1 : 0 }
        case 1:
            page = "app_list"; focus = appListIndex(index)
        case 2:
            guard let app, let rawName = app["name"], !(rawName is NSNull) else {
                return (nil, "invalid_app")
            }
            let name = String(describing: rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return (nil, "invalid_app") }
            guard integer(app["action"]) == 1 else { return (nil, "ignored_app_action") }
            page = "embedded_app"
            let knownNames = ["com.rayneo.liteos.recorder", "com.rayneo.liteos.aiSubtitle",
                "com.rayneo.liteos.conversationAssist", "com.rayneo.liteos.todo",
                "com.rayneo.liteos.prompter", "com.rayneo.liteos.ai_memory"]
            focus = knownNames.firstIndex(of: name) ?? appListIndex(index) ?? index
        default:
            page = "glass_preview_scene_\(scene)"; focus = index
        }
        return (Self(scene: scene, page: page, rawIndex: index, focusIndex: focus, app: app,
            data: data, timestamp: payload["ts"] as? String), "accepted")
    }

    private static func appListIndex(_ value: Int?) -> Int? {
        value.map { $0 > 0 ? min($0 - 1, 6) : 0 }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard number.doubleValue.isFinite else { return nil }
            return number.intValue
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

/// Uses its own lock; receive callbacks never acquire the device operation lock.
final class DashboardPreviewStateStore {
    private let lock = NSLock()
    private var connectionEpoch = 0
    private var disconnectedAt: Date?
    private var report: DashboardPreviewReport?
    private var reportEpoch: Int?
    private var stateReceivedAt: Date?
    private var lastReceivedAt: Date?
    private var lastEvent: [String: Any]?
    private var disposition = "not_received"
    private var receivedCount = 0
    private var config: [String: Any]?
    private var configReadAt: Date?
    private var configEpoch: Int?

    func receive(_ message: [String: Any], receivedAt: Date, sequence: Int) {
        let decoded = DashboardPreviewReport.decode(message)
        lock.lock(); defer { lock.unlock() }
        receivedCount += 1; lastReceivedAt = receivedAt
        lastEvent = ["sequence": sequence, "body": message]
        disposition = decoded.disposition
        if let decoded = decoded.report {
            report = decoded; stateReceivedAt = receivedAt
            reportEpoch = disconnectedAt.map { receivedAt < $0 } == true ? nil : connectionEpoch
        }
    }

    func disconnected() {
        lock.lock(); defer { lock.unlock() }
        connectionEpoch += 1; disconnectedAt = Date()
    }

    func recordConfiguration(_ value: [String: Any], requestedAt: Date, readAt: Date) {
        lock.lock(); defer { lock.unlock() }
        config = value; configReadAt = readAt
        configEpoch = disconnectedAt.map { requestedAt < $0 } == true ? nil : connectionEpoch
    }

    func snapshot(connected: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        func freshness(present: Bool, epoch: Int?) -> String {
            guard present else { return "not_received" }
            guard connected else { return "stale_disconnected" }
            return epoch == connectionEpoch ? "reported_this_connection" : "awaiting_report_after_reconnect"
        }
        return ["passive": true, "connected": connected, "source": report == nil ? "none" : "glasses_report",
            "freshness": freshness(present: report != nil, epoch: reportEpoch),
            "lastReceivedAt": lastReceivedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "stateReceivedAt": stateReceivedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "receivedCount": receivedCount, "lastDisposition": disposition,
            "report": report?.metadata as Any? ?? NSNull(), "lastEvent": lastEvent as Any? ?? NSNull(),
            "configuration": config as Any? ?? NSNull(),
            "configurationSource": config == nil ? "none" : "dashboard_config_reply",
            "configurationReadAt": configReadAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "configurationFreshness": freshness(present: config != nil, epoch: configEpoch)]
    }
}
