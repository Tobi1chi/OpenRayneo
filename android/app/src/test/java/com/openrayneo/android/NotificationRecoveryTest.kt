// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationRecoveryTest {
    private class FakeTimerQueue {
        data class Entry(val task: Runnable, val delayMs: Long)
        val scheduled = ArrayDeque<Entry>()

        fun schedule(task: Runnable, delayMs: Long) {
            scheduled.addLast(Entry(task, delayMs))
        }

        fun cancel(task: Runnable) {
            scheduled.removeAll { it.task === task }
        }

        fun popNext(): Entry = scheduled.removeFirst()
    }

    private class FakeReader(var entries: List<NavigationFeed.Entry> = emptyList()) :
        NavigationNotificationReader {
        var unboundCount = 0
        override fun snapshot(): List<NavigationFeed.Entry> = entries
        override fun unbind() {
            unboundCount++
        }
    }

    @Test
    fun missingPermissionPublishesNotGrantedWithoutBinding() {
        val timers = FakeTimerQueue()
        var bindCalls = 0
        val recovery = NotificationRecovery(
            authorized = { false },
            bind = { bindCalls++ },
            resetBinding = {},
            schedule = timers::schedule,
            cancel = timers::cancel,
            changed = {},
            replace = { _, _ -> },
            log = {},
        )
        recovery.refresh()
        assertEquals(NotificationReadPhase.NOT_GRANTED, recovery.state.phase)
        assertEquals(0, bindCalls)
        assertTrue(timers.scheduled.isEmpty())
    }

    @Test
    fun retryBackoffProgressesToFailedAndManualRestartRecovers() {
        val timers = FakeTimerQueue()
        var bindCalls = 0
        var resetCalls = 0
        var snapshotCount = -1
        val recovery = NotificationRecovery(
            authorized = { true },
            bind = { bindCalls++ },
            resetBinding = { resetCalls++ },
            schedule = timers::schedule,
            cancel = timers::cancel,
            changed = {},
            replace = { list, _ -> snapshotCount = list.size },
            log = {},
        )

        // Attempt 1 -> 8s timeout -> schedules 2s retry with resetBinding.
        recovery.refresh()
        assertEquals(1, bindCalls)
        val timeout1 = timers.popNext()
        assertEquals(8_000L, timeout1.delayMs)
        timeout1.task.run()
        assertEquals(1, resetCalls)
        val retry1 = timers.popNext()
        assertEquals(2_000L, retry1.delayMs)

        // Attempt 2 -> 8s timeout -> schedules 5s retry with resetBinding.
        retry1.task.run()
        assertEquals(2, bindCalls)
        val timeout2 = timers.popNext()
        timeout2.task.run()
        assertEquals(2, resetCalls)
        val retry2 = timers.popNext()
        assertEquals(5_000L, retry2.delayMs)

        // Attempt 3 -> 8s timeout -> transitions to FAILED.
        retry2.task.run()
        assertEquals(3, bindCalls)
        timers.popNext().task.run()
        assertEquals(NotificationReadPhase.FAILED, recovery.state.phase)

        // Manual restart unblocks and synchronizes once reader connects.
        recovery.refresh(manual = true, restart = true)
        val restartTask = timers.popNext()
        assertEquals(500L, restartTask.delayMs)
        restartTask.task.run()
        assertEquals(4, bindCalls)

        val reader = FakeReader(
            listOf(
                NavigationFeed.Entry(
                    key = "k1",
                    title = "中关村南大街",
                    texts = listOf("直行200米｜高德导航中"),
                    updatedAt = 1L,
                    channel = "ROUTE_CHANNEL_ID",
                ),
            ),
        )
        recovery.connected(reader)
        assertTrue(recovery.owns(reader))
        assertEquals(NotificationReadPhase.CONNECTED, recovery.state.phase)
        assertEquals(1, snapshotCount)

        recovery.disconnected(reader)
        assertFalse(recovery.owns(reader))
    }
}
