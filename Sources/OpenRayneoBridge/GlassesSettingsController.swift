// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Launcher settings shared by the official app's control pages.
final class GlassesSettingsController {
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private var sequence: UInt16 = 0x6000

    init(transport: RFCOMMTransport, lock: NSRecursiveLock) {
        self.transport = transport
        self.lock = lock
    }

    func synchronizeClock() throws {
        lock.lock(); defer { lock.unlock() }
        try send(type: 5, command: "sync_time", payload: ["value": 0, "mode": 0, "data": try string([
            "utc": String(Int(Date().timeIntervalSince1970)), "offset": TimeZone.current.secondsFromGMT(), "timezone": TimeZone.current.identifier
        ])])
    }

    func route(method: String, path: String, body: [String: Any]) throws -> (Int, [String: Any])? {
        guard path.hasPrefix("/v1/glasses/") else { return nil }
        lock.lock(); defer { lock.unlock() }
        switch (method, path) {
        case ("GET", "/v1/glasses/status"):
            return (200, try read(type: 1, command: "request_general_status", field: "generalStatus"))
        case ("GET", "/v1/glasses/settings"):
            return (200, try read(type: 4, command: "request_general_settings", field: "generalSettings"))
        case ("GET", "/v1/glasses/changes"):
            var changes: [[String: Any]] = []
            while let message = transport.waitForMessage(timeout: 0, matching: {
                $0.protocolID == 0x0f && [1, 3, 4, 6, 17].contains($0.messageType ?? 0)
            }) {
                if let body = message.json {
                    changes.append(["type": message.messageType ?? 0, "receivedAt": message.receivedAt.timeIntervalSince1970, "body": body])
                }
            }
            return (200, ["changes": changes])
        case ("PATCH", "/v1/glasses/brightness"):
            guard let value = body["value"] as? Int else { throw BridgeError(status: 400, message: "value is required") }
            return (202, try command(type: 2, replyType: 3, name: "brightness_change", payload: ["value": value, "mode": 0, "data": ""]))
        case ("PATCH", "/v1/glasses/display"), ("PATCH", "/v1/glasses/wakeup"), ("PATCH", "/v1/glasses/units"):
            let name = path.hasSuffix("display") ? "display_config" : path.hasSuffix("wakeup") ? "wakeup_config" : "system_unints_config"
            return (202, try command(type: 5, replyType: 6, name: name,
                                     payload: ["value": 0, "mode": 0, "data": try string(body)]))
        case ("PATCH", "/v1/glasses/dashboard"):
            return (202, try command(type: 18, replyType: 19, name: "dashboard_update", payload: [
                "value": 0, "mode": 0, "data": try string(body), "ts": String(Int(Date().timeIntervalSince1970))
            ]))
        case ("POST", "/v1/glasses/cards"):
            guard let name = body["command"] as? String, ["clock_update", "stock_update", "mail_update"].contains(name),
                  let data = body["items"] else { throw BridgeError(status: 400, message: "command and items are required") }
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            return (202, try command(type: 18, replyType: 19, name: name, payload: ["value": 0, "mode": 0, "data": encoded, "ts": String(Int(Date().timeIntervalSince1970))]))
        case ("PATCH", "/v1/glasses/control"):
            guard let name = body["command"] as? String,
                  ["head_gestures", "auto_lock_time", "language_change", "privacy_config", "crown_config", "sync_time", "device_name_change", "system_unints_config"].contains(name) else {
                throw BridgeError(status: 400, message: "Unknown settings command")
            }
            var payload: [String: Any] = ["value": body["value"] as? Int ?? 0, "mode": body["mode"] as? Int ?? 0]
            if let data = body["data"] as? [String: Any] { payload["data"] = try string(data) }
            else { payload["data"] = body["data"] as? String ?? "" }
            return (202, try command(type: 5, replyType: 6, name: name, payload: payload))
        case ("PATCH", "/v1/glasses/assistant"):
            guard let name = body["command"] as? String,
                  ["set_ai_voice_wakeup", "set_ai_work_mode", "set_ai_lang", "set_ai_model_str", "set_ai_wakeup_word", "set_ai_state"].contains(name) else {
                throw BridgeError(status: 400, message: "Unknown voice assistant command")
            }
            let mode = body["mode"] as? Int ?? 0
            if name == "set_ai_wakeup_word", ![1, 2].contains(mode) {
                throw BridgeError(status: 400, message: "唤醒词 mode：1 = 小雷小雷，2 = OK RayNeo / Hey RayNeo。")
            }
            let wireMode = ["set_ai_state", "set_ai_voice_wakeup", "set_ai_work_mode"].contains(name) ? (mode == 0 ? 0 : 1) : mode
            return (202, try command(type: 16, replyType: 17, name: name, payload: [
                "value": 0, "mode": name == "set_ai_model_str" ? 0 : wireMode,
                "data": name == "set_ai_model_str" ? body["data"] as? String ?? "" : ""
            ]))
        case ("PATCH", "/v1/glasses/focus"):
            return (202, try command(type: 2, replyType: 3, name: "focus_mode", payload: ["value": body["enabled"] as? Bool == true ? 1 : 0, "mode": body["enableGlassClose"] as? Bool == false ? 0 : 1, "data": try string([
                "type": 2, "auto": body["automatic"] as? Bool == true ? 1 : 0,
                "begin": body["begin"] as? String ?? "09:00", "end": body["end"] as? String ?? "18:00", "weekday": body["weekday"] as? [Int] ?? Array(0...6)
            ])]))
        case ("PATCH", "/v1/glasses/focus/enabled"):
            guard let enabled = body["enabled"] as? Bool else {
                throw BridgeError(status: 400, message: "enabled is required")
            }
            let status = try read(type: 1, command: "request_general_status", field: "generalStatus")
            guard let focus = (status["generalStatus"] as? [String: Any])?["focusMode"] as? [String: Any],
                  var policy = focus["policy"] as? [String: Any], let close = focus["enableGlassClose"] as? Int else {
                throw BridgeError(status: 502, message: "眼镜未返回当前勿扰策略。")
            }
            policy["type"] = 1
            return (202, try command(type: 2, replyType: 3, name: "focus_mode", payload: [
                "value": enabled ? 1 : 0, "mode": close, "data": try string(policy)
            ]))
        default: return nil
        }
    }

    private func string(_ body: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private func send(type: UInt64, command: String, payload: [String: Any]) throws {
        sequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: 0x0f, sequence: sequence, type: type,
                                                      body: ["cmd": command, "payload": payload]))
    }

    private func read(type: UInt64, command: String, field: String) throws -> [String: Any] {
        try transport.ensureConnected()
        let started = Date()
        try send(type: type, command: command, payload: ["value": 0, "mode": 0, "data": ""])
        guard let reply = transport.waitForMessage(timeout: 5, matching: {
            $0.protocolID == 0x0f && $0.messageType == type && $0.receivedAt >= started && $0.json?[field] != nil
        })?.json else { throw BridgeError(status: 504, message: "Glasses did not return \(field)") }
        return reply
    }

    private func command(type: UInt64, replyType: UInt64, name: String, payload: [String: Any]) throws -> [String: Any] {
        try transport.ensureConnected()
        let started = Date()
        try send(type: type, command: name, payload: payload)
        let reply = transport.waitForMessage(timeout: 3, matching: {
            $0.protocolID == 0x0f && $0.messageType == replyType && $0.receivedAt >= started &&
                ($0.json?["cmd"] as? String == name || (type == 16 && $0.json?["cmd"] as? String == "sync_ai_settings"))
        })?.json
        let stateSynchronized = type == 16 && reply?["cmd"] as? String == "sync_ai_settings"
        var result: [String: Any] = ["sent": name, "acknowledged": reply != nil && !stateSynchronized]
        if stateSynchronized { result["stateSynchronized"] = true }
        if let reply { result["reply"] = reply }
        return result
    }
}
