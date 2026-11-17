// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import okhttp3.*
import okio.Buffer
import okio.ByteString
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Existing Bailian run-task protocol; timestamps remain on the uncut 16kHz PCM timeline. */
internal class ConversationASR(config: JSONObject,
    private val sentence: (String, Long, Long, String, List<SpeechWord>) -> Unit,
    private val failed: (String) -> Unit, private val completed: () -> Unit) : WebSocketListener() {
    private val task = UUID.randomUUID().toString()
    private val model = config.optString("asrModel").ifBlank { "qwen-audio-3.1-asr-flash-message" }
    private val key = config.optString("asrKey").trim()
    private val address = config.optString("asrUrl").ifBlank { "wss://dashscope.aliyuncs.com/api-ws/v1/inference" }
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS).build()
    private val pending = Buffer()
    private var socket: WebSocket? = null
    private var started = false
    private var finishing = false
    private var ended = false
    private var finishSent = false
    private val seen = mutableSetOf<String>()

    @Synchronized fun start() {
        require(key.isNotEmpty()) { "请先填写百炼 ASR API Key" }
        require(address.startsWith("wss://")) { "ASR 服务地址需使用 WSS" }
        socket = http.newWebSocket(Request.Builder().url(address).header("Authorization", "Bearer $key").build(), this)
    }
    @Synchronized fun canAcceptAudio() = !ended && !finishing && pending.size + (socket?.queueSize() ?: 0) < 128000
    @Synchronized fun append(samples: FloatArray) {
        if (ended || finishing) return
        check(pending.size + samples.size * 2 <= 480000) { "ASR 待发送音频超过15秒，已停止本轮以保留错误状态" }
        for (sample in samples) pending.writeShortLe((sample * 32768).toInt().coerceIn(-32768, 32767))
        pump()
    }
    @Synchronized fun finish() { if (!ended) { finishing = true; pump() } }
    @Synchronized fun cancel() { if (!ended) { ended = true; pending.clear(); socket?.cancel(); release() } }
    override fun onOpen(webSocket: WebSocket, response: Response) {
        val parameters = JSONObject().put("format", "pcm").put("sample_rate", 16000)
            .put("intermediate_result_enabled", false).put("disfluency_removal_enabled", false)
            .put("heartbeat", true).put("vad_model", "far_field_meeting_16k")
        webSocket.send(JSONObject().put("header", header("run-task")).put("payload", JSONObject()
            .put("task_group", "audio").put("task", "asr").put("function", "recognition")
            .put("model", model).put("parameters", parameters).put("input", JSONObject())).toString())
    }
    @Synchronized override fun onMessage(webSocket: WebSocket, text: String) {
        if (ended) return
        try {
        val data = JSONObject(text); val header = data.optJSONObject("header") ?: return
        if (header.optString("task_id") != task) return
        when (header.optString("event")) {
            "task-started" -> { started = true; pump() }
            "result-generated" -> {
                val s = data.optJSONObject("payload")?.optJSONObject("output")?.optJSONObject("sentence") ?: return
                if (!s.optBoolean("sentence_end") || s.optBoolean("heartbeat")) return
                val content = s.optString("text").trim()
                val id = task + ":" + s.optString("sentence_id")
                if (content.isNotEmpty() && seen.add(id)) {
                    val words = s.optJSONArray("words")?.let { a -> (0 until a.length()).mapNotNull { index ->
                        val word = a.getJSONObject(index)
                        if (!word.has("begin_time") || word.isNull("begin_time") || !word.has("end_time") || word.isNull("end_time")) null
                        else SpeechWord(word.optString("text") + word.optString("punctuation"), word.getLong("begin_time"), word.getLong("end_time"))
                    } } ?: emptyList()
                    sentence(content, s.getLong("begin_time"), s.getLong("end_time"), id, words)
                }
            }
            "task-finished" -> { ended = true; socket?.close(1000, null); release(); completed() }
            "task-failed" -> fail("ASR 请求失败：" + header.optString("error_code", "unknown"))
        }
        } catch (error: Exception) { fail("ASR 响应处理失败：${error.message}") }
    }
    override fun onMessage(webSocket: WebSocket, bytes: ByteString) = onMessage(webSocket, bytes.utf8())
    @Synchronized override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        if (!ended) fail("ASR 连接中断：" + (response?.code?.let { "HTTP $it" } ?: t.javaClass.simpleName))
    }
    @Synchronized override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        if (!ended) fail("ASR 在完整结束前关闭：$code")
    }
    private fun header(action: String) = JSONObject().put("action", action).put("task_id", task).put("streaming", "duplex")
    private fun pump() {
        val target = socket ?: return
        if (!started || ended) return
        check(target.queueSize() <= 480000) { "ASR 网络发送积压超过15秒" }
        while (pending.size >= 6400 || finishing && pending.size > 0) {
            check(target.send(pending.readByteString(minOf(pending.size, 6400)))) { "ASR 音频发送失败" }
        }
        if (finishing && !finishSent) {
            finishSent = true
            check(target.send(JSONObject().put("header", header("finish-task"))
                .put("payload", JSONObject().put("input", JSONObject())).toString())) { "ASR 结束发送失败" }
        }
    }
    private fun fail(message: String) { ended = true; pending.clear(); socket?.cancel(); release(); failed(message) }
    private fun release() { http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
}
