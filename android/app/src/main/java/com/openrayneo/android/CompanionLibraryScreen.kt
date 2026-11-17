// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions

@Composable
internal fun AgentServerScreen(model: AppModel, requestBluetoothPermission: () -> Unit) {
    val context = LocalContext.current
    val state = model.state.agentServer
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("DSH Go 与外部 Agent", style = MaterialTheme.typography.headlineSmall)
        Note("助手聊天和语音输入统一交给本机 Agent。DSH Go 插件负责回复、短提示和任务策略，工具审批与手机操控继续在 DSH Go 中处理，最终回复回到 OpenRayneo 和眼镜。")
        Note("手机持有眼镜蓝牙连接，外部Agent通过此入口调用设备工具。默认关闭；启用后，持有令牌的本机程序可读取记录、修改眼镜内容。")
        Note(state.notice)
        var port by remember(model.config.optString("localAgentPort")) { mutableStateOf(model.config.optString("localAgentPort", "8766")) }
        if (!state.enabled) {
            OutlinedTextField(port, { port = it.filter(Char::isDigit) }, label = { Text("本机端口") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true)
            TextButton(onClick = { model.saveConfig(mapOf("localAgentPort" to port)) }, enabled = port.toIntOrNull() in 1024..65535) { Text("保存端口") }
        }
        if (!model.bluetoothAllowed) {
            Note("后台设备服务需要 Android 的附近设备权限；此按钮只申请权限，不扫描或连接眼镜。")
            ToolButton(onClick = requestBluetoothPermission) { Text("授予附近设备权限") }
        } else ToolButton(onClick = { model.attempt { model.service().enableAgentServer(!state.enabled) } }) { Text(if (state.enabled) "关闭Agent入口" else "启用本机Agent入口") }
        if (state.enabled) {
            Text("http://127.0.0.1:${state.port}")
            ToolOutlinedButton(onClick = { model.attempt {
                val token = model.service().agentServer.tokenForUser()
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("OpenRayneo Agent", "http://127.0.0.1:${state.port}\nAuthorization: Bearer $token"))
                model.notice = "地址与令牌已复制"
            } }) { Text("复制地址与访问令牌") }
            TextButton(onClick = { model.attempt { model.service().agentServer.rotate() } }) { Text("重置令牌，使旧令牌失效") }
            Note("DSH Go：安装 openrayneo-dsh 插件，先在这里复制地址与访问令牌，再去 DSH 聊天页点“连接眼镜”，允许读取剪贴板以保存凭据。自定义端口需先修改插件的 Service URL。保持两款应用的后台运行权限。")
            Note("电脑经USB访问：adb forward tcp:8766 tcp:${state.port}。随后请求电脑127.0.0.1:8766。服务仅监听手机本机地址，不直接开放到局域网。")
            Note("本机 Agent 可查询记录、调用眼镜工具、领取任务并回传回复。记录同步使用下面的独立入口。")
        }
        HorizontalDivider()
        SectionLabel("手机与电脑相遇同步")
        Note("同网或USB转发时，电脑补齐记录、转写、人物和总结；分析与笔记回到手机。原始音频按需取得。离线期间各端保留资料与待同步变更。")
        if (model.state.available) {
            val sync = model.service().recordSync
            val syncState = model.state.recordSync
            Note(syncState.notice)
            ToolButton(onClick = { model.attempt { if (syncState.enabled) sync.stop() else sync.start() } }) {
                Text(if (syncState.enabled) "关闭记录同步" else "启用记录同步")
            }
            if (syncState.enabled) {
                val addresses = sync.addresses()
                addresses.forEach { Note(it) }
                if (addresses.isEmpty()) Note("当前没有局域网地址，可用USB转发连接。")
                ToolOutlinedButton(onClick = {
                    val address = addresses.firstOrNull() ?: "http://127.0.0.1:${syncState.port}"
                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("OpenRayneo 记录同步", "$address\nAuthorization: Bearer ${sync.tokenForUser()}"))
                    model.notice = "同步地址与独立令牌已复制"
                }) { Text("复制同步地址与独立令牌") }
                TextButton(onClick = { model.attempt { sync.rotate() } }) { Text("重置同步令牌") }
                Note("在 Mac 的记录同步配置中填写地址与令牌。USB连接可运行 adb forward tcp:8767 tcp:${syncState.port}，Mac填写 http://127.0.0.1:8767。")
            }
        } else Note("设备服务准备后可启用记录同步。")
    }
}

@Composable
internal fun TeleprompterScreen(model: AppModel) {
    val state = model.state.teleprompter
    var selected by remember { mutableStateOf<String?>(null) }
    var title by remember { mutableStateOf("") }
    var text by remember { mutableStateOf("") }
    var speed by remember { mutableIntStateOf(2) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("提词稿库", style = MaterialTheme.typography.headlineSmall)
        Note("稿件保存在手机，不使用官方云。发送时会停止当前显示与收音，再传输到眼镜。")
        Note(state.notice)
        if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (state.active != null) Row {
            TextButton(onClick = { model.attempt { model.service().teleprompter.control(if (state.paused) "resume" else "pause") {} } }, enabled = !state.busy) { Text(if (state.paused) "继续" else "暂停") }
            TextButton(onClick = { model.attempt { model.service().teleprompter.control("stop") {} } }, enabled = !state.busy) { Text("停止提词") }
        }
        state.documents.forEach { document ->
            TextButton(onClick = { selected = document.getString("did"); title = document.getString("title"); text = document.getString("text") }) { Text(document.getString("title")) }
        }
        OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("稿件标题") })
        OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth(), label = { Text("正文") }, minLines = 6, maxLines = 16)
        Text("滚动速度 $speed")
        Slider(speed.toFloat(), { speed = it.toInt() }, valueRange = 1f..10f, steps = 8)
        ToolOutlinedButton(onClick = { model.attempt { selected = model.service().teleprompter.save(title.trim(), text, selected ?: java.util.UUID.randomUUID().toString()); model.notice = "稿件已保存在手机" } }, enabled = title.isNotBlank() && text.isNotBlank() && !state.busy) { Text("保存稿件") }
        ToolButton(onClick = { model.attempt { model.service().startTeleprompter(title.trim(), text, speed, selected) {} } },
            enabled = title.isNotBlank() && text.isNotBlank() && !state.busy && model.state.glasses.link.phase == LinkPhase.FULL) { Text("保存并在眼镜播放") }
        TextButton(onClick = { selected = null; title = ""; text = "" }) { Text("新建稿件") }
    }
}
