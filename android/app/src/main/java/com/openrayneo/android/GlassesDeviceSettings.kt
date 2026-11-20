// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONObject

internal data class DeviceSettingsState(val status: JSONObject = JSONObject(), val settings: JSONObject = JSONObject(),
    val loaded: Boolean = false, val busy: Boolean = false, val notice: String = "连接眼镜后读取设置")
internal fun JSONObject.deviceInt(key: String): Int? = (opt(key) as? Number)?.toInt()
internal fun JSONObject.deviceFlag(key: String): Boolean? = when (val value = opt(key)) {
    is Boolean -> value; is Number -> value.toInt() == 1; else -> null
}
internal class GlassesDeviceSettings(private val requests: GlassesRequests, private val changed: () -> Unit) {
    @Volatile var state = DeviceSettingsState(); private set
    private val reported = java.util.concurrent.ConcurrentHashMap<String, Long>()
    fun refresh() = perform { readAll(); "已读取眼镜当前设置" }
    fun disconnected() { state = DeviceSettingsState(); reported.clear(); changed() }
    private fun readAll() {
        requests.request(15, 1, envelope("request_general_status")) { type, body -> type == 1 && body.has("generalStatus") }
        requests.request(15, 4, envelope("request_general_settings")) { type, body -> type == 4 && body.has("generalSettings") }
    }
    fun brightness(value: Int) { require(value in 1..17); apply("brightness_change", 2, 3, payload(value), "brightness") { it.status.deviceInt("brightness") == value } }
    fun display(height: Int, distance: Int) {
        require(height in 1..6 && distance in 1..3)
        apply("display_config", 5, 6, payload(data = JSONObject().put("height", height).put("distance", distance).toString()), "displayConfig") {
            it.settings.optJSONObject("displayConfig")?.let { v -> v.deviceInt("height") == height && v.deviceInt("distance") == distance } == true
        }
    }
    fun autoLock(seconds: Int) { require(seconds in listOf(5,10,15,25,40,60,120)); apply("auto_lock_time", 5, 6, payload(seconds), "autoLockTime") { it.settings.deviceInt("autoLockTime") == seconds } }
    fun headup(enabled: Boolean) {
        val wake = checkNotNull(state.settings.optJSONObject("wakeupConfig"))
        val data = JSONObject().put("headup_switch", if (enabled) 1 else 0)
            .put("headup_degree", wake.getInt("headupDegree")).put("crown_switch", wake.getInt("crownSwitch"))
        apply("wakeup_config", 5, 6, payload(data = data.toString()), "wakeupConfig") { it.settings.optJSONObject("wakeupConfig")?.deviceFlag("headupSwitch") == enabled }
    }
    fun wakeup(enabled: Boolean, angle: Int, crown: Int) {
        require(angle in 0..90 && crown in 0..3)
        val data = JSONObject().put("headup_switch", if (enabled) 1 else 0).put("headup_degree", angle).put("crown_switch", crown)
        apply("wakeup_config", 5, 6, payload(data = data.toString()), "wakeupConfig") { s -> s.settings.optJSONObject("wakeupConfig")?.let {
            it.deviceFlag("headupSwitch") == enabled && it.deviceInt("headupDegree") == angle && it.deviceInt("crownSwitch") == crown } == true }
    }
    fun headGestures(enabled: Boolean, mode: Int) {
        require(mode in 0..1)
        apply("head_gestures", 5, 6, payload(if (enabled) 1 else 0, mode), "headGestures") { s -> s.settings.optJSONObject("headGestures")?.let {
            it.deviceFlag("enabled") == enabled && it.deviceInt("mode") == mode } == true }
    }
    fun crown(direction: Int, double: Int, longPress: Int) {
        require(direction in 0..1 && double in 0..9 && longPress in 0..9 && longPress != 6)
        apply("crown_config", 5, 6, payload(value = direction, data = JSONObject().put("double", double).put("longPress", longPress).toString()), "crownConfig") { s ->
            s.settings.optJSONObject("crownConfig")?.let { it.deviceInt("direction") == direction && it.deviceInt("double") == double && it.deviceInt("longPress") == longPress } == true }
    }
    fun language(value: String, syncWakeWord: Boolean = false, onConfirmed: (() -> Unit)? = null) {
        require(state.settings.optJSONArray("supportedLanguages")?.let { a -> (0 until a.length()).any { a.getString(it) == value } } == true)
        check(state.loaded)
        perform(onDone = {
            if (state.settings.optString("currentLang").equals(value, ignoreCase = true)) {
                onConfirmed?.invoke()
            }
        }) {
            val message = applyBlocking(
                "language_change",
                5,
                6,
                payload(data = JSONObject().put("currentLang", value).toString()),
                "currentLang",
            ) { it.settings.optString("currentLang").equals(value, ignoreCase = true) }
            if (syncWakeWord && state.settings.optString("currentLang").equals(value, ignoreCase = true)) {
                val appMode = AppLanguage.appModeForGlassesLanguage(value)
                if (appMode != null) {
                    val targetWakeWord = AppLanguage.preferredWakeWordMode(appMode == AppLanguageMode.EN)
                    val currentWakeWord = state.settings.optJSONObject("voiceAssistantConfig")?.deviceInt("wakeupWord")
                    if (currentWakeWord != targetWakeWord) {
                        applyBlocking(
                            "set_ai_wakeup_word",
                            16,
                            17,
                            payload(mode = targetWakeWord),
                            "voiceAssistantConfig",
                        ) { it.settings.optJSONObject("voiceAssistantConfig")?.deviceInt("wakeupWord") == targetWakeWord }
                    }
                }
            }
            message
        }
    }

    fun wakeWord(mode: Int) {
        require(mode in 1..2)
        apply("set_ai_wakeup_word", 16, 17, payload(mode = mode), "voiceAssistantConfig") {
            it.settings.optJSONObject("voiceAssistantConfig")?.deviceInt("wakeupWord") == mode
        }
    }

    fun syncLanguageForApp(isEnglish: Boolean) {
        if (state.busy) return
        perform {
            if (!state.loaded) readAll()
            var latestNotice = state.notice
            val supportedArray = state.settings.optJSONArray("supportedLanguages")
            if (supportedArray != null) {
                val supported = (0 until supportedArray.length()).map { supportedArray.getString(it) }
                val target = AppLanguage.preferredGlassesLanguage(isEnglish, supported)
                val current = state.settings.optString("currentLang").trim()
                if (target != null && !current.equals(target, ignoreCase = true)) {
                    latestNotice = applyBlocking(
                        "language_change",
                        5,
                        6,
                        payload(data = JSONObject().put("currentLang", target).toString()),
                        "currentLang",
                    ) { it.settings.optString("currentLang").equals(target, ignoreCase = true) }
                }
            }
            val targetWakeWord = AppLanguage.preferredWakeWordMode(isEnglish)
            val currentWakeWord = state.settings.optJSONObject("voiceAssistantConfig")?.deviceInt("wakeupWord")
            if (currentWakeWord != targetWakeWord) {
                latestNotice = applyBlocking(
                    "set_ai_wakeup_word",
                    16,
                    17,
                    payload(mode = targetWakeWord),
                    "voiceAssistantConfig",
                ) { it.settings.optJSONObject("voiceAssistantConfig")?.deviceInt("wakeupWord") == targetWakeWord }
            }
            latestNotice
        }
    }
    fun privacy(values: Map<String, Boolean>) {
        val data = JSONObject(checkNotNull(state.settings.optJSONObject("privacyConfig")).toString())
        values.forEach { (key, value) -> require(key in setOf("mic_switch", "led_light", "led_auto_light", "log_switch")); data.put(key, if (value) 1 else 0) }
        apply("privacy_config", 5, 6, payload(data = data.toString()), "privacyConfig") { s -> values.all { (key, value) -> s.settings.optJSONObject("privacyConfig")?.deviceFlag(key) == value } }
    }
    fun voiceWake(enabled: Boolean) = apply("set_ai_voice_wakeup", 16, 17, payload(mode = if (enabled) 1 else 0), "voiceAssistantConfig") {
        it.settings.optJSONObject("voiceAssistantConfig")?.deviceFlag("voiceWakeup") == enabled
    }
    fun units(time: Int, temperature: Int, measurement: Int) {
        require(listOf(time, temperature, measurement).all { it in 1..2 })
        val data = JSONObject(checkNotNull(state.settings.optJSONObject("systemUnitsConfig")).toString())
            .put("time_format", time).put("temp_unit", temperature).put("measurement", measurement)
        apply("system_unints_config", 5, 6, payload(data = data.toString()), "systemUnitsConfig") { s -> s.settings.optJSONObject("systemUnitsConfig")?.let {
            it.deviceInt("time_format") == time && it.deviceInt("temp_unit") == temperature && it.deviceInt("measurement") == measurement } == true }
    }
    private fun apply(
        command: String,
        type: Int,
        reply: Int,
        payload: JSONObject,
        field: String,
        onConfirmed: (() -> Unit)? = null,
        matches: (DeviceSettingsState) -> Boolean,
    ) {
        check(state.loaded)
        perform(onDone = { if (matches(state)) onConfirmed?.invoke() }) {
            applyBlocking(command, type, reply, payload, field, matches)
        }
    }
    private fun applyBlocking(command: String, type: Int, reply: Int, payload: JSONObject, field: String,
                              matches: (DeviceSettingsState) -> Boolean): String {
        val before = System.nanoTime()
        var acknowledgementMissing = false
        try { requests.request(15, type, JSONObject().put("cmd", command).put("payload", payload)) { t, body -> t == reply &&
            (body.optString("cmd") == command || type == 16 && body.optString("cmd") == "sync_ai_settings") } }
        catch (error: IllegalStateException) { acknowledgementMissing = true }
        readAll()
        return if ((reported[field] ?: 0) < before) "已发送，设备尚未回报该设置的新值"
            else if (matches(state)) "已由眼镜回读确认" else if (acknowledgementMissing) "未收到修改回包，当前回读与请求不同" else "设备回读与请求不同，请核对当前值"
    }
    fun readForTool(): JSONObject { readAll(); return JSONObject().put("status", state.status).put("settings", state.settings) }
    fun tool(name: String, args: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        requests.perform({
            readAll()
            val message = when (name) {
                "device_brightness" -> {
                    val value = args.getInt("value"); require(value in 1..17)
                    applyBlocking("brightness_change", 2, 3, payload(value), "brightness") { it.status.deviceInt("brightness") == value }
                }
                "device_display" -> {
                    val height = args.getInt("height"); val distance = args.getInt("distance"); require(height in 1..6 && distance in 1..3)
                    applyBlocking("display_config", 5, 6, payload(data = JSONObject().put("height", height).put("distance", distance).toString()), "displayConfig") {
                        it.settings.optJSONObject("displayConfig")?.let { v -> v.deviceInt("height") == height && v.deviceInt("distance") == distance } == true }
                }
                else -> error("未知设备工具：$name")
            }
            JSONObject().put("message", message).put("status", state.status).put("settings", state.settings)
        }, completion)
    }
    private fun perform(onDone: (() -> Unit)? = null, work: () -> String) {
        check(!state.busy) { "请等待当前设备操作" }
        state = state.copy(busy = true, notice = "正在与眼镜同步…"); changed()
        requests.perform(work) { result ->
            state = state.copy(busy = false, notice = result.getOrElse { it.message ?: "设备操作失败" }); changed()
            if (result.isSuccess) onDone?.invoke()
        }
    }
    fun observe(type: Int, body: JSONObject) {
        val now = System.nanoTime()
        body.optJSONObject("generalStatus")?.let { data -> data.keys().forEach { reported[it] = now }; state = state.copy(status = merge(state.status, data)) }
        body.optJSONObject("generalSettings")?.let { data -> data.keys().forEach { reported[it] = now }; state = state.copy(settings = merge(state.settings, data), loaded = true) }
        val command = body.optString("cmd"); val payload = body.optJSONObject("payload")
        if (payload != null && command in setOf("sync_ai_settings", "system_unints_config", "system_units_config") && type in setOf(6,17)) {
            val raw = payload.opt("data")
            val data = if (raw is JSONObject) raw else (raw as? String)?.takeIf { it.isNotBlank() }?.let(::JSONObject)
            if (data != null) {
                if (command == "sync_ai_settings") {
                    val normalized = JSONObject()
                    listOf("ai_state" to "enabled", "ai_voice_wakeup" to "voiceWakeup", "ai_work_mode" to "workMode").forEach { (wire, key) -> if (data.has(wire)) normalized.put(key, data.opt(wire)) }
                    state = state.copy(settings = merge(state.settings, JSONObject().put("voiceAssistantConfig", normalized)))
                    reported["voiceAssistantConfig"] = now
                } else {
                    state = state.copy(settings = merge(state.settings, JSONObject().put("systemUnitsConfig", data)))
                    // A same-command payload may be an ACK echo; only full settings reads confirm unit writes.
                }
            }
        }
        changed()
    }
    private fun merge(previous: JSONObject, next: JSONObject): JSONObject = JSONObject(previous.toString()).apply {
        next.keys().forEach { key -> val old = optJSONObject(key); val value = next.opt(key)
            put(key, if (old != null && value is JSONObject) merge(old, value) else value) }
    }
    private fun payload(value: Int = 0, mode: Int = 0, data: String = "") = JSONObject().put("value", value).put("mode", mode).put("data", data)
    private fun envelope(command: String) = JSONObject().put("cmd", command).put("payload", payload())
}
