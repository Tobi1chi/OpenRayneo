// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.ZonedDateTime
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

internal data class TeleprompterState(val documents: List<JSONObject> = emptyList(), val active: String? = null,
    val paused: Boolean = false, val busy: Boolean = false, val notice: String = "保存稿件后发送到眼镜")
internal class TeleprompterLibrary(context: Context, private val requests: GlassesRequests, private val changed: () -> Unit) {
    private val folder = File(context.filesDir, "scripts").apply { mkdirs() }
    @Volatile var state = TeleprompterState(documents = folder.listFiles().orEmpty().filter { it.extension == "json" }.map { JSONObject(it.readText()) }); private set
    private val messages = LinkedBlockingQueue<Pair<Int, JSONObject>>(64)
    private val transfer = LinkedBlockingQueue<WireFields.Value>(64)
    @Volatile private var task: String? = null
    @Volatile private var disconnected = false
    private var sequence = 0x5300
    fun save(title: String, text: String, id: String = UUID.randomUUID().toString()): String {
        require(title.isNotBlank() && text.isNotBlank()); require(id.matches(Regex("[A-Za-z0-9-]{1,80}")))
        val document = JSONObject().put("did", id).put("title", title).put("text", text).put("updated", System.currentTimeMillis())
        val file = android.util.AtomicFile(File(folder, "$id.json")); val out = file.startWrite()
        try { out.write(document.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(out) }
        catch (error: Exception) { file.failWrite(out); throw error }
        state = state.copy(documents = listOf(document) + state.documents.filter { it.getString("did") != id }); changed(); return id
    }
    fun observe(frame: ProtocolCodec.Frame) {
        if (frame.protocol == 0x11 && task != null) {
            WireFields.parse(frame.payload).firstOrNull()?.let { field ->
                val fields = field.bytes?.let(WireFields::parse).orEmpty()
                if (fields.firstOrNull { it.number == 1 }?.bytes?.toString(Charsets.UTF_8) == task)
                    check(transfer.offer(field)) { "提词文件回包队列已满" }
            }
        } else if (frame.protocol == 0x14) {
            val message = ProtocolCodec.message(frame.payload); val body = message.json?.let(::JSONObject) ?: return
            if (body.optInt("action") == 2) { if (!messages.offer(message.type to body)) { messages.poll(); messages.offer(message.type to body) } }
            if (body.optInt("action") == 1 && body.optString("did") == state.active && message.type == 6) {
                state = state.copy(active = null, paused = false, notice = "眼镜已结束提词"); changed()
            }
        }
    }
    fun start(id: String, speed: Int, completion: (Result<JSONObject>) -> Unit) = operation({ play(id, speed) }, completion)
    fun startText(title: String, text: String, speed: Int, completion: (Result<JSONObject>) -> Unit) = start(save(title, text), speed, completion)
    private fun play(id: String, speed: Int): JSONObject {
        require(speed in 1..10)
        val document = state.documents.first { it.getString("did") == id }
        val text = document.getString("text"); val content = text.toByteArray(Charsets.UTF_8)
        if (state.active != null) controlBlocking("stop")
        messages.clear(); transfer.clear(); disconnected = false
        val settings = JSONObject().put("countdown", 3).put("scroll", 2).put("speed", speed).put("gear", 1)
            .put("depth", 1).put("size", 18).put("width", 492).put("leading", 4)
        val item = JSONObject().put("did", id).put("pin", false).put("title", document.getString("title")).put("offset", 0)
            .put("scroll", 2).put("total", content.size).put("timestamp", System.currentTimeMillis() / 1000)
            .put("preview", text.take(80)).put("timezone", ZonedDateTime.now().offset.totalSeconds)
        send(1, JSONObject().put("action", 2).put("type", 3).put("total", state.documents.size)
            .put("chunkinfo", JSONObject().put("chunkid", 1).put("total_items", 1).put("islast", true)).put("items", JSONArray().put(item)))
        send(2, JSONObject(settings.toString()).put("action", 1).put("did", id).put("total", content.size).put("pageOffset", 0).put("highLightOffset", 0))
        state = state.copy(active = id, paused = true)
        val taskId = "task_2_${System.currentTimeMillis()}"; task = taskId
        try {
            // MD5 and FNV are required wire fields, matching the official protocol.
            val md5 = MessageDigest.getInstance("MD5").digest(content).joinToString("") { "%02x".format(it.toInt() and 255) }
            val info = WireFields.string(1, taskId) + WireFields.string(2, id) + WireFields.integer(3, content.size.toLong()) + WireFields.string(4, md5) + WireFields.integer(5, 17)
            requests.sendRaw(ProtocolCodec.frame(17, 0, WireFields.bytes(1, info)))
            while (true) {
                check(!disconnected) { "连接断开，提词传输已取消" }
                val field = checkNotNull(transfer.poll(30, TimeUnit.SECONDS)) { "眼镜未请求文件数据，传输超时" }
                val values = WireFields.parse(checkNotNull(field.bytes))
                fun number(n: Int) = values.firstOrNull { it.number == n }?.integer
                if (field.number == 6) error("眼镜取消提词文件传输")
                if (field.number == 5) { check(number(2) == 0L) { "眼镜拒绝文件传输" }; break }
                if (field.number != 3) continue
                val offset = number(3) ?: 0; val size = minOf(checkNotNull(number(4)), content.size - offset)
                require(offset in 0 until content.size.toLong() && size in 1..60000)
                val chunk = content.copyOfRange(offset.toInt(), (offset + size).toInt())
                val entry = WireFields.string(1, taskId) + WireFields.integer(2, number(2) ?: 0) + WireFields.integer(3, offset) + WireFields.integer(4, size) + WireFields.bytes(5, chunk)
                requests.sendRaw(ProtocolCodec.frame(17, 0, WireFields.bytes(4, entry)))
            }
            accepted(2, id)
            Thread.sleep(350) // Firmware startup transition, measured on 1.0.5.12.
            var checksum = 0x811c9dc5u
            for (byte in content) checksum = (checksum xor (byte.toUInt() and 255u)) * 0x01000193u
            send(3, JSONObject(settings.toString()).put("action", 1).put("did", id).put("total", content.size)
                .put("pageOffset", 0).put("highLightOffset", 0).put("code", 1).put("checksum", checksum.toString(16).padStart(8, '0')))
            accepted(3, id)
            state = state.copy(active = id, paused = false)
            return JSONObject().put("did", id).put("accepted", true).put("message", "眼镜已确认提词播放")
        } finally { task = null }
    }
    private fun accepted(type: Int, id: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (true) {
            check(!disconnected) { "眼镜已断开" }
            val remaining = deadline - System.nanoTime(); check(remaining > 0) { "眼镜未确认提词请求$type" }
            val (received, body) = checkNotNull(messages.poll(remaining, TimeUnit.NANOSECONDS)) { "提词确认超时" }
            if (received != type || body.optString("did") != id) continue
            check(body.optInt("code") == 1 || type == 2 && body.optInt("code") == 7) { "眼镜拒绝提词：${body.optInt("code")}" }; return
        }
    }
    fun control(action: String, completion: (Result<JSONObject>) -> Unit) = operation({ controlBlocking(action) }, completion)
    private fun controlBlocking(action: String): JSONObject {
        val id = checkNotNull(state.active) { "没有本应用启动的提词" }
        val type = when (action) { "pause" -> 4; "resume" -> 5; "stop" -> 6; else -> error("提词操作应为pause/resume/stop") }
        messages.clear()
        send(type, JSONObject().put("action", 1).put("did", id).apply { if (type == 4) put("offset", 0).put("code", 1).put("isCompleted", false) })
        val actual = checkNotNull(requests.request(20, 10, JSONObject().put("action", 1).put("checksum", "").put("state", JSONObject.NULL).put("pageOffset", 0).put("highLightOffset", 0)) { reply, body -> reply == 10 && body.optInt("action") == 2 })
        check(!actual.has("code") || actual.optInt("code") == 1) { "眼镜未接受提词状态查询" }
        val expected = when (action) { "pause" -> 2; "resume" -> 1; else -> 3 }
        val matched = actual.optInt("state") == expected && (expected == 3 || actual.optString("did") == id)
        if (matched) state = state.copy(active = if (expected == 3) null else id, paused = expected == 2)
        return JSONObject().put("did", id).put("readBack", matched).put("deviceState", actual)
            .put("message", if (matched) "提词状态已回读确认" else "提词控制已发送，当前回读与请求不同")
    }
    private fun send(type: Int, body: JSONObject) = requests.sendRaw(ProtocolCodec.display(20, sequence++ and 65535, type, body.toString(), byteArrayOf()))
    private fun operation(work: () -> JSONObject, completion: (Result<JSONObject>) -> Unit) {
        check(!state.busy) { "请等待提词传输结束" }; state = state.copy(busy = true, notice = "正在与眼镜同步稿件…"); changed()
        requests.perform(work) { result -> state = state.copy(busy = false, notice = result.fold({ it.optString("message").ifBlank { "设备已确认" } }, { it.message ?: "提词失败" })); changed(); completion(result) }
    }
    fun disconnected() { disconnected = true; task = null; transfer.offer(WireFields.Value(6)); messages.offer(0 to JSONObject())
        state = state.copy(active = null, paused = false, notice = "眼镜已断开，稿件保存在手机"); changed() }
}
