// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.*
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.IBinder
import android.speech.RecognizerIntent
import android.provider.Settings
import android.app.NotificationManager
import android.text.InputType
import android.view.View
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject

internal class MainActivity : Activity() {
    private var bridge: BridgeService? = null
    private var bound = false
    private lateinit var status: TextView
    private lateinit var audioState: TextView
    private lateinit var deviceList: LinearLayout
    private lateinit var logView: TextView
    private lateinit var bleOnly: CheckBox
    private lateinit var navState: TextView
    private lateinit var agentState: TextView
    private lateinit var agentAnswer: TextView
    private lateinit var codexState: TextView
    private lateinit var codexAnswer: TextView
    private lateinit var approvals: LinearLayout
    private lateinit var mobileInput: EditText
    private lateinit var codexInput: EditText
    private lateinit var navNotifications: LinearLayout
    private var notificationKey = ""
    private val fields = linkedMapOf<String, EditText>()
    private val panels = linkedMapOf<String, LinearLayout>()
    private var devicesKey = ""
    private var approvalKey = ""
    private var selectedTab = "设备"
    private var permissionAction: (() -> Unit)? = null
    private val observer: () -> Unit = { refresh() }
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            bridge = (binder as BridgeService.LocalBinder).service
            bridge!!.observers.add(observer); refresh()
            perform { bridge!!.connection.showBonded() }
        }
        override fun onServiceDisconnected(name: ComponentName) { bridge = null; status.text = "服务已断开，请重新打开应用" }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = column().apply { setPadding(dp(16), dp(12), dp(16), dp(12)); fitsSystemWindows = true }
        setContentView(ScrollView(this).apply { fitsSystemWindows = true; addView(content) })
        label(content, "OpenRayneo", 24f); status = label(content, "需要附近设备权限")
        audioState = label(content, "眼镜收音未启动", 13f)
        val tabs = LinearLayout(this).also { content.addView(it) }
        for (name in listOf("设备", "导航", "Agent", "电脑", "设置")) {
            panels[name] = column().apply { visibility = if (name == "设备") View.VISIBLE else View.GONE; content.addView(this) }
            tabs.addView(Button(this).apply {
                text = name; textSize = 13f
                setOnClickListener { selectedTab = name; panels.forEach { (k, v) -> v.visibility = if (k == name) View.VISIBLE else View.GONE }; refresh() }
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
        buildDevice(panels.getValue("设备")); buildNavigation(panels.getValue("导航"))
        buildAgent(panels.getValue("Agent")); buildCodex(panels.getValue("电脑")); buildSettings(panels.getValue("设置"))
        needPermissions(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)) {
            val intent = Intent(this, BridgeService::class.java)
            startForegroundService(intent); bound = bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        }
    }
    private fun buildDevice(panel: LinearLayout) {
        label(panel, "连接由后台服务保持。眼镜连接手机，电脑通过网络接入。")
        bleOnly = checkbox(panel, "仅 BLE 诊断（导航和 Agent 显示需取消此项）")
        button(panel, "扫描眼镜") { service().scan() }
        deviceList = column().also { panel.addView(it) }
        button(panel, "发送测试通知") { service().connection.sendTestNotification() }
        label(panel, "导航使用固定网格和字幕音频，按单声道接收；问答使用实时提示和双声道音频。当前仅显示音量，不保存、不上传、不自动识别。", 13f)
        button(panel, "暂停眼镜显示与收音") { service().pausePrompt() }
        button(panel, "打开实时提示与收音") { service().openStandby() }
        button(panel, "重启音频解码（保持页面）") { service().retryAudio() }
        button(panel, "断开眼镜") { service().disconnect() }
        button(panel, "允许后台状态通知") { needPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS)) {} }
        button(panel, "复制连接日志") {
            getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("OpenRayneo", service().logs.joinToString("\n")))
            toast("日志已复制")
        }
        logView = label(panel, "", 12f)
    }
    private fun buildNavigation(panel: LinearLayout) {
        label(panel, "在高德 App 中正常导航，OpenRayneo 只跟随你选定的高德通知，无需地图 Key 或定位权限。")
        button(panel, "开启通知使用权") { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
        button(panel, "打开高德导航") {
            val intent = packageManager.getLaunchIntentForPackage(NavigationFeed.PACKAGE)
            check(intent != null) { "请先在手机安装高德地图" }
            startActivity(intent)
        }
        button(panel, "刷新通知连接") { NavigationNotifications.requestConnection(this) }
        navState = label(panel, "等待高德导航通知")
        label(panel, "高德当前通知：开始导航后回到此页，选择要跟随的一条。")
        navNotifications = column().also { panel.addView(it) }
        button(panel, "恢复眼镜导航显示") { service().reopenNavigation() }
        button(panel, "停止眼镜跟随") { service().stopNavigation() }
    }
    private fun buildAgent(panel: LinearLayout) {
        label(panel, "手机直接调用配置的模型，可查询导航跟随状态和发送眼镜通知。使用兼容 Chat Completions 的工具调用接口。")
        mobileInput = input(panel, "输入问题或指令", multiline = true)
        button(panel, "手机系统语音输入") { voice(21) }
        button(panel, "发送给手机 Agent") { require(mobileInput.text.isNotBlank()) { "请输入内容" }; service().submitAnswer(AnswerSource.MOBILE_AGENT, mobileInput.text.toString()) }
        button(panel, "停止回答") { service().cancelAnswer(AnswerSource.MOBILE_AGENT) }
        button(panel, "新对话") { service().clearAgent() }
        agentState = label(panel, "模型尚未配置"); agentAnswer = label(panel, "")
        button(panel, "重新显示回答到眼镜") { service().revealAnswer(AnswerSource.MOBILE_AGENT) }
        button(panel, "结束眼镜回答") { service().dismissAnswer() }
        label(panel, "导航使用固定网格，回答使用实时提示页；切换页面时会重建对应音频会话。手机系统语音输入仍未接入眼镜音频。")
    }
    private fun buildCodex(panel: LinearLayout) {
        label(panel, "连接电脑 Codex，使用独立会话。USB 调试可使用本机转发；跨网络需配置 WSS 地址。")
        button(panel, "连接／恢复 Codex") { service().connectCodex() }
        codexInput = input(panel, "交给电脑 Codex 的任务", multiline = true)
        button(panel, "手机系统语音输入") { voice(22) }
        button(panel, "发送电脑任务") { require(codexInput.text.isNotBlank()) { "请输入任务" }; service().submitAnswer(AnswerSource.COMPUTER_CODEX, codexInput.text.toString()) }
        button(panel, "停止电脑任务") { service().cancelAnswer(AnswerSource.COMPUTER_CODEX) }
        button(panel, "新电脑会话") { service().newCodexConversation() }
        codexState = label(panel, "电脑未连接")
        approvals = column().also { panel.addView(it) }; codexAnswer = label(panel, "")
        button(panel, "重新显示电脑回答到眼镜") { service().revealAnswer(AnswerSource.COMPUTER_CODEX) }
        button(panel, "结束眼镜回答") { service().dismissAnswer() }
    }
    private fun buildSettings(panel: LinearLayout) {
        val config = AppSettings(this).read()
        label(panel, "手机模型", 20f)
        setting(panel, config, "modelUrl", "接口地址，例如 https://服务商/v1")
        setting(panel, config, "modelName", "模型名称（需支持工具调用）")
        setting(panel, config, "modelKey", "模型 API Key", true)
        label(panel, "电脑 Codex", 20f)
        setting(panel, config, "codexUrl", "wss://电脑地址，或 ws://127.0.0.1:4500")
        setting(panel, config, "codexToken", "电脑连接令牌", true)
        setting(panel, config, "codexCwd", "电脑工作目录（绝对路径）")
        button(panel, "保存配置") { saveSettings(); toast("配置已加密保存，地址变化后请重新连接") }
        button(panel, "导入本地配置文件") { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("application/json").addCategory(Intent.CATEGORY_OPENABLE), 30) }
    }
    private fun saveSettings() {
        val store = AppSettings(this); val config = store.read()
        val changed = listOf("codexUrl", "codexCwd", "codexToken").any { fields[it]!!.text.toString().trim() != config.optString(it) }
        if (listOf("modelUrl", "modelName", "modelKey").any { fields[it]!!.text.toString().trim() != config.optString(it) }) bridge?.clearAgent()
        fields.forEach { (k, v) -> config.put(k, v.text.toString().trim()) }
        config.remove("amapKey"); config.remove("amapConsent")
        if (changed) { bridge?.closeCodex(); config.remove("codexThread") }
        store.save(config)
    }
    private fun refresh() {
        val s = bridge ?: return
        audioState.text = s.displayStatus + "\n" + s.audioStatus
        status.text = s.status; bleOnly.isEnabled = !s.ready && !s.busy
        if (selectedTab == "设备") {
            logView.text = s.logs.joinToString("\n")
            val key = s.devices.keys.joinToString() + s.ready + s.busy
            if (key != devicesKey) {
                devicesKey = key; deviceList.removeAllViews()
                s.devices.values.forEach { device -> button(deviceList, "连接 ${device.name}") { s.connect(device, bleOnly.isChecked) }
                    .isEnabled = !s.ready && (!s.busy || s.status.startsWith("正在扫描")) }
            }
        }
        if (selectedTab == "导航") {
            navState.text = s.navigation.status + if (s.displayStatus.isBlank()) "" else "\n眼镜：${s.displayStatus}"
            val key = s.navigation.entries.values.joinToString { it.key + it.texts.joinToString() }
            if (key != notificationKey) {
                notificationKey = key; navNotifications.removeAllViews()
                s.navigation.entries.values.forEach { entry ->
                    label(navNotifications, entry.texts.joinToString("\n").ifBlank { "这条通知没有可读取的文字" }, 14f)
                    button(navNotifications, "跟随这条高德通知") { service().followNavigation(entry.key) }
                }
            }
        }
        if (selectedTab == "Agent") { agentState.text = s.agent.status; agentAnswer.text = s.agent.answer }
        if (selectedTab == "电脑") {
            codexState.text = s.codex.status; codexAnswer.text = s.codex.answer
            val key = s.codex.requests.joinToString { it.id.toString() }
            if (key != approvalKey) { approvalKey = key; approvals.removeAllViews(); s.codex.requests.forEach { approval(s.codex, it) } }
        }
    }
    private fun approval(client: CodexClient, request: CodexClient.Request) {
        if (request.method == "item/tool/requestUserInput") {
            val answers = linkedMapOf<String, EditText>(); val questions = request.params.getJSONArray("questions")
            for (i in 0 until questions.length()) {
                val q = questions.getJSONObject(i); label(approvals, q.getString("question"))
                q.optJSONArray("options")?.let { options -> label(approvals, (0 until options.length()).joinToString("\n") { options.getJSONObject(it).optString("label") }) }
                answers[q.getString("id")] = input(approvals, "你的回复", secret = q.optBoolean("isSecret"))
            }
            button(approvals, "提交回复") {
                val values = JSONObject(); answers.forEach { (id, view) -> values.put(id, JSONObject().put("answers", JSONArray().put(view.text.toString()))) }
                client.reply(request, JSONObject().put("answers", values))
            }
        } else {
            label(approvals, "Codex 请求确认\n${request.details}", 13f)
            button(approvals, "允许这一次") { client.reply(request, JSONObject().put("decision", "accept")) }
            button(approvals, "拒绝") { client.reply(request, JSONObject().put("decision", "decline")) }
        }
    }
    private fun service(): BridgeService {
        val service = checkNotNull(bridge) { "请授予附近设备权限后重新打开应用" }
        startForegroundService(Intent(this, BridgeService::class.java))
        return service
    }
    private fun needPermissions(permissions: Array<String>, action: () -> Unit) {
        if (permissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) action()
        else { permissionAction = action; requestPermissions(permissions, 10) }
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 10) {
            val action = permissionAction; permissionAction = null
            if (results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED }) perform { action?.invoke() }
            else toast("需要对应权限才能启用该功能，可在系统设置中调整")
        }
    }
    private fun voice(code: Int) { startActivityForResult(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM).putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN"), code) }
    override fun onActivityResult(code: Int, result: Int, data: Intent?) {
        super.onActivityResult(code, result, data); if (result != RESULT_OK) return
        perform {
            if (code == 21 || code == 22) {
                (if (code == 21) mobileInput else codexInput).setText(data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull().orEmpty())
            } else if (code == 30) {
                val uri = data?.data ?: return@perform
                val config = contentResolver.openInputStream(uri)!!.use { stream ->
                    val bytes = stream.readNBytes(16385); require(bytes.size <= 16384) { "配置文件过大" }; JSONObject(String(bytes, Charsets.UTF_8))
                }
                for (key in listOf("codexUrl", "codexToken", "codexCwd")) if (config.has(key)) fields[key]?.setText(config.getString(key))
                saveSettings(); toast("配置已导入，请删除下载目录中的连接配置文件")
            }
        }
    }
    override fun onResume() {
        super.onResume()
        if (getSystemService(NotificationManager::class.java).isNotificationListenerAccessGranted(ComponentName(this, NavigationNotifications::class.java)) && !NavigationFeed.connected) {
            NavigationNotifications.requestConnection(this)
        }
    }
    override fun onDestroy() { bridge?.observers?.remove(observer); if (bound) unbindService(serviceConnection); super.onDestroy() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun label(parent: LinearLayout, value: String, size: Float = 16f) = TextView(this).apply {
        text = value; textSize = size; setTextColor(Color.rgb(28, 35, 38)); setPadding(0, dp(8), 0, dp(8)); setTextIsSelectable(true); parent.addView(this)
    }
    private fun input(parent: LinearLayout, hint: String, secret: Boolean = false, multiline: Boolean = false) = EditText(this).apply {
        this.hint = hint; inputType = InputType.TYPE_CLASS_TEXT or if (secret) InputType.TYPE_TEXT_VARIATION_PASSWORD else if (multiline) InputType.TYPE_TEXT_FLAG_MULTI_LINE else InputType.TYPE_TEXT_VARIATION_NORMAL
        maxLines = if (multiline) 5 else 1; parent.addView(this)
    }
    private fun checkbox(parent: LinearLayout, value: String) = CheckBox(this).apply { text = value; parent.addView(this) }
    private fun setting(parent: LinearLayout, config: JSONObject, key: String, hint: String, secret: Boolean = false) {
        label(parent, hint, 13f); fields[key] = input(parent, hint, secret).apply { setText(config.optString(key)) }
    }
    private fun button(parent: LinearLayout, value: String, action: () -> Unit) = Button(this).apply { text = value; setOnClickListener { perform(action) }; parent.addView(this) }
    private fun toast(message: String) { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
    private fun perform(action: () -> Unit) { try { action() } catch (error: Exception) { AlertDialog.Builder(this).setMessage(error.message ?: "操作失败").setPositiveButton("知道了", null).show() } }
}
