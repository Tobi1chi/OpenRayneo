// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

internal enum class NotificationReadPhase {
    NOT_GRANTED,
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    FAILED,
}

internal data class NotificationReadState(
    val phase: NotificationReadPhase = NotificationReadPhase.DISCONNECTED,
    val detail: String = "等待通知监听服务",
)

internal interface NavigationNotificationReader {
    fun snapshot(): List<NavigationFeed.Entry>

    fun unbind()
}

/** All calls are serialized on the main thread. Timers retry binding, never alter permission. */
internal class NotificationRecovery(
    private val authorized: () -> Boolean,
    private val bind: () -> Unit,
    private val resetBinding: () -> Unit,
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val changed: (NotificationReadState) -> Unit,
    private val replace: (List<NavigationFeed.Entry>, NotificationReadState) -> Unit,
    private val log: (String) -> Unit,
) {
    var state = NotificationReadState()
        private set

    private var reader: NavigationNotificationReader? = null
    private var attempts = 0
    private var pending = false
    private val timeout = Runnable {
        pending = false
        retry()
    }
    private val retryTask = Runnable {
        pending = false
        requestBind()
    }

    fun owns(candidate: NavigationNotificationReader) =
        reader === candidate && state.phase == NotificationReadPhase.CONNECTED

    fun refresh(manual: Boolean = false, restart: Boolean = false) {
        if (!checkPermission()) return
        if (restart) {
            clearTimers()
            val previous = reader
            reader = null
            attempts = 0
            publish(NotificationReadPhase.DISCONNECTED, "正在重新连接通知监听")
            runCatching { if (previous != null) previous.unbind() else resetBinding() }
                .onFailure { log("通知监听解绑失败：${it.javaClass.simpleName}") }
            // requestUnbind disables callbacks immediately; do not wait for onListenerDisconnected.
            pending = true
            schedule(retryTask, 500)
        } else if (reader != null) {
            synchronize()
        } else if (!pending) {
            if (manual) attempts = 0
            if (attempts < 3) requestBind()
        }
    }

    fun connected(candidate: NavigationNotificationReader) {
        if (!checkPermission()) return
        clearTimers()
        reader = candidate
        synchronize()
    }

    fun disconnected(candidate: NavigationNotificationReader) {
        if (reader !== candidate) return
        reader = null
        clearTimers()
        publish(NotificationReadPhase.DISCONNECTED, "通知监听已断开，准备恢复")
        if (checkPermission()) retry()
    }

    private fun synchronize() {
        val active = reader ?: return
        try {
            val entries = active.snapshot()
            if (reader !== active) return
            clearTimers()
            attempts = 0
            // Publish the snapshot and readiness together, without briefly rendering stale
            // directions.
            state = NotificationReadState(NotificationReadPhase.CONNECTED, "通知监听已连接")
            replace(entries, state)
            log("通知快照同步：高德候选 ${entries.size} 条，可解析 ${entries.count { it.instruction != null }} 条")
        } catch (failure: Exception) {
            if (reader !== active) return
            reader = null
            publish(NotificationReadPhase.DISCONNECTED, "读取通知失败，正在恢复监听")
            log("通知快照读取失败：${failure.javaClass.simpleName}")
            runCatching { active.unbind() }
            retry()
        }
    }

    private fun requestBind() {
        if (!checkPermission() || reader != null) return
        if (attempts >= 3) {
            failed()
            return
        }
        attempts++
        pending = true
        publish(NotificationReadPhase.CONNECTING, "权限已开启，正在连接通知监听（$attempts/3）")
        schedule(timeout, 8_000)
        try {
            bind()
        } catch (failure: Exception) {
            cancel(timeout)
            pending = false
            log("通知监听重连请求失败：${failure.javaClass.simpleName}")
            retry()
        }
    }

    private fun retry() {
        if (!checkPermission()) return
        if (attempts >= 3) {
            failed()
            return
        }
        // A failed system bind can leave the component enabled. Rebind alone then does nothing.
        // Rebuild that binding before the next delayed attempt; never toggle notification access.
        if (attempts > 0)
            runCatching { resetBinding() }
                .onFailure { log("通知监听绑定重置失败：${it.javaClass.simpleName}") }
        pending = true
        publish(NotificationReadPhase.CONNECTING, "权限已开启，等待恢复通知监听")
        schedule(retryTask, if (attempts <= 1) 2_000 else 5_000)
    }

    private fun failed() {
        clearTimers()
        publish(NotificationReadPhase.FAILED, "通知权限已开启，但监听未连接；请点“恢复通知读取”")
    }

    private fun checkPermission(): Boolean {
        if (authorized()) return true
        clearTimers()
        reader = null
        attempts = 0
        publish(NotificationReadPhase.NOT_GRANTED, "尚未开启通知使用权")
        return false
    }

    private fun clearTimers() {
        cancel(timeout)
        cancel(retryTask)
        pending = false
    }

    private fun publish(phase: NotificationReadPhase, detail: String) {
        val next = NotificationReadState(phase, detail)
        if (state == next) return
        state = next
        changed(next)
        log(detail)
    }
}
