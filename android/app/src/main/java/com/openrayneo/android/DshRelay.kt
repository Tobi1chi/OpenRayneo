// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.os.Handler
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Encrypted Agent outbox. Offline queued work survives phone/service restarts. */
internal class DshRelay(private val main: Handler, private val repository: ConversationRepository,
    private val restored: (String, String, JSONObject) -> Unit, private val progress: (String) -> Unit) {
    private data class Request(val id: String, val text: String, val context: String,
        val complete: (Result<String>) -> Unit, val kind: String, val input: JSONObject?,
        var state: String = "queued", var session: String = "", var claimedAt: Long = 0L, var answer: String? = null, var delivered: Boolean = false, val createdAt: Long = System.currentTimeMillis()) {
        fun json() = JSONObject().put("id", id).put("text", text).put("context", context).put("kind", kind).put("input", input)
            .put("state", state).put("sessionId", session).put("claimedAt", claimedAt).put("answer", answer).put("delivered", delivered).put("createdAt", createdAt)
    }
    private val lock = Object()
    private val requests = linkedMapOf<String, Request>()
    init {
        val saved = repository.readAgentOutbox()
        repeat(saved.length()) { index ->
            val row = saved.getJSONObject(index); val input = row.optJSONObject("input")
            val text = row.getString("text")
            val request = Request(row.getString("id"), text, row.getString("context"), { result ->
                result.onSuccess { restored(text, it, input ?: JSONObject()) }
            }, row.optString("kind", "task"), input, row.optString("state", "queued"), row.optString("sessionId"), row.optLong("claimedAt"), row.optString("answer").takeUnless { it == "null" }, row.optBoolean("delivered"), row.optLong("createdAt", row.optLong("claimedAt")))
            requests[request.id] = request
            if (request.state == "running") scheduleTimeout(request)
            if (request.state == "completed" && !request.delivered && request.answer != null) deliver(request)
        }
    }
    private fun persist() {
        val finished = requests.values.filter { it.state !in setOf("queued", "running") }.dropLast(64).map { it.id }.toSet()
        finished.forEach { requests.remove(it) }
        repository.saveAgentOutbox(JSONArray(requests.values.map { it.json() }))
    }
    fun submit(text: String, context: String, kind: String = "task", input: JSONObject? = null, complete: (Result<String>) -> Unit): String {
        val id = UUID.randomUUID().toString()
        if (input?.optString("recordId")?.isNotBlank() == true) input.put("derivedId", id)
        val request = Request(id, text, context, complete, kind, input)
        synchronized(lock) { requests[request.id] = request; persist(); lock.notifyAll() }
        return id
    }
    private fun deliver(request: Request) { main.post {
        request.complete(Result.success(request.answer.orEmpty()))
        synchronized(lock) { request.delivered = true; persist() }
    } }
    private fun scheduleTimeout(request: Request) {
        val timeout = if (request.kind == "task") 600_000L else 90_000L
        val remaining = (request.claimedAt + timeout - System.currentTimeMillis()).coerceAtLeast(0)
        main.postDelayed({
            val expired = synchronized(lock) {
                if (requests[request.id] === request && request.state == "running") {
                    request.state = "failed"; persist(); true
                } else false
            }
            if (expired) request.complete(Result.failure(IllegalStateException("外部Agent处理超时，请在DSH查看本轮任务")))
        }, remaining)
    }
    fun next(authorized: () -> Boolean): JSONObject {
        val deadline = System.currentTimeMillis() + 20_000
        synchronized(lock) {
            while (authorized() && requests.values.none { it.state == "queued" }) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) return JSONObject().put("request", JSONObject.NULL)
                lock.wait(minOf(remaining, 1_000))
            }
            check(authorized()) { "Agent入口已关闭或令牌已变更" }
            val request = requests.values.first { it.state == "queued" }
            request.state = "running"; request.claimedAt = System.currentTimeMillis(); persist(); scheduleTimeout(request)
            main.post { progress("本机外部Agent已接收；手机操作与审批请在Agent软件查看") }
            return JSONObject().put("request", request.json().put("createdFor", "openrayneo").put("expiresInSeconds", if (request.kind == "task") 600 else 90))
        }
    }
    fun list(): JSONArray = synchronized(lock) { JSONArray(requests.values.map { request ->
        JSONObject().put("id", request.id).put("state", request.state).put("kind", request.kind).put("sessionId", request.session)
            .put("claimedAt", request.claimedAt).put("createdAt", request.createdAt).put("recordId", request.input?.optString("recordId"))
            .put("backfill", request.input?.optBoolean("backfill") ?: false)
    }) }
    fun status(id: String): JSONObject = synchronized(lock) {
        val request = requests[id]
        JSONObject().put("id", id).put("state", request?.state ?: "cancelled").put("sessionId", request?.session.orEmpty())
    }
    fun update(id: String, body: JSONObject): JSONObject = synchronized(lock) {
        val request = checkNotNull(requests[id]) { "DSH请求已失效" }
        if (request.state == "completed" && body.optString("state") == "completed") return status(id)
        check(request.state == "running") { "DSH请求已结束或取消" }
        if (body.has("sessionId")) request.session = body.getString("sessionId")
        when (body.getString("state")) {
            "running" -> main.post { progress(body.optString("message", "DSH Go 正在处理任务")) }
            "completed" -> {
                val answer = body.getString("answer").trim()
                request.state = "completed"; request.answer = answer; persist()
                deliver(request)
            }
            "failed" -> {
                request.state = "failed"; persist()
                main.post { request.complete(Result.failure(IllegalStateException(body.optString("error", "DSH任务未完成，请打开DSH Go查看")))) }
            }
            else -> error("未知DSH任务状态")
        }
        if (request.state == "running") persist()
        status(id)
    }
    fun cancelRequest(id: String) = cancelMatching { it.id == id }
    fun cancelConversation(key: String) = cancelMatching { it.input?.optString("conversationKey") == key }
    private fun cancelMatching(matches: (Request) -> Boolean) = synchronized(lock) {
        requests.values.filter { it.state in setOf("queued", "running") && matches(it) }.forEach { request ->
            request.state = "cancelled"
            main.post { request.complete(Result.failure(IllegalStateException("DSH本次请求已取消；已执行操作保留"))) }
        }
        persist(); lock.notifyAll()
    }
    fun cancel(kind: String? = null) = synchronized(lock) {
        requests.values.filter { it.state in setOf("queued", "running") && (kind == null || kind == it.kind) }.forEach { request ->
            request.state = "cancelled"
            main.post { request.complete(Result.failure(IllegalStateException("DSH任务已取消；已执行的操作会保留"))) }
        }
        persist(); lock.notifyAll()
    }
}
