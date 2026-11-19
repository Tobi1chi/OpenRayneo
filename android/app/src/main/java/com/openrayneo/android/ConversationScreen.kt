// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronLeft
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Search
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.delay

@Composable
internal fun ConversationScreen(model: AppModel, actions: UiActions, open: (String) -> Unit) {
    val state = model.state.conversation
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var liveSpeaker by remember { mutableStateOf<SpeechSegment?>(null) }
    LaunchedEffect(state.activeRecord?.id) { liveSpeaker = null }
    var query by rememberSaveable { mutableStateOf("") }
    var dateText by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var monthly by rememberSaveable { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val openAudio = state.records.any { it.audioPending }
    LaunchedEffect(state.running, openAudio) {
        now = System.currentTimeMillis()
        while (state.running || openAudio) {
            delay(60_000)
            now = System.currentTimeMillis()
        }
    }
    val date = LocalDate.parse(dateText)
    val record = state.records.firstOrNull { it.id == selected }
    if (record != null) {
        ConversationDetail(model, record, actions) { selected = null }
        return
    }
    liveSpeaker?.let { segment -> state.activeRecord?.let { active ->
        SpeakerBindingDialog(model, active, segment, actions) { liveSpeaker = null }
    } }
    var source by rememberSaveable { mutableStateOf(ConversationSource.REALTIME) }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            ContentCard {
                Text("记录与记忆", style = MaterialTheme.typography.headlineSmall)
                Note("全天智记以时间线和总结呈现，独立记录保留各自的起止时间与内容。本人、其他人及未知／混叠发言均保存；点击原话可更正人物归属。")
                if (!state.running) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ConversationSource.entries.forEach { option -> FilterChip(source == option, { source = option }, label = { Text(option.title) }) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ToolButton(onClick = { model.attempt { model.service().startConversation(ConversationMode.DAILY, source) } },
                            enabled = state.modelReady && model.state.glasses.link.phase == LinkPhase.FULL) { Text("开始日常") }
                        ToolOutlinedButton(onClick = { model.attempt { model.service().startConversation(ConversationMode.MEETING, source) } },
                            enabled = state.modelReady && model.state.glasses.link.phase == LinkPhase.FULL) { Text("开始会议") }
                    }
                } else {
                    Text("${state.mode.title} · ${state.source.title} · 已接收${state.decodedSeconds.toInt()}秒音频")
                    ToolButton(onClick = { model.service().conversations.stop() }, enabled = !state.stopping) { Text(if (state.stopping) "正在收尾…" else "停止记录与收音") }
                }
                Note(state.status)
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (!state.modelReady) Note("本地声音模型正在准备；加载失败时请查看上方错误。")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { open("voice-settings") }) { Text("语音与总结") }
                    TextButton(onClick = { open("voice-profiles") }) { Text("声音与人物") }
                }
            }
        }
        if (state.lastHint.isNotBlank()) item {
            ContentCard { Text("最近短提示", style = MaterialTheme.typography.titleMedium); Text(state.lastHint) }
        }
        if (state.running && state.segments.isNotEmpty()) {
            item { SectionLabel("当前对话") }
            items(state.segments.takeLast(12), key = { it.id }) { segment -> SpeechRow(segment, state.people, state.activeRecord) { liveSpeaker = segment } }
        }
        item {
            SectionLabel("记录日程")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!monthly, { monthly = false }, label = { Text("按天") })
                FilterChip(monthly, { monthly = true }, label = { Text("按月") })
                TextButton(onClick = { dateText = LocalDate.now().toString() }) { Text("今天") }
            }
            Surface(Modifier.fillMaxWidth().padding(top = 10.dp), shape = MaterialTheme.shapes.large,
                color = tokens.cardBackground) {
                Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { dateText = (if (monthly) date.minusMonths(1) else date.minusDays(1)).toString() }) {
                        Icon(Icons.Outlined.ChevronLeft, "上一${if (monthly) "月" else "天"}")
                    }
                    Text(if (monthly) "${date.year}年${date.monthValue}月" else "${date.monthValue}月${date.dayOfMonth}日",
                        Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    IconButton(onClick = { dateText = (if (monthly) date.plusMonths(1) else date.plusDays(1)).toString() }) {
                        Icon(Icons.Outlined.ChevronRight, "下一${if (monthly) "月" else "天"}")
                    }
                }
            }
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(top = 10.dp), label = { Text("搜索本时段原话、人物或记忆") }, singleLine = true,
                shape = MaterialTheme.shapes.medium, leadingIcon = { Icon(Icons.Outlined.Search, null) })
        }
        val begin = (if (monthly) date.withDayOfMonth(1) else date).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val end = (if (monthly) date.withDayOfMonth(1).plusMonths(1) else date.plusDays(1)).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val matchingRecords = state.records.filter { row ->
                query.isBlank() || row.title.contains(query, true) || row.summary.contains(query, true) ||
                    row.segments.any { it.text.contains(query, true) || state.people.firstOrNull { p -> p.id == it.personId }?.name?.contains(query, true) == true } ||
                    row.memories.any { it.subject.contains(query, true) || it.text.contains(query, true) } ||
                    row.summaries.any { it.text.contains(query, true) }
        }
        val records = matchingRecords.filter { row ->
            row.createdAt < end && calendarRecordEnd(row, now) > begin
        }.sortedBy { it.createdAt }
        val recordsByDay = records.flatMap { row -> calendarRecordDays(row, begin, end, now).map { it to row } }
            .groupBy({ it.first }, { it.second })
        val summariesByDay = matchingRecords.flatMap { it.summaries }.filter { it.kind == "day_end" && it.day.isNotBlank() }
            .sortedBy { it.stale }.distinctBy { it.day to it.text }
            .map { LocalDate.parse(it.day) to it }
            .filter { (day, _) -> day >= localDate(begin) && day < localDate(end) }
            .groupBy({ it.first }, { it.second })
        val days = (recordsByDay.keys + summariesByDay.keys).sorted()
        if (days.isEmpty()) item { Note("这个时段还没有匹配的记录。可切换日期，或开始一条记录。") }
        days.forEach { day ->
            val dayRecords = recordsByDay[day].orEmpty()
            val dayBegin = day.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val dayEnd = day.plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            item(key = "day:$day") { SectionLabel("${day.monthValue}月${day.dayOfMonth}日 · ${dayRecords.size}条记录") }
            summariesByDay[day].orEmpty().forEach { summary -> item {
                ContentCard { Text("日总结", style = MaterialTheme.typography.titleMedium); Text(summary.text); if (summary.stale) Note("关联内容有更正，等待刷新") }
            } }
            dayRecords.groupBy { timePeriod(it.createdAt.coerceAtLeast(dayBegin)) }.forEach { (period, periodRecords) ->
                item(key = "period:$day:$period") { Note(period) }
                items(periodRecords, key = { "$day:${it.id}" }) { row ->
                    val daySegments = row.segments.filter { segment ->
                        row.timeOf(segment) < dayEnd && row.endTimeOf(segment) > dayBegin
                    }
                    OutlinedCard(Modifier.fillMaxWidth().clickable { selected = row.id }) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(row.title, style = MaterialTheme.typography.titleMedium)
                            Note("${row.source.title} · ${recordTime(row)} · 当天${daySegments.size}条原话")
                            if (row.processingPending) Note("音频已保存，转写与说话人分析待补齐")
                            if (row.source == ConversationSource.ALWAYS_ON) daySegments.take(3).forEach { segment ->
                                Note("${SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(row.timeOf(segment)))} · ${segment.text}")
                            } else if (row.summary.isNotBlank()) Text(row.summary.take(160))
                            if (row.summaryStale) Note("归属有修改，摘要等待重新整理")
                            if (row.derived.any { it.stale }) Note("关联 Agent 结果需要刷新")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SpeechRow(segment: SpeechSegment, people: List<VoicePerson>, record: ConversationRecord? = null, action: (() -> Unit)? = null) {
    OutlinedCard(Modifier.fillMaxWidth().then(if (action != null) Modifier.clickable(onClick = action) else Modifier)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val name = people.firstOrNull { it.id == segment.personId }?.name ?: if (segment.speaker == "未知") "未知说话人" else "说话人${segment.speaker}"
            val start = record?.timeOf(segment) ?: segment.timelineAt.takeIf { it > 0 }
            val end = record?.endTimeOf(segment) ?: segment.timelineEndAt.takeIf { it > 0 }
            val clock = SimpleDateFormat("HH:mm:ss", Locale.CHINA)
            val time = start?.let { clock.format(Date(it)) + (end?.let { until -> "–${clock.format(Date(until))}" } ?: "") } ?: formatOffset(segment.beginMS)
            Note((if (segment.timeBasis == "legacy-estimate") "历史时间估计" else "手机接收时间") + if (segment.processingMode == "backfill") " · 历史音频补齐" else "")
            Note("通道${segment.sourceChannel} · " + (when (segment.identityBasis) { "channel1_default_self" -> "通道1默认本人"; "native_wake_self" -> "唤醒默认本人"; "voiceprint" -> "声纹匹配"; "manual" -> "人工更正"; "mixed" -> "混合识别"; else -> "身份待识别" }))
            Note("$time · $name${if (segment.mixed) " · 重叠或混合" else if (!segment.stable) " · 暂定" else ""}")
            if (segment.candidates.isNotEmpty()) {
                Note("声纹候选 · " + segment.candidates.joinToString(" · ") { match ->
                    "${people.firstOrNull { it.id == match.personId }?.name ?: "已移除人物"} ${"%.2f".format(match.score)}"
                })
            } else segment.matchScore?.let { Note("声音相似度 ${"%.2f".format(it)}") }
            if (segment.matchReason.isNotBlank()) Note(segment.matchReason)
            Text(segment.text)
        }
    }
}

@Composable
private fun ConversationDetail(model: AppModel, record: ConversationRecord, actions: UiActions, back: () -> Unit) {
    val state = model.state.conversation
    var speakerEdit by remember { mutableStateOf<SpeechSegment?>(null) }
    var memoryEdit by remember { mutableStateOf<AttributedMemory?>(null) }
    var filter by rememberSaveable(record.id) { mutableStateOf<String?>(null) }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TextButton(back) { Text("返回记录") }
            Text(record.title, style = MaterialTheme.typography.headlineSmall)
            Note("${record.source.title} · ${recordTime(record)}")
            Note(if (record.source == ConversationSource.ALWAYS_ON) "全天智记时间线与总结；点击原话可更正人物。" else "${record.mode.title} · 点击原话可更正说话人，点击记忆可更正叙述对象。")
            if (record.processingPending) Note("原始音频已保存，转写与说话人分析待补齐；完成后一起显示。")
            ToolButton(onClick = { model.service().conversations.summarize(record.id) }, enabled = !state.summarizing && record.segments.isNotEmpty()) {
                Text(if (state.summarizing) "正在整理…" else "整理摘要与记忆")
            }
            if (record.audioSamples > 0) {
                Note("已保存${record.audioSamples / 16000}秒${record.audioChannels}声道原始音频，在手机加密存储，电脑按需取得。")
                Row {
                    TextButton(onClick = { actions.exportRecording(record.id) }) { Text("导出WAV") }
                    TextButton(onClick = { model.attempt { model.service().conversations.retranscribe(record.id) } }, enabled = !state.running) { Text("从原音频补齐缺失片段") }
                }
            }
            if (record.summary.isNotBlank()) Text(record.summary)
            if (record.summaryStale) Note("内容有更新，请重新整理摘要。")
            record.summaries.filter { it.kind != "rolling" }.forEach { summary ->
                Text(if (summary.kind == "day_end") "${summary.day.ifBlank { "日期未记录" }} 日总结" else "记录结束总结", style = MaterialTheme.typography.titleSmall)
                Text(summary.text)
                if (summary.stale) Note("来源有更正，等待刷新")
            }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        if (record.derived.isNotEmpty()) item { SectionLabel("关联的 Agent 分析与笔记") }
        items(record.derived, key = { "derived:${it.id}" }) { derived ->
            ContentCard {
                Text(when (derived.kind) { "analysis" -> "分析"; "tags" -> "标签"; else -> "补充笔记" }, style = MaterialTheme.typography.titleSmall)
                if (derived.text.isNotBlank()) Text(derived.text)
                if (derived.tags.isNotEmpty()) Note(derived.tags.joinToString(" · "))
                if (derived.stale) Note("来源有更正，需要由原 Agent 刷新")
            }
        }
        if (record.speakerSamples.isNotEmpty()) item {
            SectionLabel("已采集的声音 · 点击命名")
            record.speakerSamples.forEach { (label, samples) ->
                val segment = record.segments.firstOrNull { it.speaker == label }
                    ?: SpeechSegment("voice:$label", 0, 0, "本次会话已自动提取${samples.size}段声音特征", speaker = label, personId = record.speakerPeople[label])
                TextButton(onClick = { speakerEdit = segment }) {
                    Text("说话人$label · ${state.people.firstOrNull { it.id == segment.personId }?.name ?: "待标注"} · ${samples.size}段样本")
                }
            }
        }
        if (record.memories.isNotEmpty()) item { SectionLabel("有来源的记忆") }
        items(record.memories, key = { it.id }) { memory ->
            OutlinedCard(Modifier.fillMaxWidth().clickable { memoryEdit = memory }) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("${memory.subject} · ${memory.kind}", style = MaterialTheme.typography.titleSmall)
                    Text(memory.text)
                    memory.sourceIds.forEach { id -> record.segments.firstOrNull { it.id == id }?.let { source -> Note("原话：${source.text}") } }
                }
            }
        }
        item {
            SectionLabel("原话时间线")
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FilterChip(filter == null, { filter = null }, label = { Text("全部") })
                record.segments.map { it.speaker }.distinct().take(6).forEach { name ->
                    FilterChip(filter == name, { filter = name }, label = { Text(name) })
                }
            }
        }
        record.segments.filter { filter == null || it.speaker == filter }.groupBy { localDate(record.timeOf(it)) }.forEach { (day, segments) ->
            item(key = "timeline:$day") { SectionLabel("${day.monthValue}月${day.dayOfMonth}日") }
            items(segments, key = { it.id }) { segment ->
                SpeechRow(segment, state.people, record) { speakerEdit = segment }
            }
        }
    }
    speakerEdit?.let { segment -> SpeakerBindingDialog(model, record, segment, actions) { speakerEdit = null } }
    memoryEdit?.let { memory ->
        var subject by remember(memory.id) { mutableStateOf(memory.subject) }
        var text by remember(memory.id) { mutableStateOf(memory.text) }
        AlertDialog(onDismissRequest = { memoryEdit = null }, title = { Text("更正记忆归属") }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(subject, { subject = it }, label = { Text("这件事说的是谁") })
                OutlinedTextField(text, { text = it }, label = { Text("记忆内容") })
                Note("说话人和原文来源保留；保存后需重新整理摘要。")
            }
        }, confirmButton = { TextButton(onClick = {
            model.service().conversations.correctMemory(record.id, memory.id, subject.trim(), text.trim()); memoryEdit = null
        }, enabled = subject.isNotBlank() && text.isNotBlank()) { Text("保存更正") } }, dismissButton = { TextButton(onClick = { memoryEdit = null }) { Text("取消") } })
    }
}

@Composable
private fun SpeakerBindingDialog(model: AppModel, record: ConversationRecord, segment: SpeechSegment, actions: UiActions, dismiss: () -> Unit) {
    val people = model.state.conversation.people
    var history by remember { mutableStateOf(false) }
    if (history) {
        HistoricalSpeakerDialog(model, segment.personId, record.id, segment.id, dismiss = dismiss)
        return
    }
    var personId by remember { mutableStateOf(segment.personId ?: record.speakerPeople[segment.speaker]) }
    var name by remember { mutableStateOf("") }
    var all by remember { mutableStateOf(segment.speaker != "未知") }
    var rememberVoice by remember { mutableStateOf(record.speakerSamples[segment.speaker]?.isNotEmpty() == true) }
    val picked = model.selectedContact
    LaunchedEffect(picked) { if (picked != null) { name = picked.name; personId = null } }
    AlertDialog(onDismissRequest = dismiss, title = { Text("说话人${segment.speaker}") }, text = {
        Column(Modifier.heightIn(max = 500.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Note(segment.text)
            TextButton(onClick = { history = true }) { Text("选择历史发言并批量更正") }
            Row { Checkbox(all, { all = it }, enabled = segment.speaker != "未知"); Text("应用到本次记录的同一说话人") }
            people.forEach { person ->
                Row(Modifier.fillMaxWidth().clickable { personId = person.id }) {
                    RadioButton(personId == person.id, { personId = person.id }); Text(person.name)
                }
            }
            OutlinedTextField(name, { name = it; personId = null }, label = { Text("或新建人物名称") })
            TextButton(onClick = { model.selectedContact = null; actions.contact() }) { Text("从联系人选择") }
            Row { Checkbox(rememberVoice, { rememberVoice = it }, enabled = all && record.speakerSamples[segment.speaker]?.isNotEmpty() == true)
                Text("记住这个声音，供下次识别") }
            Note("已自动采集${record.speakerSamples[segment.speaker].orEmpty().size}段声纹。勾选后，命名的声音将在下次会话参与匹配；关闭则只改本次标签。相似度是声音对比得分。")
        }
    }, confirmButton = { TextButton(onClick = {
        val person = people.firstOrNull { it.id == personId } ?: VoicePerson(name = name.trim(), contactUri = picked?.uri)
        if (all) model.service().conversations.bind(record.id, segment.speaker, person, rememberVoice)
        else {
            model.service().conversations.correctSpeaker(record.id, setOf(segment.id), person.id, person)
        }
        model.selectedContact = null; dismiss()
    }, enabled = personId != null || name.isNotBlank()) { Text("保存") } }, dismissButton = {
        TextButton(onClick = { model.selectedContact = null; dismiss() }) { Text("取消") }
    })
}

private fun formatOffset(milliseconds: Long): String = "%02d:%02d".format(milliseconds / 60000, milliseconds / 1000 % 60)

private fun localDate(time: Long): LocalDate = Instant.ofEpochMilli(time).atZone(ZoneId.systemDefault()).toLocalDate()
private fun calendarRecordEnd(record: ConversationRecord, now: Long): Long = record.endedAt
    ?: if (record.audioPending) now else record.segments.maxOfOrNull { record.endTimeOf(it) } ?: record.createdAt
private fun calendarRecordDays(record: ConversationRecord, begin: Long, end: Long, now: Long): List<LocalDate> {
    val start = record.createdAt.coerceAtLeast(begin)
    val until = calendarRecordEnd(record, now).coerceAtMost(end)
    if (until <= start) return emptyList()
    val lastDay = localDate(until - 1)
    return generateSequence(localDate(start)) { day -> day.plusDays(1).takeIf { it <= lastDay } }.toList()
}
private fun timePeriod(time: Long): String = when (Instant.ofEpochMilli(time).atZone(ZoneId.systemDefault()).hour) {
    in 0..5 -> "凌晨 00:00–06:00"
    in 6..11 -> "上午 06:00–12:00"
    in 12..17 -> "下午 12:00–18:00"
    else -> "晚间 18:00–24:00"
}
private fun recordTime(record: ConversationRecord): String {
    val format = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)
    return format.format(Date(record.createdAt)) + " → " + (record.endedAt?.let { format.format(Date(it)) } ?: "结束时间未记录")
}

/** Select exact historical turns before changing identity; original ASR and audio remain intact. */
@Composable
internal fun HistoricalSpeakerDialog(
    model: AppModel, personId: String?, initialRecordId: String? = null, initialSegmentId: String? = null,
    split: Boolean = false, dismiss: () -> Unit,
) {
    val state = model.state.conversation
    val rows = state.records.map { record -> record to record.segments.filter { segment ->
        if (personId != null) segment.personId == personId else initialRecordId == null || record.id == initialRecordId
    } }.filter { it.second.isNotEmpty() }.sortedByDescending { it.first.createdAt }
    val selection = remember(personId, initialRecordId, initialSegmentId, split) {
        mutableStateMapOf<String, Set<String>>().apply {
            if (initialRecordId != null && initialSegmentId != null) put(initialRecordId, setOf(initialSegmentId))
        }
    }
    var expanded by remember { mutableStateOf(setOfNotNull(initialRecordId)) }
    var targetId by remember { mutableStateOf(personId) }
    var name by remember { mutableStateOf("") }
    val selected = selection.filterValues { it.isNotEmpty() }
    val count = selected.values.sumOf { it.size }
    AlertDialog(onDismissRequest = dismiss, title = { Text(if (split) "拆分人物的历史发言" else "批量更正历史人物归属") }, text = {
        Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Note("先选择记录或展开挑选发言。此次将修改 ${selected.size} 条记录、$count 段原话；相关总结和 Agent 结果将标记需刷新，原文与音频保留。")
            if (split) OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("拆分出的新人物名称") })
            else {
                Text("更正为", style = MaterialTheme.typography.titleSmall)
                Row(Modifier.fillMaxWidth().clickable { targetId = null }) {
                    RadioButton(targetId == null, { targetId = null }); Text("未知说话人")
                }
                state.people.filter { it.mergedInto == null }.forEach { person ->
                    Row(Modifier.fillMaxWidth().clickable { targetId = person.id }) {
                        RadioButton(targetId == person.id, { targetId = person.id }); Text(person.name)
                    }
                }
            }
            HorizontalDivider()
            if (rows.isEmpty()) Note("没有可更正的关联发言。")
            rows.forEach { (record, turns) ->
                val ids = turns.map { it.id }.toSet()
                Row(Modifier.fillMaxWidth()) {
                    Checkbox(ids.isNotEmpty() && selection[record.id].orEmpty().containsAll(ids), { checked ->
                        selection[record.id] = if (checked) ids else emptySet()
                    })
                    Column(Modifier.weight(1f)) {
                        Text(record.title, style = MaterialTheme.typography.titleSmall)
                        Note("${recordTime(record)} · ${selection[record.id].orEmpty().size}/${turns.size}段")
                        TextButton(onClick = { expanded = if (record.id in expanded) expanded - record.id else expanded + record.id }) {
                            Text(if (record.id in expanded) "收起发言" else "挑选发言")
                        }
                    }
                }
                if (record.id in expanded) turns.forEach { turn ->
                    Row(Modifier.fillMaxWidth()) {
                        Checkbox(turn.id in selection[record.id].orEmpty(), { checked ->
                            val old = selection[record.id].orEmpty()
                            selection[record.id] = if (checked) old + turn.id else old - turn.id
                        })
                        Column(Modifier.weight(1f).padding(top = 10.dp)) { Note(formatOffset(turn.beginMS)); Text(turn.text) }
                    }
                }
                HorizontalDivider()
            }
        }
    }, confirmButton = { TextButton(onClick = {
        model.attempt {
            if (split) model.service().conversations.splitPerson(requireNotNull(personId), name.trim(), selected)
            else model.service().conversations.correctSpeakers(selected, targetId)
        }
        dismiss()
    }, enabled = count > 0 && (!split || name.isNotBlank())) { Text("确认${if (split) "拆分" else "更正"}$count 段") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
