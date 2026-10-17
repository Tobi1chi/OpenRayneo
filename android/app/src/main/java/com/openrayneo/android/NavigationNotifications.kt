// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import kotlin.math.roundToInt
import org.json.JSONObject

internal object NavigationFeed {
    const val PACKAGE = "com.autonavi.minimap"

    data class Entry(
        val key: String,
        val title: String,
        val texts: List<String>,
        val updatedAt: Long,
        val channel: String,
    ) {
        val instruction
            get() = GaodeNotificationParser.parse(texts)
    }

    val entries = linkedMapOf<String, Entry>()
    val observers = mutableSetOf<() -> Unit>()
    private var preferences: android.content.SharedPreferences? = null
    private var automaticSelection = true
    var listenerState = NotificationReadState()
        private set

    var lastSnapshotAt = 0L
        private set

    val connected
        get() = listenerState.phase == NotificationReadPhase.CONNECTED

    var selectedKey: String? = null
        private set

    var enabled = false
        private set

    val selected
        get() = if (enabled) entries[selectedKey] else null

    val status: String
        get() =
            when {
                !connected -> listenerState.detail
                !enabled -> "请在高德开始导航，再选择要跟随的通知"
                selected == null -> "等待选定的高德通知；若通知已更换，请重新选择"
                selected?.instruction == null -> "已收到高德通知，但其中没有可识别的转向和距离，请查看高德"
                else -> selected!!.instruction!!.let { "跟随高德：${it.direction} · ${it.meters}米" }
            }

    val frame: String?
        get() {
            if (!enabled) return null
            if (!connected) return NavigationFrame.status("通知读取已断开", "请查看手机")
            val entry = selected ?: return NavigationFrame.status("等待高德通知", "请以手机导航为准")
            return entry.instruction?.let {
                NavigationFrame.render(it.direction, it.meters, entry.title)
            } ?: NavigationFrame.status("指令暂未识别", "请查看高德")
        }

    fun initialize(context: Context) {
        if (preferences != null) return
        preferences = context.getSharedPreferences("navigation_notification", Context.MODE_PRIVATE)
        selectedKey = preferences!!.getString("key", null)
        enabled = preferences!!.getBoolean("enabled", false)
        automaticSelection =
            preferences!!.getBoolean(
                "automaticSelection",
                selectedKey == null && !preferences!!.contains("enabled"),
            )
    }

    fun connection(value: NotificationReadState) {
        listenerState = value
        if (!connected) entries.clear()
        changed()
    }

    fun replace(snapshot: List<Entry>, state: NotificationReadState) {
        listenerState = state
        lastSnapshotAt = System.currentTimeMillis()
        entries.clear()
        snapshot.forEach { entries[it.key] = it }
        if (automaticSelection && selectedKey == null) {
            val candidate =
                snapshot.firstOrNull { it.channel == "ROUTE_CHANNEL_ID" && it.instruction != null }
            if (candidate != null) {
                follow(candidate.key)
                return
            }
        }
        changed()
    }

    fun update(entry: Entry) {
        entries[entry.key] = entry
        // The observed Xiaomi/Gaode maneuver notification uses this channel; the persistent
        // foreground-service notification only says navigation is running and must not win.
        if (
            automaticSelection &&
                selectedKey == null &&
                entry.channel == "ROUTE_CHANNEL_ID" &&
                entry.instruction != null
        )
            follow(entry.key)
        else changed()
    }

    fun remove(key: String) {
        if (entries.remove(key) != null) changed()
    }

    fun follow(key: String) {
        check(entries.containsKey(key)) { "该通知已消失，请在高德开始导航后刷新" }
        selectedKey = key
        enabled = true
        automaticSelection = false
        preferences
            ?.edit()
            ?.putString("key", key)
            ?.putBoolean("enabled", true)
            ?.putBoolean("automaticSelection", false)
            ?.apply()
        changed()
    }

    fun stop() {
        enabled = false
        automaticSelection = false
        preferences
            ?.edit()
            ?.putBoolean("enabled", false)
            ?.putBoolean("automaticSelection", false)
            ?.apply()
        changed()
    }

    private fun changed() = observers.toList().forEach { it() }
}

internal class NavigationNotifications : NotificationListenerService() {
    private val reader =
        object : NavigationNotificationReader {
            override fun snapshot(): List<NavigationFeed.Entry> =
                checkNotNull(activeNotifications) { "通知快照不可用" }
                    .filter { it.packageName == NavigationFeed.PACKAGE }
                    .mapNotNull(::parseSafely)

            override fun unbind() = requestUnbind()
        }

    override fun onCreate() {
        super.onCreate()
        NavigationFeed.initialize(this)
        initialize(this)
    }

    override fun onListenerConnected() {
        recovery!!.connected(reader)
    }

    override fun onListenerDisconnected() {
        recovery!!.disconnected(reader)
    }

    override fun onNotificationPosted(notification: StatusBarNotification) {
        if (notification.packageName != NavigationFeed.PACKAGE || recovery?.owns(reader) != true)
            return
        val entry = parseSafely(notification)
        if (entry != null) NavigationFeed.update(entry) else NavigationFeed.remove(notification.key)
    }

    override fun onNotificationRemoved(notification: StatusBarNotification) {
        if (notification.packageName == NavigationFeed.PACKAGE && recovery?.owns(reader) == true)
            NavigationFeed.remove(notification.key)
    }

    private fun parseSafely(item: StatusBarNotification): NavigationFeed.Entry? =
        try {
            parse(item)
        } catch (failure: Exception) {
            Log.w("OpenRayneo", "高德通知解析失败：${failure.javaClass.simpleName}")
            null
        }

    private fun parse(item: StatusBarNotification): NavigationFeed.Entry? {
        val notification = item.notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        if (notification.channelId != "ROUTE_CHANNEL_ID" && notification.category != "navigation")
            return null
        val extras = notification.extras ?: Bundle.EMPTY
        val texts =
            buildList {
                    for (key in
                        listOf(
                            Notification.EXTRA_TITLE,
                            Notification.EXTRA_TEXT,
                            Notification.EXTRA_BIG_TEXT,
                            Notification.EXTRA_SUB_TEXT,
                            Notification.EXTRA_SUMMARY_TEXT,
                        )) {
                        extras
                            .getCharSequence(key)
                            ?.toString()
                            ?.trim()
                            ?.takeIf { it.isNotBlank() }
                            ?.let(::add)
                    }
                    extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach { value ->
                        value?.toString()?.trim()?.takeIf { it.isNotBlank() }?.let(::add)
                    }
                    runCatching { extras.getString("miui.focus.param")?.let(::JSONObject) }
                        .getOrNull()
                        ?.let { focus ->
                            for (key in listOf("title", "content")) focus
                                .optString(key)
                                .takeIf { it.isNotBlank() }
                                ?.let(::add)
                        }
                }
                .distinct()
        return NavigationFeed.Entry(
            item.key,
            extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            texts,
            item.postTime,
            notification.channelId.orEmpty(),
        )
    }

    override fun onDestroy() {
        recovery?.disconnected(reader)
        super.onDestroy()
    }

    companion object {
        private var recovery: NotificationRecovery? = null
        private val main = Handler(Looper.getMainLooper())

        private fun initialize(context: Context) {
            if (recovery != null) return
            val application = context.applicationContext
            val component = ComponentName(application, NavigationNotifications::class.java)
            recovery =
                NotificationRecovery(
                    authorized = {
                        application
                            .getSystemService(NotificationManager::class.java)
                            .isNotificationListenerAccessGranted(component)
                    },
                    bind = { requestRebind(component) },
                    resetBinding = { if (Build.VERSION.SDK_INT >= 34) requestUnbind(component) },
                    schedule = { task, delay -> main.postDelayed(task, delay) },
                    cancel = { main.removeCallbacks(it) },
                    changed = NavigationFeed::connection,
                    replace = NavigationFeed::replace,
                    log = { Log.i("OpenRayneo", it) },
                )
        }

        /**
         * App foreground entry and background health checks resnapshot even if already connected.
         */
        fun refresh(context: Context, foreground: Boolean = false) {
            initialize(context)
            recovery!!.refresh(manual = foreground)
        }

        /** User-requested recovery keeps authorization and the selected notification unchanged. */
        fun requestConnection(context: Context) {
            initialize(context)
            recovery!!.refresh(manual = true, restart = true)
        }
    }
}

internal object GaodeNotificationParser {
    data class Instruction(val direction: String, val meters: Int)

    private val actions =
        linkedMapOf(
            "向左前方行驶" to "左前",
            "向右前方行驶" to "右前",
            "向左后方行驶" to "左后",
            "向右后方行驶" to "右后",
            "左前方转弯" to "左前",
            "右前方转弯" to "右前",
            "向左转" to "左转",
            "向右转" to "右转",
            "向左前方" to "左前",
            "向右前方" to "右前",
            "直行" to "直行",
            "左转" to "左转",
            "右转" to "右转",
            "掉头" to "掉头",
        )
    private val action = actions.keys.joinToString("|") { Regex.escape(it) }
    private const val number = "([0-9]+(?:\\.[0-9]+)?)\\s*(公里|千米|米|km|m)"
    // Observed real notification: android.text = "直行314米｜高德导航中".
    private val actionFirst = Regex("^($action)\\s*$number(?:[｜|\\s]|$)", RegexOption.IGNORE_CASE)
    private val distanceFirst =
        Regex(
            "^(?:前方\\s*)?$number\\s*(?:后|处)?\\s*($action)(?:[，,。｜|\\s]|进入|驶入|$)",
            RegexOption.IGNORE_CASE,
        )

    fun parse(texts: List<String>): Instruction? {
        for (text in texts) {
            val normalized = text.trim()
            val first = actionFirst.find(normalized)
            if (first != null)
                return instruction(first.groupValues[1], first.groupValues[2], first.groupValues[3])
            val second = distanceFirst.find(normalized)
            if (second != null)
                return instruction(
                    second.groupValues[3],
                    second.groupValues[1],
                    second.groupValues[2],
                )
        }
        return null
    }

    private fun instruction(action: String, value: String, unit: String): Instruction? {
        val distance = value.toDoubleOrNull() ?: return null
        val meters = distance * if (unit.lowercase() in setOf("公里", "千米", "km")) 1000 else 1
        if (!meters.isFinite() || meters !in 0.0..9999.0) return null
        return Instruction(actions.getValue(action), meters.roundToInt())
    }
}
