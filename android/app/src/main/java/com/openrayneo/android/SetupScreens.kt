// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

@Composable
internal fun OnboardingScreen(
    model: AppModel,
    actions: UiActions,
    connect: () -> Unit,
    configure: (String) -> Unit,
) {
    val step = model.onboardingStep
    val scroll = rememberScrollState()
    LaunchedEffect(step) { scroll.scrollTo(0) }
    val titles = listOf("开始使用 OpenRayneo", "连接眼镜", "开启导航跟随", "配置助手", "检查设置")
    val subtitles =
        listOf(
            "欢迎使用 OpenRayneo。用几步完成设置，也可以稍后继续。",
            "用手机直接连接 RayNeo iO，导航与回答便能显示在眼前。",
            "路线由高德规划，OpenRayneo 读取通知，把方向、距离与路名带到眼镜。",
            "手机可以独立调用模型；电脑在线时，也可以把任务交给 Codex。两项都可稍后配置。",
            "下面是当前准备情况。未完成的项目随时可以在设置中继续。",
        )
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("OpenRayneo", style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = model::finishSetup) { Text("稍后设置") }
        }
        LinearProgressIndicator(
            progress = { (step + 1) / 5f },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
        )
        Column(
            Modifier.weight(1f).verticalScroll(scroll).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "开始使用 · ${step + 1} / 5",
                color = MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.labelLarge,
            )
            Text(titles[step], style = MaterialTheme.typography.headlineLarge)
            Note(subtitles[step])
            when (step) {
                0 -> {
                    GlassesArtwork(
                        Modifier.fillMaxWidth().height(90.dp),
                        MaterialTheme.colorScheme.primary,
                    )
                    SetupRow(Icons.Outlined.NearMe, "抬眼看导航", "跟随手机高德的真实导航通知")
                    SetupRow(Icons.Outlined.AutoAwesome, "随时问助手", "连接你自己的模型与电脑 Codex")
                    SetupRow(Icons.Outlined.Tune, "由你掌控", "显示与收音可以随时暂停")
                }
                1 -> {
                    ContentCard {
                        GlassesArtwork(
                            Modifier.fillMaxWidth().height(110.dp),
                            MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            if (model.state.glasses.link.phase == LinkPhase.FULL) "眼镜已连接"
                            else "连接前的小准备",
                            style = MaterialTheme.typography.titleLarge,
                        )
                        Note("1. 唤醒眼镜并靠近手机\n2. 断开官方 App 或电脑的眼镜连接\n3. 在手机上确认系统配对提示")
                        ToolButton(onClick = connect, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                if (model.state.glasses.link.phase == LinkPhase.FULL) "查看连接"
                                else "连接眼镜"
                            )
                        }
                    }
                    Note("只在连接时申请“附近设备”权限。未连接也可以先配置助手。")
                }
                2 -> {
                    ContentCard {
                        Text(
                            if (model.notificationAllowed) "通知使用权已开启" else "允许读取高德导航通知",
                            style = MaterialTheme.typography.titleMedium,
                        )
                        if (model.notificationAllowed) Note(model.state.notificationReadStatus)
                        Note("系统会授予通知使用权，应用只处理高德导航通知。通知正文不会发送给模型。")
                        ToolOutlinedButton(
                            onClick = actions.notificationAccess,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(if (model.notificationAllowed) "查看通知权限" else "前往开启通知使用权")
                        }
                    }
                    var example by rememberSaveable { mutableIntStateOf(0) }
                    val samples =
                        listOf(
                            Triple("直行", 300, "沿中山路"),
                            Triple("右转", 80, "进入人民路"),
                            Triple("左转", 20, "沿滨河路"),
                        )
                    val sample = samples[example]
                    GridPreview(
                        NavigationFrame.render(sample.first, sample.second, sample.third),
                        "演示 · 与眼镜相同的导航网格",
                    )
                    TextButton(onClick = { example = (example + 1) % samples.size }) {
                        Text("切换演示指令")
                    }
                    Note("以上是界面演示，不会发送到眼镜或启动导航。真实导航请在高德 App 中开始。")
                }
                3 -> {
                    SetupOption(
                        "手机模型",
                        "填写服务地址、模型名与 API Key。使用你自己的模型服务。",
                        model.config.optString("modelKey").isNotBlank(),
                        Icons.Outlined.Smartphone,
                    ) {
                        configure("model")
                    }
                    SetupOption(
                        "电脑 Codex",
                        "导入电脑生成的配置文件，或填写连接参数。USB 联调需电脑开启转发。",
                        model.config.optString("codexToken").isNotBlank(),
                        Icons.Outlined.Computer,
                    ) {
                        configure("computer")
                    }
                    Note("“已保存”只表示填写了配置。真实连接结果会在助手页显示。手机语音输入目前使用手机的识别服务。")
                }
                4 -> {
                    ContentCard {
                        CompletionRow(
                            "眼镜连接",
                            model.state.glasses.link.phase == LinkPhase.FULL,
                            "已连接",
                            "稍后连接",
                        )
                        CompletionRow("导航通知权限", model.notificationAllowed, "已开启", "稍后授权")
                        CompletionRow(
                            "手机模型",
                            model.config.optString("modelKey").isNotBlank(),
                            "已保存配置",
                            "可选，稍后配置",
                        )
                        CompletionRow(
                            "电脑 Codex",
                            model.config.optString("codexToken").isNotBlank(),
                            "已保存配置",
                            "可选，稍后配置",
                        )
                    }
                    if (!model.backgroundNotifications)
                        ContentCard {
                            Text("在后台也能看到连接状态", style = MaterialTheme.typography.titleMedium)
                            Note("允许状态通知后，可在系统通知栏查看眼镜连接并停止服务。")
                            ToolOutlinedButton(onClick = actions.notificationPermission) {
                                Text("允许状态通知")
                            }
                        }
                    Note("在“设置 → 再看一次使用引导”中，随时回到这里。")
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (step > 0) ToolOutlinedButton(onClick = { model.step(step - 1) }) { Text("上一步") }
            ToolButton(
                onClick = { if (step == 4) model.finishSetup() else model.step(step + 1) },
                modifier = Modifier.weight(1f).heightIn(min = 52.dp),
            ) {
                Text(if (step == 0) "开始设置" else if (step == 4) "进入 OpenRayneo" else "继续")
            }
        }
    }
}

@Composable
private fun SetupRow(icon: ImageVector, title: String, description: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Note(description)
        }
    }
}

@Composable
private fun SetupOption(
    title: String,
    description: String,
    saved: Boolean,
    icon: ImageVector,
    click: () -> Unit,
) {
    ContentCard {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.titleLarge)
        Note(description)
        if (saved) StatusPill("已保存配置")
        ToolOutlinedButton(onClick = click, modifier = Modifier.fillMaxWidth()) {
            Text(if (saved) "查看配置" else "配置$title")
        }
    }
}

@Composable
private fun CompletionRow(title: String, done: Boolean, complete: String, incomplete: String) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (done) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
            null,
            tint =
                if (done) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Column {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Note(if (done) complete else incomplete)
        }
    }
}

@Composable
internal fun SettingsScreen(
    model: AppModel,
    actions: UiActions,
    open: (String) -> Unit,
    replay: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SectionLabel("连接你的服务")
        SettingsRow(
            "手机模型",
            if (model.config.optString("modelKey").isBlank()) "尚未配置"
            else model.config.optString("modelName").ifBlank { "已保存配置" },
            Icons.Outlined.Smartphone,
        ) {
            open("model")
        }
        SettingsRow(
            "电脑 Codex",
            if (model.state.computerConnected) "已连接" else "连接参数与配置导入",
            Icons.Outlined.Computer,
        ) {
            open("computer")
        }
        SectionLabel("权限与设备")
        SettingsRow(
            "附近设备",
            if (model.bluetoothAllowed) "已授权" else "连接眼镜时需要",
            Icons.Outlined.Bluetooth,
        ) {
            actions.appSettings()
        }
        SettingsRow(
            "高德通知使用权",
            if (model.notificationAllowed) "已授权 · ${model.state.notificationReadStatus}"
            else "导航跟随时需要",
            Icons.Outlined.NotificationsNone,
            actions.notificationAccess,
        )
        SettingsRow(
            "后台状态通知",
            if (model.backgroundNotifications) "已允许" else "可选，查看后台连接状态",
            Icons.Outlined.NotificationsActive,
        ) {
            if (model.backgroundNotifications) actions.appSettings()
            else actions.notificationPermission()
        }
        SettingsRow("设备与诊断", "连接日志、测试通知与音频恢复", Icons.Outlined.Tune) { open("diagnostics") }
        SectionLabel("外观")
        ContentCard {
            listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色").forEach { (key, title) ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(
                        selected = model.appearance == key,
                        onClick = { model.changeAppearance(key) },
                    )
                    TextButton(onClick = { model.changeAppearance(key) }) { Text(title) }
                }
            }
        }
        SectionLabel("了解 OpenRayneo")
        SettingsRow("再看一次使用引导", "连接眼镜、导航演示与助手配置", Icons.Outlined.Explore, replay)
        Note(
            "OpenRayneo ${BuildConfig.VERSION_NAME}\n音频仅在手机内存中处理。系统语音输入尚未接入眼镜音频。",
            Modifier.padding(vertical = 12.dp),
        )
    }
}

@Composable
private fun SettingsRow(title: String, summary: String, icon: ImageVector, click: () -> Unit) {
    Card(
        onClick = click,
        colors =
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        ListItem(
            headlineContent = { Text(title) },
            supportingContent = { Text(summary) },
            leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
            trailingContent = { Icon(Icons.Outlined.ChevronRight, null) },
            colors =
                ListItemDefaults.colors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ),
        )
    }
}

@Composable
internal fun ConfigurationScreen(model: AppModel, mobile: Boolean, importConfig: () -> Unit) {
    val urlKey = if (mobile) "modelUrl" else "codexUrl"
    val nameKey = if (mobile) "modelName" else "codexCwd"
    val secretKey = if (mobile) "modelKey" else "codexToken"
    val url = model.formDrafts[urlKey].orEmpty()
    val name = model.formDrafts[nameKey].orEmpty()
    val secret = model.formDrafts[secretKey].orEmpty()
    var showSecret by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val ready = url.isNotBlank() && secret.isNotBlank() && (!mobile || name.isNotBlank())
    Column(
        Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Icon(
            if (mobile) Icons.Outlined.Smartphone else Icons.Outlined.Computer,
            null,
            Modifier.size(40.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(if (mobile) "模型服务配置" else "电脑连接配置", style = MaterialTheme.typography.headlineMedium)
        Note(
            if (mobile) "支持兼容 Chat Completions 且支持工具调用的模型服务。请向服务商获取地址、模型名和 API Key。"
            else "先在电脑运行 OpenRayneo 的 Codex 连接脚本，再导入它生成的配置。USB 模式还需要开启端口转发。"
        )
        if (!mobile) {
            ToolButton(onClick = importConfig, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.FileOpen, null)
                Spacer(Modifier.width(8.dp))
                Text("导入电脑配置文件")
            }
            Note("选择 OpenRayneo-setup.json。它包含访问凭据，导入完成后请删除下载目录中的副本。")
            HorizontalDivider()
            Text("或手动填写", style = MaterialTheme.typography.titleMedium)
        }
        OutlinedTextField(
            url,
            { model.formDrafts[urlKey] = it },
            Modifier.fillMaxWidth(),
            label = { Text(if (mobile) "服务地址" else "电脑服务地址") },
            keyboardOptions =
                KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            placeholder = { Text(if (mobile) "https://服务商/v1" else "ws://127.0.0.1:4500") },
            singleLine = true,
            supportingText = {
                Text(if (mobile) "使用 HTTPS 地址，不要把密钥放进地址中" else "USB：本机地址；无线连接：使用 WSS")
            },
        )
        OutlinedTextField(
            name,
            { model.formDrafts[nameKey] = it },
            Modifier.fillMaxWidth(),
            label = { Text(if (mobile) "模型名称" else "电脑工作目录（可选）") },
            singleLine = true,
        )
        OutlinedTextField(
            secret,
            { model.formDrafts[secretKey] = it },
            Modifier.fillMaxWidth(),
            label = { Text(if (mobile) "API Key" else "连接令牌") },
            keyboardOptions =
                KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
            keyboardActions = KeyboardActions(onDone = { keyboard?.hide() }),
            visualTransformation =
                if (showSecret) VisualTransformation.None else PasswordVisualTransformation(),
            singleLine = true,
            trailingIcon = {
                IconButton(onClick = { showSecret = !showSecret }) {
                    Icon(
                        if (showSecret) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                        if (showSecret) "隐藏密钥" else "显示密钥",
                    )
                }
            },
        )
        ToolButton(
            onClick = {
                model.saveConfig(
                    if (mobile) mapOf("modelUrl" to url, "modelName" to name, "modelKey" to secret)
                    else mapOf("codexUrl" to url, "codexCwd" to name, "codexToken" to secret)
                )
            },
            enabled = ready,
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
        ) {
            Text("保存配置")
        }
        Note("凭据使用 Android Keystore 加密保存。保存不会发起模型请求或电脑任务，连接结果请在助手页查看。")
        if (!mobile)
            ContentCard {
                Text("USB 连接步骤", style = MaterialTheme.typography.titleMedium)
                Note(
                    "1. 电脑安装并登录 Codex CLI\n2. 运行仓库中的 scripts/phone-codex.py\n3. 电脑执行 adb reverse tcp:4500 tcp:4500\n4. 在助手页选择电脑 Codex，点击连接"
                )
            }
    }
}

@Composable
internal fun DiagnosticsScreen(model: AppModel, actions: UiActions) {
    val context = LocalContext.current
    val s = model.state
    var bleOnly by rememberSaveable { mutableStateOf(false) }
    val ready = s.glasses.link.phase in setOf(LinkPhase.FULL, LinkPhase.BLE_ONLY)
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ContentCard {
            Text("通知读取", style = MaterialTheme.typography.titleMedium)
            Note(if (model.notificationAllowed) "系统权限已授权" else "系统权限未授权")
            Note(s.notificationReadStatus)
            Note("当前高德候选：${s.navigationEntries.size} 条")
            if (s.notificationSnapshotAt > 0)
                Note(
                    "最近快照同步：" +
                        java.text
                            .SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                            .format(java.util.Date(s.notificationSnapshotAt))
                )
            ToolOutlinedButton(
                onClick = {
                    model.attempt {
                        NavigationNotifications.requestConnection(model.getApplication())
                    }
                },
                enabled = model.notificationAllowed,
            ) {
                Text("恢复通知读取")
            }
        }
        ContentCard {
            Text(model.deviceName, style = MaterialTheme.typography.titleLarge)
            Note(s.glasses.link.detail)
            Note(s.glasses.displayDescription)
            Note(s.glasses.audio.detail)
            ToolOutlinedButton(
                onClick = { model.attempt { model.service().connection.sendTestNotification() } },
                enabled = ready,
            ) {
                Text("发送测试通知")
            }
            ToolOutlinedButton(
                onClick = { model.attempt { model.service().retryAudio() } },
                enabled =
                    s.glasses.session?.phase in
                        setOf(PagePhase.LAYOUT, PagePhase.SETTLING, PagePhase.READY),
            ) {
                Text("重启音频解码，保持页面")
            }
            ToolOutlinedButton(
                onClick = { model.attempt { model.service().disconnect() } },
                enabled = ready || s.glasses.link.phase == LinkPhase.CONNECTING,
            ) {
                Text("断开眼镜")
            }
        }
        ContentCard {
            Text("高级连接诊断", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(bleOnly, { bleOnly = it }, enabled = !ready)
                Text("仅 BLE 诊断", Modifier.padding(start = 12.dp))
            }
            Note("仅用于连接排查；导航和助手显示需要完整连接。")
            if (bleOnly) {
                ToolOutlinedButton(onClick = actions.scan, enabled = !ready) { Text("扫描设备") }
                s.devices.forEach { device ->
                    TextButton(onClick = { model.connect(device, true) }, enabled = !ready) {
                        Text("诊断连接 ${device.name}")
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            SectionLabel("连接日志")
            TextButton(
                onClick = {
                    context
                        .getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(
                            ClipData.newPlainText("OpenRayneo", s.logs.joinToString("\n"))
                        )
                    model.notice = "日志已复制"
                }
            ) {
                Text("复制日志")
            }
        }
        ContentCard { Note(s.logs.joinToString("\n").ifBlank { "暂无连接日志" }) }
    }
}
