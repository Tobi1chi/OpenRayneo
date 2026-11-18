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
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.foundation.shape.CircleShape
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
                if (route in listOf("model", "computer", "diagnostics", "voice-settings", "voice-profiles", "device-settings", "content", "teleprompter", "agent-api") && !model.onboarding)
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
                            style =
                                if (route.isEmpty()) MaterialTheme.typography.headlineSmall
                                else MaterialTheme.typography.titleLarge,
                            text = when (route) {
                                "settings" -> "设置"
                                "model" -> "手机模型"
                                "computer" -> "电脑连接"
                                "diagnostics" -> "设备与诊断"
                                "voice-settings" -> "语音与提示词"
                                "voice-profiles" -> "声音与人物"
                                "device-settings" -> "眼镜设置"
                                "content" -> "首页与内容"
                                "teleprompter" -> "提词资料"
                                "agent-api" -> "DSH Go 与外部 Agent"
                                else -> listOf("OpenRayneo", "导航", "助手", "记录")[tab]
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
                            if (s.glasses.link.phase == LinkPhase.FULL && tab != 0) StatusPill("已连接")
                            IconButton(onClick = { route = "settings" }) {
                                Icon(Icons.Outlined.Settings, "设置")
                            }
                        }
                    },
                    colors =
                        TopAppBarDefaults.topAppBarColors(
                            containerColor = tokens.pageBackground,
                            scrolledContainerColor = tokens.pageBackground,
                        ),
                )
        },
        bottomBar = {
            if (route.isEmpty() && !model.onboarding && !keyboardVisible)
                Column {
                HorizontalDivider(color = tokens.activityBarBorder)
                NavigationBar(
                    containerColor = tokens.activityBarBackground,
                    tonalElevation = 0.dp,
                ) {
                    val icons =
                        listOf(
                            Icons.Outlined.Visibility,
                            Icons.Outlined.NearMe,
                            Icons.AutoMirrored.Outlined.Chat,
                            Icons.Outlined.FolderOpen,
                        )
                    listOf("眼镜", "导航", "助手", "记录").forEachIndexed { index, title ->
                        NavigationBarItem(
                            selected = tab == index,
                            onClick = { tab = index },
                            colors =
                                NavigationBarItemDefaults.colors(
                                    indicatorColor = tokens.activityBarActiveBackground,
                                    selectedIconColor = tokens.activityBarActiveForeground,
                                    selectedTextColor = tokens.activityBarActiveLabelForeground,
                                    unselectedIconColor = tokens.activityBarInactiveForeground,
                                    unselectedTextColor = tokens.activityBarInactiveForeground,
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
                }
        },
        snackbarHost = { SnackbarHost(snackbars) },
        containerColor = tokens.pageBackground,
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
                "voice-settings" -> VoiceSettingsScreen(model, actions)
                "voice-profiles" -> VoiceProfilesScreen(model)
                "device-settings" -> GlassesSettingsScreen(model)
                "content" -> CompanionContentScreen(model)
                "teleprompter" -> TeleprompterScreen(model)
                "agent-api" -> AgentServerScreen(model, actions.bluetoothPermission)
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
                                        { route = "device-settings" },
                                        { route = it },
                                    )
                                1 ->
                                    NavigationScreen(
                                        model,
                                        actions,
                                        { sources = true },
                                        { devices = true },
                                    )
                                2 -> AssistantScreen(model, actions, { route = it })
                                else -> ConversationScreen(model, actions, { route = it })
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
    configure: (String) -> Unit,
) {
    val state = model.state.glasses
    val linked = state.link.phase == LinkPhase.FULL
    val reachable = linked || state.link.phase == LinkPhase.BLE_ONLY
    val busy =
        state.link.phase in
            setOf(LinkPhase.CONNECTING, LinkPhase.SCANNING, LinkPhase.RETRY_WAIT, LinkPhase.CLOSING)
    LazyColumn(
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            ContentCard {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    StatusPill(
                        if (linked) "已连接 · 手机直连"
                        else if (busy) "正在连接"
                        else if (reachable) "仅蓝牙低功耗"
                        else "未连接",
                        active = linked,
                    )
                    if (reachable)
                        TextButton(onClick = diagnostics) {
                            Text("管理")
                            Icon(Icons.Outlined.ChevronRight, null, Modifier.size(18.dp))
                        }
                }
                GlassesArtwork(
                    Modifier.fillMaxWidth().height(96.dp).padding(horizontal = 16.dp),
                    live = linked,
                )
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(model.deviceName, style = MaterialTheme.typography.headlineSmall)
                    Note(if (linked) "显示、收音与导航可以随时开启。" else state.link.detail)
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth(), strokeCap = StrokeCap.Round)
                if (!reachable)
                    ToolButton(onClick = connect, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.AutoMirrored.Outlined.BluetoothSearching, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (busy) "查看连接进度" else "连接眼镜")
                    }
                if (reachable || busy) {
                    ToolOutlinedButton(
                        onClick = { model.attempt { model.service().disconnect() } },
                        enabled = !state.disconnecting && state.link.phase != LinkPhase.CLOSING,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(if (state.disconnecting) "正在断开…" else "断开连接")
                    }
                    Note("断开会结束显示与收音、停止自动重连，并保留配对记录。随后可切换到其他设备连接。")
                }
            }
        }
        item {
            val tiles =
                listOf(
                    Triple("导航", Icons.Outlined.NearMe) { navigate(1) },
                    Triple("助手", Icons.AutoMirrored.Outlined.Chat) { navigate(2) },
                    Triple("语音记录", Icons.Outlined.GraphicEq) { navigate(3) },
                    Triple("首页与内容", Icons.Outlined.Dashboard) { configure("content") },
                    Triple("提词稿库", Icons.AutoMirrored.Outlined.Article) { configure("teleprompter") },
                    Triple("外部 Agent", Icons.Outlined.Hub) { configure("agent-api") },
                )
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                tiles.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { (title, icon, click) ->
                            FeatureTile(title, icon, Modifier.weight(1f), click)
                        }
                    }
                }
            }
        }
        item { SectionLabel("眼镜画面") }
        item { GlassesOutputPreview(state) }
        if (linked)
            item {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Note(state.displayDescription)
                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        ToolOutlinedButton(onClick = { navigate(1) }) { Text("导航") }
                        ToolOutlinedButton(
                            onClick = { model.attempt { model.service().openStandby() } }
                        ) {
                            Text("实时提示")
                        }
                        if (state.session?.mode == PageMode.PROMPT && state.session.phase == PagePhase.READY)
                            ToolOutlinedButton(onClick = { model.attempt { model.service().clearDisplay() } }) {
                                Text("清空屏幕")
                            }
                        if (state.intent is DisplayIntent.Answer)
                            ToolOutlinedButton(onClick = { model.attempt { model.service().dismissAnswer() } }) {
                                Text("结束眼镜回答")
                            }
                        if (state.session != null)
                            ToolOutlinedButton(onClick = { model.attempt { model.service().pausePrompt() } }) {
                                Text("暂停显示与收音")
                            }
                    }
                    if (state.session?.mode == PageMode.PROMPT && state.session.phase == PagePhase.READY)
                        Note("清空屏幕会保留收音。")
                }
            }
        item { SectionLabel("眼镜音频") }
        item {
            ContentCard {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    val receiving = state.audio.phase == AudioPhase.RECEIVING
                    Box(
                        Modifier.size(40.dp).background(
                            if (receiving) tokens.badgeBackground else tokens.cardIconBackground,
                            CircleShape,
                        ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Outlined.GraphicEq,
                            null,
                            Modifier.size(20.dp),
                            tint =
                                if (receiving) tokens.badgeForeground else tokens.iconForeground,
                        )
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("收音状态", style = MaterialTheme.typography.titleSmall)
                        Note(state.audio.detail)
                    }
                }
                if (state.audio.phase == AudioPhase.RECEIVING) {
                    val levels = model.state.audioLevels
                    val channels =
                        if (levels.channels == 1) listOf("单声道" to levels.left)
                        else listOf("声道 1 · 本人" to levels.left, "声道 2 · 环境" to levels.right)
                    channels.forEach { (label, rms) ->
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                label,
                                style = MaterialTheme.typography.labelMedium,
                                color = tokens.descriptionForeground,
                            )
                            LinearProgressIndicator(
                                progress = {
                                    ((20 * kotlin.math.log10(rms.coerceAtLeast(.00001)) + 60) / 60)
                                        .toFloat()
                                        .coerceIn(0f, 1f)
                                },
                                modifier = Modifier.fillMaxWidth().height(6.dp),
                                color = tokens.progressBarBackground,
                                trackColor = tokens.progressBarTrack,
                                strokeCap = StrokeCap.Round,
                                gapSize = 0.dp,
                                drawStopIndicator = {},
                            )
                        }
                    }
                }
                Note("仅在手机计算音量，不保存或上传音频。")
            }
        }
    }
}

@Composable
private fun FeatureTile(
    title: String,
    icon: ImageVector,
    modifier: Modifier,
    click: () -> Unit,
) {
    Surface(
        onClick = click,
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = tokens.cardBackground,
    ) {
        Column(
            Modifier.padding(horizontal = 12.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                Modifier.size(36.dp).background(tokens.cardIconBackground, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, Modifier.size(19.dp), tint = tokens.iconForeground)
            }
            Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 2)
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
