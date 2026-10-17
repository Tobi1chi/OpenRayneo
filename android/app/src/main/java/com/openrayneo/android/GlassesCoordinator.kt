// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

/** Pure decision logic. The service commits the state before executing effects or accepting callbacks. */
internal object GlassesCoordinator {
    fun reduce(previous: GlassesState, event: GlassesEvent): GlassesTransition {
        var state = previous
        val effects = mutableListOf<GlassesEffect>()
        fun cancelRestore() {
            if (state.restoreRevision != null) effects += GlassesEffect.CancelRestore
            state = state.copy(restoreRevision = null)
        }
        fun setIntent(intent: DisplayIntent) {
            cancelRestore()
            state = state.copy(intent = intent, revision = state.revision + 1,
                ownership = DisplayOwnership.APP, answerPermit = null, blockedRevision = null, error = null)
        }
        fun resetSession() {
            cancelRestore()
            effects += GlassesEffect.ResetPage
            effects += GlassesEffect.StopAudio
            effects += GlassesEffect.CancelCloseTimeout
            state = state.copy(session = null, audio = AudioState())
        }
        fun returnIntent(target: ReturnTarget): DisplayIntent = when (target) {
            ReturnTarget.NAVIGATION -> if (state.navigation.enabled) DisplayIntent.Navigation else DisplayIntent.Idle
            ReturnTarget.PROMPT_STANDBY -> DisplayIntent.PromptStandby
            ReturnTarget.IDLE -> DisplayIntent.Idle
        }
        fun showAnswer(content: AnswerContent) {
            val target = when (val intent = state.intent) {
                DisplayIntent.Navigation -> ReturnTarget.NAVIGATION
                DisplayIntent.PromptStandby -> ReturnTarget.PROMPT_STANDBY
                is DisplayIntent.Answer -> intent.returnTo
                DisplayIntent.Idle -> ReturnTarget.IDLE
            }
            setIntent(DisplayIntent.Answer(content.ref, target))
            state = state.copy(answer = content)
        }
        when (event) {
            GlassesEvent.BeginConnection -> {
                resetSession()
                setIntent(if (state.navigation.enabled) DisplayIntent.Navigation else DisplayIntent.PromptStandby)
                state = state.copy(link = LinkState(LinkPhase.CONNECTING, "正在连接眼镜"), disconnecting = false)
            }
            is GlassesEvent.LinkChanged -> {
                val lost = state.link.phase == LinkPhase.FULL && event.state.phase != LinkPhase.FULL
                if (lost) {
                    resetSession()
                    state = state.copy(revision = state.revision + 1, answerPermit = null, blockedRevision = null, error = null)
                }
                state = state.copy(link = event.state)
                if (state.disconnecting && event.state.phase == LinkPhase.DISCONNECTED) state = state.copy(disconnecting = false)
            }
            is GlassesEvent.NavigationChanged -> {
                val newlyFollowing = !state.navigation.enabled && event.state.enabled
                state = state.copy(navigation = event.state)
                // Preserve first-use auto-selection only while the connection's default page owns the display.
                if (newlyFollowing && state.intent == DisplayIntent.PromptStandby && state.ownership == DisplayOwnership.APP && !state.disconnecting) {
                    setIntent(DisplayIntent.Navigation)
                }
            }
            is GlassesEvent.SelectNavigation -> {
                setIntent(DisplayIntent.Navigation)
                state = state.copy(navigation = event.state)
                effects += GlassesEffect.FollowNavigation(checkNotNull(event.state.key))
            }
            GlassesEvent.StopNavigation -> {
                val current = state.intent
                val next = if (current is DisplayIntent.Answer && current.returnTo == ReturnTarget.NAVIGATION)
                    current.copy(returnTo = ReturnTarget.IDLE) else if (current == DisplayIntent.Navigation) DisplayIntent.Idle else current
                val owner = state.ownership
                setIntent(next)
                state = state.copy(ownership = owner, navigation = state.navigation.copy(enabled = false, frame = null))
                effects += GlassesEffect.StopFollowing
            }
            GlassesEvent.PauseDisplay -> setIntent(DisplayIntent.Idle)
            GlassesEvent.OpenStandby -> setIntent(DisplayIntent.PromptStandby)
            GlassesEvent.RetryAudio -> state.session?.takeIf {
                state.link.phase == LinkPhase.FULL && state.ownership == DisplayOwnership.APP &&
                    !state.disconnecting && it.phase in setOf(PagePhase.LAYOUT, PagePhase.SETTLING, PagePhase.READY)
            }?.let {
                state = state.copy(audio = AudioState(AudioPhase.WAITING_PACKET, "解码器已重启，等待新的眼镜音频包"))
                effects += GlassesEffect.StopAudio
                effects += GlassesEffect.StartAudio(it.id, if (it.mode == PageMode.NAVIGATION) 1 else 2)
            }
            GlassesEvent.DismissAnswer -> (state.intent as? DisplayIntent.Answer)?.let { setIntent(returnIntent(it.returnTo)) }
            GlassesEvent.Disconnect -> {
                setIntent(DisplayIntent.Idle)
                state = state.copy(disconnecting = true)
            }
            is GlassesEvent.AnswerRequested -> state = state.copy(answerPermit = AnswerPermit(event.ref, state.revision))
            is GlassesEvent.CancelAnswer -> if (state.answerPermit?.ref?.source == event.source) state = state.copy(answerPermit = null)
            is GlassesEvent.AnswerCompleted -> {
                if (state.answerPermit == event.permit && event.permit.ref == event.content.ref &&
                    event.permit.revision == state.revision && state.link.phase == LinkPhase.FULL &&
                    state.ownership == DisplayOwnership.APP && !state.disconnecting) showAnswer(event.content)
            }
            is GlassesEvent.RevealAnswer -> if (!state.disconnecting) showAnswer(event.content)
            is GlassesEvent.SessionSignal -> {
                val session = state.session
                if (session?.id != event.id) return GlassesTransition(state, emptyList())
                when (val signal = event.signal) {
                    is PageSignal.Closed -> if (session.phase == PagePhase.CLOSING) {
                        effects += GlassesEffect.CancelCloseTimeout
                        state = state.copy(session = null)
                        if (signal.error != null) state = state.copy(error = signal.error, blockedRevision = state.revision)
                    }
                    is PageSignal.Ended -> {
                        resetSession()
                        setIntent(DisplayIntent.Idle)
                        state = state.copy(ownership = DisplayOwnership.YIELDED, error = signal.message)
                    }
                    else -> if (session.phase != PagePhase.CLOSING) when (signal) {
                        is PageSignal.AudioAccepted -> {
                            state = state.copy(audio = AudioState(AudioPhase.WAITING_PACKET, "音频会话已确认，等待眼镜音频"))
                            effects += GlassesEffect.StartAudio(session.id, signal.channels)
                        }
                        PageSignal.LayoutPending -> state = state.copy(session = session.copy(phase = PagePhase.LAYOUT))
                        PageSignal.Settling -> state = state.copy(session = session.copy(phase = PagePhase.SETTLING))
                        is PageSignal.Written -> {
                            val latest = signal.content == session.content
                            state = state.copy(session = session.copy(writtenContent = signal.content,
                                phase = if (latest) PagePhase.READY else session.phase))
                            val answer = state.intent as? DisplayIntent.Answer
                            if (latest && answer?.returnTo == ReturnTarget.NAVIGATION && state.navigation.enabled && state.restoreRevision != state.revision) {
                                cancelRestore()
                                state = state.copy(restoreRevision = state.revision)
                                effects += GlassesEffect.ScheduleRestore(session.id, state.revision, answer.ref)
                            }
                        }
                        is PageSignal.Failed -> {
                            cancelRestore()
                            state = state.copy(error = signal.message, blockedRevision = state.revision, answerPermit = null)
                        }
                        else -> Unit
                    }
                }
            }
            is GlassesEvent.AudioChanged -> if (state.session?.id == event.id && state.session?.phase != PagePhase.CLOSING) state = state.copy(audio = event.state)
            is GlassesEvent.RestoreAnswer -> {
                val answer = state.intent as? DisplayIntent.Answer
                if (state.session?.id == event.id && state.session?.phase == PagePhase.READY &&
                    state.revision == event.revision && answer?.ref == event.ref && state.ownership == DisplayOwnership.APP) {
                    setIntent(returnIntent(answer.returnTo))
                }
            }
            is GlassesEvent.CloseTimedOut -> if (state.session?.id == event.id && state.session?.phase == PagePhase.CLOSING) {
                resetSession()
                state = state.copy(error = "页面关闭未完成，请主动重试；眼镜实际页面未知", blockedRevision = state.revision)
            }
            is GlassesEvent.ExternalPage -> {
                if (state.ownership == DisplayOwnership.YIELDED && state.session == null && state.intent == DisplayIntent.Idle)
                    return GlassesTransition(state, emptyList())
                resetSession()
                setIntent(DisplayIntent.Idle)
                state = state.copy(ownership = DisplayOwnership.YIELDED, error = event.description)
            }
        }

        val target = target(state)
        val session = state.session
        if (state.link.phase == LinkPhase.FULL && session != null && session.phase != PagePhase.CLOSING &&
            (target == null || target.first != session.mode || state.blockedRevision == state.revision)) {
            cancelRestore()
            state = state.copy(session = session.copy(phase = PagePhase.CLOSING), audio = AudioState())
            effects += GlassesEffect.StopAudio
            effects += GlassesEffect.ScheduleCloseTimeout(session.id)
            effects += GlassesEffect.ClosePage(session.id)
        } else if (state.link.phase == LinkPhase.FULL && target != null && state.blockedRevision != state.revision) {
            if (session == null) {
                val newSession = PageSession(state.nextSession, target.first, PagePhase.STARTING, target.second)
                state = state.copy(session = newSession, nextSession = state.nextSession + 1)
                effects += GlassesEffect.StartPage(newSession)
            } else if (session.phase != PagePhase.CLOSING && session.content != target.second) {
                state = state.copy(session = session.copy(content = target.second))
                effects += GlassesEffect.UpdatePage(session.id, target.second)
            }
        }
        if (state.disconnecting && state.session == null && state.link.phase != LinkPhase.CLOSING) {
            state = state.copy(link = LinkState(LinkPhase.CLOSING, "正在断开眼镜"))
            effects += GlassesEffect.DisconnectTransport
        }
        return GlassesTransition(state, effects)
    }

    private fun target(state: GlassesState): Pair<PageMode, PageContent>? {
        if (state.disconnecting || state.ownership != DisplayOwnership.APP) return null
        return when (val intent = state.intent) {
            DisplayIntent.Idle -> null
            DisplayIntent.PromptStandby -> PageMode.PROMPT to PageContent("standby", "OpenRayneo", "实时提示已就绪")
            DisplayIntent.Navigation -> state.navigation.frame?.takeIf { state.navigation.enabled }?.let {
                PageMode.NAVIGATION to PageContent("navigation", it)
            }
            is DisplayIntent.Answer -> state.answer?.takeIf { it.ref == intent.ref }?.let {
                PageMode.PROMPT to PageContent("${it.ref.source}:${it.ref.taskId}", it.question.ifBlank { "Agent" }, it.text)
            }
        }
    }
}
