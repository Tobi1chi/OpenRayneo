// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class BridgeController {
    private let transport: RFCOMMTransport
    let displays: DisplayController
    let speech: SpeechController
    let settings: GlassesSettingsController
    let schedules: ScheduleController
    let todoSync: ScheduleTodoSync
    let nativeRecording: NativeRecordingController
    let files: FileTransferController
    let networkRelay: NetworkRelayController
    let capabilities: CapabilityController
    let maintenance: MaintenanceController
    let ota: OTAUpdateController
    let teleprompterFollow: TeleprompterFollowController
    let assistantRuntime = AssistantRuntimeController()
    let nativeAssistant: NativeAssistantController
    private let operationLock: NSRecursiveLock
    private var nextSequence: UInt16 = 0
    private var recordingForeground: Bool?
    private var recordingVisibilityGeneration: Int?
    private var recordingVisibilityError: String?
    private let visibilityStateLock = NSLock()
    private var recordingVisibilitySnapshot: [String: Any] = [:]
    private var activeDocumentID: String?
    private var lastDocumentID: String?
    private var activeDocumentText = ""
    private var activeTeleprompterSettings: [String: Any] = [:]
    private var teleprompterPaused = false
    private var teleprompterPageOffset = 0
    private var teleprompterHighlightOffset = 0
    private var teleprompterError: String?
    private let teleprompterEvents = DispatchQueue(label: "openrayneo.teleprompter-events")
    private let teleprompterRepository = TeleprompterRepository()
    private var pendingDocumentID: String?
    private lazy var stateSynchronization = DeviceStateSynchronization(isCurrent: { [weak self] generation in
        guard let self else { return false }
        return self.transport.isConnected && self.transport.isBLEReady && self.transport.currentConnectionGeneration == generation
    }, steps: { [weak self] in self?.connectionSynchronizationSteps() ?? [] })

    init(address: String) {
        let transport = RFCOMMTransport(address: address)
        let operationLock = NSRecursiveLock()
        self.operationLock = operationLock
        self.transport = transport
        let nativeAssistant = NativeAssistantController(transport: transport)
        self.nativeAssistant = nativeAssistant
        transport.setNativeAssistantHandler { [weak nativeAssistant] in nativeAssistant?.handle($0) }
        let teleprompterFollow = TeleprompterFollowController(transport: transport, lock: operationLock)
        self.teleprompterFollow = teleprompterFollow
        settings = GlassesSettingsController(transport: transport, lock: operationLock)
        let todoStore = TodoOwnershipStore(deviceID: address)
        let todoSync = ScheduleTodoSync(transport: transport, lock: operationLock, todoStore: todoStore)
        self.todoSync = todoSync
        transport.setTodoStatusHandler { [weak todoSync] in todoSync?.handle($0) }
        schedules = ScheduleController(transport: transport, lock: operationLock, sync: todoSync)
        nativeRecording = NativeRecordingController(transport: transport, lock: operationLock, deviceID: address)
        let files = FileTransferController(transport: transport, lock: operationLock)
        self.files = files
        transport.setFileTransferHandlers(message: { [weak files] in files?.handle($0) }, corrupt: { [weak files] in files?.handleCorruptFrame($0) })
        let networkRelay = NetworkRelayController(transport: transport)
        self.networkRelay = networkRelay
        transport.setNetworkRelayHandler { [weak networkRelay] in networkRelay?.handle($0) }
        let capabilities = CapabilityController(transport: transport, lock: operationLock)
        self.capabilities = capabilities
        transport.setCapabilityHandler { [weak capabilities] in capabilities?.handle($0) }
        let maintenance = MaintenanceController(transport: transport, lock: operationLock)
        self.maintenance = maintenance
        transport.setMaintenanceHandler { [weak maintenance] in maintenance?.handle($0) }
        let ota = OTAUpdateController(transport: transport, lock: operationLock, deviceID: address)
        self.ota = ota
        transport.setOTAHandler { [weak ota] in ota?.handle($0) }
        let displays = DisplayController(transport: transport, lock: operationLock, deviceID: address, todoStore: todoStore, todoSync: todoSync)
        self.displays = displays
        transport.setDisplayControlHandler { [weak displays] message in displays?.handle(message) }
        speech = SpeechController(transport: transport, displays: displays)
        let stateSynchronization = self.stateSynchronization
        transport.setConnectionStateHandlers(ready: { [weak self, weak stateSynchronization] generation in
            guard let self else { return }
            self.displays.connectionReady()
            stateSynchronization?.request(generation: generation)
        }, lost: { [weak self, weak stateSynchronization] bleDisconnected in
            guard let self else { return }
            stateSynchronization?.connectionLost()
            self.nativeAssistant.connectionLost()
            self.displays.connectionLost(bleDisconnected: bleDisconnected)
            self.todoSync.cancelTodoSync()
        })
        transport.setTeleprompterHandlers(message: { [weak self] message in
            guard let self else { return }
            if message.messageType == 9 { self.teleprompterFollow.handle(message) }
            else { self.teleprompterEvents.async { [weak self] in self?.receiveTeleprompterControl(message) } }
        }, disconnected: { [weak self] in
            guard let self else { return }
            self.todoSync.cancelTodoSync()
            self.teleprompterFollow.connectionClosed()
            self.teleprompterEvents.async { [weak self] in
                guard let self else { return }
                self.operationLock.lock(); defer { self.operationLock.unlock() }
                self.cacheFollowPosition()
                if self.activeDocumentID != nil { self.teleprompterError = "眼镜连接已断开" }
            }
        })
    }

    var isConnected: Bool { transport.isConnected }
    var isBLEReady: Bool { transport.isBLEReady }
    var synchronizationStatus: [String: Any] { stateSynchronization.status }
    var diagnostics: [String: Any] {
        var result = transport.diagnostics
        result["appVisibility"] = visibilityStatus
        result["synchronization"] = stateSynchronization.status
        result["nativeAssistant"] = nativeAssistant.status
        return result
    }

    var visibilityStatus: [String: Any] {
        var result = transport.appVisibilityStatus
        visibilityStateLock.lock(); let recording = recordingVisibilitySnapshot; visibilityStateLock.unlock()
        result["recordingLastSentForeground"] = recording["recordingLastSentForeground"] ?? NSNull()
        result["recordingError"] = recording["recordingError"] ?? NSNull()
        return result
    }

    func synchronizeAppVisibility(_ foreground: Bool) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        defer {
            visibilityStateLock.lock()
            recordingVisibilitySnapshot = ["recordingLastSentForeground": recordingForeground as Any? ?? NSNull(),
                "recordingError": recordingVisibilityError as Any? ?? NSNull()]
            visibilityStateLock.unlock()
        }
        var failure: Error?
        do { try transport.setAppForeground(foreground) } catch { failure = error }
        let status = transport.appVisibilityStatus
        let generation = status["connectionGeneration"] as? Int
        if transport.isConnected, recordingForeground != foreground || recordingVisibilityGeneration != generation {
            do {
                try nativeRecording.reportForeground(foreground)
                recordingForeground = foreground; recordingVisibilityGeneration = generation
                recordingVisibilityError = nil
            } catch {
                recordingVisibilityError = (error as? BridgeError)?.message ?? error.localizedDescription
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    var teleprompterStatus: [String: Any] {
        operationLock.lock(); defer { operationLock.unlock() }
        cacheFollowPosition()
        let smart = activeTeleprompterSettings["scroll"] as? Int == 1
        var result = smart ? teleprompterFollow.status : [:]
        result["running"] = activeDocumentID != nil
        result["previewing"] = pendingDocumentID != nil && activeDocumentID == nil
        result["did"] = activeDocumentID ?? lastDocumentID as Any? ?? NSNull()
        result["paused"] = teleprompterPaused
        result["pageOffset"] = teleprompterPageOffset
        result["highLightOffset"] = teleprompterHighlightOffset
        result["totalBytes"] = activeDocumentText.utf8.count
        result["offsetUnit"] = "utf8_bytes"
        result["scroll"] = activeTeleprompterSettings["scroll"] as? Int ?? 2
        result["settings"] = activeTeleprompterSettings
        result["state"] = activeDocumentID != nil ? (teleprompterPaused ? 2 : 1) : (pendingDocumentID == nil ? 3 : 4)
        result["controlEvents"] = transport.displayEvents.filter { $0["protocol"] as? Int == 0x14 }
        if let teleprompterError { result["error"] = teleprompterError }
        return result
    }

    private func cacheFollowPosition() {
        guard activeTeleprompterSettings["scroll"] as? Int == 1 else { return }
        let state = teleprompterFollow.status
        teleprompterPageOffset = state["pageOffset"] as? Int ?? teleprompterPageOffset
        teleprompterHighlightOffset = state["highLightOffset"] as? Int ?? teleprompterHighlightOffset
    }

    private func receiveTeleprompterControl(_ message: RemoteMessage) {
        guard let type = message.messageType, let json = message.json else { return }
        operationLock.lock(); defer { operationLock.unlock() }
        if json["action"] as? Int == 1, [UInt64(1), 2, 3].contains(type) {
            do {
                switch type {
                case 1:
                    if json["type"] as? Int == 4, json["chunkid"] == nil, json["chunkId"] == nil,
                       let code = json["code"] as? Int, [20, 21, 26, 28].contains(code) {
                        throw BridgeError(status: 409, message: "眼镜提词快捷操作发生冲突，code=\(code)")
                    }
                    let items = try teleprompterRepository.listMetadata()
                    try sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": 1, "total": items.count,
                        "chunkinfo": ["chunkid": 1, "total_items": items.count, "islast": true], "items": items])
                case 2: try prepareGlassesTeleprompter(json)
                case 3: try playGlassesTeleprompter(json)
                default: break
                }
            } catch {
                teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription
                if type == 1 { try? sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": 1, "code": 2, "total": 0, "items": []]) }
            }
            return
        }
        if [UInt64(7), 8].contains(type), json["action"] as? Int == 1,
           let did = json["did"] as? String {
            do {
                try sendTeleprompter(type: type, action: 2, body: ["action": 2, "did": did, "code": 1])
                guard did == activeDocumentID || did == pendingDocumentID else { return }
                if type == 8 {
                    cacheFollowPosition()
                    let total = activeDocumentText.utf8.count
                    let page = min(total, max(0, json["pageOffset"] as? Int ?? teleprompterPageOffset))
                    let highlight = min(total, max(page, json["highLightOffset"] as? Int ?? teleprompterHighlightOffset))
                    guard page != teleprompterPageOffset || highlight != teleprompterHighlightOffset else { return }
                    teleprompterPageOffset = page
                    teleprompterHighlightOffset = highlight
                    if activeTeleprompterSettings["scroll"] as? Int == 1 { teleprompterFollow.seek(byteOffset: highlight) }
                } else {
                    guard did == activeDocumentID else { return }
                    var next = activeTeleprompterSettings
                    for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
                        if let value = json[key] { next[key] = value }
                    }
                    guard !NSDictionary(dictionary: next).isEqual(to: activeTeleprompterSettings) else { return }
                    cacheFollowPosition()
                    activeTeleprompterSettings = next
                    if next["scroll"] as? Int == 1 {
                        try teleprompterFollow.start(did: did, text: activeDocumentText, settings: next)
                        teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
                        teleprompterFollow.setPaused(teleprompterPaused)
                    } else { teleprompterFollow.stop() }
                }
            } catch { teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription }
            return
        }
        guard [UInt64(4), 5, 6].contains(type) else { return }
        guard let documentID = activeDocumentID, json["did"] as? String == documentID,
              let action = json["action"] as? Int, action == 1 || action == 2 else { return }
        if action == 2, let code = json["code"] as? Int, code != 1 {
            teleprompterError = "眼镜拒绝提词控制 type=\(type)，code=\(code)"
            return
        }
        cacheFollowPosition()
        switch type {
        case 4:
            teleprompterPaused = true
            teleprompterFollow.setPaused(true)
        case 5:
            teleprompterPaused = false
            teleprompterFollow.setPaused(false)
        case 6:
            teleprompterFollow.stop()
            activeDocumentID = nil
            pendingDocumentID = nil
        default: break
        }
        if action == 1 {
            do { try sendTeleprompter(type: type, action: 2, body: ["action": 2, "did": documentID, "code": 1]) }
            catch { teleprompterError = error.localizedDescription }
        }
    }

    private func prepareGlassesTeleprompter(_ body: [String: Any]) throws {
        let did = body["did"] as? String ?? ""
        guard !did.isEmpty, let document = try teleprompterRepository.load(did: did) else {
            try sendTeleprompter(type: 2, action: 2, body: ["action": 2, "did": did, "code": 5])
            throw BridgeError(status: 404, message: "眼镜选择的稿件未保存在这台 Mac")
        }
        if activeDocumentID == did || pendingDocumentID == did { return }
        teleprompterFollow.stop()
        activeDocumentID = nil; pendingDocumentID = did; lastDocumentID = did
        activeDocumentText = document.text; activeTeleprompterSettings = document.settings.wireBody
        teleprompterPageOffset = 0; teleprompterHighlightOffset = 0; teleprompterPaused = false; teleprompterError = nil
        var response = document.settings.wireBody
        response.merge(["action": 2, "did": did, "code": 1, "pageOffset": 0, "highLightOffset": 0]) { _, new in new }
        let started = Date()
        do {
            try sendTeleprompter(type: 2, action: 2, body: response)
            try sendScriptTransfer(taskID: "task_2_\(Int64(Date().timeIntervalSince1970 * 1000))", documentID: did, content: Data(document.text.utf8))
            try waitForTeleprompterAcceptance(type: 2, documentID: did, since: started, timeout: 30, transferFinishedAt: Date())
        } catch {
            pendingDocumentID = nil
            throw error
        }
    }

    private func playGlassesTeleprompter(_ body: [String: Any]) throws {
        let did = body["did"] as? String ?? ""
        guard !did.isEmpty, did == pendingDocumentID || did == activeDocumentID else {
            try sendTeleprompter(type: 3, action: 2, body: ["action": 2, "did": did, "code": 2])
            throw BridgeError(status: 409, message: "眼镜请求播放的稿件与已准备稿件不一致")
        }
        do {
            if activeTeleprompterSettings["scroll"] as? Int == 1 {
                try teleprompterFollow.start(did: did, text: activeDocumentText, settings: activeTeleprompterSettings)
                teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
            }
            var response = activeTeleprompterSettings
            response.merge(["action": 2, "did": did, "code": 1,
                "checksum": ProtocolCodec.fnv1a32(Data(activeDocumentText.utf8)),
                "pageOffset": teleprompterPageOffset, "highLightOffset": teleprompterHighlightOffset]) { _, new in new }
            try sendTeleprompter(type: 3, action: 2, body: response)
            activeDocumentID = did; pendingDocumentID = nil; teleprompterPaused = false; teleprompterError = nil
        } catch {
            teleprompterFollow.stop()
            try? sendTeleprompter(type: 3, action: 2, body: ["action": 2, "did": did, "code": 2])
            throw error
        }
    }

    func connect() throws {
        try transport.ensureConnected()
        _ = stateSynchronization.request(generation: transport.currentConnectionGeneration).wait(timeout: .now() + 35)
    }

    func prepareSystemPairing() throws {
        try transport.prepareSystemPairing()
    }

    func synchronizeDeviceState() throws -> [String: Any] {
        try transport.ensureConnected()
        _ = stateSynchronization.request(generation: transport.currentConnectionGeneration, refresh: true).wait(timeout: .now() + 35)
        return stateSynchronization.status
    }

    func interruptDataChannel() {
        transport.interruptDataChannel()
    }

    func suspendConnectionRecovery() {
        transport.suspendRecovery()
    }

    private func connectionSynchronizationSteps() -> [DeviceStateSynchronization.Step] {
        [
            .init(name: "clock", confirmation: "sent", read: { [self] in
                try settings.synchronizeClock()
                return ["sent": true]
            }),
            .init(name: "visibility", confirmation: "sent", read: { [self] in
                try synchronizeAppVisibility(transport.appVisibilityStatus["requestedForeground"] as? Bool ?? true)
                return visibilityStatus
            }),
            .init(name: "recording", confirmation: "read_back", read: { [self] in
                operationLock.lock(); defer { operationLock.unlock() }
                try nativeRecording.queryCurrentStatus()
                let state = try nativeRecording.route(method: "GET", path: "/v1/native-recording", body: [:])?.1 ?? [:]
                return ["activeUUID": state["activeUUID"] ?? NSNull(), "activeState": state["activeState"] ?? NSNull()]
            }),
            .init(name: "status", confirmation: "read_back", read: { [self] in
                try settings.route(method: "GET", path: "/v1/glasses/status", body: [:])?.1 ?? [:]
            }),
            .init(name: "settings", confirmation: "read_back", read: { [self] in
                try settings.route(method: "GET", path: "/v1/glasses/settings", body: [:])?.1 ?? [:]
            }),
            .init(name: "teleprompter", confirmation: "read_back", read: { [self] in
                let state = try synchronizeTeleprompterState()
                return state.filter { ["did", "state", "paused", "pageOffset", "highLightOffset", "totalBytes", "error"].contains($0.key) }
            })
        ]
    }

    func postNotification(title: String, body: String, source: [String: Any] = [:]) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "notificationUID": source["notificationUID"] as? String ?? String(timestamp),
            "appId": source["appId"] as? String ?? "com.openrayneo.bridge",
            "appName": source["appName"] as? String ?? "OpenRayneo Bridge",
            "title": title,
            "subtitle": source["subtitle"] as? String as Any? ?? NSNull(),
            "content": body,
            "timestamp": source["timestamp"] as? String ?? String(timestamp),
            "category": source["category"] as? Int ?? 0,
            "reply": false,
            "type": 1
        ]
        try sendNotification(payload)
    }

    func startTeleprompter(title: String, text: String, speed: Int, documentID requestedID: String? = nil, options: [String: Any] = [:]) throws -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !text.isEmpty else { throw BridgeError(status: 400, message: "text must not be empty") }
        if activeDocumentID != nil { try controlTeleprompter("stop") }
        pendingDocumentID = nil

        let documentID = requestedID ?? Self.uuidV7()
        let content = Data(text.utf8)
        let characterCount = content.count
        let timestamp = Int64(Date().timeIntervalSince1970)
        let timezone = TimeZone.current.secondsFromGMT()
        var settings: [String: Any] = [
            "countdown": 3,
            "scroll": 2,
            "speed": speed,
            "gear": 1,
            "depth": 1,
            "size": 18,
            "width": 492,
            "leading": 4
        ]
        for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
            if let value = options[key] { settings[key] = value }
        }
        let pageOffset = max(0, min(content.count, options["pageOffset"] as? Int ?? 0))
        let highlightOffset = max(pageOffset, min(content.count, options["highLightOffset"] as? Int ?? pageOffset))
        let savedSettings = try JSONDecoder().decode(TeleprompterPlaybackSettings.self, from: JSONSerialization.data(withJSONObject: settings))
        try teleprompterRepository.upsert(did: documentID, title: title, text: text, settings: savedSettings,
            pageOffset: pageOffset, highLightOffset: highlightOffset)

        teleprompterFollow.stop()
        if settings["scroll"] as? Int == 1 {
            try teleprompterFollow.start(did: documentID, text: text, settings: settings)
            teleprompterFollow.seek(byteOffset: highlightOffset)
        }
        var started = false
        defer {
            if !started {
                teleprompterFollow.stop()
                if transport.isConnected { try? sendTeleprompter(type: 6, action: 1, body: ["action": 1, "did": documentID]) }
            }
        }

        var startBody: [String: Any] = settings
        startBody["action"] = 1
        startBody["total"] = characterCount
        startBody["did"] = documentID
        startBody["pageOffset"] = pageOffset
        startBody["highLightOffset"] = highlightOffset
        var item: [String: Any] = [
            "did": documentID,
            "pin": false,
            "title": title,
            "offset": 0,
            "scroll": settings["scroll"] as? Int ?? 2,
            "total": characterCount,
            "timestamp": timestamp,
            "preview": String(text.prefix(80)),
            "timezone": timezone
        ]
        if title.isEmpty { item["title"] = "Untitled" }
        let listBody: [String: Any] = [
            "action": 2,
            "type": 3,
            "total": try teleprompterRepository.listMetadata().count,
            "chunkinfo": ["chunkid": 1, "total_items": 1, "islast": true],
            "items": [item]
        ]
        try sendTeleprompter(type: 1, action: 2, body: listBody)

        let handshakeStarted = Date()
        try sendTeleprompter(type: 2, action: 1, body: startBody)
        let taskID = "task_2_\(Int64(Date().timeIntervalSince1970 * 1000))"
        try sendScriptTransfer(taskID: taskID, documentID: documentID, content: content)
        try waitForTeleprompterAcceptance(type: 2, documentID: documentID, since: handshakeStarted, timeout: 30, transferFinishedAt: Date())
        // Firmware 1.0.5.12 sends its receipt before the 300 ms startup view
        // transition finishes. An immediate play request cannot start its countdown.
        usleep(350_000)

        var transferBody: [String: Any] = settings
        transferBody["action"] = 1
        transferBody["did"] = documentID
        transferBody["total"] = characterCount
        transferBody["pageOffset"] = pageOffset
        transferBody["highLightOffset"] = highlightOffset
        transferBody["code"] = 1
        transferBody["checksum"] = ProtocolCodec.fnv1a32(content)
        let playRequested = Date()
        try sendTeleprompter(type: 3, action: 1, body: transferBody)
        try waitForTeleprompterAcceptance(type: 3, documentID: documentID, since: playRequested, timeout: 15)

        activeDocumentID = documentID
        pendingDocumentID = nil
        lastDocumentID = documentID
        activeDocumentText = text
        activeTeleprompterSettings = settings
        teleprompterPageOffset = pageOffset
        teleprompterHighlightOffset = highlightOffset
        teleprompterPaused = false
        teleprompterError = nil
        started = true
        return documentID
    }

    func controlTeleprompter(_ action: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let documentID = activeDocumentID ?? (action == "stop" ? pendingDocumentID : nil) else {
            throw BridgeError(status: 409, message: "No teleprompter script is active")
        }
        cacheFollowPosition()
        switch action {
        case "pause":
            try sendTeleprompter(type: 4, action: 1, body: [
                "action": 1,
                "did": documentID,
                "offset": 0,
                "code": 1,
                "isCompleted": false
            ])
            teleprompterFollow.setPaused(true)
            teleprompterPaused = true
        case "resume":
            try sendTeleprompter(type: 5, action: 1, body: ["action": 1, "did": documentID])
            teleprompterFollow.setPaused(false)
            teleprompterPaused = false
        case "stop":
            teleprompterFollow.stop()
            try sendTeleprompter(type: 6, action: 1, body: ["action": 1, "did": documentID])
            activeDocumentID = nil
            pendingDocumentID = nil
        default:
            throw BridgeError(status: 404, message: "Unknown teleprompter action")
        }
    }

    func updateTeleprompterSettings(_ settings: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let documentID = activeDocumentID else { throw BridgeError(status: 409, message: "No teleprompter script is active") }
        var body = settings
        body["action"] = 1; body["did"] = documentID
        var nextSettings = activeTeleprompterSettings
        for (key, value) in settings { nextSettings[key] = value }
        if nextSettings["scroll"] as? Int == 1 {
            cacheFollowPosition()
            try teleprompterFollow.start(did: documentID, text: activeDocumentText, settings: nextSettings)
            teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
            teleprompterFollow.setPaused(teleprompterPaused)
        } else { teleprompterFollow.stop() }
        try sendTeleprompter(type: 7, action: 1, body: body)
        activeTeleprompterSettings = nextSettings
    }

    func updateTeleprompterProgress(_ position: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard let documentID = activeDocumentID else { throw BridgeError(status: 409, message: "No teleprompter script is active") }
        var body = position
        body["action"] = 1; body["did"] = documentID
        try sendTeleprompter(type: 8, action: 1, body: body)
        if let offset = position["pageOffset"] as? Int { teleprompterPageOffset = offset }
        if let offset = position["highLightOffset"] as? Int { teleprompterHighlightOffset = offset }
        if let offset = position["highLightOffset"] as? Int { teleprompterFollow.seek(byteOffset: offset) }
    }

    func updateTeleprompterLibrary(_ body: [String: Any]) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try transport.ensureConnected()
        let items = body["items"] as? [[String: Any]] ?? []
        try sendTeleprompter(type: 1, action: 2, body: ["action": 2, "type": body["type"] as? Int ?? 3,
            "total": body["total"] as? Int ?? items.count, "items": items,
            "chunkinfo": ["chunkid": 1, "total_items": items.count, "islast": true]])
    }

    func synchronizeTeleprompterState() throws -> [String: Any] {
        operationLock.lock(); defer { operationLock.unlock() }
        let started = Date()
        try sendTeleprompter(type: 10, action: 1, body: ["action": 1, "checksum": "", "state": NSNull(), "pageOffset": 0, "highLightOffset": 0])
        guard let reply = transport.waitForMessage(timeout: 10, matching: {
            $0.protocolID == 0x14 && $0.messageType == 10 && $0.receivedAt >= started && $0.json?["action"] as? Int == 2
        })?.json else {
            throw BridgeError(status: 504, message: "眼镜未返回提词状态")
        }
        if let code = reply["code"] as? Int, code != 1 {
            throw BridgeError(status: 503, message: "眼镜拒绝提词状态查询，code=\(code)")
        }
        guard let state = reply["state"] as? Int, (1...4).contains(state) else {
            throw BridgeError(status: 502, message: "眼镜返回了无法识别的提词状态")
        }
        cacheFollowPosition()
        if state == 3 {
            teleprompterFollow.stop(); activeDocumentID = nil; pendingDocumentID = nil
            teleprompterPaused = false; teleprompterError = nil
            return teleprompterStatus
        }
        guard let did = reply["did"] as? String, !did.isEmpty,
              let document = try teleprompterRepository.load(did: did) else {
            throw BridgeError(status: 404, message: "眼镜当前稿件不在本地稿件库，无法恢复播放状态")
        }
        let checksum = ProtocolCodec.fnv1a32(Data(document.text.utf8))
        if let remoteChecksum = reply["checksum"] as? String, !remoteChecksum.isEmpty, remoteChecksum != checksum {
            throw BridgeError(status: 409, message: "眼镜稿件与本地正文校验值不同，请重新传输后播放")
        }
        var restoredSettings = document.settings.wireBody
        for key in ["countdown", "scroll", "speed", "gear", "depth", "size", "width", "leading"] {
            if let value = reply[key] { restoredSettings[key] = value }
        }
        let total = document.text.utf8.count
        teleprompterPageOffset = min(total, max(0, reply["pageOffset"] as? Int ?? 0))
        teleprompterHighlightOffset = min(total, max(teleprompterPageOffset, reply["highLightOffset"] as? Int ?? teleprompterPageOffset))
        teleprompterFollow.stop()
        lastDocumentID = did; activeDocumentText = document.text; activeTeleprompterSettings = restoredSettings
        activeDocumentID = state == 4 ? nil : did; pendingDocumentID = state == 4 ? did : nil
        teleprompterPaused = state == 2; teleprompterError = nil
        if state != 4, restoredSettings["scroll"] as? Int == 1 {
            do {
                try teleprompterFollow.start(did: did, text: document.text, settings: restoredSettings)
                teleprompterFollow.seek(byteOffset: teleprompterHighlightOffset)
                teleprompterFollow.setPaused(teleprompterPaused)
            } catch { teleprompterError = (error as? BridgeError)?.message ?? error.localizedDescription }
        }
        return teleprompterStatus
    }

    private func sendNotification(_ body: [String: Any]) throws {
        let frame = try ProtocolCodec.notificationFrame(sequence: takeSequence(), body: body)
        try transport.send(frame)
    }

    private func sendTeleprompter(type: UInt64, action: UInt64, body: [String: Any]) throws {
        let frame = try ProtocolCodec.teleprompterFrame(sequence: takeSequence(), type: type, action: action, body: body)
        try transport.send(frame)
        usleep(25_000)
    }

    private func waitForTeleprompterAcceptance(type: UInt64, documentID: String, since started: Date, timeout: TimeInterval, transferFinishedAt: Date? = nil) throws {
        guard let reply = transport.waitForMessage(timeout: timeout, matching: {
            guard $0.protocolID == 0x14 && $0.messageType == type && $0.receivedAt >= started &&
                $0.json?["action"] as? Int == 2 && $0.json?["did"] as? String == documentID else { return false }
            if type == 2, $0.json?["code"] as? Int == 1, let transferFinishedAt {
                return $0.receivedAt >= transferFinishedAt
            }
            return true
        })?.json else { throw BridgeError(status: 504, message: "眼镜未确认提词请求 type=\(type)") }
        guard let code = reply["code"] as? Int, code == 1 || (type == 2 && code == 7) else {
            throw BridgeError(status: 503, message: "眼镜拒绝提词请求 type=\(type)，code=\(reply["code"] ?? "missing")")
        }
    }

    private func sendScriptTransfer(taskID: String, documentID: String, content: Data) throws {
        var info = ProtocolCodec.field(1, string: taskID)
        info.append(ProtocolCodec.field(2, string: documentID))
        info.append(ProtocolCodec.field(3, varint: UInt64(content.count)))
        info.append(ProtocolCodec.field(4, string: ProtocolCodec.md5(content)))
        info.append(ProtocolCodec.field(5, varint: 17))
        try transport.send(ProtocolCodec.fileTransferFrame(protobuf: ProtocolCodec.field(1, bytes: info)))

        while true {
            let message = transport.waitForMessage(timeout: 30) {
                guard $0.protocolID == 0x11, let field = ProtocolCodec.firstFieldNumber($0.protobuf),
                      [UInt64(3), 5, 6].contains(field), let payload = ProtocolCodec.nestedBytes($0.protobuf, field: field) else { return false }
                return ProtocolCodec.stringValue(payload, field: 1) == taskID
            }
            guard let message, let field = ProtocolCodec.firstFieldNumber(message.protobuf),
                  let request = ProtocolCodec.nestedBytes(message.protobuf, field: field) else {
                throw BridgeError(status: 504, message: "Glasses script transfer timed out")
            }
            if field == 6 { throw BridgeError(status: 409, message: "Glasses cancelled script transfer") }
            if field == 5 {
                guard (ProtocolCodec.varintValue(request, field: 2) ?? 0) == 0 else {
                    throw BridgeError(status: 503, message: "Glasses rejected script transfer")
                }
                fputs("[RayNeo iO transfer] Glasses confirmed \(content.count) bytes\n", stderr)
                return
            }
            guard let requestedSize = ProtocolCodec.varintValue(request, field: 4) else {
                throw BridgeError(status: 502, message: "Glasses requested a script chunk without its size")
            }
            let offsetValue = ProtocolCodec.varintValue(request, field: 3) ?? 0
            guard offsetValue <= UInt64(content.count) else {
                throw BridgeError(status: 502, message: "Glasses requested a script chunk outside the file")
            }
            let offset = Int(offsetValue)
            let size = Int(min(requestedSize, UInt64(content.count) - offsetValue))
            guard size > 0 else {
                throw BridgeError(status: 502, message: "Glasses requested an empty script chunk")
            }
            let end = offset + size
            let chunk = content.subdata(in: offset..<end)
            var entry = ProtocolCodec.field(1, string: taskID)
            entry.append(ProtocolCodec.field(2, varint: ProtocolCodec.varintValue(request, field: 2) ?? 0))
            entry.append(ProtocolCodec.field(3, varint: UInt64(offset)))
            entry.append(ProtocolCodec.field(4, varint: UInt64(chunk.count)))
            entry.append(ProtocolCodec.field(5, bytes: chunk))
            try transport.send(ProtocolCodec.fileTransferFrame(protobuf: ProtocolCodec.field(4, bytes: entry)))
            fputs("[RayNeo iO transfer] Sent bytes \(offset)..<\(end) of \(content.count)\n", stderr)
        }
    }

    private func takeSequence() -> UInt16 {
        nextSequence &+= 1
        return nextSequence
    }

    private static func uuidV7() -> String {
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> UInt64((5 - index) * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let value = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return value.uuidString.lowercased()
    }
}

