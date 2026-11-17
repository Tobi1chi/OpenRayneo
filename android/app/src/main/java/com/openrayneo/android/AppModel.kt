// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.app.NotificationManager
import android.content.*
import android.content.pm.PackageManager
import android.os.IBinder
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import org.json.JSONObject

internal data class ChatRecord(val question: String, val answer: String)
internal data class SelectedContact(val name: String, val uri: String)

internal data class CompanionState(
    val available: Boolean = false,
    val glasses: GlassesState = GlassesState(),
    val conversation: ConversationState = ConversationState(),
    val deviceSettings: DeviceSettingsState = DeviceSettingsState(),
    val content: CompanionContentState = CompanionContentState(),
    val teleprompter: TeleprompterState = TeleprompterState(),
    val agentServer: AgentServerState = AgentServerState(),
    val recordSync: AgentServerState = AgentServerState(notice = "相遇同步已关闭"),
    val phoneEphemeral: Boolean = false,
    val nativeWakeAvailable: Boolean = false,
    val devices: List<RayneoConnection.Device> = emptyList(),
    val navigationEntries: List<NavigationFeed.Entry> = emptyList(),
    val navigationStatus: String = "在高德开始导航后，回到这里跟随通知",
    val notificationConnected: Boolean = false,
    val phoneQuestion: String = "",
    val phoneAnswer: String = "",
    val phoneRunning: Boolean = false,
    val phoneStatus: String = "配置模型后即可开始对话",
    val computerQuestion: String = "",
    val computerAnswer: String = "",
    val computerRunning: Boolean = false,
    val computerStatus: String = "电脑尚未连接",
    val computerConnected: Boolean = false,
    val approvals: List<CodexClient.Request> = emptyList(),
    val logs: List<String> = emptyList(),
    val audioLevels: PromptAudio.State = PromptAudio.State(),
    val notificationReadStatus: String = "等待通知监听服务",
    val notificationSnapshotAt: Long = 0,
    val notificationReadPhase: NotificationReadPhase = NotificationReadPhase.DISCONNECTED,
)

internal class AppModel(application: Application) : AndroidViewModel(application) {
    private val context = application
    private val preferences = context.getSharedPreferences("companion_ui", Context.MODE_PRIVATE)
    private val settings = AppSettings(context)
    @SuppressLint(
        "StaticFieldLeak"
    ) // Application-bound service; the binding and observer are released in onCleared.
    private var bridge: BridgeService? = null
    private var bound = false
    var state by mutableStateOf(CompanionState())
        private set

    var config by mutableStateOf(JSONObject())
        private set

    val mobileModelConfigured: Boolean get() = MobileModelEndpoint.isConfigured(
        config.optString("modelUrl"), config.optString("modelName"), config.optString("modelKey"))

    var error by mutableStateOf<String?>(null)
    var notice by mutableStateOf<String?>(null)
    var bluetoothAllowed by mutableStateOf(false)
        private set

    var notificationAllowed by mutableStateOf(false)
        private set

    var backgroundNotifications by mutableStateOf(false)
        private set

    var onboarding by mutableStateOf(!preferences.getBoolean("onboardingComplete", false))
        private set

    var onboardingStep by mutableIntStateOf(preferences.getInt("onboardingStep", 0))
        private set

    var appearance by mutableStateOf(preferences.getString("appearance", "system") ?: "system")
        private set

    var deviceName by
        mutableStateOf(preferences.getString("deviceName", "RayNeo iO") ?: "RayNeo iO")
        private set

    var phoneDraft by mutableStateOf("")
    var selectedContact by mutableStateOf<SelectedContact?>(null)
    var computerDraft by mutableStateOf("")
    var phoneHistory by mutableStateOf<List<ChatRecord>>(emptyList())
        private set

    var computerHistory by mutableStateOf<List<ChatRecord>>(emptyList())
        private set

    // Form drafts survive activity recreation without writing secrets into saved instance state.
    val formDrafts = mutableStateMapOf<String, String>()
    var wantsScan = false
    private val files = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    fun exportRecording(id: String, uri: android.net.Uri) {
        val s = service(); val record = s.conversations.repository.records.first { it.id == id }
        files.execute {
            val result = runCatching { context.contentResolver.openOutputStream(uri)!!.use { s.conversations.recordings.exportWav(record.audioId ?: id, record.audioSamples, it) } }
            main.post { result.fold({ notice = "会议音频已导出到所选位置" }, { error = it.message ?: "导出失败" }) }
        }
    }
    private val observer: () -> Unit = { refresh() }
    private val connection =
        object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                bridge = (binder as BridgeService.LocalBinder).service
                bridge!!.observers.add(observer)
                refresh()
                if (bluetoothAllowed) runCatching { bridge!!.connection.showBonded() }
                if (wantsScan && bluetoothAllowed) {
                    wantsScan = false
                    scan()
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                bridge = null
                state = CompanionState()
            }
        }

    init {
        attempt {
            config = settings.read()
            resetFormDrafts()
        }
        refreshPermissions()
        bound =
            context.bindService(
                Intent(context, BridgeService::class.java),
                connection,
                Context.BIND_AUTO_CREATE,
            )
        if (!bound) error = "暂时无法启动连接服务，请重新打开应用"
    }

    fun attempt(action: () -> Unit) {
        try {
            action()
        } catch (failure: Exception) {
            error = failure.message ?: "操作未完成，请重试"
        }
    }

    fun service(): BridgeService = checkNotNull(bridge) { "连接服务正在准备，请稍后重试" }

    private fun refresh() {
        val s = bridge ?: return
        state =
            CompanionState(
                available = true,
                glasses = s.state,
                conversation = s.conversations.state,
                deviceSettings = s.deviceSettings.state,
                content = s.content.state,
                teleprompter = s.teleprompter.state,
                agentServer = s.agentServer.state,
                recordSync = s.recordSync.state,
                phoneEphemeral = s.agent.ephemeral,
                nativeWakeAvailable = s.voiceTransport.nativeActive,
                devices = s.devices.values.toList(),
                navigationEntries = s.navigation.entries.values.toList(),
                navigationStatus = s.navigation.status,
                notificationConnected = s.navigation.connected,
                phoneQuestion = s.agent.question,
                phoneAnswer = s.agent.answer,
                phoneRunning = s.agent.running,
                phoneStatus = s.agent.status,
                computerQuestion = s.codex.question,
                computerAnswer = s.codex.answer,
                computerRunning = s.codex.running,
                computerStatus = s.codex.status,
                computerConnected = s.codex.connected,
                approvals = s.codex.requests.toList(),
                logs = s.logs.toList(),
                audioLevels = s.audioLevels,
                notificationReadStatus = s.navigation.listenerState.detail,
                notificationSnapshotAt = s.navigation.lastSnapshotAt,
                notificationReadPhase = s.navigation.listenerState.phase,
            )
    }

    fun refreshPermissions() {
        bluetoothAllowed =
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT).all {
                context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }
        notificationAllowed =
            context
                .getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(
                    ComponentName(context, NavigationNotifications::class.java)
                )
        backgroundNotifications =
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        NavigationNotifications.refresh(context, foreground = true)
    }

    fun scan() = attempt {
        if (bridge == null) {
            wantsScan = true
            return@attempt
        }
        service().scan()
        service().connection.showBonded()
    }

    fun connect(device: RayneoConnection.Device, diagnostic: Boolean) = attempt {
        service().connect(device, diagnostic)
        deviceName = device.name
        preferences.edit().putString("deviceName", deviceName).apply()
    }

    fun saveConfig(values: Map<String, String>) = attempt {
        val old = settings.read()
        val updated = JSONObject(old.toString())
        values.forEach { (key, value) -> updated.put(key, value.trim()) }
        val mobileChanged =
            listOf("modelUrl", "modelName", "modelKey", "mobileAgentBackend").any {
                old.optString(it) != updated.optString(it)
            }
        val computerChanged =
            listOf("codexUrl", "codexToken", "codexCwd").any {
                old.optString(it) != updated.optString(it)
            }
        if (computerChanged) updated.remove("codexThread")
        updated.remove("amapKey")
        updated.remove("amapConsent")
        settings.save(updated)
        if (mobileChanged) {
            bridge?.clearAgent()
            phoneHistory = emptyList()
        }
        if (computerChanged) {
            bridge?.closeCodex()
            computerHistory = emptyList()
        }
        config = updated
        bridge?.conversations?.configurationChanged()
        resetFormDrafts()
        notice = "配置已加密保存"
    }

    private fun resetFormDrafts() {
        configurationKeys.forEach {
            formDrafts[it] = config.optString(it)
        }
    }

    fun importConfig(data: JSONObject) {
        val keys = configurationKeys
        saveConfig(keys.filter { data.has(it) }.associateWith { data.getString(it) })
    }
    companion object {
        val configurationKeys = listOf("modelUrl", "modelName", "modelKey", "mobileAgentBackend", "localAgentPort", "codexUrl", "codexCwd", "codexToken",
            "asrKey", "asrUrl", "asrModel", "decisionKey", "decisionUrl", "decisionModel", "nativeAutoAnswer", "audioChannel",
            "speakerThreshold", "voiceRoutingPrompt", "memoryPrompt", "memoryAutoSummary", "answerClearSeconds", "saveMeetingAudio")
    }

    fun send(source: AnswerSource) = attempt {
        val mobile = source == AnswerSource.MOBILE_AGENT
        val text = (if (mobile) phoneDraft else computerDraft).trim()
        require(text.isNotBlank()) { "先写下你的问题" }
        val old =
            if (mobile) ChatRecord(state.phoneQuestion, state.phoneAnswer)
            else ChatRecord(state.computerQuestion, state.computerAnswer)
        val oldWasEphemeral = state.phoneEphemeral
        service().submitAnswer(source, text)
        if (mobile) {
            if (old.question.isNotBlank() && !oldWasEphemeral) phoneHistory = (phoneHistory + old).takeLast(30)
            phoneDraft = ""
        } else {
            if (old.question.isNotBlank()) computerHistory = (computerHistory + old).takeLast(30)
            computerDraft = ""
        }
    }

    fun newConversation(source: AnswerSource) = attempt {
        if (source == AnswerSource.MOBILE_AGENT) {
            service().newMobileConversation()
            phoneHistory = emptyList()
        } else {
            service().newCodexConversation()
            computerHistory = emptyList()
        }
    }

    fun step(value: Int) {
        onboardingStep = value.coerceIn(0, 4)
        preferences.edit().putInt("onboardingStep", onboardingStep).apply()
    }

    fun finishSetup() {
        onboarding = false
        preferences.edit().putBoolean("onboardingComplete", true).apply()
    }

    fun replaySetup() {
        step(0)
        onboarding = true
    }

    fun changeAppearance(value: String) {
        appearance = value
        preferences.edit().putString("appearance", value).apply()
    }

    override fun onCleared() {
        bridge?.observers?.remove(observer)
        if (bound) context.unbindService(connection)
        files.shutdown()
        bridge = null
        bound = false
    }
}
