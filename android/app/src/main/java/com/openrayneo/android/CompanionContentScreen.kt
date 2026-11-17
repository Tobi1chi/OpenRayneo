// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
internal fun CompanionContentScreen(model: AppModel) {
    val state = model.state.content
    val connected = model.state.glasses.link.phase == LinkPhase.FULL
    val editable = connected && !state.busy
    var page by rememberSaveable { mutableIntStateOf(0) }
    var title by rememberSaveable { mutableStateOf("") }
    var editId by rememberSaveable { mutableStateOf<Long?>(null) }
    var start by rememberSaveable { mutableStateOf("") }
    var end by rememberSaveable { mutableStateOf("") }
    var cityQuery by rememberSaveable { mutableStateOf("") }
    val formatter = remember { DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm") }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("首页与内容", style = MaterialTheme.typography.headlineSmall)
        ToolButton(onClick = { model.attempt { model.service().content.refresh() } }, enabled = editable) { Text("读取眼镜内容") }
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Note(if (connected) state.notice else "请先连接眼镜")
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("布局", "待办", "日程", "天气").forEachIndexed { i, name -> FilterChip(page == i, { page = i; editId = null; title = "" }, label = { Text(name) }) }
        }
        when (page) {
            0 -> DashboardLayoutEditor(model)
            1 -> {
                state.todos.forEach { row ->
                    OutlinedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
                        Text(row.optString("title"), style = MaterialTheme.typography.titleMedium)
                        Note(if (row.optString("syncState") == "outcome_unknown") "修改结果待确认" else if (row.optInt("status") == 1) "已完成" else "待完成")
                        Row {
                            TextButton(onClick = { title = row.getString("title"); editId = row.getLong("eventID") }) { Text("编辑") }
                            TextButton(onClick = { model.attempt { model.service().content.run {
                                model.service().content.todo("update", JSONObject().put("event_id", row.getLong("eventID")).put("completed", row.optInt("status") != 1))
                            } } }, enabled = editable) { Text(if (row.optInt("status") == 1) "撤销完成" else "完成") }
                            TextButton(onClick = { model.attempt { model.service().content.run {
                                model.service().content.todo("delete", JSONObject().put("event_id", row.getLong("eventID")))
                            } } }, enabled = editable) { Text("删除") }
                        }
                    } }
                }
                OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("待办标题") })
                ToolButton(onClick = { model.attempt { model.service().content.run {
                    model.service().content.todo(if (editId == null) "add" else "update", JSONObject().put("title", title.trim()).apply { editId?.let { put("event_id", it) } })
                } } }, enabled = editable && title.isNotBlank()) { Text(if (editId == null) "添加到眼镜" else "保存待办") }
                if (editId != null) TextButton(onClick = { editId = null; title = "" }) { Text("结束编辑") }
            }
            2 -> {
                state.schedules.forEach { row ->
                    OutlinedCard(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
                        Text(row.optString("title"), style = MaterialTheme.typography.titleMedium)
                        Note(java.time.Instant.ofEpochSecond(row.getLong("startTime")).atZone(ZoneId.systemDefault()).format(formatter) + " — " +
                            java.time.Instant.ofEpochSecond(row.getLong("endTime")).atZone(ZoneId.systemDefault()).format(formatter))
                        Row {
                            TextButton(onClick = { title = row.getString("title"); editId = row.getLong("eventID")
                                start = java.time.Instant.ofEpochSecond(row.getLong("startTime")).atZone(ZoneId.systemDefault()).format(formatter)
                                end = java.time.Instant.ofEpochSecond(row.getLong("endTime")).atZone(ZoneId.systemDefault()).format(formatter)
                            }) { Text("编辑") }
                            TextButton(onClick = { model.attempt { model.service().content.run {
                                model.service().content.schedule("delete", JSONObject().put("event_id", row.getLong("eventID")))
                            } } }, enabled = editable) { Text("删除") }
                        }
                    } }
                }
                OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("日程标题") })
                OutlinedTextField(start, { start = it }, Modifier.fillMaxWidth(), label = { Text("开始：yyyy-MM-dd HH:mm") })
                OutlinedTextField(end, { end = it }, Modifier.fillMaxWidth(), label = { Text("结束：yyyy-MM-dd HH:mm") })
                ToolButton(onClick = { model.attempt {
                    val args = JSONObject().put("title", title.trim()).put("start_time", LocalDateTime.parse(start, formatter).atZone(ZoneId.systemDefault()).toEpochSecond())
                        .put("end_time", LocalDateTime.parse(end, formatter).atZone(ZoneId.systemDefault()).toEpochSecond())
                    editId?.let { args.put("event_id", it) }
                    model.service().content.run { model.service().content.schedule(if (editId == null) "add" else "update", args) }
                } }, enabled = editable && title.isNotBlank() && start.isNotBlank() && end.isNotBlank()) { Text(if (editId == null) "添加到眼镜" else "保存日程") }
                if (editId != null) TextButton(onClick = { editId = null; title = "" }) { Text("结束编辑") }
            }
            3 -> {
                OutlinedTextField(cityQuery, { cityQuery = it }, Modifier.fillMaxWidth(), label = { Text("搜索城市") })
                ToolButton(onClick = { model.attempt { model.service().content.run { model.service().content.searchCities(cityQuery) } } }, enabled = !state.busy && cityQuery.isNotBlank()) { Text("查找城市") }
                state.weatherCities.forEach { city -> TextButton(onClick = { model.attempt { model.service().content.run { model.service().content.weather(city) } } }, enabled = editable) {
                    Text(listOf(city.optString("name"), city.optString("admin1"), city.optString("country")).filter { it.isNotBlank() }.joinToString(" · "))
                } }
                state.weather?.let { card ->
                    Text("${card.getString("location")} · ${card.getInt("temp")}° · ${card.getString("des")}", style = MaterialTheme.typography.titleMedium)
                    ToolButton(onClick = { model.attempt { model.service().content.run { model.service().content.pushWeather() } } }, enabled = editable) { Text("同步首页温度与天气卡") }
                    Row {
                        Checkbox(state.automaticWeather, { model.attempt { model.service().content.setAutomaticWeather(it) } }, enabled = editable)
                        Text("连接时及每30分钟更新天气")
                    }
                    ToolOutlinedButton(onClick = { model.attempt { model.service().content.automaticWeather(force = true) } }, enabled = editable && state.automaticWeather) { Text("立即自动更新") }
                    Note("首页温度使用这里选中的城市。天气由Open-Meteo提供；断开连接后停止更新。")
                }
            }
        }
    }
}

@Composable
private fun DashboardLayoutEditor(model: AppModel) {
    val state = model.state.content
    val config = state.dashboard
    if (config == null) { Note("读取眼镜内容后，可配置首页样式和小组件顺序。"); return }
    var mode by remember(config.toString()) { mutableIntStateOf(config.optInt("simple_mode")) }
    var widgets by remember(config.toString()) { mutableStateOf(config.optJSONArray("widgets").ints()) }
    val names = mapOf(1 to "天气", 2 to "待办", 3 to "日程", 4 to "股票", 5 to "邮件", 6 to "世界时钟")
    val enabled = !state.busy && model.state.glasses.link.phase == LinkPhase.FULL
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf("标准", "简洁", "斜分").forEachIndexed { index, title -> FilterChip(mode == index, { mode = index }, label = { Text(title) }) }
    }
    widgets.forEachIndexed { index, id ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(names[id] ?: "设备组件$id", Modifier.weight(1f))
            TextButton(onClick = { widgets = widgets.toMutableList().apply { add(index - 1, removeAt(index)) } }, enabled = index > 0) { Text("上移") }
            TextButton(onClick = { widgets = widgets.toMutableList().apply { add(index + 1, removeAt(index)) } }, enabled = index < widgets.lastIndex) { Text("下移") }
            TextButton(onClick = { widgets = widgets.filter { it != id } }, enabled = widgets.size > 1) { Text("移除") }
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf(1,2,3,6).filter { it !in widgets }.forEach { id ->
            TextButton(onClick = { widgets = widgets + id }, enabled = widgets.size < 5 && (id != 1 || state.weather != null)) { Text("加${names[id]}") }
        }
    }
    Note("天气先在天气页配置城市；世界时钟使用手机当前时区。已有股票和邮件组件保留，数据源继续由原配置维护。")
    ToolButton(onClick = { model.attempt { model.service().content.run { model.service().content.layout(mode, widgets) } } }, enabled = enabled) { Text("应用首页布局") }
}
