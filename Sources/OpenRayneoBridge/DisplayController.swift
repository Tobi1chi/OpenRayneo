// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Experimental display messages reconstructed from the official Android APK.
/// A device acknowledgment and a visible result are reported separately.
final class DisplayController {
    static let promptLanguages = ["en-US", "fr-FR", "de-DE", "es-ES", "it-IT", "zh-CN", "yue-CN", "ja-JP", "ko-KR", "pl-PL"]
    private struct Session {
        var id: String
        var protocolID: UInt8
        var ready: Bool
        var phase = "starting"
        var startedAt = Date()
    }
    private struct ConnectionRecovery {
        let id = UUID()
        let sid: String
        let wasListening: Bool
        var requiresBLEReport: Bool
        var readyAt: Date?
        var preparing = false
    }
    private let eventQueue = DispatchQueue(label: "openrayneo.caption-events")
    private let transport: RFCOMMTransport
    private let lock: NSRecursiveLock
    private var nextSequence: UInt16 = 0x4000
    private var session: Session? {
        didSet {
            if oldValue?.id != session?.id { cancelScheduledClear() }
            if pendingPromptUpdate?.sid != session?.id { pendingPromptUpdate = nil }
            if connectionRecovery?.sid != session?.id { connectionRecovery = nil }
        }
    }
    private var connectionRecovery: ConnectionRecovery?
    private var connectionOnline = true
    private var disconnectedBLE = false
    private let captionSettingsURL: URL
    private var displayDraft: [String: Any] = ["font_size": 2, "content_width": 100, "max_lines": 5,
        "position": "center", "is_display": true, "straight_view": "original"]
    private var effectiveDisplay: [String: Any] = [:]
    private var displayRequest: (sid: String, scope: String, startedAt: Date)?
    private var promptPreferences = ["language": "zh-CN", "scenario": "face_to_face"]
    private var activePromptSettings: [String: Any] = [:]
    private var pendingPromptUpdate: (sid: String, startedAt: Date, previous: [String: String], previousSettings: [String: Any], settings: [String: Any])?
    private var pendingGlobalDisplay = false
    private var lastSession: [String: Any] = ["active": false, "phase": "idle"]
    private var lastCaptionResult: [String: Any] = [:]
    private var scheduledClear: DispatchWorkItem?
    private var contentRevision = UUID()
    private var clearAt: Date?
    private var speechStateHandler: ((UInt8, String, String, Int) -> Void)?
    private var speechSettingsHandler: ((String, [String: Any]) -> Void)?
    private var speechRecoveryHandler: ((String, @escaping (Bool) -> Void) -> Void)?
    private let todoStore: TodoOwnershipStore
    private let todoSync: ScheduleTodoSync
    private var speechReserved = false
    private let speechUpdateLock = NSLock()
    private var speechUpdateSID: String?
    private var lifeLogObservationID: String?
    private var lifeLogTaskID: String?
    private var lifeLogEnabledByProbe = false
    private var lifeLogSwitchNeedsCleanup = false
    private var lifeLogRequestedEnabled: Bool?
    private var lifeLogSwitchRequestedAt = Date.distantPast
    private var lifeLogObservedEnabled: Bool?
    private var lifeLogObservedAt = Date.distantPast
    private var lifeLogSwitchResult: [String: Any] = [:]
    private var lifeLogSwitchError: String?
    private var lifeLogProbeError: String?
    private var lifeLogAudioProbe: LifeLogAudioProbe?
    private var lifeLogIdleTimeout = 30
    private var lifeLogVADDelay = 2
    private var lifeLogObservationDeadline: Date?
    private var lifeLogFinalizing = false
    private var lifeLogStopCompletion: DispatchGroup?
    private let lifeLogEventsQueue = DispatchQueue(label: "openrayneo.lifelog-events")
    private var assistantFeed: AssistantAudioFeed?
    private let dashboardPreview = DashboardPreviewStateStore()

    var canStartNativeAssistant: Bool {
        lock.lock(); defer { lock.unlock() }
        return session == nil && !speechReserved && lifeLogObservationID == nil && !lifeLogFinalizing
    }

    var isSpeechReserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return speechReserved || lifeLogObservationID != nil
    }

    func startSpeechDisplay(languageOverride: String? = nil) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !speechReserved, session == nil, lifeLogObservationID == nil else {
            throw BridgeError(status: 409, message: "Stop the current display session before starting ASR")
        }
        speechReserved = true
        do {
            let response = try route(method: "POST", path: "/v1/prompts/start",
                body: languageOverride.map { ["language": $0] } ?? [:], forSpeech: true)
            guard response?.1["accepted"] as? Bool == true, let session else {
                throw BridgeError(status: 504, message: "Glasses did not accept the audio session")
            }
            speechUpdateLock.lock(); speechUpdateSID = session.id; speechUpdateLock.unlock()
            return session.id
        } catch {
            try? stopSpeechDisplay()
            throw error
        }
    }

    func updateSpeechText(_ text: String) throws {
        speechUpdateLock.lock(); let id = speechUpdateSID; speechUpdateLock.unlock()
        guard let id else { throw BridgeError(status: 409, message: "Audio display is stopping") }
        _ = try updateSharedSpeechText(["text": "实时语音识别", "translation": text, "final": true], expectedSID: id)
    }

    func invalidateSpeechUpdates(expectedSID: String?) {
        speechUpdateLock.lock(); defer { speechUpdateLock.unlock() }
        if expectedSID == nil || speechUpdateSID == expectedSID { speechUpdateSID = nil }
    }

    func updateSharedSpeechText(_ body: [String: Any], expectedSID: String, clear: Bool = false) throws -> (Int, [String: Any])? {
        lock.lock(); defer { lock.unlock() }
        speechUpdateLock.lock(); let current = speechUpdateSID; speechUpdateLock.unlock()
        guard current == expectedSID, speechReserved, session?.id == expectedSID else {
            throw BridgeError(status: 409, message: "Audio display changed or is stopping; reply was not sent")
        }
        return try route(method: "POST", path: clear ? "/v1/prompts/clear" : "/v1/prompts/text", body: body, forSpeech: true)
    }

    func stopSpeechDisplay(expectedSID: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let expectedSID, let current = session, current.id != expectedSID { return }
        invalidateSpeechUpdates(expectedSID: expectedSID)
        defer { speechReserved = false }
        if speechReserved, session != nil {
            _ = try route(method: "POST", path: "/v1/prompts/stop", body: [:], forSpeech: true)
        }
    }

    init(transport: RFCOMMTransport, lock: NSRecursiveLock, deviceID: String? = nil,
         todoStore: TodoOwnershipStore? = nil, todoSync: ScheduleTodoSync? = nil) {
        self.transport = transport
        self.lock = lock
        let store = todoStore ?? TodoOwnershipStore(deviceID: deviceID ?? ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? "")
        self.todoStore = store
        self.todoSync = todoSync ?? ScheduleTodoSync(transport: transport, lock: lock, todoStore: store)
        let identifier = (deviceID ?? ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? "default")
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        captionSettingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenRayneo/CaptionSettings/\(identifier).json")
        if let data = try? Data(contentsOf: captionSettingsURL),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let draft = saved["display"] as? [String: Any] { displayDraft.merge(draft) { _, new in new } }
            if let preferences = saved["prompts"] as? [String: String] { promptPreferences.merge(preferences) { _, new in new } }
            pendingGlobalDisplay = saved["pendingGlobal"] as? Bool == true
        }
    }

    func setSpeechStateHandler(_ handler: ((UInt8, String, String, Int) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        speechStateHandler = handler
    }

    func setSpeechSettingsHandler(_ handler: ((String, [String: Any]) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        speechSettingsHandler = handler
    }

    func setSpeechRecoveryHandler(_ handler: ((String, @escaping (Bool) -> Void) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        speechRecoveryHandler = handler
    }

    func connectionLost(bleDisconnected: Bool = true) {
        dashboardPreview.disconnected()
        lock.lock(); defer { lock.unlock() }
        if !connectionOnline {
            if bleDisconnected {
                disconnectedBLE = true
                connectionRecovery?.requiresBLEReport = true
                lifeLogTaskID = nil
            }
            return
        }
        connectionOnline = false
        cancelScheduledClear()
        disconnectedBLE = bleDisconnected
        displayRequest = nil
        pendingPromptUpdate = nil
        if lifeLogTaskID != nil {
            lifeLogAudioProbe?.endAssistantRound(reason: "transport_disconnected")
            if bleDisconnected { lifeLogTaskID = nil }
        }
        guard var current = session else { return }
        if current.protocolID == 0x17, current.ready, ["active", "paused", "disconnected"].contains(current.phase) {
            let wasListening = connectionRecovery?.wasListening ?? (current.phase == "active")
            connectionRecovery = ConnectionRecovery(sid: current.id, wasListening: wasListening, requiresBLEReport: bleDisconnected)
            current.phase = "disconnected"
            session = current
            lastSession = sessionInfo(current)
            speechStateHandler?(current.protocolID, current.id, "disconnected", 4)
        } else {
            lastSession = sessionInfo(current, active: false)
            lastSession["phase"] = "disconnected"
            session = nil
            invalidateSpeechUpdates(expectedSID: current.id)
            speechStateHandler?(current.protocolID, current.id, "closed", 4)
        }
    }

    func connectionReady() {
        lock.lock(); defer { lock.unlock() }
        guard !connectionOnline else { return }
        connectionOnline = true
        connectionRecovery?.readyAt = Date()
        if !disconnectedBLE, let taskID = lifeLogTaskID {
            lifeLogAudioProbe?.beginAssistantRound("\(taskID):asr:\(UUID().uuidString)", wireTaskID: taskID,
                                                  boundary: "transport_reconnected")
        }
        if var recovery = connectionRecovery, !recovery.requiresBLEReport, var current = session {
            if recovery.wasListening {
                recovery.preparing = true; connectionRecovery = recovery
                prepareConnectionRecovery(recovery, attribution: "retained_spp_session")
            } else {
                current.phase = "paused"; session = current; connectionRecovery = nil
                speechStateHandler?(0x17, current.id, "paused", 4)
            }
        }
        // Proactive AI waits for the glasses' type 11 report; link-ready is not a start command.
    }

    private func consumeRecoveryReport(_ message: RemoteMessage) {
        guard connectionOnline, var recovery = connectionRecovery, recovery.requiresBLEReport,
              let readyAt = recovery.readyAt,
              !recovery.preparing, message.receivedAt >= readyAt,
              var current = session, current.protocolID == 0x17, current.id == recovery.sid,
              let json = message.json, let state = json["state"] as? String else { return }
        let reportedSID = (json["sid"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard reportedSID.isEmpty || reportedSID == current.id else { return }
        let attribution = reportedSID.isEmpty ? "unique_disconnected_session" : "explicit_sid"
        switch state.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "idle":
            lastSession = sessionInfo(current, active: false)
            lastSession["phase"] = "closed"
            lastSession["recoveryAttribution"] = attribution
            session = nil
            invalidateSpeechUpdates(expectedSID: current.id)
            speechStateHandler?(0x17, current.id, "closed", 4)
        case "paused":
            guard recovery.wasListening else {
                current.phase = "paused"; session = current; connectionRecovery = nil
                lastSession = sessionInfo(current)
                lastSession["recoveryAttribution"] = attribution
                speechStateHandler?(0x17, current.id, "paused", 4)
                return
            }
            recovery.preparing = true
            connectionRecovery = recovery
            prepareConnectionRecovery(recovery, attribution: attribution)
        default: return
        }
    }

    private func prepareConnectionRecovery(_ recovery: ConnectionRecovery, attribution: String) {
        let complete: (Bool) -> Void = { [weak self] prepared in
            self?.eventQueue.async { [weak self] in
                self?.finishConnectionRecovery(token: recovery.id, prepared: prepared, attribution: attribution)
            }
        }
        if speechReserved, let speechRecoveryHandler { speechRecoveryHandler(recovery.sid, complete) }
        else { complete(!speechReserved) }
    }

    private func finishConnectionRecovery(token: UUID, prepared: Bool, attribution: String) {
        lock.lock(); defer { lock.unlock() }
        guard connectionOnline, var recovery = connectionRecovery, recovery.id == token,
              var current = session, current.id == recovery.sid else { return }
        guard prepared else {
            recovery.preparing = false; connectionRecovery = recovery
            lastCaptionResult = ["recovery": "failed", "sid": current.id, "error": "主机音频恢复准备失败。"]
            return
        }
        do {
            if recovery.requiresBLEReport {
                try send(0x17, type: 2, body: ["sid": current.id, "code": 1, "final_settings": activePromptSettings])
                try send(0x17, type: 3, body: ["sid": current.id, "reason_code": 9, "text": ""])
            }
            current.phase = "active"; session = current; connectionRecovery = nil
            lastSession = sessionInfo(current)
            lastSession["recoveryAttribution"] = attribution
            lastCaptionResult = ["recovery": "sent", "sid": current.id, "attribution": attribution, "visible": "unverified"]
            speechStateHandler?(0x17, current.id, "active", 9)
        } catch {
            recovery.preparing = false; connectionRecovery = recovery
            lastCaptionResult = ["recovery": "failed", "sid": current.id, "error": error.localizedDescription]
        }
    }

    // The receive callback must return before acquiring the operation lock.
    func handle(_ message: RemoteMessage) {
        if message.protocolID == 0x0f, message.messageType == 24 {
            dashboardPreview.receive(message.json ?? [:], receivedAt: message.receivedAt, sequence: Int(message.sequence))
            return
        }
        guard [0x13, 0x17].contains(message.protocolID), message.messageType != 4 else { return }
        eventQueue.async { [weak self] in self?.consumeCaptionEvent(message) }
    }

    private func consumeCaptionEvent(_ message: RemoteMessage) {
        lock.lock(); defer { lock.unlock() }
        if message.protocolID == 0x17, message.messageType == 11 {
            consumeRecoveryReport(message)
            return
        }
        if message.protocolID == 0x13, message.messageType == 8, let request = displayRequest,
           message.receivedAt >= request.startedAt, let json = message.json, json["sid"] as? String == request.sid {
            if json["code"] as? Int == 1 {
                if let config = json["effective_config"] as? [String: Any] { mergeEffectiveDisplay(config) }
                if request.scope == "global", pendingGlobalDisplay {
                    pendingGlobalDisplay = false
                    try? persistCaptionPreferences()
                }
            }
            lastCaptionResult = ["sent": true, "scope": request.scope, "acknowledged": true,
                "accepted": json["code"] as? Int == 1, "reply": json, "sid": request.sid, "visible": "unverified"]
        }
        guard var current = session, current.protocolID == message.protocolID,
              message.receivedAt >= current.startedAt, let json = message.json,
              json["sid"] as? String == current.id else { return }
        if message.messageType == 3, let reason = json["reason_code"] as? Int {
            if connectionRecovery != nil, [8, 9, 12, 13].contains(reason) { return }
            let phase: String
            switch reason {
            case 8, 12: phase = "paused"
            case 9, 13: phase = "active"
            case 1...7, 10, 11, 14: phase = "closed"
            case 17:
                lastCaptionResult = ["type": 3, "reason": reason, "sid": current.id, "phase": "weak_network"]
                return
            default: return
            }
            current.phase = phase
            session = phase == "closed" ? nil : current
            lastSession = sessionInfo(current, active: phase != "closed")
            lastSession["reason"] = reason
            if phase == "closed" { invalidateSpeechUpdates(expectedSID: current.id) }
            speechStateHandler?(current.protocolID, current.id, phase, reason)
        } else if message.messageType == 8, current.protocolID == 0x13 {
            if json["code"] as? Int == 1 {
                if let config = json["effective_config"] as? [String: Any] { mergeEffectiveDisplay(config) }
                current.ready = true; current.phase = "active"; session = current
            } else if !current.ready {
                lastSession = sessionInfo(current, active: false); lastSession["phase"] = "failed"
                session = nil
            }
        } else if message.messageType == 2, let code = json["code"] as? Int,
                  let pending = pendingPromptUpdate, pending.sid == current.id, message.receivedAt >= pending.startedAt {
            pendingPromptUpdate = nil
            if code == 1 {
                activePromptSettings = pending.settings
                if let actual = json["final_settings"] as? [String: Any] {
                    activePromptSettings.merge(actual) { _, returned in returned }
                }
                speechSettingsHandler?(current.id, activePromptSettings)
                lastCaptionResult = ["sent": "prompt_settings", "applicationAccepted": true, "code": code]
            } else {
                promptPreferences = pending.previous
                activePromptSettings = pending.previousSettings
                try? persistCaptionPreferences()
                speechSettingsHandler?(current.id, activePromptSettings)
                lastCaptionResult = ["sent": "prompt_settings", "applicationAccepted": false, "code": code,
                    "error": "眼镜拒绝设置更新，已保留原有会话与配置。"]
            }
        } else if current.protocolID == 0x17, message.messageType == 2,
                  json["code"] as? Int == 1, current.phase == "starting", !current.ready {
            // CaptionMsg type 2 is the start result; see official-caption-protocols.md.
            // The business/sid/time guard above excludes stopped or replaced sessions.
            current.ready = true; current.phase = "active"; session = current
            if let actual = json["final_settings"] as? [String: Any] {
                activePromptSettings.merge(actual) { _, returned in returned }
            }
            lastCaptionResult = ["sent": "start", "sid": current.id, "acknowledged": true,
                "accepted": true, "reply": json, "visible": "unverified"]
        } else if message.messageType == 2, let code = json["code"] as? Int, code != 1 {
            current.ready = false; current.phase = "failed"
            lastSession = sessionInfo(current, active: false)
            lastSession["code"] = code
            session = nil
            invalidateSpeechUpdates(expectedSID: current.id)
            speechStateHandler?(current.protocolID, current.id, "closed", code)
        }
    }

    private func captionSettingsRoute(method: String, path: String, body: [String: Any], forSpeech: Bool) throws -> (Int, [String: Any])? {
        guard ["/v1/caption-settings", "/v1/caption-settings/display", "/v1/captions/config", "/v1/prompts/settings"].contains(path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        switch (method, path) {
        case ("GET", "/v1/caption-settings"):
            return (200, captionSettingsStatus())
        case ("PATCH", "/v1/caption-settings/display"):
            let proposed = try validatedDisplayConfig(body, merging: displayDraft)
            let previous = displayDraft
            displayDraft = proposed
            do { try persistCaptionPreferences() } catch { displayDraft = previous; throw error }
            return (200, captionSettingsStatus())
        case ("POST", "/v1/captions/config"):
            guard !speechReserved, lifeLogObservationID == nil, session?.protocolID != 0x17 else {
                throw BridgeError(status: 409, message: "请先停止实时提示或收音，再应用字幕显示配置。")
            }
            let scope = body["scope"] as? String ?? "global"
            guard ["temporary", "global"].contains(scope) else { throw BridgeError(status: 400, message: "scope must be temporary or global") }
            if let requested = body["sid"] as? String, let current = session, requested != current.id {
                throw BridgeError(status: 409, message: "字幕预览会话已变化，请刷新后重试。")
            }
            if scope == "global" {
                pendingGlobalDisplay = true
                try persistCaptionPreferences()
                if let current = session, current.protocolID == 0x13 {
                    try send(0x13, type: 3, body: ["sid": current.id, "reason_code": 10, "text": ""])
                    lastSession = sessionInfo(current, active: false)
                    lastSession["phase"] = "closed"
                    session = nil
                }
            }
            do {
                let result = try applyCaptionDisplay(scope: scope)
                return (result["acknowledged"] as? Bool == true ? 200 : 202, result)
            } catch {
                if scope == "global" {
                    lastCaptionResult = ["sent": false, "deferred": true, "error": error.localizedDescription]
                    var status = captionSettingsStatus(); status["result"] = lastCaptionResult
                    return (202, status)
                }
                throw error
            }
        case ("POST", "/v1/prompts/settings"):
            let previous = promptPreferences
            var proposed = previous
            if let language = body["language"] as? String {
                guard Self.promptLanguages.contains(language) else { throw BridgeError(status: 400, message: "不支持的实时提示语言。") }
                proposed["language"] = language
            }
            if let scenario = body["scenario"] as? String {
                guard ["group_conversation", "face_to_face"].contains(scenario) else { throw BridgeError(status: 400, message: "scenario must be group_conversation or face_to_face") }
                proposed["scenario"] = scenario
            }
            if let current = session, current.protocolID == 0x17 {
                guard current.ready, connectionRecovery == nil else {
                    throw BridgeError(status: 409, message: "等待当前实时提示会话确认或恢复后再修改设置。")
                }
                if let requested = body["sid"] as? String, requested != current.id { throw BridgeError(status: 409, message: "实时提示会话已变化。") }
                let activeLanguage = activePromptSettings["source_language"] as? String ?? previous["language"]
                guard !speechReserved || forSpeech || body["language"] == nil || proposed["language"] == activeLanguage else {
                    throw BridgeError(status: 409, message: "活动收音的语言更新须经过主机 ASR 控制器。")
                }
                var settings = promptSettings(proposed)
                if body["language"] == nil, let activeLanguage {
                    settings["source_language"] = activeLanguage
                    settings["target_language"] = activeLanguage
                }
                let started = Date()
                promptPreferences = proposed
                do { try persistCaptionPreferences() } catch { promptPreferences = previous; throw error }
                do { try send(0x17, type: 2, body: ["sid": current.id, "code": 1, "final_settings": settings]) }
                catch { promptPreferences = previous; try? persistCaptionPreferences(); throw error }
                pendingPromptUpdate = (current.id, started, previous, activePromptSettings, settings)
                activePromptSettings = settings
                lastCaptionResult = ["sent": "prompt_settings", "sid": current.id, "applicationAccepted": NSNull(), "visible": "unverified"]
            } else {
                promptPreferences = proposed
                do { try persistCaptionPreferences() } catch { promptPreferences = previous; throw error }
                lastCaptionResult = ["saved": true, "sent": false]
            }
            return (200, captionSettingsStatus())
        default: return nil
        }
    }

    private func persistCaptionPreferences() throws {
        try FileManager.default.createDirectory(at: captionSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["display": displayDraft, "prompts": promptPreferences,
            "pendingGlobal": pendingGlobalDisplay]).write(to: captionSettingsURL, options: .atomic)
    }

    private func promptSettings(_ preferences: [String: String]) -> [String: Any] {
        let language = preferences["language"] ?? "zh-CN"
        return ["mode": "conversation", "source_language": language, "target_language": language,
            "save_audio": false, "direction": preferences["scenario"] == "group_conversation" ? "around" : "ahead"]
    }

    private func validatedDisplayConfig(_ input: [String: Any], merging base: [String: Any]) throws -> [String: Any] {
        var result = base
        for key in ["font_size", "content_width", "max_lines"] where input[key] != nil {
            guard let value = input[key] as? Int else { throw BridgeError(status: 400, message: "\(key) must be an integer") }
            result[key] = value
        }
        for key in ["position", "straight_view"] where input[key] != nil {
            guard let value = input[key] as? String else { throw BridgeError(status: 400, message: "\(key) must be a string") }
            if key == "straight_view", !["original", "translation"].contains(value) { throw BridgeError(status: 400, message: "straight_view must be original or translation") }
            result[key] = value
        }
        if input["is_display"] != nil {
            guard let value = input["is_display"] as? Bool else { throw BridgeError(status: 400, message: "is_display must be Boolean") }
            result["is_display"] = value
        }
        return result
    }

    private func mergeEffectiveDisplay(_ config: [String: Any]) {
        for key in ["font_size", "content_width", "max_lines", "position", "is_display", "straight_view"] {
            if let value = config[key], !(value is NSNull) { effectiveDisplay[key] = value }
        }
    }

    private func sessionInfo(_ value: Session, active: Bool = true) -> [String: Any] {
        ["active": active, "sid": value.id, "business": Int(value.protocolID), "ready": value.ready,
         "phase": value.phase, "startedAt": value.startedAt.timeIntervalSince1970]
    }

    private func captionSettingsStatus() -> [String: Any] {
        ["displayDraft": displayDraft, "effectiveDisplay": effectiveDisplay, "prompts": promptPreferences,
         "activePromptSettings": activePromptSettings, "pendingGlobal": pendingGlobalDisplay,
         "promptUpdatePending": pendingPromptUpdate != nil,
         "session": session.map { sessionInfo($0) } ?? lastSession, "result": lastCaptionResult,
         "hostLanguageHotReload": true, "clearAt": clearAt?.timeIntervalSince1970 as Any? ?? NSNull()]
    }

    private func applyCaptionDisplay(scope: String) throws -> [String: Any] {
        try transport.ensureConnected()
        let id = scope == "temporary" ? session?.id ?? UUID().uuidString : UUID().uuidString
        var config = displayDraft
        config["is_display"] = scope == "temporary" && (displayDraft["is_display"] as? Bool ?? true)
        let started = Date()
        let previousSession = session
        if scope == "temporary" { session = Session(id: id, protocolID: 0x13, ready: false, startedAt: started) }
        displayRequest = (id, scope, started)
        do { try send(0x13, type: 7, body: ["sid": id, "force": false, "scope": scope, "config": config]) }
        catch { if scope == "temporary" { session = previousSession }; displayRequest = nil; throw error }
        let reply = transport.waitForMessage(timeout: 8) {
            $0.protocolID == 0x13 && $0.messageType == 8 && $0.receivedAt >= started && $0.json?["sid"] as? String == id
        }
        var result: [String: Any] = ["sid": id, "scope": scope, "sent": true,
            "acknowledged": reply != nil, "visible": "unverified"]
        if let json = reply?.json {
            let accepted = json["code"] as? Int == 1
            result["accepted"] = accepted
            result["reply"] = json
            if accepted {
                if let returned = json["effective_config"] as? [String: Any] { mergeEffectiveDisplay(returned) }
                if scope == "temporary" { session?.ready = true; session?.phase = "active" }
                else { pendingGlobalDisplay = false; try persistCaptionPreferences() }
            } else if scope == "temporary", let current = session {
                lastSession = sessionInfo(current, active: false); lastSession["phase"] = "failed"
                session = previousSession
            }
        }
        lastCaptionResult = result
        var status = captionSettingsStatus(); status["result"] = result
        return status.merging(result) { _, new in new }
    }

    func route(method: String, path: String, body: [String: Any], forSpeech: Bool = false) throws -> (Int, [String: Any])? {
        if let result = try captionSettingsRoute(method: method, path: path, body: body, forSpeech: forSpeech) { return result }
        if method == "POST", path == "/v1/lifelog/stop" {
            lock.lock()
            stopLifeLogProbe()
            let completion = lifeLogStopCompletion
            lock.unlock()
            let finished = completion?.wait(timeout: .now() + 10) != .timedOut
            lock.lock(); defer { lock.unlock() }
            return (finished ? 200 : 202, lifeLogStatus())
        }
        if path == "/v1/lifelog" || path.hasPrefix("/v1/lifelog/") {
            lock.lock()
            defer { lock.unlock() }
            switch (method, path) {
            case ("GET", "/v1/lifelog"):
                return (200, lifeLogStatus())
            case ("POST", "/v1/lifelog/assistant-audio"):
                guard let assistantFeed else { throw BridgeError(status: 409, message: "Start LifeLog with assistant_capture first") }
                var response = assistantFeed.read(after: body["after"] as? Int ?? 0)
                response["audioStatus"] = lifeLogAudioProbe?.status
                return (200, response)
            case ("POST", "/v1/lifelog/observe"):
                guard session == nil, !speechReserved, lifeLogObservationID == nil, !lifeLogFinalizing else {
                    throw BridgeError(status: 409, message: "Stop the active audio/display session first")
                }
                let duration = body["duration"] as? Int ?? 300
                guard duration == 0 || (10...86_400).contains(duration) else { throw BridgeError(status: 400, message: "duration must be 0 (manual stop), or 10 to 86400 seconds") }
                let delay = body["vad_start_delay_sec"] as? Int ?? 2
                guard (1...60).contains(delay) else { throw BridgeError(status: 400, message: "vad_start_delay_sec must be 1 to 60") }
                let idle = body["idle_timeout_sec"] as? Int ?? (duration == 0 ? 300 : 30)
                guard idle > 0 else { throw BridgeError(status: 400, message: "idle_timeout_sec must be positive") }
                try transport.ensureConnected()
                let record = body["record"] as? Bool ?? false
                let preserve = body["preserve_audio"] as? Bool ?? record
                let feed = body["assistant_capture"] as? Bool == true ? AssistantAudioFeed(inputMode: .buffered) : nil
                assistantFeed = feed
                let id = UUID().uuidString
                let store = preserve ? try LifeLogCaptureStore(observationID: id) : nil
                let probe = body["inspect_audio"] as? Bool == true || record || preserve || feed != nil
                    ? try LifeLogAudioProbe(record: record, assistantFeed: feed, captureStore: store) : nil
                lifeLogAudioProbe = probe
                transport.setLifeLogAudioHandler { [weak self, weak probe] message in
                    self?.lifeLogEventsQueue.async { probe?.consume(message) }
                }
                lifeLogObservationID = id
                lifeLogIdleTimeout = idle
                lifeLogVADDelay = delay
                lifeLogObservationDeadline = duration == 0 ? nil : Date().addingTimeInterval(Double(duration))
                lifeLogProbeError = nil
                transport.observeLifeLog { [weak self] message in
                    self?.lifeLogEventsQueue.async {
                        guard let self else { return }
                        self.lock.lock()
                        defer { self.lock.unlock() }
                        guard self.lifeLogObservationID == id else { return }
                        if message.messageType == 165 {
                            let remoteTask = (message.json?["taskId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if remoteTask.isEmpty || remoteTask == self.lifeLogTaskID {
                                self.lifeLogAudioProbe?.endAssistantRound(reason: "glasses_exit_rc\(message.json?["rc"] as? Int ?? 0)")
                                self.lifeLogTaskID = nil
                            }
                            return
                        }
                        guard self.lifeLogTaskID == nil else { return }
                        do { try self.startLifeLogAudio() }
                        catch { self.lifeLogProbeError = (error as? BridgeError)?.message ?? error.localizedDescription }
                    }
                }
                if duration > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    if self.lifeLogObservationID == id { self.stopLifeLogProbe() }
                } }
                return (200, lifeLogStatus())
            case ("POST", "/v1/lifelog/switch"):
                guard lifeLogObservationID != nil, let enabled = body["enabled"] as? Bool else {
                    throw BridgeError(status: 409, message: "Start a LifeLog observation and provide enabled")
                }
                _ = try setLifeLogSwitch(enabled)
                return (202, lifeLogStatus().merging(lifeLogSwitchResult) { _, result in result })
            case ("POST", "/v1/lifelog/record"):
                guard lifeLogObservationID != nil, lifeLogTaskID == nil else {
                    throw BridgeError(status: 409, message: "Start a LifeLog observation with no active task first")
                }
                try startLifeLogAudio()
                return (202, lifeLogStatus())
            default: return nil
            }
        }
        if method == "GET", path == "/v1/display/events" {
            return (200, ["events": transport.displayEvents, "discardedAudioPackets": transport.displayAudioPacketCount])
        }
        if method == "GET", path == "/v1/dashboard/preview" {
            return (200, dashboardPreview.snapshot(connected: transport.isConnected))
        }
        if method == "GET", path == "/v1/dashboard" {
            lock.lock()
            defer { lock.unlock() }
            let requestedAt = Date()
            var response = try launcherCommand("dashboard_config", data: "", timestamp: "0")
            if let reply = response["reply"] as? [String: Any],
               let payload = reply["payload"] as? [String: Any],
               let data = payload["data"] as? String,
               let bytes = data.data(using: .utf8),
               let config = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                response["config"] = config
                dashboardPreview.recordConfiguration(config, requestedAt: requestedAt, readAt: Date())
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
        if method == "GET", path == "/v1/todos/local" {
            let items = todoSync.localTodoItems()
            return (200, ["items": items, "ownedEventIDs": ownedTodoIDs(items)])
        }
        if method == "GET", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            let reply = try queryTodos()
            let items = try todoItems(reply)
            let localItems = todoSync.localTodoItems()
            return (200, ["reply": reply, "localItems": localItems,
                "ownedEventIDs": Array(Set(ownedTodoIDs(items) + ownedTodoIDs(localItems))).sorted(),
                "localOwnedEventIDs": ownedTodoIDs(localItems)])
        }
        if method == "POST", path == "/v1/todos" {
            lock.lock()
            defer { lock.unlock() }
            return (202, try mutateTodo(action: "add", id: nil, body: body))
        }
        if (method == "PATCH" || method == "DELETE"), path.hasPrefix("/v1/todos/") {
            lock.lock()
            defer { lock.unlock() }
            guard let id = Int64(path.dropFirst("/v1/todos/".count)) else {
                throw BridgeError(status: 400, message: "Invalid todo ID")
            }
            return (202, try mutateTodo(action: method == "PATCH" ? "update" : "delete", id: id, body: body))
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
            if protocolID == 0x13 {
                displayDraft = try validatedDisplayConfig(body, merging: displayDraft)
                try persistCaptionPreferences()
                let result = try applyCaptionDisplay(scope: "temporary")
                return (200, result.merging(result["result"] as? [String: Any] ?? [:]) { _, new in new })
            }
            var preferences = promptPreferences
            if let language = body["language"] as? String {
                guard Self.promptLanguages.contains(language) else { throw BridgeError(status: 400, message: "不支持的实时提示语言。") }
                preferences["language"] = language
            }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let started = Date()
            let settings = promptSettings(preferences)
            session = Session(id: id, protocolID: protocolID, ready: false, startedAt: started)
            do {
                try send(protocolID, type: 1, body: ["sid": id, "trigger": 1, "force": false, "code": 0, "settings": settings])
            } catch { session = nil; throw error }
            let replyType: UInt64 = 2
            let reply = transport.waitForMessage(timeout: 8) {
                $0.protocolID == protocolID && $0.messageType == replyType && $0.receivedAt >= started && $0.json?["sid"] as? String == id
            }
            guard let reply, let json = reply.json else {
                activePromptSettings = settings
                return (202, ["sid": id, "sent": "start", "acknowledged": false, "visible": "unverified"])
            }
            let code = (json["code"] as? NSNumber)?.intValue
            session?.ready = code == 1
            session?.phase = code == 1 ? "active" : "failed"
            activePromptSettings = settings
            if code == 1, let actual = json["final_settings"] as? [String: Any] {
                activePromptSettings.merge(actual) { _, returned in returned }
            }
            pendingPromptUpdate = nil
            if code != 1, let current = session {
                lastSession = sessionInfo(current, active: false)
                lastSession["code"] = code as Any? ?? NSNull()
                session = nil
            }
            return (200, ["sid": id, "sent": "start", "acknowledged": true,
                          "accepted": code == 1, "reply": json, "visible": "unverified"])
        case "text":
            guard let session, session.protocolID == protocolID, session.ready, session.phase == "active" else {
                throw BridgeError(status: 409, message: "A confirmed display session is required")
            }
            guard let text = body["text"] as? String, !text.isEmpty else {
                throw BridgeError(status: 400, message: "text must not be empty")
            }
            if let requested = body["sid"] as? String, requested != session.id {
                throw BridgeError(status: 409, message: "显示会话已变化，未覆盖新的内容。")
            }
            let clearAfter = body["clear_after_ms"] as? Int ?? 0
            guard (0...600_000).contains(clearAfter) else {
                throw BridgeError(status: 400, message: "clear_after_ms must be between 0 and 600000")
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
            cancelScheduledClear()
            if clearAfter > 0 { scheduleClear(after: clearAfter, session: session) }
            lastCaptionResult = ["sid": session.id, "sent": "text", "updatedAt": Date().timeIntervalSince1970]
            return (202, ["sid": session.id, "sent": "text", "clear_after_ms": clearAfter,
                          "clearAt": clearAt?.timeIntervalSince1970 as Any? ?? NSNull(), "visible": "unverified"])
        case "clear":
            guard let current = session, current.protocolID == protocolID, current.ready, current.phase == "active" else {
                throw BridgeError(status: 409, message: "A confirmed display session is required")
            }
            if let requested = body["sid"] as? String, requested != current.id {
                throw BridgeError(status: 409, message: "显示会话已变化，未清除新的内容。")
            }
            try clearDisplay(current)
            return (202, ["sid": current.id, "sent": "clear", "session_kept": true, "visible": "unverified"])
        case "stop":
            guard let session, session.protocolID == protocolID else {
                throw BridgeError(status: 409, message: "No matching text display session")
            }
            if let requested = body["sid"] as? String, requested != session.id { throw BridgeError(status: 409, message: "显示会话已变化。") }
            if connectionOnline {
                try send(protocolID, type: 3, body: ["sid": session.id, "reason_code": protocolID == 0x13 ? 10 : 2, "text": ""])
            }
            lastSession = sessionInfo(session, active: false)
            lastSession["phase"] = "closed"
            self.session = nil
            return (202, ["sid": session.id, "sent": "stop", "visible": "unverified"])
        default:
            return nil
        }
    }

    private func cancelScheduledClear() {
        scheduledClear?.cancel(); scheduledClear = nil; clearAt = nil; contentRevision = UUID()
    }

    private func clearDisplay(_ current: Session) throws {
        // A full-width blank is already supported by the glasses' text grid. Final replaces retained text.
        var content: [String: Any] = ["source_transcript": "　", "target_translation": "　"]
        if current.protocolID == 0x17 { content["keyword_info"] = NSNull(); content["label"] = 0 }
        try send(current.protocolID, type: 5, body: ["sid": current.id, "mode": current.protocolID == 0x17 ? 4 : 3,
                                                   "status": 1, "content": content])
        cancelScheduledClear()
        lastCaptionResult = ["sid": current.id, "sent": "clear", "session_kept": true, "clearedAt": Date().timeIntervalSince1970, "visible": "unverified"]
    }

    private func scheduleClear(after milliseconds: Int, session current: Session) {
        let revision = contentRevision
        clearAt = Date().addingTimeInterval(Double(milliseconds) / 1000)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.contentRevision == revision, self.session?.id == current.id,
                  self.session?.phase == "active", self.connectionOnline else { return }
            do { try self.clearDisplay(current) }
            catch { self.lastCaptionResult = ["sent": "clear", "error": error.localizedDescription, "sid": current.id] }
        }
        scheduledClear = work
        eventQueue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }

    private func send(_ protocolID: UInt8, type: UInt64, body: [String: Any]) throws {
        nextSequence &+= 1
        try transport.send(ProtocolCodec.displayFrame(protocolID: protocolID, sequence: nextSequence, type: type, body: body))
    }

    private func lifeLogStatus() -> [String: Any] {
        // Read already-received authoritative reports, without sending a query.
        // life_log_switch_result is an operation result, not the enabled state.
        while let report = transport.waitForMessage(timeout: 0, matching: {
            guard $0.protocolID == 0x0f, $0.messageType == 21, $0.receivedAt > self.lifeLogObservedAt,
                  $0.json?["cmd"] as? String == "life_log_switch",
                  let payload = $0.json?["payload"] as? [String: Any], let value = payload["value"] as? Int else { return false }
            return value == 0 || value == 1
        }) {
            lifeLogObservedAt = report.receivedAt
            if let payload = report.json?["payload"] as? [String: Any], let value = payload["value"] as? Int,
               value == 0 || value == 1 {
                lifeLogObservedEnabled = value == 1
                if value == 0, report.receivedAt >= lifeLogSwitchRequestedAt {
                    lifeLogEnabledByProbe = false; lifeLogSwitchNeedsCleanup = false
                }
            }
        }
        var result = transport.lifeLogDiagnostics
        result["observing"] = lifeLogObservationID != nil
        result["finalizing"] = lifeLogFinalizing
        result["taskID"] = lifeLogTaskID as Any? ?? NSNull()
        result["observationID"] = lifeLogObservationID as Any? ?? NSNull()
        result["deadline"] = lifeLogObservationDeadline?.timeIntervalSince1970 as Any? ?? NSNull()
        result["idleTimeoutSec"] = lifeLogIdleTimeout
        result["vadStartDelaySec"] = lifeLogVADDelay
        result["enabledByProbe"] = lifeLogEnabledByProbe
        result["switchCleanupRequired"] = lifeLogSwitchNeedsCleanup
        result["requestedEnabled"] = lifeLogRequestedEnabled as Any? ?? NSNull()
        result["observedEnabled"] = lifeLogObservedEnabled as Any? ?? NSNull()
        result["observedEnabledAt"] = lifeLogObservedEnabled == nil ? NSNull() : lifeLogObservedAt.timeIntervalSince1970 as Any
        result["switchResult"] = lifeLogSwitchResult
        result["error"] = (lifeLogProbeError ?? lifeLogSwitchError) as Any? ?? NSNull()
        result["audioInspection"] = lifeLogAudioProbe?.status as Any? ?? NSNull()
        return result
    }

    private func startLifeLogAudio() throws {
        let id = UUID().uuidString.lowercased()
        lifeLogAudioProbe?.beginAssistantRound(id)
        do { try send(0x0d, type: 162, body: ["taskId": id, "idleTimeoutSec": lifeLogIdleTimeout]) }
        catch { lifeLogAudioProbe?.endAssistantRound(); throw error }
        lifeLogTaskID = id
        try send(0x0d, type: 168, body: ["inRealtimePage": false])
    }

    private func setLifeLogSwitch(_ enabled: Bool) throws -> [String: Any]? {
        let started = Date()
        let previousCleanup = lifeLogSwitchNeedsCleanup
        lifeLogRequestedEnabled = enabled
        lifeLogSwitchRequestedAt = started
        if enabled { lifeLogSwitchNeedsCleanup = true }
        do { try send(0x0f, type: 20, body: ["cmd": "life_log_switch", "payload": ["value": enabled ? 1 : 0, "mode": 0,
            "data": enabled ? "{\"delay\":\(lifeLogVADDelay)}" : ""]]) }
        catch {
            let message = "LifeLog 开关发送失败；设备状态未确认，仍需检查或重试关闭。"
            lifeLogSwitchError = message
            lifeLogSwitchResult = ["sent": false, "requestedEnabled": enabled, "acknowledged": false,
                "accepted": NSNull(), "error": message]
            throw error
        }
        let reply = transport.waitForMessage(timeout: 5) {
            $0.protocolID == 0x0f && $0.messageType == 21 && $0.receivedAt >= started && $0.json?["cmd"] as? String == "life_log_switch_result"
        }?.json
        let payload = reply?["payload"] as? [String: Any]
        let code = payload?["value"] as? Int
        let accepted = code == 0
        let meaning = code.map { [0: "success", 1: "noMicPermission", 2: "hallFolded", 3: "deviceLowBattery"][$0] ?? "unknown" }
        if accepted {
            lifeLogEnabledByProbe = enabled
            lifeLogSwitchNeedsCleanup = enabled
            lifeLogSwitchError = nil
        } else {
            if enabled, code != nil { lifeLogSwitchNeedsCleanup = previousCleanup }
            if let code {
                lifeLogSwitchError = "LifeLog 开关被拒绝：\(meaning ?? "unknown")（\(code)）。"
            } else { lifeLogSwitchError = reply == nil ? "LifeLog 开关结果超时，设备状态未确认。" : "LifeLog 开关回复缺少结果码，设备状态未确认。" }
        }
        lifeLogSwitchResult = ["sent": "life_log_switch", "requestedEnabled": enabled,
            "acknowledged": reply != nil, "accepted": code.map { $0 == 0 } as Any? ?? NSNull(),
            "code": code as Any? ?? NSNull(), "meaning": meaning as Any? ?? NSNull(),
            "reply": reply as Any? ?? NSNull()]
        if let lifeLogSwitchError { lifeLogSwitchResult["error"] = lifeLogSwitchError }
        return reply
    }

    private func stopLifeLogProbe() {
        // The official normal-stop path disables the device switch before
        // stopping its local runtime. Keep ingress installed through that reply.
        if lifeLogEnabledByProbe || lifeLogSwitchNeedsCleanup {
            do { _ = try setLifeLogSwitch(false) }
            catch { lifeLogProbeError = "Could not send LifeLog switch-off; disable it on the glasses" }
        }
        lifeLogObservationID = nil
        lifeLogObservationDeadline = nil
        transport.observeLifeLog(nil)
        transport.setLifeLogAudioHandler(nil)
        lifeLogTaskID = nil
        let probe = lifeLogAudioProbe
        let feed = assistantFeed
        if !lifeLogFinalizing, let probe {
            let completion = DispatchGroup(); completion.enter()
            lifeLogStopCompletion = completion
            lifeLogFinalizing = true
            lifeLogEventsQueue.async { [weak self] in
                var failure: String?
                do { try probe.finish() }
                catch { failure = error.localizedDescription }
                feed?.finish()
                if let self {
                    self.lock.lock()
                    if let failure { self.lifeLogProbeError = failure }
                    self.lifeLogFinalizing = false
                    self.lock.unlock()
                }
                completion.leave()
            }
        } else if probe == nil {
            feed?.finish()
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
        try todoSync.query(eventType: 1)
    }

    private func ownedTodoIDs(_ items: [[String: Any]]) -> [String] {
        items.filter(todoStore.owns).compactMap { ($0["eventID"] as? NSNumber)?.stringValue }
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
        try todoSync.sendTodos(items, total: items.count)
    }

    private func todoWireItem(_ item: [String: Any]) -> [String: Any] {
        ["eventType": 1, "eventID": item["eventID"] ?? 0,
         "createTime": item["createTime"] ?? 0, "title": item["title"] ?? "",
         "isImportant": item["isImportant"] ?? false, "status": item["status"] ?? 0,
         "lastModifiedTime": item["lastModifiedTime"] ?? 0, "eventSource": item["eventSource"] ?? 0]
    }

    private func mutateTodo(action: String, id requestedID: Int64?, body: [String: Any]) throws -> [String: Any] {
        let requestID = body["requestID"] as? String ?? UUID().uuidString
        var arguments = body
        arguments.removeValue(forKey: "requestID")
        if let requestedID { arguments["eventID"] = String(requestedID) }
        let canonical = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
        if let old = todoStore.mutation(requestID) {
            guard old.action == action, old.arguments == canonical else {
                throw BridgeError(status: 409, message: "A requestID cannot be reused for a different todo mutation")
            }
            if let cached = old.result, let bytes = cached.data(using: .utf8),
               var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], result["readBack"] as? Bool == true {
                result["duplicate"] = true
                return result
            }
            return try confirmTodoMutation(action: action, id: old.eventID, arguments: arguments,
                requestID: requestID, duplicate: true, wasVisibleBeforeMutation: old.wasVisibleBeforeMutation ?? true)
        }
        if action != "delete" {
            if arguments["important"] != nil, !(arguments["important"] is Bool) {
                throw BridgeError(status: 400, message: "important must be a boolean")
            }
            if arguments["completed"] != nil, !(arguments["completed"] is Bool) {
                throw BridgeError(status: 400, message: "completed must be a boolean")
            }
            if action == "add" || arguments["title"] != nil {
                guard let title = arguments["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BridgeError(status: 400, message: "title must not be empty")
                }
            }
            if action == "update", arguments["title"] == nil, arguments["important"] == nil, arguments["completed"] == nil {
                throw BridgeError(status: 400, message: "Provide title, important or completed")
            }
        }
        var items = try todoItems(queryTodos())
        let localItems = todoSync.localTodoItems()
        let id: Int64
        var target: [String: Any]
        let wasCompleted: Bool
        let wasVisibleBeforeMutation: Bool
        if action == "add" {
            let existing = Set((items + localItems).compactMap { ($0["eventID"] as? NSNumber)?.int64Value })
            guard let free = (Int64(90_000)..<100_000).first(where: { !existing.contains($0) }) else {
                throw BridgeError(status: 409, message: "No free local todo ID")
            }
            id = free
            let now = Date().timeIntervalSince1970, created = Int64(now * 1000)
            target = ["eventType": 1, "eventID": id, "createTime": created,
                "title": arguments["title"] as! String, "isImportant": arguments["important"] as? Bool ?? false,
                "status": 0, "lastModifiedTime": Int64(now), "eventSource": 0]
            wasCompleted = false
            wasVisibleBeforeMutation = false
            items.append(target)
            try todoStore.claim(id: id, createdMilliseconds: created)
        } else {
            guard let requestedID else { throw BridgeError(status: 404, message: "Todo not found") }
            let index = items.firstIndex { ($0["eventID"] as? NSNumber)?.int64Value == requestedID }
            let deviceItem = index.map { items[$0] }
            let cachedItem = localItems.first { ($0["eventID"] as? NSNumber)?.int64Value == requestedID }
            let pendingItem = cachedItem.flatMap { cached -> [String: Any]? in
                guard cached["syncState"] as? String == "outcome_unknown",
                      deviceItem == nil || (deviceItem?["createTime"] as? NSNumber) == (cached["createTime"] as? NSNumber)
                else { return nil }
                return cached
            }
            // A user may explicitly address one completed historical item. Never
            // append unrelated cached items to the pending alignment list.
            guard let existing = pendingItem ?? deviceItem ?? cachedItem.flatMap({
                ($0["status"] as? NSNumber)?.intValue == 1 ? $0 : nil
            }) else {
                throw BridgeError(status: 404, message: "Todo not found")
            }
            id = requestedID
            target = todoWireItem(existing)
            wasCompleted = (existing["status"] as? NSNumber)?.intValue == 1
            wasVisibleBeforeMutation = index != nil
            if action == "delete" {
                if let index { items.remove(at: index) }
            }
            else {
                if let title = arguments["title"] as? String { target["title"] = title }
                if let important = arguments["important"] as? Bool { target["isImportant"] = important }
                if let completed = arguments["completed"] as? Bool { target["status"] = completed ? 1 : 0 }
                target["lastModifiedTime"] = Int64(Date().timeIntervalSince1970)
                if let index { items[index] = target }
                else if arguments["completed"] as? Bool == false { items.append(target) }
            }
        }
        // Persist the intent before writing. An uncertain response can only be reconciled by reading.
        try todoStore.begin(requestID, action: action, arguments: canonical, id: id,
            wasVisibleBeforeMutation: wasVisibleBeforeMutation, item: todoWireItem(target))
        if action == "delete" {
            try send(0x16, type: 7, body: ["eventType": 1, "todoTotal": 1, "eventIDList": [id.magnitude]])
            try todoStore.markSent(requestID)
        } else {
            try send(0x16, type: 2, body: todoWireItem(target))
            try todoStore.markSent(requestID)
            let pending = items.filter { ($0["status"] as? NSNumber)?.intValue != 1 }
            if action == "update", !wasCompleted, arguments["completed"] as? Bool == true, pending.isEmpty {
                try synchronizeTodos([])
            } else if action == "update", wasCompleted || !wasVisibleBeforeMutation,
                      arguments["completed"] as? Bool == false {
                try synchronizeTodos(pending)
            }
        }
        return try confirmTodoMutation(action: action, id: id, arguments: arguments,
            requestID: requestID, duplicate: false, wasVisibleBeforeMutation: wasVisibleBeforeMutation)
    }

    private func confirmTodoMutation(action: String, id: Int64, arguments: [String: Any], requestID: String,
                                     duplicate: Bool, wasVisibleBeforeMutation: Bool) throws -> [String: Any] {
        let items = try todoItems(queryTodos())
        let item = items.first { ($0["eventID"] as? NSNumber)?.int64Value == id }
        let matches: Bool
        if action == "delete" { matches = wasVisibleBeforeMutation && item == nil }
        else {
            matches = item != nil && (arguments["title"] == nil || item?["title"] as? String == arguments["title"] as? String)
                && (arguments["important"] == nil || item?["isImportant"] as? Bool == arguments["important"] as? Bool)
                && (arguments["completed"] == nil || item?["status"] as? Int == ((arguments["completed"] as? Bool == true) ? 1 : 0))
        }
        var result: [String: Any] = ["eventID": id, "requestID": requestID, "action": action,
            "status": matches ? "confirmed_by_readback" : "outcome_unknown", "readBack": matches,
            "duplicate": duplicate, "visible": "unverified"]
        if action == "update", arguments["completed"] as? Bool == true {
            result["pendingRemoved"] = wasVisibleBeforeMutation && item == nil
        }
        if matches, action == "delete" { try todoStore.release(id: id) }
        try todoStore.complete(requestID, result: result)
        return result
    }
}
