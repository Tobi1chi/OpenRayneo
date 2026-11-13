// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GlassesCoordinatorTest {
    @Test
    fun connectionStartsStandbyAndAutoFollowsFirstNavigationNotification() {
        var state = GlassesState()
        state = GlassesCoordinator.reduce(state, GlassesEvent.BeginConnection).state
        assertEquals(DisplayIntent.PromptStandby, state.intent)

        val full = GlassesCoordinator.reduce(
            state,
            GlassesEvent.LinkChanged(LinkState(LinkPhase.FULL, "已连接")),
        )
        state = full.state
        val promptSession = checkNotNull(state.session)
        assertEquals(PageMode.PROMPT, promptSession.mode)
        assertTrue(full.effects.any { it is GlassesEffect.StartPage })

        val frame = NavigationFrame.render("左转", 120, "中关村大街")
        val navAuto = GlassesCoordinator.reduce(
            state,
            GlassesEvent.NavigationChanged(NavigationState(true, "gaode-1", frame)),
        )
        state = navAuto.state
        assertEquals(DisplayIntent.Navigation, state.intent)
        assertEquals(PagePhase.CLOSING, state.session?.phase)
        assertTrue(navAuto.effects.contains(GlassesEffect.ClosePage(promptSession.id)))

        val closed = GlassesCoordinator.reduce(
            state,
            GlassesEvent.SessionSignal(promptSession.id, PageSignal.Closed()),
        )
        state = closed.state
        val navSession = checkNotNull(state.session)
        assertEquals(PageMode.NAVIGATION, navSession.mode)
        assertEquals(frame, navSession.content.text)
    }

    @Test
    fun answerInterruptsNavigationAndRestoresAfterTimeout() {
        val navFrame = NavigationFrame.render("直行", 300, "北四环")
        var state = GlassesState(
            intent = DisplayIntent.Navigation,
            link = LinkState(LinkPhase.FULL, "已连接"),
            navigation = NavigationState(true, "gaode-1", navFrame),
            session = PageSession(
                id = 1,
                mode = PageMode.NAVIGATION,
                phase = PagePhase.READY,
                content = PageContent("navigation", navFrame),
                writtenContent = PageContent("navigation", navFrame),
            ),
            nextSession = 2,
        )

        val ref = AnswerRef(AnswerSource.MOBILE_AGENT, 10)
        state = GlassesCoordinator.reduce(state, GlassesEvent.AnswerRequested(ref)).state
        val permit = checkNotNull(state.answerPermit)

        val completed = GlassesCoordinator.reduce(
            state,
            GlassesEvent.AnswerCompleted(AnswerContent(ref, "现在几点", "下午三点"), permit),
        )
        state = completed.state
        assertEquals(DisplayIntent.Answer(ref, ReturnTarget.NAVIGATION), state.intent)
        assertEquals(PagePhase.CLOSING, state.session?.phase)

        val afterNavClose = GlassesCoordinator.reduce(
            state,
            GlassesEvent.SessionSignal(1, PageSignal.Closed()),
        )
        state = afterNavClose.state
        val answerSession = checkNotNull(state.session)
        assertEquals(PageMode.PROMPT, answerSession.mode)

        state = GlassesCoordinator.reduce(
            state,
            GlassesEvent.SessionSignal(answerSession.id, PageSignal.Settling),
        ).state
        val written = GlassesCoordinator.reduce(
            state,
            GlassesEvent.SessionSignal(answerSession.id, PageSignal.Written(answerSession.content)),
        )
        state = written.state
        val scheduleRestore = written.effects.filterIsInstance<GlassesEffect.ScheduleRestore>().single()
        assertEquals(answerSession.id, scheduleRestore.id)

        val restored = GlassesCoordinator.reduce(
            state,
            GlassesEvent.RestoreAnswer(scheduleRestore.id, scheduleRestore.revision, scheduleRestore.ref),
        )
        assertEquals(DisplayIntent.Navigation, restored.state.intent)
        assertEquals(PagePhase.CLOSING, restored.state.session?.phase)
    }

    @Test
    fun staleAnswerPermitIsRejectedWhenRevisionAdvances() {
        var state = GlassesState(
            intent = DisplayIntent.PromptStandby,
            link = LinkState(LinkPhase.FULL, "已连接"),
        )
        val ref = AnswerRef(AnswerSource.COMPUTER_CODEX, 1)
        state = GlassesCoordinator.reduce(state, GlassesEvent.AnswerRequested(ref)).state
        val stalePermit = checkNotNull(state.answerPermit)

        // User pauses display before the LLM finishes responding.
        state = GlassesCoordinator.reduce(state, GlassesEvent.PauseDisplay).state
        assertNull(state.answerPermit)

        val ignored = GlassesCoordinator.reduce(
            state,
            GlassesEvent.AnswerCompleted(AnswerContent(ref, "Q", "A"), stalePermit),
        )
        assertEquals(DisplayIntent.Idle, ignored.state.intent)
        assertNull(ignored.state.answer)
    }

    @Test
    fun externalTeleprompterYieldsOwnershipAndRetryAudioUsesModeChannelCount() {
        var state = GlassesState(
            intent = DisplayIntent.PromptStandby,
            link = LinkState(LinkPhase.FULL, "已连接"),
            session = PageSession(
                id = 4,
                mode = PageMode.PROMPT,
                phase = PagePhase.READY,
                content = PageContent("standby", "OpenRayneo", "实时提示已就绪"),
            ),
        )

        val retried = GlassesCoordinator.reduce(state, GlassesEvent.RetryAudio)
        assertEquals(
            listOf(GlassesEffect.StopAudio, GlassesEffect.StartAudio(4, 2)),
            retried.effects,
        )

        val yielded = GlassesCoordinator.reduce(
            retried.state,
            GlassesEvent.ExternalPage("检测到眼镜提词器活动，已让出显示"),
        )
        assertEquals(DisplayOwnership.YIELDED, yielded.state.ownership)
        assertNull(yielded.state.session)
        assertTrue(yielded.effects.contains(GlassesEffect.ResetPage))
        assertTrue(yielded.effects.contains(GlassesEffect.StopAudio))
    }

    @Test
    fun closeTimeoutBlocksAutomaticReopenLoop() {
        val state = GlassesState(
            intent = DisplayIntent.PromptStandby,
            link = LinkState(LinkPhase.FULL, "已连接"),
            session = PageSession(
                id = 7,
                mode = PageMode.NAVIGATION,
                phase = PagePhase.CLOSING,
                content = PageContent("navigation", NavigationFrame.status("测试")),
            ),
            revision = 3,
        )
        val timedOut = GlassesCoordinator.reduce(state, GlassesEvent.CloseTimedOut(7))
        assertNull(timedOut.state.session)
        assertEquals(3L, timedOut.state.blockedRevision)
        assertTrue(timedOut.effects.none { it is GlassesEffect.StartPage })
    }
}
