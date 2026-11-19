// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*
import org.json.JSONObject
import java.time.LocalTime

internal class BridgeService : Service() {
    inner class LocalBinder : Binder() { val service get() = this@BridgeService }
    private val binder = LocalBinder()
    private val main = Handler(Looper.getMainLooper())
    val observers = mutableSetOf<() -> Unit>()
    val devices = linkedMapOf<String, RayneoConnection.Device>()
    val logs = ArrayDeque<String>()
    lateinit var settings: AppSettings; private set
    lateinit var conversations: ConversationController; private set
    lateinit var voiceTransport: GlassesVoiceTransport; private set
    lateinit var requests: GlassesRequests; private set
    lateinit var deviceSettings: GlassesDeviceSettings; private set
    lateinit var teleprompter: TeleprompterLibrary; private set
    lateinit var agentServer: LocalAgentServer; private set
    lateinit var recordSync: RecordSyncServer; private set
    lateinit var content: CompanionContent; private set
    private lateinit var supervisor: ConnectionSupervisor
    val connection get() = supervisor.transport
    private lateinit var display: GlassesDisplay
    private lateinit var audio: PromptAudio
    private lateinit var voiceAudio: PromptAudio
    val navigation get() = NavigationFeed
    lateinit var agent: MobileAgent; private set
    lateinit var codex: CodexClient; private set
    var state = GlassesState(); private set
    val status get() = state.link.detail
    val ready get() = state.link.phase in setOf(LinkPhase.FULL, LinkPhase.BLE_ONLY)
    val busy get() = state.link.phase in setOf(LinkPhase.SCANNING, LinkPhase.CONNECTING, LinkPhase.RETRY_WAIT, LinkPhase.CLOSING)
    val displayStatus get() = state.displayDescription
    val audioStatus get() = state.audio.detail
    val audioLevels get() = if (voiceAudio.state.active) voiceAudio.state else audio.state
    private val events = ArrayDeque<GlassesEvent>()
    private var dispatching = false
    private var destroyed = false
    private var initialized = false
    private var foreground = false
    private var stopAfterDisconnect = false
    private var restoreTask: Runnable? = null
    private var autoClearFor: AnswerRef? = null
    private var clearAnswerTask: Runnable? = null
    private var closeTask: Runnable? = null
    private var audioOwner: Long? = null
    private var nextAnswer = 0L
    private val serviceInstance = java.util.UUID.randomUUID().toString()
    private var latestRealtimeRequest = 0L
    private val pendingAnswers = mutableMapOf<AnswerSource, AnswerPermit>()
    private data class VoiceDelivery(val ref: AnswerRef, val source: ConversationSource, val wakeId: String?)
    private var voiceReply: VoiceDelivery? = null
    private var conversationOwnsDisplay = false
    private var resumeAlwaysOn: ConversationMode? = null
    private var notificationText = ""
    private var notificationReadStatus = ""
    private val navigationObserver: () -> Unit = {
        if (notificationReadStatus != navigation.listenerState.detail) {
            notificationReadStatus = navigation.listenerState.detail
            onLog(notificationReadStatus)
        }
        dispatch(GlassesEvent.NavigationChanged(navigationSnapshot()))
    }
    private val notificationRefresh = object : Runnable {
        override fun run() {
            if (navigation.enabled) NavigationNotifications.refresh(this@BridgeService)
            content.automaticWeather()
            main.postDelayed(this, 30_000)
        }
    }
    private val audioRefresh = object : Runnable {
        override fun run() {
            audioOwner?.let { dispatch(GlassesEvent.AudioChanged(it, audio.state.coordinatorState())) }
            if (conversations.state.running) audioLevels.error?.let { conversations.transportError(it) }
            main.postDelayed(this, 1_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this)
        supervisor = ConnectionSupervisor(this, main,
            { dispatch(GlassesEvent.LinkChanged(it)) }, { devices[it.bluetooth.address] = it; notifyUI() },
            { frame, source -> runCatching {
                teleprompter.observe(frame)
                requests.receive(frame)
                voiceTransport.receive(frame)
                display.receive(frame, source)
            }.onFailure { onLog("眼镜消息解析失败：$source") } }, ::onLog)
        requests = GlassesRequests(main, connection::sendFrame)
        deviceSettings = GlassesDeviceSettings(requests, ::notifyUI)
        content = CompanionContent(this, requests, { connection.resolvedClassicAddress?.takeIf { state.link.phase == LinkPhase.FULL } }, ::notifyUI)
        teleprompter = TeleprompterLibrary(this, requests, ::notifyUI)
        agentServer = LocalAgentServer(main, settings, ::notifyUI, {
            JSONObject().put("version", BuildConfig.VERSION_NAME).put("versionCode", BuildConfig.VERSION_CODE)
                .put("phoneId", nativeIdentity().getString("phoneId")).put("link", state.link.phase.name).put("display", state.displayDescription).put("conversationRunning", conversations.state.running)
        }, {
            org.json.JSONArray(conversations.repository.records.map { it.json().apply { remove("speakerSamples") } })
        }, { name, args, allowed, completion -> requests.withPermission(allowed) { executeTool(name, args, completion) } }, { agent.harness }, ::recordAPI)
        requests.observe = { protocol, type, body ->
            when (protocol) { 15 -> deviceSettings.observe(type, body); 22 -> content.observe(type, body) }
        }
        conversations = ConversationController(this, settings, ::notifyUI, ::conversationCapture, ::submitVoiceRequest,
            { segment, source ->
                if (source == ConversationSource.NATIVE) segment.roundId?.let { voiceTransport.asr(segment.text, it) }
            }, ::resumeBackground)
        recordSync = RecordSyncServer(settings, conversations.repository, conversations.recordings, main, ::notifyUI)
        if (settings.read().optBoolean("recordSyncEnabled")) recordSync.start()
        voiceAudio = PromptAudio { left, right -> conversations.accept(left, right) }
        voiceTransport = GlassesVoiceTransport(connection::sendFrame, ::nativeWake, {
            voiceAudio.stop(); voiceAudio.start(1); conversations.nextRound()
        }, { ended ->
            if (ended) conversations.stop() else { voiceAudio.stop(); conversations.endRound() }
        }, { voiceAudio.accept(it) }, { conversations.transportError(it) })
        audio = PromptAudio { left, right ->
            if (conversations.state.running && conversations.state.source == ConversationSource.REALTIME) conversations.accept(left, right)
        }
        display = GlassesDisplay(connection::sendFrame,
            { task, delay -> main.postDelayed(task, delay) }, { main.removeCallbacks(it) }, ::onLog,
            { id, signal -> dispatch(GlassesEvent.SessionSignal(id, signal)) },
            { id, packet -> if (audioOwner == id && state.session?.id == id) audio.accept(packet) },
            { dispatch(GlassesEvent.ExternalPage(it)) })
        navigation.initialize(this)
        navigation.stop()
        navigation.observers.add(navigationObserver)
        agent = MobileAgent(settings, conversations.repository, { question, answer, input -> deliverExternalVoice(question, answer, input) }, ::notifyUI, { name, args, allowed, completion -> requests.withPermission(allowed) { executeTool(name, args, completion) } }) { question, answer -> completed(AnswerSource.MOBILE_AGENT, question, answer) }
        if (settings.read().optBoolean("localAgentEnabled")) agentServer.start()
        codex = CodexClient(settings, ::notifyUI) { question, answer -> completed(AnswerSource.COMPUTER_CODEX, question, answer) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("bridge", "眼镜连接与导航", NotificationManager.IMPORTANCE_LOW))
        initialized = true
        dispatch(GlassesEvent.NavigationChanged(navigationSnapshot()))
        NavigationNotifications.refresh(this)
        main.postDelayed(notificationRefresh, 30_000)
        main.postDelayed(audioRefresh, 1_000)
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            cancelAnswer(AnswerSource.MOBILE_AGENT); closeCodex()
            dispatch(GlassesEvent.StopNavigation)
            stopAfterDisconnect = true
            disconnect()
        } else {
            startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                if (PhoneLocation.allowed(this)) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0)
            foreground = true
        }
        return START_NOT_STICKY
    }

    fun enableLocationWhileVisible() {
        if (foreground && PhoneLocation.allowed(this))
            startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
    }

    private fun dispatch(event: GlassesEvent) {
        if (destroyed) return
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { dispatch(event) }; return }
        events.addLast(event)
        if (dispatching) return
        dispatching = true
        try {
            while (events.isNotEmpty()) {
                val transition = GlassesCoordinator.reduce(state, events.removeFirst())
                val previous = state
                state = transition.state
                if (previous.link.phase == LinkPhase.FULL && state.link.phase != LinkPhase.FULL) {
                    conversations.stop(); voiceTransport.disconnected(); voiceAudio.stop()
                    requests.disconnected(); deviceSettings.disconnected(); content.disconnected(); teleprompter.disconnected()
                }
                if (previous.link.phase != LinkPhase.FULL && state.link.phase == LinkPhase.FULL) content.connected()
                if (previous.session != null && state.session == null && previous.session.mode == PageMode.PROMPT && conversations.state.running && conversations.state.source == ConversationSource.REALTIME && conversationOwnsDisplay &&
                    (state.ownership != DisplayOwnership.APP || state.intent == DisplayIntent.Idle || state.intent == DisplayIntent.Navigation || state.error != null)) {
                    conversationOwnsDisplay = false; conversations.stop()
                }
                updateAnswerClearTimer()
                if (state.displayDescription != previous.displayDescription) onLog(state.displayDescription)
                transition.effects.forEach { effect ->
                    runCatching { execute(effect) }.onFailure { error ->
                        val message = error.message ?: "眼镜操作失败"
                        onLog(message)
                        when (effect) {
                            is GlassesEffect.StartPage -> events.add(GlassesEvent.SessionSignal(effect.session.id, PageSignal.Failed(message)))
                            is GlassesEffect.UpdatePage -> events.add(GlassesEvent.SessionSignal(effect.id, PageSignal.Failed(message)))
                            is GlassesEffect.ClosePage -> events.add(GlassesEvent.SessionSignal(effect.id, PageSignal.Closed(message)))
                            is GlassesEffect.StartAudio -> events.add(GlassesEvent.AudioChanged(effect.id, AudioState(AudioPhase.FAILED, message)))
                            is GlassesEffect.FollowNavigation -> events.add(GlassesEvent.StopNavigation)
                            else -> Unit
                        }
                    }
                }
            }
        } finally { dispatching = false }
        updateNotification(); notifyUI()
        if (stopAfterDisconnect && state.link.phase == LinkPhase.DISCONNECTED && !state.disconnecting) {
            stopAfterDisconnect = false
            foreground = false
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        }
    }
    private fun execute(effect: GlassesEffect) {
        when (effect) {
            is GlassesEffect.StartPage -> display.start(effect.session)
            is GlassesEffect.UpdatePage -> display.update(effect.id, effect.content)
            is GlassesEffect.ClosePage -> display.stop(effect.id)
            GlassesEffect.ResetPage -> display.reset()
            is GlassesEffect.StartAudio -> { audioOwner = effect.id; audio.start(effect.channels) }
            GlassesEffect.StopAudio -> { audioOwner = null; audio.stop() }
            is GlassesEffect.FollowNavigation -> navigation.follow(effect.key)
            GlassesEffect.StopFollowing -> navigation.stop()
            is GlassesEffect.ScheduleRestore -> {
                restoreTask?.let(main::removeCallbacks)
                restoreTask = Runnable { dispatch(GlassesEvent.RestoreAnswer(effect.id, effect.revision, effect.ref)) }
                    .also { main.postDelayed(it, 12_000) }
            }
            GlassesEffect.CancelRestore -> { restoreTask?.let(main::removeCallbacks); restoreTask = null }
            is GlassesEffect.ScheduleCloseTimeout -> {
                closeTask?.let(main::removeCallbacks)
                closeTask = Runnable { dispatch(GlassesEvent.CloseTimedOut(effect.id)) }.also { main.postDelayed(it, 1_500) }
            }
            GlassesEffect.CancelCloseTimeout -> { closeTask?.let(main::removeCallbacks); closeTask = null }
            GlassesEffect.DisconnectTransport -> supervisor.disconnect()
        }
    }

    fun scan() {
        check(!ready && state.link.phase != LinkPhase.CONNECTING && !state.disconnecting) { "请先断开当前连接" }
        devices.clear(); supervisor.scan()
    }
    fun connect(device: RayneoConnection.Device, bleOnly: Boolean) {
        check(!ready && !state.disconnecting) { "请先断开当前连接" }
        startForegroundService(Intent(this, BridgeService::class.java))
        dispatch(GlassesEvent.BeginConnection)
        runCatching { supervisor.connect(device, bleOnly) }.onFailure {
            supervisor.disconnect(); onLog(it.message ?: "连接失败")
        }
    }
    fun disconnect() {
        supervisor.cancelRetries()
        conversations.stop()
        dispatch(GlassesEvent.Disconnect)
    }
    fun followNavigation(key: String) {
        conversationOwnsDisplay = false
        if (conversations.state.running) conversations.stop()
        check(!state.disconnecting) { "请等待断开完成" }
        val entry = checkNotNull(navigation.entries[key]) { "该通知已消失，请在高德开始导航后刷新" }
        val frame = entry.instruction?.let { NavigationFrame.render(it.direction, it.meters, entry.title) }
            ?: NavigationFrame.status("指令暂未识别", "请查看高德")
        dispatch(GlassesEvent.SelectNavigation(NavigationState(true, key, frame)))
    }
    fun stopNavigation() = dispatch(GlassesEvent.StopNavigation)
    fun reopenNavigation() {
        val key = navigation.selectedKey ?: error("请先选择要跟随的高德通知")
        followNavigation(key)
    }
    fun clearDisplay() { autoClearFor = null; clearAnswerTask?.let(main::removeCallbacks); clearAnswerTask = null; dispatch(GlassesEvent.ClearDisplay) }
    fun enableAgentServer(enabled: Boolean) {
        if (enabled) {
            check(checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                "请先授予附近设备权限，再启用本机Agent入口"
            }
            agentServer.start()
            startForegroundService(Intent(this, BridgeService::class.java))
        } else agentServer.stop()
    }
    fun startTeleprompter(title: String, text: String, speed: Int, documentId: String? = null, completion: (Result<JSONObject>) -> Unit) {
        check(state.link.phase == LinkPhase.FULL && !state.disconnecting) { "请先完整连接眼镜" }
        conversationOwnsDisplay = false; conversations.stop(); dispatch(GlassesEvent.PauseDisplay)
        val allowed = requests.permission()
        val deadline = SystemClock.elapsedRealtime() + 2_500
        val wait = object : Runnable {
            override fun run() {
                if (!allowed() || state.link.phase != LinkPhase.FULL || state.disconnecting) { completion(Result.failure(IllegalStateException("眼镜已断开"))); return }
                if (state.session == null) {
                    val id = teleprompter.save(title, text, documentId ?: java.util.UUID.randomUUID().toString())
                    requests.withPermission(allowed) { teleprompter.start(id, speed, completion) }
                } else if (SystemClock.elapsedRealtime() < deadline) main.postDelayed(this, 50)
                else completion(Result.failure(IllegalStateException("旧显示尚未结束，请稍后重新播放")))
            }
        }; main.post(wait)
    }
    fun startConversation(mode: ConversationMode, source: ConversationSource, target: VoicePerson? = null) {
        check(state.link.phase == LinkPhase.FULL && !state.disconnecting) { "请先完整连接眼镜" }
        conversations.start(mode, source, target, if (source == ConversationSource.NATIVE) voiceTransport.wakeId else null)
    }
    private fun nativeWake() {
        notifyUI()
        if (!settings.read().optBoolean("nativeAutoAnswer")) return
        if (state.link.phase != LinkPhase.FULL || state.disconnecting) return
        if (conversations.state.running) {
            if (conversations.state.source == ConversationSource.ALWAYS_ON) {
                resumeAlwaysOn = conversations.state.mode.takeUnless { conversations.state.stopping }
                val wake = voiceTransport.wakeId
                conversations.handoffForWake {
                    if (voiceTransport.nativeActive && voiceTransport.wakeId == wake && state.link.phase == LinkPhase.FULL && !state.disconnecting)
                        startConversation(ConversationMode.DAILY, ConversationSource.NATIVE)
                    else resumeBackground()
                }
                return
            }
            if (conversations.state.source != ConversationSource.NATIVE) return
            conversations.nextRound(voiceTransport.wakeId); agent.harness.cancel("route"); agent.harness.cancel("hint"); voiceAudio.stop(); voiceAudio.start(1); voiceTransport.start(ConversationSource.NATIVE)
        } else {
            try { startConversation(ConversationMode.DAILY, ConversationSource.NATIVE) }
            catch (error: Exception) { conversations.report(error.message ?: "原生接听失败") }
        }
    }
    private fun resumeBackground() {
        val mode = resumeAlwaysOn ?: return
        if (destroyed || state.disconnecting || state.link.phase != LinkPhase.FULL) { resumeAlwaysOn = null; return }
        if (voiceTransport.nativeActive || conversations.state.running) return
        resumeAlwaysOn = null
        startConversation(mode, ConversationSource.ALWAYS_ON)
    }
    private fun conversationCapture(source: ConversationSource, start: Boolean) {
        if (start) {
            when (source) {
                ConversationSource.REALTIME -> { conversationOwnsDisplay = true; dispatch(GlassesEvent.OpenStandby) }
                ConversationSource.NATIVE, ConversationSource.ALWAYS_ON -> {
                    conversationOwnsDisplay = false
                    dispatch(GlassesEvent.PauseDisplay); voiceAudio.start(1); voiceTransport.start(source)
                }
            }
        } else {
            if (source == ConversationSource.NATIVE && voiceTransport.nativeActive) resumeAlwaysOn = null
            agent.harness.cancel("route"); agent.harness.cancel("hint")
            if (source == ConversationSource.REALTIME) {
                if (conversationOwnsDisplay) dispatch(GlassesEvent.PauseDisplay)
                conversationOwnsDisplay = false
            } else { voiceAudio.stop(); voiceTransport.stop() }
        }
    }
    private fun submitVoiceRequest(request: VoiceRequest): Boolean? {
        val identity = nativeIdentity()
        val input = JSONObject().put("source", request.source.name).put("wakeId", request.wakeId)
            .put("recordId", request.recordId).put("sourceRevision", request.sourceRevision).put("backfill", request.backfill)
            .put("contextKey", identity.getString("conversationKey"))
        if (request.source == ConversationSource.NATIVE && !request.backfill) {
            input.put("phoneId", identity.getString("phoneId")).put("conversationKey", identity.getString("conversationKey"))
        }
        if (request.source == ConversationSource.REALTIME) {
            latestRealtimeRequest = ++nextAnswer
            input.put("serviceInstance", serviceInstance).put("displayRevision", state.revision).put("realtimeRequest", latestRealtimeRequest)
        }
        // The relay's encrypted outbox accepts work even while DSH or the network is unavailable.
        agent.harness.submit(request.text, request.context + "\n入队时刻：${java.time.ZonedDateTime.now()}（交付时由外部Agent更新当前时间）", input = input) { result ->
            result.fold({ answer -> deliverExternalVoice(request.text, answer, input) }, { conversations.report(it.message ?: "外部Agent任务未完成") })
        }
        return true
    }
    private fun deliverExternalVoice(question: String, answer: String, input: JSONObject) {
        if (answer.isBlank()) return
        val id = input.optString("recordId")
        if (id.isNotBlank()) {
            conversations.repository.applyDerived(RecordDerived(id = input.optString("derivedId").ifBlank { java.util.UUID.randomUUID().toString() }, recordId = id, sourceRevision = input.optInt("sourceRevision", 1),
                kind = "analysis", text = answer, agent = "phone-local-agent"))
            conversations.refreshRecords()
        }
        val source = ConversationSource.valueOf(input.optString("source", "ALWAYS_ON"))
        val conversationKey = input.optString("conversationKey")
        if (source == ConversationSource.NATIVE && conversationKey.isNotBlank() && conversationKey != nativeIdentity().getString("conversationKey")) return
        if (input.optString("contextKey") == nativeIdentity().getString("conversationKey")) conversations.rememberReply(question, answer)
        val wake = input.optString("wakeId").takeUnless { it.isBlank() || it == "null" }
        if (source == ConversationSource.NATIVE && wake != null && wake == voiceTransport.wakeId && voiceTransport.nativeActive)
            voiceTransport.reply(answer, question, wake)
        else if (source == ConversationSource.REALTIME && input.optString("serviceInstance") == serviceInstance &&
            input.optLong("realtimeRequest") == latestRealtimeRequest && input.optLong("displayRevision", -1) == state.revision &&
            conversations.state.running && conversations.state.activeRecord?.id == id && conversationOwnsDisplay &&
            state.ownership == DisplayOwnership.APP && state.link.phase == LinkPhase.FULL && !state.disconnecting) {
            val ref = AnswerRef(AnswerSource.MOBILE_AGENT, input.getLong("realtimeRequest"))
            dispatch(GlassesEvent.AnswerRequested(ref))
            val permit = checkNotNull(state.answerPermit)
            autoClearFor = ref; clearAnswerTask?.let(main::removeCallbacks); clearAnswerTask = null
            dispatch(GlassesEvent.AnswerCompleted(AnswerContent(ref, question, answer), permit))
        } else if (state.link.phase == LinkPhase.FULL && !state.disconnecting) connection.sendNotification("助手", answer)
    }
    fun pausePrompt() { conversations.stop(); dispatch(GlassesEvent.PauseDisplay) }
    fun openStandby() = dispatch(GlassesEvent.OpenStandby)
    fun retryAudio() {
        check(state.link.phase == LinkPhase.FULL && state.session?.phase in setOf(PagePhase.LAYOUT, PagePhase.SETTLING, PagePhase.READY)) {
            "请先启动导航或实时提示，并等待眼镜确认"
        }
        dispatch(GlassesEvent.RetryAudio)
    }
    fun dismissAnswer() = dispatch(GlassesEvent.DismissAnswer)

    fun submitAnswer(source: AnswerSource, text: String, context: String = "", allowTools: Boolean = true, retainHistory: Boolean = true, forceDsh: Boolean = false) {
        if (source == AnswerSource.MOBILE_AGENT) {
            check(agentServer.state.enabled) { "请先在设置的“DSH Go 与外部 Agent”启用本机入口，并启动DSH Go插件" }
        }
        when (source) {
            AnswerSource.MOBILE_AGENT -> check(!agent.running) { "请等待回答，或先停止" }
            AnswerSource.COMPUTER_CODEX -> check(codex.connected && !codex.running) { "请连接电脑并等待当前任务结束" }
        }
        autoClearFor = null; clearAnswerTask?.let(main::removeCallbacks); clearAnswerTask = null
        val ref = AnswerRef(source, ++nextAnswer)
        dispatch(GlassesEvent.AnswerRequested(ref))
        pendingAnswers[source] = checkNotNull(state.answerPermit)
        if (source == AnswerSource.MOBILE_AGENT) voiceReply = null
        try {
            when (source) {
                AnswerSource.MOBILE_AGENT -> agent.submit(text, context, allowTools, retainHistory, forceDsh)
                AnswerSource.COMPUTER_CODEX -> codex.submit(text)
            }
        } catch (error: Exception) {
            pendingAnswers.remove(source); dispatch(GlassesEvent.CancelAnswer(source)); throw error
        }
    }
    fun cancelAnswer(source: AnswerSource) {
        invalidateAnswer(source)
        when (source) {
            AnswerSource.MOBILE_AGENT -> agent.cancel()
            AnswerSource.COMPUTER_CODEX -> codex.cancel()
        }
    }
    private fun invalidateAnswer(source: AnswerSource) {
        pendingAnswers.remove(source)
        dispatch(GlassesEvent.CancelAnswer(source))
    }
    private fun nativeIdentity(reset: Boolean = false): JSONObject {
        val config = settings.read()
        var changed = false
        if (config.optString("phoneInstanceId").isBlank()) { config.put("phoneInstanceId", java.util.UUID.randomUUID().toString()); changed = true }
        if (reset || config.optString("nativeConversationKey").isBlank()) { config.put("nativeConversationKey", java.util.UUID.randomUUID().toString()); changed = true }
        if (changed) settings.save(config)
        return JSONObject().put("phoneId", config.getString("phoneInstanceId")).put("conversationKey", config.getString("nativeConversationKey"))
    }
    fun newMobileConversation() {
        val previous = nativeIdentity().getString("conversationKey")
        nativeIdentity(reset = true)
        conversations.resetAgentConversation()
        agent.harness.cancelConversation(previous)
        clearAgent()
    }
    fun clearAgent() { invalidateAnswer(AnswerSource.MOBILE_AGENT); agent.clear() }
    fun connectCodex() { invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.connect() }
    fun closeCodex() { invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.close() }
    fun newCodexConversation() {
        check(!codex.running) { "请先结束当前电脑任务" }
        invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.newConversation()
    }
    private fun completed(source: AnswerSource, question: String, text: String) {
        val permit = pendingAnswers.remove(source) ?: return
        val delivery = voiceReply?.takeIf { it.ref == permit.ref }
        if (text.isBlank()) {
            if (delivery != null) voiceReply = null
            if (state.answerPermit == permit) dispatch(GlassesEvent.CancelAnswer(source))
            return
        }
        if (delivery != null) {
            voiceReply = null
            conversations.rememberReply(question, text)
            if (delivery.source == ConversationSource.NATIVE) {
                if (voiceTransport.nativeActive && delivery.wakeId == voiceTransport.wakeId && delivery.wakeId != null)
                    voiceTransport.reply(text, question, delivery.wakeId)
                else if (state.link.phase == LinkPhase.FULL) connection.sendNotification("助手", text)
                return
            }
            if (delivery.source == ConversationSource.ALWAYS_ON || state.answerPermit != permit) {
                if (state.link.phase == LinkPhase.FULL) connection.sendNotification("助手", text)
                return
            }
        }
        if (text.isNotBlank()) {
            autoClearFor = permit.ref; clearAnswerTask?.let(main::removeCallbacks); clearAnswerTask = null
            dispatch(GlassesEvent.AnswerCompleted(AnswerContent(permit.ref, question, text), permit))
        }
    }
    private fun updateAnswerClearTimer() {
        val ref = autoClearFor ?: return
        if ((state.intent as? DisplayIntent.Answer)?.ref != ref || state.ownership != DisplayOwnership.APP || state.link.phase != LinkPhase.FULL) {
            autoClearFor = null; clearAnswerTask?.let(main::removeCallbacks); clearAnswerTask = null; return
        }
        val session = state.session ?: return
        if (clearAnswerTask != null || session.phase != PagePhase.READY || session.writtenContent != session.content) return
        val seconds = settings.read().optInt("answerClearSeconds", 0).coerceIn(0,3600)
        if (seconds == 0) { autoClearFor = null; return }
        val revision = state.revision; val id = session.id
        clearAnswerTask = Runnable {
            if (state.session?.id == id && state.revision == revision && (state.intent as? DisplayIntent.Answer)?.ref == ref) clearDisplay()
        }.also { main.postDelayed(it, seconds * 1000L) }
    }
    fun revealAnswer(source: AnswerSource) {
        check(state.link.phase == LinkPhase.FULL && !state.disconnecting) { "请先完整连接眼镜" }
        val (question, answer) = when (source) {
            AnswerSource.MOBILE_AGENT -> agent.question to agent.answer
            AnswerSource.COMPUTER_CODEX -> codex.question to codex.answer
        }
        require(answer.isNotBlank()) { "还没有可显示的回答" }
        dispatch(GlassesEvent.RevealAnswer(AnswerContent(AnswerRef(source, ++nextAnswer), question, answer)))
    }
    private fun navigationSnapshot() = NavigationState(navigation.enabled, navigation.selectedKey, navigation.frame)
    private fun recordAPI(method: String, rawPath: String, body: JSONObject): JSONObject? {
        val path = rawPath.substringBefore('?')
        val query = if (rawPath.contains('?')) rawPath.substringAfter('?').split('&').associate { row ->
            java.net.URLDecoder.decode(row.substringBefore('='), "UTF-8") to java.net.URLDecoder.decode(row.substringAfter('=', ""), "UTF-8")
        } else emptyMap()
        val args = JSONObject(body.toString()).apply { query.forEach { (key, value) -> put(key, value) } }
        val repository = conversations.repository
        return when {
            method == "GET" && path in setOf("/v1/records", "/v1/conversations") || method == "POST" && path == "/v1/records/query" ->
                JSONObject().put("items", repository.query(args.optLong("from", Long.MIN_VALUE), args.optLong("to", Long.MAX_VALUE), args.optString("recordId"), args.optString("text")))
            method == "GET" && path.startsWith("/v1/conversations/") -> JSONObject().put("items", repository.query(id = path.substringAfterLast('/')))
            method == "GET" && path == "/v1/records/people" -> JSONObject().put("items", org.json.JSONArray(repository.people.map { it.publicJson() }))
            method == "POST" && path == "/v1/records/derived" -> {
                val item = RecordDerived.parse(body)
                check(repository.applyDerived(item)) { "记录不存在" }; conversations.refreshRecords()
                JSONObject().put("item", item.json()).put("persisted", true)
            }
            method == "GET" && path == "/v1/records/sync" -> JSONObject().put("enabled", recordSync.state.enabled).put("port", recordSync.state.port)
                .put("notice", recordSync.state.notice).put("addresses", org.json.JSONArray(recordSync.addresses()))
            else -> null
        }
    }
    private fun executeTool(name: String, args: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        when (name) {
            "navigation_status" -> completion(Result.success(JSONObject().put("following", state.navigation.enabled)
                .put("notificationPresent", navigation.selected != null).put("status", navigation.status)))
            "stop_navigation_mirroring" -> { stopNavigation(); completion(Result.success(JSONObject().put("following", false).put("gaodeNavigationChanged", false))) }
            "show_notification" -> {
                connection.sendNotification(args.getString("title"), args.getString("body"))
                completion(Result.success(JSONObject().put("queued", true).put("visible", "unverified")))
            }
            "record_query" -> completion(Result.success(JSONObject().put("items", conversations.repository.query(args.optLong("from", Long.MIN_VALUE),
                args.optLong("to", Long.MAX_VALUE), args.optString("recordId"), args.optString("text")))))
            "record_annotate" -> {
                val item = RecordDerived.parse(args)
                check(conversations.repository.applyDerived(item)) { "记录不存在" }; conversations.refreshRecords()
                completion(Result.success(JSONObject().put("item", item.json()).put("persisted", true)))
            }
            "memory_search" -> {
                val query = args.getString("query")
                val rows = conversations.repository.records.mapNotNull { record ->
                    val segments = record.segments.filter { it.text.contains(query, true) }
                    val memories = record.memories.filter { it.text.contains(query, true) || it.subject.contains(query, true) }
                    if (segments.isEmpty() && memories.isEmpty()) null else JSONObject().put("record_id", record.id).put("mode", record.mode.name)
                        .put("segments", org.json.JSONArray(segments.map { it.json() })).put("memories", org.json.JSONArray(memories.map { it.json() }))
                }
                completion(Result.success(JSONObject().put("items", org.json.JSONArray(rows))))
            }
            "teleprompter_start" -> startTeleprompter(args.getString("title"), args.getString("text"), args.optInt("speed", 2), completion = completion)
            "teleprompter_control" -> teleprompter.control(args.getString("action"), completion)
            "display_clear" -> { check(state.session?.mode == PageMode.PROMPT && state.ownership == DisplayOwnership.APP) { "当前没有本应用拥有的实时提示页" }; clearDisplay(); completion(Result.success(JSONObject().put("queued", true))) }
            "device_read" -> requests.perform({ deviceSettings.readForTool() }, completion)
            else -> if (name.startsWith("device_")) deviceSettings.tool(name, args, completion)
                else content.execute(name, args, completion)
        }
    }
    private fun onLog(text: String) {
        android.util.Log.i("OpenRayneo", text)
        logs.addLast("${LocalTime.now().withNano(0)} $text")
        while (logs.size > 80) logs.removeFirst()
        if (!dispatching) notifyUI()
    }
    private fun notifyUI() { if (initialized && !destroyed) observers.toList().forEach { it() } }
    private fun summary() = state.displayDescription + when (state.audio.phase) {
        AudioPhase.RECEIVING -> " · 收音中"
        AudioPhase.WAITING_PACKET, AudioPhase.WAITING_PCM -> " · 等待音频"
        AudioPhase.STALLED -> " · 音频已中断"
        AudioPhase.FAILED -> " · 音频错误"
        AudioPhase.STOPPED -> ""
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, BridgeService::class.java).setAction("STOP"), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "bridge").setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("OpenRayneo").setContentText(summary()).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止服务", stop).build()).build()
    }
    private fun updateNotification() {
        if (!initialized || !foreground || stopAfterDisconnect) return
        val text = summary()
        if (text != notificationText) { notificationText = text; getSystemService(NotificationManager::class.java).notify(1, notification()) }
    }
    override fun onDestroy() {
        destroyed = true; observers.clear(); main.removeCallbacksAndMessages(null)
        navigation.observers.remove(navigationObserver)
        agent.close(); codex.close(); conversations.close(); agentServer.close(); recordSync.close(); requests.close(); content.close(); display.reset(); audio.close(); voiceAudio.close(); supervisor.close()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
