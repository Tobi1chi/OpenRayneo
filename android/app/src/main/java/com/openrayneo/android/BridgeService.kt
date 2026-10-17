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
    private lateinit var supervisor: ConnectionSupervisor
    val connection get() = supervisor.transport
    private lateinit var display: GlassesDisplay
    private lateinit var audio: PromptAudio
    val navigation get() = NavigationFeed
    lateinit var agent: MobileAgent; private set
    lateinit var codex: CodexClient; private set
    var state = GlassesState(); private set
    val status get() = state.link.detail
    val ready get() = state.link.phase in setOf(LinkPhase.FULL, LinkPhase.BLE_ONLY)
    val busy get() = state.link.phase in setOf(LinkPhase.SCANNING, LinkPhase.CONNECTING, LinkPhase.RETRY_WAIT, LinkPhase.CLOSING)
    val displayStatus get() = state.displayDescription
    val audioStatus get() = state.audio.detail
    val audioLevels get() = audio.state
    private val events = ArrayDeque<GlassesEvent>()
    private var dispatching = false
    private var destroyed = false
    private var initialized = false
    private var foreground = false
    private var stopAfterDisconnect = false
    private var restoreTask: Runnable? = null
    private var closeTask: Runnable? = null
    private var audioOwner: Long? = null
    private var nextAnswer = 0L
    private val pendingAnswers = mutableMapOf<AnswerSource, AnswerPermit>()
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
            main.postDelayed(this, 30_000)
        }
    }
    private val audioRefresh = object : Runnable {
        override fun run() {
            audioOwner?.let { dispatch(GlassesEvent.AudioChanged(it, audio.state.coordinatorState())) }
            main.postDelayed(this, 1_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(this)
        supervisor = ConnectionSupervisor(this, main,
            { dispatch(GlassesEvent.LinkChanged(it)) }, { devices[it.bluetooth.address] = it; notifyUI() },
            { frame, source -> runCatching { display.receive(frame, source) }.onFailure { onLog("眼镜消息解析失败：$source") } }, ::onLog)
        audio = PromptAudio()
        display = GlassesDisplay(connection::sendFrame,
            { task, delay -> main.postDelayed(task, delay) }, { main.removeCallbacks(it) }, ::onLog,
            { id, signal -> dispatch(GlassesEvent.SessionSignal(id, signal)) },
            { id, packet -> if (audioOwner == id && state.session?.id == id) audio.accept(packet) },
            { dispatch(GlassesEvent.ExternalPage(it)) })
        navigation.initialize(this)
        navigation.observers.add(navigationObserver)
        agent = MobileAgent(settings, ::notifyUI, ::executeTool) { question, answer -> completed(AnswerSource.MOBILE_AGENT, question, answer) }
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
            startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            foreground = true
        }
        return START_NOT_STICKY
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
        dispatch(GlassesEvent.Disconnect)
    }
    fun followNavigation(key: String) {
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
    fun pausePrompt() = dispatch(GlassesEvent.PauseDisplay)
    fun openStandby() = dispatch(GlassesEvent.OpenStandby)
    fun retryAudio() {
        check(state.link.phase == LinkPhase.FULL && state.session?.phase in setOf(PagePhase.LAYOUT, PagePhase.SETTLING, PagePhase.READY)) {
            "请先启动导航或实时提示，并等待眼镜确认"
        }
        dispatch(GlassesEvent.RetryAudio)
    }
    fun dismissAnswer() = dispatch(GlassesEvent.DismissAnswer)

    fun submitAnswer(source: AnswerSource, text: String) {
        when (source) {
            AnswerSource.MOBILE_AGENT -> check(!agent.running) { "请等待回答，或先停止" }
            AnswerSource.COMPUTER_CODEX -> check(codex.connected && !codex.running) { "请连接电脑并等待当前任务结束" }
        }
        val ref = AnswerRef(source, ++nextAnswer)
        dispatch(GlassesEvent.AnswerRequested(ref))
        pendingAnswers[source] = checkNotNull(state.answerPermit)
        try {
            when (source) {
                AnswerSource.MOBILE_AGENT -> agent.submit(text)
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
    fun clearAgent() { invalidateAnswer(AnswerSource.MOBILE_AGENT); agent.clear() }
    fun connectCodex() { invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.connect() }
    fun closeCodex() { invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.close() }
    fun newCodexConversation() {
        check(!codex.running) { "请先结束当前电脑任务" }
        invalidateAnswer(AnswerSource.COMPUTER_CODEX); codex.newConversation()
    }
    private fun completed(source: AnswerSource, question: String, text: String) {
        val permit = pendingAnswers.remove(source) ?: return
        if (text.isNotBlank()) dispatch(GlassesEvent.AnswerCompleted(AnswerContent(permit.ref, question, text), permit))
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
    private fun executeTool(name: String, args: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        when (name) {
            "navigation_status" -> completion(Result.success(JSONObject().put("following", state.navigation.enabled)
                .put("notificationPresent", navigation.selected != null).put("status", navigation.status)))
            "stop_navigation_mirroring" -> { stopNavigation(); completion(Result.success(JSONObject().put("following", false).put("gaodeNavigationChanged", false))) }
            "show_notification" -> {
                connection.sendNotification(args.getString("title"), args.getString("body"))
                completion(Result.success(JSONObject().put("queued", true).put("visible", "unverified")))
            }
            else -> completion(Result.failure(IllegalArgumentException("未知工具")))
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
        agent.close(); codex.close(); display.reset(); audio.close(); supervisor.close()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
