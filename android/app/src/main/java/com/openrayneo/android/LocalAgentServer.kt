// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal data class AgentServerState(val enabled: Boolean = false, val port: Int = 0, val notice: String = "本机Agent入口已关闭")
/** Explicitly enabled, loopback-only API. No model credentials, raw audio or voice vectors are returned. */
internal class LocalAgentServer(private val main: Handler, private val settings: AppSettings, private val changed: () -> Unit,
    private val status: () -> JSONObject, private val records: () -> JSONArray,
    private val execute: (String, JSONObject, () -> Boolean, (Result<JSONObject>) -> Unit) -> Unit,
    private val harness: () -> DshRelay,
    private val recordAPI: (String, String, JSONObject) -> JSONObject?) {
    private data class Task(val id: String = UUID.randomUUID().toString(), val createdAt: Long = System.currentTimeMillis(),
        @Volatile var cancelled: Boolean = false, var state: String = "running", var result: JSONObject? = null, var error: String? = null)
    private val tasks = linkedMapOf<String, Task>() // Main-thread owned.
    private val network = Executors.newFixedThreadPool(3)
    private val slots = java.util.concurrent.Semaphore(8)
    private val clients = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    @Volatile private var socket: ServerSocket? = null
    @Volatile private var token = ""
    var state = AgentServerState(); private set
    fun tokenForUser(): String = token
    fun start() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (socket != null) return
        val config = settings.read()
        token = config.optString("localAgentToken").ifBlank {
            Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP or Base64.URL_SAFE).also {
                config.put("localAgentToken", it); settings.save(config)
            }
        }
        config.put("localAgentEnabled", true); settings.save(config)
        val server = ServerSocket(config.optInt("localAgentPort", 8766), 8, InetAddress.getByName("127.0.0.1")); socket = server
        state = AgentServerState(true, server.localPort, "仅本机监听 · 请求需独立Bearer令牌"); changed()
        network.execute {
            try { while (!server.isClosed) { val client = server.accept(); if (!slots.tryAcquire()) client.close() else {
                clients.add(client); network.execute { try { handle(client) } finally { clients.remove(client); client.close(); slots.release() } }
            } } }
            catch (error: java.io.IOException) { if (!server.isClosed) main.post { state = state.copy(notice = "Agent入口中断：${error.message}"); stop() } }
        }
    }
    fun stop(persistSetting: Boolean = true) {
        if (persistSetting) { val config = settings.read(); config.put("localAgentEnabled", false); settings.save(config) }
        socket?.close(); socket = null; token = ""
        clients.forEach { it.close() }; clients.clear()
        tasks.values.forEach { it.cancelled = true }; tasks.clear()
        state = AgentServerState(); changed()
    }
    fun rotate() { stop(); val config = settings.read(); config.remove("localAgentToken"); settings.save(config); start() }
    private fun handle(client: Socket) = client.use { connection ->
        connection.soTimeout = 5_000
        var code = 200
        val response: JSONObject = try {
            val input = BufferedInputStream(connection.getInputStream())
            fun line(): String {
                val out = java.io.ByteArrayOutputStream()
                while (true) { val b = input.read(); require(b >= 0) { "HTTP头未结束" }; if (b == 10) break; out.write(b); require(out.size() <= 8192) }
                return out.toString(Charsets.US_ASCII.name()).trimEnd('\r')
            }
            val request = line().split(' '); require(request.size == 3)
            val headers = mutableMapOf<String, String>(); var headerBytes = 0
            while (true) { val value = line(); headerBytes += value.length; require(headerBytes <= 16384); if (value.isEmpty()) break
                require(value.contains(':')); headers[value.substringBefore(':').lowercase()] = value.substringAfter(':').trim() }
            if (token.isEmpty() || headers["authorization"] != "Bearer $token") { code = 401; JSONObject().put("error", "Bearer令牌无效") }
            else if (headers.containsKey("origin")) { code = 403; JSONObject().put("error", "不接受网页跨域调用") }
            else {
                require(!headers.containsKey("transfer-encoding")) { "请使用Content-Length" }
                val length = headers["content-length"]?.toInt() ?: 0; require(length in 0..262144)
                val bytes = input.readNBytes(length); require(bytes.size == length)
                val body = if (bytes.isEmpty()) JSONObject() else JSONObject(bytes.toString(Charsets.UTF_8))
                val authorized = headers["authorization"]
                if (request[0] == "GET" && request[1] == "/v1/harness/next") {
                    harness().next { socket != null && authorized == "Bearer $token" }
                } else mainResult {
                    check(socket != null && authorized == "Bearer $token") { "Agent入口已关闭或令牌已变更" }
                    tasks.entries.removeAll { System.currentTimeMillis() - it.value.createdAt > 120_000 }
                    val path = request[1]
                    when {
                        path.substringBefore('?').startsWith("/v1/records") || path.startsWith("/v1/conversations/") || path.startsWith("/v1/conversations?") ->
                            recordAPI(request[0], path, body) ?: JSONObject().put("error", "没有这个记录入口").also { code = 404 }
                        request[0] == "GET" && path == "/v1/status" -> status()
                        request[0] == "GET" && path == "/v1/tools" -> JSONObject().put("tools", CompanionTools.definitions())
                        request[0] == "GET" && path == "/v1/conversations" -> JSONObject().put("items", records())
                        request[0] == "GET" && path == "/v1/harness/requests" -> JSONObject().put("items", harness().list())
                        request[0] == "GET" && path == "/v1/tasks" -> JSONObject().put("items", JSONArray(tasks.values.map { taskJSON(it).put("createdAt", it.createdAt) }))
                        request[0] == "GET" && path.startsWith("/v1/harness/requests/") -> harness().status(path.substringAfterLast('/'))
                        request[0] == "POST" && path.startsWith("/v1/harness/requests/") -> harness().update(path.substringAfterLast('/'), body)
                        request[0] == "GET" && path.startsWith("/v1/tasks/") -> taskJSON(checkNotNull(tasks[path.substringAfterLast('/')]) { "任务不存在或已过期" })
                        request[0] == "POST" && path.startsWith("/v1/tasks/") && path.endsWith("/cancel") -> {
                            val task = checkNotNull(tasks[path.removeSuffix("/cancel").substringAfterLast('/')]); task.cancelled = true; task.state = "cancelled"
                            taskJSON(task).put("message", "后续设备写入已取消，已经执行的操作会保留")
                        }
                        request[0] == "POST" && path == "/v1/tools/call" -> {
                            check(tasks.size < 32) { "待处理任务过多，请等待或取消" }
                            val name = body.getString("name"); val args = body.optJSONObject("arguments") ?: JSONObject()
                            require((0 until CompanionTools.definitions().length()).any { CompanionTools.definitions().getJSONObject(it).getJSONObject("function").getString("name") == name }) { "未知工具" }
                            if (CompanionTools.mutates(name)) require(args.optString("request_id").isNotBlank()) { "写入操作须提供稳定request_id以避免重试重复" }
                            val task = Task(); tasks[task.id] = task
                            try { execute(name, args, { !task.cancelled && System.currentTimeMillis() - task.createdAt < 120_000 }) { result ->
                                if (!task.cancelled) { task.state = if (result.isSuccess) "completed" else "failed"; task.result = result.getOrNull(); task.error = result.exceptionOrNull()?.message }
                            } } catch (error: Exception) { task.state = "failed"; task.error = error.message }
                            taskJSON(task)
                        }
                        else -> { code = 404; JSONObject().put("error", "没有这个API入口") }
                    }
                }
            }
        } catch (error: Exception) { code = 400; JSONObject().put("error", error.message ?: "请求未完成") }
        val bytes = response.toString().toByteArray(Charsets.UTF_8)
        try { connection.getOutputStream().apply {
            write("HTTP/1.1 $code ${if (code == 200) "OK" else "Error"}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${bytes.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII)); write(bytes); flush()
        } } catch (_: java.io.IOException) { /* Client closed its own request. */ }
    }
    private fun mainResult(action: () -> JSONObject): JSONObject {
        val latch = CountDownLatch(1); var result: Result<JSONObject>? = null
        main.post { result = runCatching(action); latch.countDown() }
        check(latch.await(5, TimeUnit.SECONDS)) { "主服务未响应" }; return checkNotNull(result).getOrThrow()
    }
    private fun taskJSON(task: Task) = JSONObject().put("id", task.id).put("state", task.state).put("result", task.result).put("error", task.error)
    fun close() { stop(false); network.shutdownNow() }
}
