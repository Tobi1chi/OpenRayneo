// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

@Composable
internal fun VoiceSettingsScreen(model: AppModel, actions: UiActions) {
    val drafts = model.formDrafts
    val voiceKeys = listOf("asrKey", "asrUrl", "asrModel", "nativeAutoAnswer", "audioChannel", "speakerThreshold", "memoryPrompt", "memoryAutoSummary", "answerClearSeconds")
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("语音与记忆配置", style = MaterialTheme.typography.headlineSmall)
        Note("声音特征与说话人处理在本机运行，ASR与记录总结使用你配置的服务。回复、短提示和任务判断交给手机本机 Agent；密钥由Android Keystore加密保存。")
        SectionLabel("百炼ASR")
        VoiceField(model, "asrKey", "API Key", secret = true)
        VoiceField(model, "asrUrl", "WSS地址", "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        VoiceField(model, "asrModel", "模型", "qwen-audio-3.1-asr-flash-message")
        var auto by remember(model.config) { mutableStateOf(model.config.optBoolean("nativeAutoAnswer")) }
        Row { Checkbox(auto, { auto = it; drafts["nativeAutoAnswer"] = it.toString() }); Text("小雷小雷唤醒后自动接听") }
        Note("原生唤醒接听后接收音频，由ASR与说话人处理完成后交给本机 Agent。")
        var autoMemory by remember(model.config) { mutableStateOf(model.config.optString("memoryAutoSummary", "true") != "false") }
        Row { Checkbox(autoMemory, { autoMemory = it; drafts["memoryAutoSummary"] = it.toString() }); Text("自动生成滚动、日终与记录结束总结") }
        Note("全天智记与独立记录自动保存原始音频；声音登记仅保存声音特征。转写延迟时，先保存音频，恢复后补齐转写与说话人分析。")
        VoiceField(model, "answerClearSeconds", "实时提示回答后清屏秒数；0保留", "0")
        SectionLabel("当前位置与天气")
        Note("本机 Agent 可通过工具查询天气；定位工具需要位置权限。后台语音使用眼镜连接的前台服务。")
        TextButton(onClick = actions.locationPermission) { Text("允许位置访问") }
        SectionLabel("声道与识别判断")
        Note("正常双通道同时处理：通道1默认本人，通道2独立识别；全天智记与其他单声道全量识别说话人。此选项仅用于主动登记，不改变记录策略。")
        VoiceField(model, "audioChannel", "登记诊断声道：0/1通道一、2通道二", "0")
        VoiceField(model, "speakerThreshold", "声音匹配阈值（尚待你的声音校准）", "0.7")
        SectionLabel("记录总结")
        VoiceField(model, "modelUrl", "总结模型服务地址")
        VoiceField(model, "modelName", "总结模型名称")
        VoiceField(model, "modelKey", "总结模型 API Key", secret = true)
        StructuredVoicePrompt(model, "memoryPrompt", "记忆归属与整理", ConversationPrompts.memory)
        Note("此模型只用于应用内记录总结。原话、说话人和叙述对象分别保存；全部可获取转写长期保留。")
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        ToolButton(onClick = {
            val invalid = listOf("speakerThreshold")
                .firstOrNull { key -> val value = drafts[key].orEmpty(); value.isNotBlank() && value.toDoubleOrNull()?.let { it.isFinite() && it in 0.0..1.0 } != true }
            if (invalid != null) error = "$invalid 需在0到1之间"
            else if (drafts["audioChannel"].orEmpty().isNotBlank() && drafts["audioChannel"]?.toIntOrNull() !in 0..2) error = "声道应为0、1或2"
            else if (drafts["answerClearSeconds"].orEmpty().isNotBlank() && drafts["answerClearSeconds"]?.toIntOrNull() !in 0..3600) error = "清屏延时需为0到3600秒"
            else { error = null; model.saveConfig((voiceKeys + listOf("modelUrl", "modelName", "modelKey")).associateWith { drafts[it].orEmpty() }) }
        }, modifier = Modifier.fillMaxWidth()) { Text("保存语音配置") }
    }
}

@Composable
private fun VoiceField(model: AppModel, key: String, label: String, fallback: String = "", secret: Boolean = false) {
    val value = model.formDrafts[key].orEmpty()
    if (secret) OutlinedTextField(value, { model.formDrafts[key] = it }, Modifier.fillMaxWidth(), label = { Text(label) },
        visualTransformation = PasswordVisualTransformation(), singleLine = true)
    else OutlinedTextField(value, { model.formDrafts[key] = it }, Modifier.fillMaxWidth(), label = { Text(label) }, placeholder = { Text(fallback) }, singleLine = true)
}

@Composable
private fun StructuredVoicePrompt(model: AppModel, key: String, title: String, fallback: String) {
    val raw = model.formDrafts[key].orEmpty()
    var expanded by remember { mutableStateOf(false) }
    val initial = remember(key, model.config) {
        if (raw.trim().startsWith("{")) JSONObject(raw) else JSONObject().put("objective", raw.ifBlank { fallback }).put("rules", JSONArray())
    }
    var role by remember(initial) { mutableStateOf(initial.optString("role")) }
    var objective by remember(initial) { mutableStateOf(initial.optString("objective")) }
    var rules by remember(initial) { mutableStateOf(initial.optJSONArray("rules")?.let { a -> (0 until a.length()).joinToString("\n") { a.getString(it) } }.orEmpty()) }
    fun update() {
        model.formDrafts[key] = JSONObject().put("role", role).put("objective", objective)
            .put("rules", JSONArray(rules.lines().map { it.trim() }.filter { it.isNotEmpty() })).toString()
    }
    OutlinedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onClick = { expanded = !expanded }) { Text(title + if (expanded) " · 收起" else " · 编辑") }
            if (expanded) {
                TextButton(onClick = { role = ""; objective = fallback; rules = ""; update() }) { Text("恢复本版默认提示词") }
                OutlinedTextField(role, { role = it; update() }, Modifier.fillMaxWidth(), label = { Text("角色") })
                OutlinedTextField(objective, { objective = it; update() }, Modifier.fillMaxWidth(), label = { Text("目标") }, minLines = 3)
                OutlinedTextField(rules, { rules = it; update() }, Modifier.fillMaxWidth(), label = { Text("规则，每行一条") }, minLines = 3)
            }
        }
    }
}

@Composable
internal fun VoiceProfilesScreen(model: AppModel) {
    val state = model.state.conversation
    val self = state.people.firstOrNull { it.self }
    var rename by remember { mutableStateOf<VoicePerson?>(null) }
    var merge by remember { mutableStateOf<VoicePerson?>(null) }
    var history by remember { mutableStateOf<VoicePerson?>(null) }
    var split by remember { mutableStateOf<VoicePerson?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("声音与人物", style = MaterialTheme.typography.headlineSmall)
        Note("清晰声音会自动建立未命名人物档案，跨记录尝试关联。可命名、合并、拆分或选择历史发言纠正；声音特征只存手机。登记本人时请独自说三四句，每句后稍作停顿。")
        if (state.running && state.mode == ConversationMode.ENROLL) {
            var confirmed by remember { mutableStateOf(false) }
            Text("人声${state.enrollmentTotalSeconds.toInt()}秒 · 一致样本${state.enrollmentSeconds.toInt()}秒 · 接收音频${state.decodedSeconds.toInt()}秒")
            if (state.enrollmentCanConfirm && !state.enrollmentReady) {
                Note("模型对样本一致性有疑问。确认全程只有你说话时，可手动标注这些样本；有其他人说话时请重新录制。")
                Row { Checkbox(confirmed, { confirmed = it }); Text("我确认这些人声全部由本人说出") }
            }
            ToolButton(onClick = { model.service().conversations.saveEnrollment(self?.name ?: "我", true, self?.contactUri, confirmAllSamples = confirmed) }, enabled = !state.stopping && (state.enrollmentReady || state.enrollmentCanConfirm && confirmed)) { Text("保存我的声音") }
            TextButton(onClick = { model.service().conversations.stop() }) { Text("停止登记") }
        } else ToolButton(onClick = { model.attempt { model.service().startConversation(ConversationMode.ENROLL, ConversationSource.REALTIME, self) } },
            enabled = !state.running && state.modelReady && model.state.glasses.link.phase == LinkPhase.FULL) { Text(if (self?.samples?.isNotEmpty() == true) "重新登记我的声音" else "登记我的声音") }
        Note(state.status)
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        state.people.filter { it.mergedInto == null }.forEach { person ->
            OutlinedCard(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text(person.name + if (person.self) " · 我" else "", style = MaterialTheme.typography.titleMedium)
                    if (person.unnamed) Note("自动建立 · 待命名")
                    Note(if (person.samples.isEmpty()) "未登记声音" else "已登记${person.samples.size}个声音样本")
                    if (person.contactUri != null) Note("已关联选定联系人")
                    Row {
                        TextButton(onClick = { rename = person }) { Text("命名") }
                        TextButton(onClick = { merge = person }, enabled = state.people.count { it.mergedInto == null } > 1) { Text("合并") }
                        TextButton(onClick = { split = person }) { Text("拆分") }
                    }
                    TextButton(onClick = { history = person }) { Text("选择历史发言更正") }
                    if (person.samples.isNotEmpty()) TextButton(onClick = { model.service().conversations.removeVoice(person.id) }) { Text("移除声音，保留人物记录") }
                }
            }
        }
    }
    rename?.let { person ->
        var name by remember(person.id) { mutableStateOf(person.name) }
        AlertDialog(onDismissRequest = { rename = null }, title = { Text("人物命名") }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("人物名称") }, singleLine = true)
                Note("更新此人物的名称和关联显示，相关总结及 Agent 结果将标记需刷新。")
            }
        }, confirmButton = { TextButton(onClick = { model.attempt { model.service().conversations.renamePerson(person.id, name.trim()) }; rename = null }, enabled = name.isNotBlank()) { Text("保存名称") } },
            dismissButton = { TextButton(onClick = { rename = null }) { Text("取消") } })
    }
    merge?.let { PersonMergeDialog(model, it) { merge = null } }
    history?.let { HistoricalSpeakerDialog(model, it.id, dismiss = { history = null }) }
    split?.let { HistoricalSpeakerDialog(model, it.id, split = true, dismiss = { split = null }) }
}

@Composable
private fun PersonMergeDialog(model: AppModel, initial: VoicePerson, dismiss: () -> Unit) {
    val state = model.state.conversation
    val people = state.people.filter { it.mergedInto == null }
    var sourceIds by remember { mutableStateOf(setOf(initial.id)) }
    var targetId by remember { mutableStateOf<String?>(null) }
    var recordIds by remember { mutableStateOf(emptySet<String>()) }
    val records = state.records.filter { record -> record.segments.any { it.personId in sourceIds } }
    val validRecords = records.filter { it.id in recordIds }
    val affected = validRecords.sumOf { record -> record.segments.count { it.personId in sourceIds } }
    AlertDialog(onDismissRequest = dismiss, title = { Text("合并人物档案") }, text = {
        Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("要合并的档案", style = MaterialTheme.typography.titleSmall)
            people.filter { it.id != targetId }.forEach { person ->
                Row(Modifier.fillMaxWidth()) {
                    Checkbox(person.id in sourceIds, { checked -> sourceIds = if (checked) sourceIds + person.id else sourceIds - person.id })
                    Text(person.name, Modifier.padding(top = 12.dp))
                }
            }
            Text("合并到", style = MaterialTheme.typography.titleSmall)
            people.filter { it.id !in sourceIds }.forEach { person ->
                Row(Modifier.fillMaxWidth().clickable { targetId = person.id }) {
                    RadioButton(targetId == person.id, { targetId = person.id }); Text(person.name, Modifier.padding(top = 12.dp))
                }
            }
            Text("历史归属的修改范围", style = MaterialTheme.typography.titleSmall)
            records.forEach { record ->
                Row(Modifier.fillMaxWidth()) {
                    Checkbox(record.id in recordIds, { checked -> recordIds = if (checked) recordIds + record.id else recordIds - record.id })
                    Column(Modifier.weight(1f).padding(top = 8.dp)) {
                        Text(record.title)
                        Note(java.text.SimpleDateFormat("M月d日 HH:mm", java.util.Locale.CHINA).format(java.util.Date(record.createdAt)))
                    }
                }
            }
            Note("将合并 ${sourceIds.size} 份声音档案，并更正已选 ${validRecords.size} 条记录、$affected 段发言。相关总结和 Agent 结果将标记需刷新。未选历史原话保留当前归属。")
        }
    }, confirmButton = { TextButton(onClick = {
        model.attempt { model.service().conversations.mergePeople(sourceIds, requireNotNull(targetId), validRecords.map { it.id }.toSet()) }
        dismiss()
    }, enabled = sourceIds.isNotEmpty() && targetId != null && targetId !in sourceIds) { Text("确认合并") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
