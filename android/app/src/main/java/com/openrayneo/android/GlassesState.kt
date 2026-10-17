// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

internal enum class AnswerSource { MOBILE_AGENT, COMPUTER_CODEX }
internal data class AnswerRef(val source: AnswerSource, val taskId: Long)
internal data class AnswerContent(val ref: AnswerRef, val question: String, val text: String)
internal enum class ReturnTarget { IDLE, PROMPT_STANDBY, NAVIGATION }
internal sealed interface DisplayIntent {
    data object Idle : DisplayIntent
    data object PromptStandby : DisplayIntent
    data object Navigation : DisplayIntent
    data class Answer(val ref: AnswerRef, val returnTo: ReturnTarget) : DisplayIntent
}
internal enum class DisplayOwnership { APP, YIELDED }
internal enum class LinkPhase { DISCONNECTED, SCANNING, CONNECTING, BLE_ONLY, FULL, RETRY_WAIT, CLOSING }
internal data class LinkState(val phase: LinkPhase = LinkPhase.DISCONNECTED, val detail: String = "等待连接眼镜")
internal enum class PageMode { NAVIGATION, PROMPT }
internal enum class PagePhase { STARTING, LAYOUT, SETTLING, READY, CLOSING }
internal data class PageContent(val key: String, val text: String, val answer: String? = null)
internal data class PageSession(
    val id: Long, val mode: PageMode, val phase: PagePhase, val content: PageContent,
    val writtenContent: PageContent? = null,
)
internal data class NavigationState(val enabled: Boolean = false, val key: String? = null, val frame: String? = null)
internal enum class AudioPhase { STOPPED, WAITING_PACKET, WAITING_PCM, RECEIVING, STALLED, FAILED }
internal data class AudioState(val phase: AudioPhase = AudioPhase.STOPPED, val detail: String = "眼镜收音已停止")
internal data class AnswerPermit(val ref: AnswerRef, val revision: Long)
internal data class GlassesState(
    val intent: DisplayIntent = DisplayIntent.Idle,
    val ownership: DisplayOwnership = DisplayOwnership.APP,
    val link: LinkState = LinkState(),
    val navigation: NavigationState = NavigationState(),
    val session: PageSession? = null,
    val audio: AudioState = AudioState(),
    val answer: AnswerContent? = null,
    val revision: Long = 0,
    val nextSession: Long = 1,
    val answerPermit: AnswerPermit? = null,
    val restoreRevision: Long? = null,
    val blockedRevision: Long? = null,
    val error: String? = null,
    val disconnecting: Boolean = false,
) {
    val displayDescription: String get() = when {
        disconnecting -> "正在关闭眼镜会话"
        ownership == DisplayOwnership.YIELDED -> "已让出眼镜显示，请主动选择要恢复的功能"
        error != null -> error
        session?.phase == PagePhase.CLOSING -> "正在关闭原页面"
        link.phase == LinkPhase.BLE_ONLY -> "仅 BLE 诊断连接，未启动显示或收音"
        link.phase != LinkPhase.FULL -> link.detail
        session == null -> "已连接，眼镜显示空闲"
        session.phase == PagePhase.STARTING -> "等待眼镜确认启动"
        session.phase == PagePhase.LAYOUT -> "正在确认导航布局"
        session.phase == PagePhase.SETTLING -> "页面已确认，正在发送内容"
        session.writtenContent != session.content -> "正在更新眼镜内容"
        session.mode == PageMode.NAVIGATION -> "导航会话已就绪"
        intent is DisplayIntent.Answer -> "回答会话已就绪"
        else -> "实时提示会话已就绪"
    }
}
internal sealed interface PageSignal {
    data class AudioAccepted(val channels: Int) : PageSignal
    data object LayoutPending : PageSignal
    data object Settling : PageSignal
    data class Written(val content: PageContent) : PageSignal
    data class Failed(val message: String) : PageSignal
    data class Ended(val message: String) : PageSignal
    data class Closed(val error: String? = null) : PageSignal
}
internal sealed interface GlassesEvent {
    data object BeginConnection : GlassesEvent
    data class LinkChanged(val state: LinkState) : GlassesEvent
    data class NavigationChanged(val state: NavigationState) : GlassesEvent
    data class SelectNavigation(val state: NavigationState) : GlassesEvent
    data object StopNavigation : GlassesEvent
    data object PauseDisplay : GlassesEvent
    data object OpenStandby : GlassesEvent
    data object RetryAudio : GlassesEvent
    data object DismissAnswer : GlassesEvent
    data object Disconnect : GlassesEvent
    data class AnswerRequested(val ref: AnswerRef) : GlassesEvent
    data class CancelAnswer(val source: AnswerSource) : GlassesEvent
    data class AnswerCompleted(val content: AnswerContent, val permit: AnswerPermit) : GlassesEvent
    data class RevealAnswer(val content: AnswerContent) : GlassesEvent
    data class SessionSignal(val id: Long, val signal: PageSignal) : GlassesEvent
    data class AudioChanged(val id: Long, val state: AudioState) : GlassesEvent
    data class RestoreAnswer(val id: Long, val revision: Long, val ref: AnswerRef) : GlassesEvent
    data class CloseTimedOut(val id: Long) : GlassesEvent
    data class ExternalPage(val description: String) : GlassesEvent
}
internal sealed interface GlassesEffect {
    data class StartPage(val session: PageSession) : GlassesEffect
    data class UpdatePage(val id: Long, val content: PageContent) : GlassesEffect
    data class ClosePage(val id: Long) : GlassesEffect
    data object ResetPage : GlassesEffect
    data class StartAudio(val id: Long, val channels: Int) : GlassesEffect
    data object StopAudio : GlassesEffect
    data class FollowNavigation(val key: String) : GlassesEffect
    data object StopFollowing : GlassesEffect
    data class ScheduleRestore(val id: Long, val revision: Long, val ref: AnswerRef) : GlassesEffect
    data object CancelRestore : GlassesEffect
    data class ScheduleCloseTimeout(val id: Long) : GlassesEffect
    data object CancelCloseTimeout : GlassesEffect
    data object DisconnectTransport : GlassesEffect
}
internal data class GlassesTransition(val state: GlassesState, val effects: List<GlassesEffect>)
