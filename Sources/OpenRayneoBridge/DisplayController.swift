// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Experimental display messages reconstructed from the official Android APK.
/// A device acknowledgment and a visible result are reported separately.
final class DisplayController {
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private var nextSequence: UInt16 = 0x4000
    private var session: (id: String, protocolID: UInt8, ready: Bool)?
    private var ownedTodoIDs = Set<Int64>()
    private var speechReserved = false
    private var lifeLogObservationID: String?
    private var lifeLogTaskID: String?
    private var lifeLogEnabledByProbe = false
    private var lifeLogProbeError: String?

    var isSpeechReserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return speechReserved || lifeLogObservationID != nil
    }

    func startSpeechDisplay() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !speechReserved, session == nil, lifeLogObservationID == nil else {
            throw BridgeError(status: 409, message: "Stop the current display session before starting ASR")
        }
        speechReserved = true
        do {
            let response = try route(method: "POST", path: "/v1/prompts/start", body: [:], forSpeech: true)
            guard response?.1["accepted"] as? Bool == true, let session else {
                throw BridgeError(status: 504, message: "Glasses did not accept the audio session")
            }
            return session.id
        } catch {
            try? stopSpeechDisplay()
            throw error
        }
    }

    func updateSpeechText(_ text: String) throws {
        _ = try route(method: "POST", path: "/v1/prompts/text", body: ["text": "实时语音识别", "translation": text, "final": true], forSpeech: true)
    }

    func stopSpeechDisplay() throws {
        lock.lock()
        defer { speechReserved = false; lock.unlock() }
        if speechReserved, session != nil {
            _ = try route(method: "POST", path: "/v1/prompts/stop", body: [:], forSpeech: true)
        }
    }

    init(transport: RFCOMMTransport, lock: NSRecursiveLock) {
        self.transport = transport
        self.lock = lock
    }

    func route(method: String, path: String, body: [String: Any], forSpeech: Bool = false) throws -> (Int, [String: Any])? {
        if path == "/v1/lifelog" || path.hasPrefix("/v1/lifelog/") {
            lock.lock()
            defer { lock.unlock() }
            switch (method, path) {
            case ("GET", "/v1/lifelog"):
                return (200, lifeLogStatus())
            case ("POST", "/v1/lifelog/observe"):
                guard session == nil, !speechReserved, lifeLogObservationID == nil else {
                    throw BridgeError(status: 409, message: "Stop the active audio/display session first")
                }
                let duration = body["duration"] as? Int ?? 300
                guard (10...600).contains(duration) else { throw BridgeError(status: 400, message: "duration must be 10 to 600 seconds") }
                try transport.ensureConnected()
                let id = UUID().uuidString
                lifeLogObservationID = id
                lifeLogProbeError = nil
                transport.observeLifeLog { [weak self] message in
                    DispatchQueue.global().async {
                        guard let self else { return }
                        self.lock.lock()
                        defer { self.lock.unlock() }
                        guard self.lifeLogObservationID == id else { return }
                        if message.messageType == 165 {
                            let remoteTask = message.json?["taskId"] as? String
                            if remoteTask == nil || remoteTask == self.lifeLogTaskID { self.lifeLogTaskID = nil }
                            return
                        }
                        guard self.lifeLogTaskID == nil else { return }
                        do { try self.startLifeLogAudio() }
                        catch { self.lifeLogProbeError = (error as? BridgeError)?.message ?? error.localizedDescription }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    if self.lifeLogObservationID == id { self.stopLifeLogProbe() }
                }
                return (200, lifeLogStatus())
            case ("POST", "/v1/lifelog/switch"):
                guard lifeLogObservationID != nil, let enabled = body["enabled"] as? Bool else {
                    throw BridgeError(status: 409, message: "Start a LifeLog observation and provide enabled")
                }
                if enabled { lifeLogEnabledByProbe = true }
                let reply = try setLifeLogSwitch(enabled)
                if !enabled, reply != nil { lifeLogEnabledByProbe = false }
                return (202, ["sent": "life_log_switch", "requestedEnabled": enabled,
                              "acknowledged": reply != nil, "reply": reply as Any? ?? NSNull()])
            case ("POST", "/v1/lifelog/record"):
                guard lifeLogObservationID != nil, lifeLogTaskID == nil else {
                    throw BridgeError(status: 409, message: "Start a LifeLog observation with no active task first")
                }
                try startLifeLogAudio()
                return (202, lifeLogStatus())
            case ("POST", "/v1/lifelog/stop"):
                stopLifeLogProbe()
                return (200, lifeLogStatus())
            default: return nil
            }
        }
        if method == "GET", path == "/v1/display/events" {
            return (200, ["events": transport.displayEvents, "discardedAudioPackets": transport.displayAudioPacketCount])
        }
        if method == "GET", path == "/v1/dashboard" {
            lock.lock()
            defer { lock.unlock() }
            var response = try launcherCommand("dashboard_config", data: "", timestamp: "0")
            if let reply = response["reply"] as? [String: Any],
               let payload = reply["payload"] as? [String: Any],
               let data = payload["data"] as? String,
               let bytes = data.data(using: .utf8),
               let config = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                response["config"] = config
            }
            return (response["acknowledged"] as? Bool == true ? 200 : 504, response)
        }
        if method == "POST", path == "/v1/weather/current" || path == "/v1/weather/cities" {
            lock.lock()
            defer { lock.unlock() }
            let command: String
            let encoded: String
            if path == "/v1/weather/current" {
                try validateWeatherLocation(body)
                command = "current_weather_update"
                encoded = try jsonString(body)
            } else {
                guard let cities = body["cities"] as? [[String: Any]], !cities.isEmpty else {
                    throw BridgeError(status: 400, message: "cities must be a nonempty array")
                }
                for city in cities {
                    try validateWeatherLocation(city)
                    guard let id = city["location_id"] as? String, !id.isEmpty else {
                        throw BridgeError(status: 400, message: "Each city requires a location_id string")
                    }
                }
                command = "weather_update"
                encoded = "[" + (try cities.map(encodeWeatherCity)).joined(separator: ",") + "]"
            }
            var response = try launcherCommand(command, data: encoded, timestamp: String(Int64(Date().timeIntervalSince1970)))
            response["visible"] = "unverified"
            return (202, response)
        }
        if method == "GET", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            return (200, ["reply": try queryTodos()])
        }
        if method == "POST", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            guard let title = body["title"] as? String, !title.isEmpty else {
                throw BridgeError(status: 400, message: "title must not be empty")
            }
            var items = try todoItems(queryTodos())
            let existing = Set(items.compactMap { ($0["eventID"] as? NSNumber)?.int64Value })
            guard let id = (Int64(90_000)..<100_000).first(where: { !existing.contains($0) }) else {
                throw BridgeError(status: 409, message: "No free local test task ID")
            }
            let now = Date().timeIntervalSince1970
            items.append([
                "eventType": 1, "eventID": id, "createTime": Int64(now * 1000),
                "title": title, "isImportant": body["important"] as? Bool ?? false,
                "status": 0, "lastModifiedTime": Int64(now)
            ])
            try synchronizeTodos(items)
            ownedTodoIDs.insert(id)
            let confirmed = try todoItems(queryTodos())
            let found = confirmed.first { ($0["eventID"] as? NSNumber)?.int64Value == id }
            return (202, ["eventID": id, "sent": "todo", "readBack": found?["title"] as? String == title,
                          "visible": "unverified"])
        }
        if method == "DELETE", path.hasPrefix("/v1/todos/") {
            lock.lock()
            defer { lock.unlock() }
            guard let id = Int64(path.dropFirst("/v1/todos/".count)), ownedTodoIDs.contains(id) else {
                throw BridgeError(status: 409, message: "Only tasks created by this bridge process can be removed")
            }
            var items = try todoItems(queryTodos())
            items.removeAll { ($0["eventID"] as? NSNumber)?.int64Value == id }
            try synchronizeTodos(items)
            let confirmed = try todoItems(queryTodos())
            let removed = !confirmed.contains { ($0["eventID"] as? NSNumber)?.int64Value == id }
            if removed { ownedTodoIDs.remove(id) }
            return (202, ["eventID": id, "sent": "removeTodo", "readBack": removed])
        }
        let prefix: String
        let protocolID: UInt8
        if path.hasPrefix("/v1/captions/") {
            prefix = "/v1/captions/"
            protocolID = 0x13
        } else if path.hasPrefix("/v1/prompts/") {
            prefix = "/v1/prompts/"
            protocolID = 0x17
        } else {
            return nil
        }
        guard method == "POST" else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if (speechReserved && !forSpeech) || lifeLogObservationID != nil {
            throw BridgeError(status: 409, message: "Stop the audio session before controlling its display session")
        }
        switch String(path.dropFirst(prefix.count)) {
        case "start":
            guard session == nil else {
                throw BridgeError(status: 409, message: "Stop the current text display session first")
            }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let config: [String: Any] = [
                "font_size": body["font_size"] as? Int ?? 2,
                "content_width": body["content_width"] as? Int ?? 100,
                "max_lines": body["max_lines"] as? Int ?? 5,
                "position": "center", "is_display": true, "straight_view": "original"
            ]
            if protocolID == 0x13 {
                try send(protocolID, type: 7, body: ["sid": id, "force": false, "scope": "temporary", "config": config])
            } else {
                try send(protocolID, type: 1, body: [
                    "sid": id, "trigger": 1, "force": false, "code": 0,
                    "settings": ["mode": "conversation", "source_language": "zh-CN",
                                 "target_language": "zh-CN", "save_audio": false, "direction": "ahead"]
                ])
            }
            session = (id, protocolID, false)
            let replyType: UInt64 = protocolID == 0x13 ? 8 : 2
            let reply = transport.waitForMessage(timeout: 8) {
                $0.protocolID == protocolID && $0.messageType == replyType && $0.json?["sid"] as? String == id
            }
            guard let reply, let json = reply.json else {
                return (202, ["sid": id, "sent": "start", "acknowledged": false, "visible": "unverified"])
            }
            let code = (json["code"] as? NSNumber)?.intValue
            session = (id, protocolID, code == 1)
            return (200, ["sid": id, "sent": "start", "acknowledged": true,
                          "accepted": code == 1, "reply": json, "visible": "unverified"])
        case "text":
            guard let session, session.protocolID == protocolID, session.ready else {
                throw BridgeError(status: 409, message: "A confirmed display session is required")
            }
            guard let text = body["text"] as? String, !text.isEmpty else {
                throw BridgeError(status: 400, message: "text must not be empty")
            }
            var content: [String: Any] = ["source_transcript": text]
            if let translation = body["translation"] as? String { content["target_translation"] = translation }
            if protocolID == 0x17 {
                content["keyword_info"] = NSNull()
                content["label"] = 0
            }
            try send(protocolID, type: 5, body: [
                "sid": session.id, "mode": protocolID == 0x17 ? 4 : 3,
                "status": (body["final"] as? Bool ?? false) ? 1 : 0, "content": content
            ])
            return (202, ["sid": session.id, "sent": "text", "visible": "unverified"])
        case "stop":
            guard let session, session.protocolID == protocolID else {
                throw BridgeError(status: 409, message: "No matching text display session")
            }
            try send(protocolID, type: 3, body: ["sid": session.id, "reason_code": protocolID == 0x13 ? 10 : 2, "text": ""])
            self.session = nil
            return (202, ["sid": session.id, "sent": "stop", "visible": "unverified"])
        default:
            return nil
        }
    }

    private func send(_ protocolID: UInt8, type: UInt64, body: [String: Any]) throws {
        nextSequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: protocolID, sequence: nextSequence, type: type, body: body))
    }

    private func lifeLogStatus() -> [String: Any] {
        var result = transport.lifeLogDiagnostics
        result["observing"] = lifeLogObservationID != nil
        result["taskID"] = lifeLogTaskID as Any? ?? NSNull()
        result["enabledByProbe"] = lifeLogEnabledByProbe
        result["error"] = lifeLogProbeError as Any? ?? NSNull()
        return result
    }

    private func startLifeLogAudio() throws {
        let id = UUID().uuidString.lowercased()
        try send(0x0d, type: 162, body: ["taskId": id, "idleTimeoutSec": 30])
        lifeLogTaskID = id
        try send(0x0d, type: 168, body: ["inRealtimePage": false])
    }

    private func setLifeLogSwitch(_ enabled: Bool) throws -> [String: Any]? {
        let started = Date()
        try send(0x0f, type: 20, body: ["cmd": "life_log_switch", "payload": ["value": enabled ? 1 : 0, "mode": 0, "data": ""]])
        return transport.waitForMessage(timeout: 5) {
            $0.protocolID == 0x0f && $0.messageType == 21 && $0.receivedAt >= started && $0.json?["cmd"] as? String == "life_log_switch_result"
        }?.json
    }

    private func stopLifeLogProbe() {
        lifeLogObservationID = nil
        transport.observeLifeLog(nil)
        if lifeLogTaskID != nil {
            do { try send(0x0d, type: 166, body: ["rc": 1]); lifeLogTaskID = nil }
            catch { lifeLogProbeError = "Could not send the LifeLog exit command" }
        }
        if lifeLogEnabledByProbe {
            do {
                let reply = try setLifeLogSwitch(false)
                if reply == nil { lifeLogProbeError = "LifeLog switch-off reply was not received" }
                else { lifeLogEnabledByProbe = false }
            } catch { lifeLogProbeError = "Could not send LifeLog switch-off; disable it on the glasses" }
        }
    }

    private func validateWeatherLocation(_ body: [String: Any]) throws {
        guard let location = body["location"] as? String, !location.isEmpty,
              body["temp"] is Int, body["icon"] is Int else {
            throw BridgeError(status: 400, message: "Weather requires location (string), temp (integer), and icon (integer)")
        }
    }

    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func encodeWeatherCity(_ city: [String: Any]) throws -> String {
        guard let hourly = city["hourly"] else { return try jsonString(city) }
        guard let entries = hourly as? [[String: Any]] else {
            throw BridgeError(status: 400, message: "hourly must be an ordered array of {time, temp, icon} objects")
        }
        // The firmware displays hourly object members in wire order. A Swift
        // dictionary cannot preserve that order, so encode these members explicitly.
        let members = try entries.map { entry -> String in
            guard let time = entry["time"] as? String, !time.isEmpty,
                  let temp = entry["temp"] as? Int, let icon = entry["icon"] as? Int else {
                throw BridgeError(status: 400, message: "Each hourly entry requires time (string), temp (integer), and icon (integer)")
            }
            return try jsonString(time) + ":" + jsonString([temp, icon])
        }
        var remaining = city
        remaining.removeValue(forKey: "hourly")
        let object = try jsonString(remaining)
        return String(object.dropLast()) + ",\"hourly\":{" + members.joined(separator: ",") + "}}"
    }

    private func launcherCommand(_ command: String, data: String, timestamp: String) throws -> [String: Any] {
        try transport.ensureConnected()
        let started = Date()
        try send(0x0f, type: 18, body: [
            "cmd": command,
            "payload": ["value": 0, "mode": 0, "data": data, "ts": timestamp]
        ])
        let reply = transport.waitForMessage(timeout: 5) {
            $0.protocolID == 0x0f && $0.messageType == 19 && $0.receivedAt >= started && $0.json?["cmd"] as? String == command
        }
        var result: [String: Any] = ["sent": command, "acknowledged": reply != nil]
        if let json = reply?.json { result["reply"] = json }
        return result
    }

    private func queryTodos() throws -> [String: Any] {
        try transport.ensureConnected()
        let started = Date()
        try send(0x16, type: 15, body: [
            "queryType": 0, "eventType": 1, "lastSyncTime": 0,
            "eventIDList": [], "needFullData": true
        ])
        var last: [String: Any] = [:]
        var records: [[String: Any]] = []
        let deadline = started.addingTimeInterval(5)
        repeat {
            guard let reply = transport.waitForMessage(timeout: max(0, deadline.timeIntervalSinceNow), matching: {
                $0.protocolID == 0x16 && $0.messageType == 16 && $0.receivedAt >= started
            }), let json = reply.json, let data = json["dataList"] as? [[String: Any]] else {
                throw BridgeError(status: 504, message: "Glasses did not answer the complete task query")
            }
            last = json
            records.append(contentsOf: data)
        } while last["isLastBatch"] as? Bool != true
        last["dataList"] = records
        return last
    }

    private func todoItems(_ reply: [String: Any]) throws -> [[String: Any]] {
        guard reply["needFullData"] as? Bool == true,
              let expected = (reply["todoTotal"] as? NSNumber)?.intValue,
              let records = reply["dataList"] as? [[String: Any]] else {
            throw BridgeError(status: 409, message: "A complete task snapshot is required before writing")
        }
        let todos = records.filter { ($0["eventType"] as? NSNumber)?.intValue == 1 }
        guard todos.count == expected, todos.allSatisfy({ $0["eventID"] is NSNumber && $0["title"] is String }) else {
            throw BridgeError(status: 409, message: "Task snapshot is incomplete or uses an unrecognized item format")
        }
        return todos
    }

    private func synchronizeTodos(_ items: [[String: Any]]) throws {
        try send(0x16, type: 6, body: ["total": items.count, "isLastBatch": true, "eventList": items])
    }
}
