// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.os.Handler
import android.os.Looper
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class MobileAgent(private val settings: AppSettings, private val changed: () -> Unit,
    private val tool: (String, JSONObject, (Result<JSONObject>) -> Unit) -> Unit,
    private val finalAnswer: (String, String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
    @Volatile private var call: Call? = null
    @Volatile private var generation = 0
    @Volatile private var pendingTool: CountDownLatch? = null
    private var history = JSONArray()
    var running = false; private set
    var status = "填写模型配置后即可使用"; private set
    var answer = ""; private set
    var question = ""; private set

    fun submit(text: String) {
        check(!running) { "请等待回答，或先停止" }
        val config = settings.read()
        val base = config.optString("modelUrl").trim().trimEnd('/')
        val uri = URI(base)
        require(uri.scheme == "https" && uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null) { "模型服务地址必须使用 HTTPS，且不包含密钥或查询参数" }
        val token = config.optString("modelKey")
        val model = config.optString("modelName").trim()
        require(token.isNotBlank() && model.isNotEmpty()) { "请在设置中填写模型名和 API Key" }
        val endpoint = if (base.endsWith("/chat/completions")) base else "$base/chat/completions"
        val session = ++generation
        question = text; running = true; answer = ""; status = "手机 Agent 正在思考…"; changed()
        val messages = JSONArray(history.toString())
        if (messages.length() == 0) messages.put(JSONObject().put("role", "system").put("content",
            "你是 OpenRayneo 手机助手，使用中文简洁回答。工具结果才是执行事实。用户在高德 App 中启动导航，本应用只读取用户选定的高德通知，不负责路线规划。不能编造方向、距离、路况或已执行的操作。停止眼镜跟随不会停止高德导航。"))
        messages.put(JSONObject().put("role", "user").put("content", text))
        worker.execute {
            try {
                var finished = false
                for (round in 0 until 6) {
                    check(session == generation) { "已取消" }
                    val body = JSONObject().put("model", model).put("messages", messages).put("stream", true).put("tools", tools())
                    val request = okhttp3.Request.Builder().url(endpoint).header("Authorization", "Bearer $token")
                        .post(body.toString().toRequestBody("application/json".toMediaType())).build()
                    val currentCall = http.newCall(request); call = currentCall
                    val result = currentCall.execute().use { response ->
                        check(response.isSuccessful) { "模型请求失败：HTTP ${response.code}，请核对地址、模型及额度" }
                        val responseBody = checkNotNull(response.body)
                        if (responseBody.contentType()?.subtype?.contains("event-stream") == true) {
                            readStream(responseBody, session)
                        } else JSONObject(responseBody.string()).getJSONArray("choices").getJSONObject(0).getJSONObject("message")
                    }
                    check(session == generation) { "已取消" }
                    messages.put(result)
                    val calls = result.optJSONArray("tool_calls")
                    if (calls == null || calls.length() == 0) {
                        val textResult = result.optString("content").takeIf { it != "null" }.orEmpty()
                        main.post {
                            if (session == generation) {
                                history = messages
                                answer = textResult; running = false; status = "回答完成"; changed()
                                if (textResult.isNotBlank()) finalAnswer(text, textResult)
                            }
                        }
                        finished = true; break
                    }
                    for (i in 0 until calls.length()) {
                        val invocation = calls.getJSONObject(i)
                        val function = invocation.getJSONObject("function")
                        val name = function.getString("name")
                        val args = JSONObject(function.optString("arguments").ifBlank { "{}" })
                        val latch = CountDownLatch(1)
                        pendingTool = latch
                        var output: Result<JSONObject> = Result.failure(IllegalStateException("工具超时，执行结果未知；请查询状态"))
                        main.post {
                            if (session != generation) { latch.countDown(); return@post }
                            status = "执行工具：$name"; changed()
                            try { tool(name, args) { output = it; latch.countDown() } }
                            catch (error: Exception) { output = Result.failure(error); latch.countDown() }
                        }
                        latch.await(45, TimeUnit.SECONDS)
                        pendingTool = null
                        check(session == generation) { "已取消" }
                        val value = output.getOrElse { JSONObject().put("error", it.message) }
                        messages.put(JSONObject().put("role", "tool").put("tool_call_id", invocation.getString("id")).put("content", value.toString()))
                    }
                }
                check(finished) { "本次工具调用已达到上限，请查看当前状态后继续" }
            } catch (error: Exception) {
                main.post { if (session == generation) { running = false; status = error.message ?: "模型连接失败"; changed() } }
            } finally { if (session == generation) call = null }
        }
    }

    private fun readStream(body: ResponseBody, session: Int): JSONObject {
        val content = StringBuilder()
        val calls = sortedMapOf<Int, JSONObject>()
        var ended = false
        val source = body.source()
        while (!source.exhausted()) {
            check(session == generation) { "已取消" }
            val line = source.readUtf8Line() ?: break
            if (!line.startsWith("data:")) continue
            val data = line.substring(5).trim()
            if (data == "[DONE]") { ended = true; break }
            val payload = JSONObject(data)
            check(!payload.has("error")) { "模型返回流式错误" }
            val choice = payload.optJSONArray("choices")?.optJSONObject(0) ?: continue
            if (!choice.isNull("finish_reason")) {
                check(choice.optString("finish_reason") in setOf("stop", "tool_calls", "function_call")) { "模型回答未完整结束：${choice.optString("finish_reason")}" }
                ended = true
            }
            val delta = choice.optJSONObject("delta") ?: continue
            if (!delta.isNull("content")) {
                content.append(delta.optString("content"))
                check(content.length <= 48000) { "模型回答过长" }
                val text = content.toString()
                main.post { if (session == generation) { answer = text; changed() } }
            }
            delta.optJSONArray("tool_calls")?.let { parts -> for (i in 0 until parts.length()) {
                val part = parts.getJSONObject(i)
                val value = calls.getOrPut(part.getInt("index")) { JSONObject().put("type", "function").put("function", JSONObject().put("name", "").put("arguments", "")) }
                if (part.has("id")) value.put("id", part.getString("id"))
                part.optJSONObject("function")?.let { incoming ->
                    val function = value.getJSONObject("function")
                    for (key in listOf("name", "arguments")) if (!incoming.isNull(key)) function.put(key, function.optString(key) + incoming.optString(key))
                }
            } }
        }
        check(ended) { "模型连接提前结束，请重试" }
        return JSONObject().put("role", "assistant").put("content", content.toString()).apply {
            if (calls.isNotEmpty()) put("tool_calls", JSONArray(calls.values.toList()))
        }
    }

    private fun tools(): JSONArray {
        fun definition(name: String, description: String, vararg fields: Pair<String, String>): JSONObject {
            val properties = JSONObject()
            fields.forEach { (key, description) -> properties.put(key, JSONObject().put("type", "string").put("description", description)) }
            return JSONObject().put("type", "function").put("function", JSONObject().put("name", name).put("description", description)
                .put("parameters", JSONObject().put("type", "object").put("properties", properties).put("required", JSONArray(fields.map { it.first })).put("additionalProperties", false)))
        }
        return JSONArray().put(definition("navigation_status", "读取当前高德通知跟随状态，不推断路线"))
            .put(definition("stop_navigation_mirroring", "停止眼镜导航跟随，保留高德 App 正在进行的导航"))
            .put(definition("show_notification", "向眼镜发送短通知", "title" to "标题", "body" to "正文"))
    }
    fun cancel() { generation++; call?.cancel(); call = null; pendingTool?.countDown(); running = false; status = "已停止；已执行的工具操作会保留"; changed() }
    fun clear() { cancel(); history = JSONArray(); question = ""; answer = ""; changed() }
    fun close() { cancel(); worker.shutdownNow() }
}
