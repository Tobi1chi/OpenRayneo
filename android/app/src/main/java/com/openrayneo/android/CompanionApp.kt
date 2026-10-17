// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.BluetoothSearching
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CompanionApp(model: AppModel, actions: UiActions) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var route by rememberSaveable { mutableStateOf("") }
    var devices by rememberSaveable { mutableStateOf(false) }
    var sources by rememberSaveable { mutableStateOf(false) }
    val snackbars = remember { SnackbarHostState() }
    val pages = rememberSaveableStateHolder()
    val s = model.state
    val keyboardVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    BackHandler(
        enabled =
            !devices &&
                !sources &&
                (route.isNotEmpty() || model.onboarding && model.onboardingStep > 0 || tab != 0)
    ) {
        if (route.isNotEmpty())
            route =
                if (route in listOf("model", "computer", "diagnostics") && !model.onboarding)
                    "settings"
                else ""
        else if (model.onboarding) model.step(model.onboardingStep - 1) else tab = 0
    }
    LaunchedEffect(model.notice) {
        model.notice?.let {
            model.notice = null
            snackbars.showSnackbar(it)
        }
    }
    Scaffold(
        topBar = {
            if (!model.onboarding || route.isNotEmpty())
                TopAppBar(
                    title = {
                        Text(
                            when (route) {
                                "settings" -> "设置"
                                "model" -> "手机模型"
                                "computer" -> "电脑连接"
                                "diagnostics" -> "设备与诊断"
                                else -> listOf("OpenRayneo", "导航", "助手")[tab]
                            }
                        )
                    },
                    navigationIcon = {
                        if (route.isNotEmpty())
                            IconButton(
                                onClick = {
                                    route =
                                        if (route == "settings" || model.onboarding) ""
                                        else "settings"
                                }
                            ) {
                                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
                            }
                    },
                    actions = {
                        if (route.isEmpty()) {
                            if (s.glasses.link.phase == LinkPhase.FULL) StatusPill("眼镜已连接")
                            IconButton(onClick = { route = "settings" }) {
                                Icon(Icons.Outlined.Settings, "设置")
                            }
                        }
                    },
                    colors =
                        TopAppBarDefaults.topAppBarColors(
                            containerColor = MaterialTheme.colorScheme.background
                        ),
                )
        },
        bottomBar = {
            if (route.isEmpty() && !model.onboarding && !keyboardVisible)
                NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
                    val icons =
                        listOf(
                            Icons.Outlined.Visibility,
                            Icons.Outlined.NearMe,
                            Icons.AutoMirrored.Outlined.Chat,
                        )
                    listOf("眼镜", "导航", "助手").forEachIndexed { index, title ->
                        NavigationBarItem(
                            selected = tab == index,
                            onClick = { tab = index },
                            colors =
                                NavigationBarItemDefaults.colors(
                                    indicatorColor = Color.Transparent
                                ),
                            icon = {
                                BadgedBox(
                                    badge = {
                                        if (index == 2 && s.approvals.isNotEmpty())
                                            Badge { Text(s.approvals.size.toString()) }
                                    }
                                ) {
                                    Icon(icons[index], null)
                                }
                            },
                            label = { Text(title) },
                        )
                    }
                }
        },
        snackbarHost = { SnackbarHost(snackbars) },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            when (route) {
                "settings" ->
                    SettingsScreen(
                        model,
                        actions,
                        { route = it },
                        {
                            model.replaySetup()
                            route = ""
                        },
                    )
                "model",
                "computer" -> ConfigurationScreen(model, route == "model", actions.importConfig)
                "diagnostics" -> DiagnosticsScreen(model, actions)
                else ->
                    if (model.onboarding)
                        OnboardingScreen(model, actions, { devices = true }, { route = it })
                    else
                        pages.SaveableStateProvider(tab) {
                            when (tab) {
                                0 ->
                                    GlassesScreen(
                                        model,
                                        { devices = true },
                                        { tab = it },
                                        { route = "diagnostics" },
                                    )
                                1 ->
                                    NavigationScreen(
                                        model,
                                        actions,
                                        { sources = true },
                                        { devices = true },
                                    )
                                else -> AssistantScreen(model, actions, { route = it })
                            }
                        }
            }
        }
    }
    if (devices)
        ModalBottomSheet(onDismissRequest = { devices = false }) { DevicePicker(model, actions) }
    if (sources)
        ModalBottomSheet(onDismissRequest = { sources = false }) {
            Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp)) {
                Text("导航通知来源", style = MaterialTheme.typography.headlineSmall)
                Note("选择包含转向和距离的通知。只有“正在导航”的消息无法提供方向。", Modifier.padding(vertical = 12.dp))
                if (s.navigationEntries.isEmpty()) Note("还没有收到高德导航通知")
                LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(s.navigationEntries, key = { it.key }) { entry ->
                        OutlinedCard(
                            onClick = {
                                model.attempt {
                                    model.service().followNavigation(entry.key)
                                    sources = false
                                }
                            }
                        ) {
                            Column(
                                Modifier.fillMaxWidth().padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    entry.title.ifBlank { "高德导航" },
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Note(entry.texts.filter { it != entry.title }.joinToString("\n"))
                                Text(
                                    if (
                                        entry.key == s.glasses.navigation.key &&
                                            s.glasses.navigation.enabled
                                    )
                                        "正在跟随"
                                    else "跟随这条通知",
                                    color = MaterialTheme.colorScheme.primary,
                                )
                            }
                        }
                    }
                }
            }
        }
    model.error?.let { message ->
        AlertDialog(
            onDismissRequest = { model.error = null },
            title = { Text("操作提示") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { model.error = null }) { Text("知道了") } },
        )
    }
}

@Composable
private fun GlassesScreen(
    model: AppModel,
    connect: () -> Unit,
    navigate: (Int) -> Unit,
    diagnostics: () -> Unit,
) {
    val state = model.state.glasses
    val linked = state.link.phase == LinkPhase.FULL
    val busy =
        state.link.phase in
            setOf(LinkPhase.CONNECTING, LinkPhase.SCANNING, LinkPhase.RETRY_WAIT, LinkPhase.CLOSING)
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            ContentCard {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(model.deviceName, style = MaterialTheme.typography.titleMedium)
                        Note(if (linked) "已连接 · 手机直连" else state.link.detail)
                    }
                    ToolOutlinedButton(
                        onClick =
                            if (linked || state.link.phase == LinkPhase.BLE_ONLY) diagnostics
                            else connect
                    ) {
                        Text(
                            if (linked || state.link.phase == LinkPhase.BLE_ONLY) "管理"
                            else if (busy) "连接进度" else "连接"
                        )
                    }
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
        item { SectionLabel("眼镜画面") }
        item { GlassesOutputPreview(state) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (linked) {
                    Note(state.displayDescription)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ToolOutlinedButton(onClick = { navigate(1) }) { Text("导航") }
                        ToolOutlinedButton(
                            onClick = { model.attempt { model.service().openStandby() } }
                        ) {
                            Text("实时提示")
                        }
                    }
                    if (state.intent is DisplayIntent.Answer)
                        TextButton(
                            onClick = { model.attempt { model.service().dismissAnswer() } }
                        ) {
                            Text("结束眼镜回答")
                        }
                    if (state.session != null)
                        TextButton(onClick = { model.attempt { model.service().pausePrompt() } }) {
                            Text("暂停显示与收音")
                        }
                }
            }
        }
        item {
            ContentCard {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(Icons.Outlined.GraphicEq, null, tint = MaterialTheme.colorScheme.primary)
                    Column {
                        Text("眼镜音频", style = MaterialTheme.typography.titleSmall)
                        Note(state.audio.detail)
                    }
                }
                if (state.audio.phase == AudioPhase.RECEIVING) {
                    val levels = model.state.audioLevels
                    val channels =
                        if (levels.channels == 1) listOf("单声道" to levels.left)
                        else listOf("声道 1" to levels.left, "声道 2" to levels.right)
                    channels.forEach { (label, rms) ->
                        Text(label, style = MaterialTheme.typography.labelSmall)
                        LinearProgressIndicator(
                            progress = {
                                ((20 * kotlin.math.log10(rms.coerceAtLeast(.00001)) + 60) / 60)
                                    .toFloat()
                                    .coerceIn(0f, 1f)
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Note("仅在手机计算音量，不保存或上传音频。")
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FeatureTile("导航", "高德通知", Icons.Outlined.NearMe, Modifier.weight(1f)) {
                    navigate(1)
                }
                FeatureTile(
                    "助手",
                    "手机 · 电脑",
                    Icons.AutoMirrored.Outlined.Chat,
                    Modifier.weight(1f),
                ) {
                    navigate(2)
                }
            }
        }
    }
}

@Composable
private fun FeatureTile(
    title: String,
    subtitle: String,
    icon: ImageVector,
    modifier: Modifier,
    click: () -> Unit,
) {
    Card(
        onClick = click,
        modifier = modifier,
        colors =
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
            Text(title, style = MaterialTheme.typography.titleMedium)
            Note(subtitle)
        }
    }
}

@Composable
private fun DevicePicker(model: AppModel, actions: UiActions) {
    val s = model.state
    val ready = s.glasses.link.phase in setOf(LinkPhase.FULL, LinkPhase.BLE_ONLY)
    val connecting =
        s.glasses.link.phase in setOf(LinkPhase.CONNECTING, LinkPhase.RETRY_WAIT, LinkPhase.CLOSING)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("连接你的眼镜", style = MaterialTheme.typography.headlineSmall)
        Note("让眼镜保持唤醒，并先断开官方 App 或电脑与眼镜的连接。出现系统配对提示时，请在手机上确认。")
        Text(s.glasses.link.detail, color = MaterialTheme.colorScheme.primary)
        if (!model.bluetoothAllowed) {
            ToolButton(onClick = actions.scan, modifier = Modifier.fillMaxWidth()) {
                Text("允许附近设备并扫描")
            }
            TextButton(onClick = actions.appSettings) { Text("前往应用权限设置") }
        } else {
            ToolButton(
                onClick = actions.scan,
                enabled = !ready && !connecting && s.available,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.AutoMirrored.Outlined.BluetoothSearching, null)
                Spacer(Modifier.width(8.dp))
                Text("扫描眼镜")
            }
        }
        if (connecting || s.glasses.link.phase == LinkPhase.SCANNING)
            LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(
            Modifier.heightIn(max = 300.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(s.devices, key = { it.bluetooth.address }) { device ->
                OutlinedCard(
                    onClick = { model.connect(device, false) },
                    enabled = !ready && !connecting,
                ) {
                    ListItem(
                        headlineContent = { Text(device.name) },
                        supportingContent = { Text(if (ready) "连接已建立" else "点按连接") },
                        leadingContent = { Icon(Icons.Outlined.Visibility, null) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    )
                }
            }
        }
        if (s.devices.isEmpty() && model.bluetoothAllowed && !connecting) Note("未发现眼镜时，可唤醒眼镜后重新扫描。")
        if (ready || connecting)
            ToolOutlinedButton(onClick = { model.attempt { model.service().disconnect() } }) {
                Text(if (ready) "断开眼镜" else "取消连接")
            }
    }
}

@Composable
private fun NavigationScreen(
    model: AppModel,
    actions: UiActions,
    sources: () -> Unit,
    connect: () -> Unit,
) {
    val s = model.state
    val nav = s.glasses.navigation
    val entry = s.navigationEntries.firstOrNull { it.key == nav.key }
    val instruction = entry?.instruction?.takeIf { nav.enabled && s.notificationConnected }
    var time by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(entry?.updatedAt) {
        while (true) {
            time = System.currentTimeMillis()
            delay(10_000)
        }
    }
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { SectionLabel("眼镜画面") }
        item { GlassesOutputPreview(s.glasses) }
        item {
            ContentCard {
                Text("高德通知", style = MaterialTheme.typography.titleMedium)
                if (instruction != null) {
                    Text(
                        "${instruction.direction} · ${instruction.meters} 米",
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Note(entry!!.title)
                } else Note(s.navigationStatus)
                val frame = nav.frame
                if (
                    frame != null &&
                        (s.glasses.session?.mode != PageMode.NAVIGATION ||
                            s.glasses.session?.writtenContent?.text != frame)
                ) {
                    GridPreview(frame, "待发送导航布局")
                }
                Note("完整路名显示在此处；眼镜布局保留右下角 8 格路名。")
            }
        }
        item {
            ContentCard {
                Text(
                    if (nav.enabled) "正在跟随高德通知" else "准备开始",
                    style = MaterialTheme.typography.titleMedium,
                )
                Note(s.notificationReadStatus)
                if (
                    s.notificationReadPhase == NotificationReadPhase.FAILED &&
                        android.os.Build.MANUFACTURER.equals("xiaomi", true)
                ) {
                    Note("小米 / HyperOS 的后台自启动可能阻止监听绑定。请检查 OpenRayneo 的“后台自启动”，允许后再恢复通知读取。")
                    TextButton(onClick = actions.appSettings) { Text("检查应用设置") }
                }
                Note(s.navigationStatus)
                if (entry != null && nav.enabled) {
                    val age = ((time - entry.updatedAt).coerceAtLeast(0) / 1000)
                    Note("最近收到通知：${if (age < 60) "${age} 秒前" else "${age / 60} 分钟前"} · 请以高德实时指引为准")
                }
                if (!model.notificationAllowed)
                    ToolButton(
                        onClick = actions.notificationAccess,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("开启通知使用权")
                    }
                else if (!nav.enabled)
                    ToolButton(onClick = actions.openGaode, modifier = Modifier.fillMaxWidth()) {
                        Text("打开高德导航")
                    }
                if (nav.enabled) {
                    if (s.glasses.link.phase != LinkPhase.FULL)
                        ToolButton(onClick = connect, modifier = Modifier.fillMaxWidth()) {
                            Text("连接眼镜")
                        }
                    else {
                        Note(s.glasses.displayDescription)
                        if (
                            s.glasses.intent != DisplayIntent.Navigation ||
                                s.glasses.ownership != DisplayOwnership.APP ||
                                s.glasses.error != null
                        )
                            ToolButton(
                                onClick = { model.attempt { model.service().reopenNavigation() } },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("恢复眼镜导航")
                            }
                    }
                    ToolOutlinedButton(
                        onClick = { model.attempt { model.service().stopNavigation() } },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("停止眼镜跟随")
                    }
                    Note("只停止眼镜跟随，高德导航继续运行。")
                }
            }
        }
        item {
            OutlinedCard(onClick = sources) {
                ListItem(
                    headlineContent = { Text("通知来源") },
                    supportingContent = {
                        Text(
                            if (s.navigationEntries.isEmpty()) "等待高德导航通知"
                            else "${s.navigationEntries.size} 条候选通知 · 点按选择"
                        )
                    },
                    leadingContent = { Icon(Icons.Outlined.NotificationsNone, null) },
                    trailingContent = { Icon(Icons.Outlined.ChevronRight, null) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }
        }
        item {
            TextButton(onClick = actions.openGaode) { Text("在高德中查看路线") }
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
            Note("保留通知授权和跟随选择，重新连接监听并读取当前通知。")
            Note("上方眼镜画面仅随写入结果更新，高德通知单独显示。关闭或断线后不把旧画面当成当前显示。")
        }
    }
}
