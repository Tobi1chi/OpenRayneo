// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONObject
import java.util.UUID

/** Protocol executor. It reports facts; only GlassesCoordinator chooses pages. */
internal class GlassesDisplay(
    private val write: (ByteArray, (Result<Unit>) -> Unit) -> Unit,
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val report: (String) -> Unit,
    private val signal: (Long, PageSignal) -> Unit,
    private val onAudio: (Long, ByteArray) -> Unit,
    private val externalPage: (String) -> Unit,
) {
    private var session: PageSession? = null
    private var sid: String? = null
    private var generation = 0
    private var audioAccepted = false
    private var accepted = false
    private var settled = false
    private var writing = false
    private var failed = false
    private var navigationFrameSent = false
    private var sequence = 0x4000
    private var pending: PageContent? = null
    private var lastWritten: PageContent? = null
    private val recentAudioSequences = ArrayDeque<Long>()
    private var audioReported = false
    private var unmatchedAudioReported = false
    private val timeout = Runnable { fail("眼镜未确认启动或布局，请主动重试") }
    private val settle = Runnable { settled = true; flush() }

    fun start(next: PageSession) {
        check(session == null) { "旧显示会话尚未关闭" }
        reset()
        validate(next.mode, next.content)
        session = next
        val id = UUID.randomUUID().toString().replace("-", "")
        sid = id; pending = next.content
        val body = JSONObject().put("sid", id).put("trigger", 1).put("force", false).put("code", 0)
            .put("settings", JSONObject().put("mode", if (next.mode == PageMode.NAVIGATION) "translation" else "conversation")
                .put("source_language", "zh-CN").put("target_language", "zh-CN")
                .put("save_audio", false).put("direction", "ahead"))
        schedule(timeout, 8_000)
        send(protocol(next.mode), 1, body) { if (sid == id && it.isFailure) fail("显示启动发送失败") }
    }

    fun update(id: Long, content: PageContent) {
        val active = session ?: return
        if (active.id != id || failed) return
        validate(active.mode, content)
        pending = content
        flush()
    }

    fun receive(frame: ProtocolCodec.Frame, source: String) {
        if (frame.protocol == 0x14) {
            val message = ProtocolCodec.message(frame.payload)
            val json = message.json?.let(::JSONObject)
            val activity = message.type == 9 && message.audio?.isNotEmpty() == true ||
                (message.type in setOf(2, 3, 5, 8) && !json?.optString("did").isNullOrBlank() && json?.optInt("code", 1) == 1)
            if (activity) externalPage("检测到眼镜提词器活动，已让出显示")
            return
        }
        val active = session ?: return
        val receivingGeneration = generation
        if (frame.protocol != protocol(active.mode) || sid == null || failed) return
        val message = ProtocolCodec.message(frame.payload)
        val json = message.json?.let(::JSONObject) ?: return
        if (json.optString("sid") != sid) {
            if (message.type == 4 && !unmatchedAudioReported) {
                unmatchedAudioReported = true
                report("收到 $source 音频包，但会话不匹配，未送入解码器")
            }
            return
        }
        if (audioAccepted && message.type == 4) {
            message.audio?.takeIf { it.isNotEmpty() }?.let { packet ->
                val number = json.optLong("seq", -1)
                if (number >= 0) {
                    if (number in recentAudioSequences) return
                    recentAudioSequences.addLast(number)
                    if (recentAudioSequences.size > 64) recentAudioSequences.removeFirst()
                }
                if (!audioReported) {
                    audioReported = true
                    report("收到首个眼镜音频包：$source，${packet.size} 字节")
                }
                onAudio(active.id, packet)
            }
            return
        }
        if (message.type == 3) {
            val reason = json.optInt("reason_code", -1)
            reset()
            signal(active.id, PageSignal.Ended("眼镜请求结束或暂停当前页面（原因 $reason），已让出显示"))
            return
        }
        if (accepted) return
        if (!audioAccepted) {
            if (message.type != 2) return
            cancel(timeout)
            if (json.optInt("code") != 1) { fail("眼镜拒绝启动会话：${json.optInt("code")}"); return }
            audioAccepted = true
            signal(active.id, PageSignal.AudioAccepted(if (active.mode == PageMode.NAVIGATION) 1 else 2))
            if (generation != receivingGeneration) return
            if (active.mode == PageMode.NAVIGATION) {
                signal(active.id, PageSignal.LayoutPending)
                if (generation != receivingGeneration) return
                val id = sid
                val config = JSONObject().put("font_size", 2).put("content_width", 100).put("max_lines", 5)
                    .put("position", "center").put("is_display", true).put("straight_view", "original")
                schedule(timeout, 8_000)
                send(0x13, 7, JSONObject().put("sid", id).put("force", false)
                    .put("scope", "temporary").put("config", config)) {
                    if (sid == id && it.isFailure) fail("导航布局配置发送失败")
                }
                return
            }
        } else {
            if (active.mode != PageMode.NAVIGATION || message.type != 8) return
            cancel(timeout)
            val config = json.optJSONObject("effective_config")
            if (json.optInt("code") != 1 || config?.optInt("font_size") != 2 || config.optInt("content_width") != 100 || config.optInt("max_lines") != 5) {
                fail("眼镜返回的布局不是字体 2／宽度 100／5 行，已停止发送导航网格")
                return
            }
        }
        accepted = true
        signal(active.id, PageSignal.Settling)
        if (generation != receivingGeneration) return
        schedule(settle, 500)
    }

    private fun flush() {
        if (!accepted || !settled || writing || failed) return
        val content = pending ?: return
        val id = sid ?: return
        val active = session ?: return
        pending = null
        if (content == lastWritten) return
        writing = true
        val text = (if (active.mode == PageMode.NAVIGATION && navigationFrameSent) "\u3000" else "") + content.text
        val fields = JSONObject().put("source_transcript", text)
        if (active.mode == PageMode.PROMPT) fields.put("target_translation", content.answer.orEmpty()).put("keyword_info", JSONObject.NULL).put("label", 0)
        send(protocol(active.mode), 5, JSONObject().put("sid", id).put("mode", if (active.mode == PageMode.NAVIGATION) 3 else 4)
            .put("status", 1).put("content", fields)) { result ->
            if (sid != id) return@send
            writing = false
            if (result.isSuccess) {
                lastWritten = content
                if (active.mode == PageMode.NAVIGATION) navigationFrameSent = true
                signal(active.id, PageSignal.Written(content))
                flush()
            } else fail("显示更新失败：${result.exceptionOrNull()?.message}")
        }
    }

    fun stop(token: Long) {
        val active = session; val id = sid
        if (active == null || active.id != token || id == null) { signal(token, PageSignal.Closed()); return }
        reset()
        val closingGeneration = generation
        send(protocol(active.mode), 3, JSONObject().put("sid", id)
            .put("reason_code", if (active.mode == PageMode.NAVIGATION) 10 else 2).put("text", "")) { result ->
            if (generation == closingGeneration) signal(token, PageSignal.Closed(result.exceptionOrNull()?.let { "关闭命令发送失败：${it.message}" }))
        }
    }
    private fun fail(message: String) {
        val active = session ?: return
        if (failed) return
        failed = true; cancel(timeout); cancel(settle)
        signal(active.id, PageSignal.Failed(message))
    }
    fun reset() {
        generation++
        cancel(timeout); cancel(settle)
        session = null; sid = null; audioAccepted = false; accepted = false; settled = false; writing = false; failed = false
        navigationFrameSent = false; pending = null; lastWritten = null
        recentAudioSequences.clear(); audioReported = false; unmatchedAudioReported = false
    }
    private fun protocol(mode: PageMode) = if (mode == PageMode.NAVIGATION) 0x13 else 0x17
    private fun validate(mode: PageMode, content: PageContent) {
        if (mode == PageMode.NAVIGATION) require(NavigationFrame.isGrid(content.text)) { "导航画面必须保持 20 列 × 5 行" }
    }
    private fun send(protocol: Int, type: Int, json: JSONObject, completion: (Result<Unit>) -> Unit) {
        try { write(ProtocolCodec.display(protocol, sequence++ and 65535, type, json.toString()), completion) }
        catch (error: Exception) { completion(Result.failure(error)) }
    }
}

internal object NavigationFrame {
    fun isGrid(text: String): Boolean = text.split('\n').let { it.size == 5 && it.all { row -> row.length == 20 } }
    private fun grid(): Array<CharArray> = Array(5) { CharArray(20) { '　' } }
    private fun put(rows: Array<CharArray>, text: String, x: Int, y: Int) {
        text.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').take(20 - x).forEachIndexed { i, c ->
            rows[y][x + i] = when (c) { ' ' -> '　'; in '!'..'~' -> (c.code + 0xfee0).toChar(); else -> c }
        }
    }
    private fun text(rows: Array<CharArray>) = rows.joinToString("\n") { String(it) }
    fun status(title: String, detail: String = ""): String = grid().let {
        put(it, title, 2, 1); put(it, detail, 2, 3); text(it)
    }
    fun render(direction: String, meters: Int, roadLabel: String = ""): String {
        val left = listOf("  █    ", " █     ", "██████ ", " █   █ ", "  █  █ ")
        val arrow = when (direction) {
            "左转", "左前", "左后" -> left
            "右转", "右前", "右后" -> left.map { it.reversed() }
            "掉头" -> listOf("  ████ ", " █   █ ", " █   █ ", "███  █ ", " █   █ ")
            "直行" -> listOf("   █   ", "  ███  ", " █████ ", "   █   ", "   █   ")
            else -> List(5) { "       " }
        }
        val rows = grid()
        arrow.forEachIndexed { i, row -> put(rows, row, 2, i) }
        put(rows, if (meters <= 0) "现在" else "${meters.coerceAtMost(9999)}米", 12, 1)
        put(rows, direction, 12, 3)
        put(rows, roadLabel.trim(), 12, 4)
        return text(rows)
    }
}
