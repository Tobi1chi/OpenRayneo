// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun GlassesSettingsScreen(model: AppModel) {
    val snapshot = model.state.deviceSettings
    val connected = model.state.glasses.link.phase == LinkPhase.FULL
    val editable = connected && snapshot.loaded && !snapshot.busy
    val status = snapshot.status
    val settings = snapshot.settings
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text("配置你的眼镜", style = MaterialTheme.typography.headlineMedium)
        Note("直接通过蓝牙读取和修改设备设置，使用时由 OpenRayneo 持有眼镜连接。")
        ToolButton(onClick = { model.attempt { model.service().deviceSettings.refresh() } },
            enabled = connected && !snapshot.busy, modifier = Modifier.fillMaxWidth()) { Text("读取眼镜设置") }
        if (snapshot.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Note(if (connected) snapshot.notice else "请先在眼镜页完成连接")
        if (snapshot.loaded) {
            SettingsSection("设备信息") {
                Text(status.optString("deviceName").ifBlank { model.deviceName }, style = MaterialTheme.typography.titleMedium)
                settings.optString("firmwareVersion").takeIf { it.isNotBlank() }?.let { Note("固件 $it") }
                status.deviceInt("battery")?.let { Note("电量 $it%") }
                status.deviceFlag("isCharging")?.let { Note(if (it) "正在充电" else "未充电") }
            }
            status.deviceInt("brightness")?.let { current ->
                var value by remember(current) { mutableIntStateOf(current) }
                SettingsSection("显示亮度") {
                    Text("亮度 $value · 当前设备值 $current")
                    Slider(value.toFloat(), { value = it.toInt() }, valueRange = 1f..17f, steps = 15, enabled = editable)
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.brightness(value) } }, enabled = editable) { Text("应用亮度") }
                    status.deviceFlag("automaticBrightness")?.let { Note("自动亮度：${if (it) "开启" else "关闭"}") }
                }
            }
            val display = settings.optJSONObject("displayConfig")
            val currentHeight = display?.deviceInt("height")
            val currentDistance = display?.deviceInt("distance")
            if (currentHeight != null && currentDistance != null) {
                var height by remember(currentHeight) { mutableIntStateOf(currentHeight) }
                var distance by remember(currentDistance) { mutableIntStateOf(currentDistance) }
                SettingsSection("画面位置") {
                    Text("高度 $height")
                    Slider(height.toFloat(), { height = it.toInt() }, valueRange = 1f..6f, steps = 4, enabled = editable)
                    Text("距离 $distance")
                    Slider(distance.toFloat(), { distance = it.toInt() }, valueRange = 1f..3f, steps = 1, enabled = editable)
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.display(height, distance) } }, enabled = editable) { Text("应用画面位置") }
                }
            }
            settings.deviceInt("autoLockTime")?.let { current ->
                var value by remember(current) { mutableIntStateOf(current) }
                SettingsSection("自动休眠") {
                    SettingsChoice("休眠时间", value, listOf(5, 10, 15, 25, 40, 60, 120).map { it to "$it 秒" }, editable) { value = it }
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.autoLock(value) } },
                        enabled = editable && value in listOf(5, 10, 15, 25, 40, 60, 120)) { Text("应用休眠时间") }
                }
            }
            settings.optJSONObject("wakeupConfig")?.let { wake ->
                val current = wake.deviceFlag("headupSwitch"); val currentAngle = wake.deviceInt("headupDegree"); val currentCrown = wake.deviceInt("crownSwitch")
                if (current != null && currentAngle != null && currentCrown != null) {
                    var enabled by remember(current) { mutableStateOf(current) }; var angle by remember(currentAngle) { mutableIntStateOf(currentAngle) }
                    var crown by remember(currentCrown) { mutableIntStateOf(currentCrown) }
                    SettingsSection("唤醒方式") {
                        SettingsToggle("抬头点亮屏幕", enabled, editable) { enabled = it }
                        Text("抬头角度 $angle°"); Slider(angle.toFloat(), { angle = it.toInt() }, valueRange = 0f..90f, enabled = editable)
                        SettingsChoice("旋钮息屏动画", crown, listOf(0 to "关闭", 1 to "陀螺仪", 2 to "戳一戳", 3 to "弹珠"), editable) { crown = it }
                        ToolButton(onClick = { model.attempt { model.service().deviceSettings.wakeup(enabled, angle, crown) } }, enabled = editable) { Text("应用唤醒设置") }
                    }
                }
            }
            settings.optJSONObject("headGestures")?.let { head ->
                val enabledNow = head.deviceFlag("enabled"); val modeNow = head.deviceInt("mode")
                if (enabledNow != null && modeNow != null) {
                    var enabled by remember(enabledNow) { mutableStateOf(enabledNow) }; var mode by remember(modeNow) { mutableIntStateOf(modeNow) }
                    SettingsSection("头部控制") {
                        SettingsToggle("允许头控", enabled, editable) { enabled = it }
                        SettingsChoice("设备模式", mode, listOf(0 to "模式0", 1 to "模式1"), editable) { mode = it }
                        ToolButton(onClick = { model.attempt { model.service().deviceSettings.headGestures(enabled, mode) } }, enabled = editable) { Text("应用头控") }
                    }
                }
            }
            settings.optJSONObject("crownConfig")?.let { crown ->
                val d = crown.deviceInt("direction"); val c = crown.deviceInt("double"); val l = crown.deviceInt("longPress")
                if (d != null && c != null && l != null) {
                    var direction by remember(d) { mutableIntStateOf(d) }; var double by remember(c) { mutableIntStateOf(c) }; var long by remember(l) { mutableIntStateOf(l) }
                    val choices = listOf(0 to "助手", 1 to "首页", 2 to "勿扰", 3 to "录音", 4 to "字幕", 5 to "提词", 6 to "全天智记", 7 to "无", 8 to "待办", 9 to "实时提示")
                    SettingsSection("旋钮操作") {
                        SettingsChoice("方向", direction, listOf(0 to "方向0", 1 to "方向1"), editable) { direction = it }
                        SettingsChoice("双击", double, choices, editable) { double = it }
                        SettingsChoice("长按", long, choices.filter { it.first != 6 }, editable) { long = it }
                        ToolButton(onClick = { model.attempt { model.service().deviceSettings.crown(direction, double, long) } }, enabled = editable) { Text("应用旋钮操作") }
                    }
                }
            }
            settings.optJSONArray("supportedLanguages")?.let { languages ->
                val choices = (0 until languages.length()).map { languages.getString(it) }
                var language by remember(settings.optString("currentLang")) { mutableStateOf(settings.optString("currentLang")) }
                if (choices.isNotEmpty() && language.isNotBlank()) SettingsSection("系统语言") {
                    choices.forEach { option -> FilterChip(language == option, { language = option }, label = { Text(option) }, enabled = editable) }
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.language(language) } }, enabled = editable) { Text("应用语言") }
                }
            }
            settings.optJSONObject("privacyConfig")?.let { privacy ->
                val labels = linkedMapOf("mic_switch" to "眼镜麦克风", "led_light" to "指示灯", "led_auto_light" to "指示灯自动亮度", "log_switch" to "设备日志")
                val values = remember(privacy.toString()) { mutableStateMapOf<String, Boolean>().apply { labels.keys.forEach { key -> privacy.deviceFlag(key)?.let { put(key, it) } } } }
                if (values.isNotEmpty()) SettingsSection("隐私与硬件") {
                    labels.forEach { (key, label) -> values[key]?.let { SettingsToggle(label, it, editable) { values[key] = it } } }
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.privacy(values.toMap()) } }, enabled = editable) { Text("应用隐私设置") }
                }
            }
            settings.optJSONObject("voiceAssistantConfig")?.deviceFlag("voiceWakeup")?.let { current ->
                var enabled by remember(current) { mutableStateOf(current) }
                SettingsSection("语音唤醒") {
                    SettingsToggle("允许唤醒眼镜助手", enabled, editable) { enabled = it }
                    Note("此项修改眼镜唤醒开关；接听方式在“语音与提示词”中配置。")
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.voiceWake(enabled) } }, enabled = editable) { Text("应用语音唤醒") }
                }
            }
            val units = settings.optJSONObject("systemUnitsConfig")
            val currentTime = units?.deviceInt("time_format")
            val currentTemp = units?.deviceInt("temp_unit")
            val currentMeasure = units?.deviceInt("measurement")
            if (currentTime != null && currentTemp != null && currentMeasure != null) {
                var time by remember(currentTime) { mutableIntStateOf(currentTime) }
                var temperature by remember(currentTemp) { mutableIntStateOf(currentTemp) }
                var measurement by remember(currentMeasure) { mutableIntStateOf(currentMeasure) }
                SettingsSection("时间与单位") {
                    SettingsChoice("时间", time, listOf(1 to "24 小时制", 2 to "12 小时制"), editable) { time = it }
                    SettingsChoice("温度", temperature, listOf(1 to "摄氏度 °C", 2 to "华氏度 °F"), editable) { temperature = it }
                    SettingsChoice("计量", measurement, listOf(1 to "公制", 2 to "英制"), editable) { measurement = it }
                    ToolButton(onClick = { model.attempt { model.service().deviceSettings.units(time, temperature, measurement) } },
                        enabled = editable && listOf(time, temperature, measurement).all { it in 1..2 }) { Text("应用时间与单位") }
                    Note("日期格式沿用眼镜当前设置。")
                }
            }
            if (settings.optJSONObject("voiceAssistantConfig") == null || units == null) {
                Note("语音唤醒与单位选项会在设备报告对应配置后出现。当前未报告的配置不使用默认值覆盖。")
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    OutlinedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun SettingsToggle(title: String, value: Boolean, enabled: Boolean, update: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f)); Switch(value, update, enabled = enabled)
    }
}

@Composable
private fun SettingsChoice(title: String, value: Int, choices: List<Pair<Int, String>>, enabled: Boolean, update: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ToolOutlinedButton(onClick = { expanded = true }, enabled = enabled) {
            Text("$title：${choices.firstOrNull { it.first == value }?.second ?: "设备值 $value"}")
        }
        DropdownMenu(expanded, { expanded = false }) {
            choices.forEach { (id, label) -> DropdownMenuItem(text = { Text(label) }, onClick = { update(id); expanded = false }) }
        }
    }
}
