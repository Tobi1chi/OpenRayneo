// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.os.Handler
import android.util.Base64
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.SecureRandom
import java.util.concurrent.Executors

/** Encounter transport adapter. Device tools remain exclusively on the loopback Agent API. */
internal class RecordSyncServer(private val settings: AppSettings, private val repository: ConversationRepository,
    private val audio: MeetingAudioStore, private val main: Handler, private val changed: () -> Unit) {
    private val network = Executors.newFixedThreadPool(4)
    private val clients = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    @Volatile private var socket: ServerSocket? = null
    @Volatile private var token = ""
    @Volatile var state = AgentServerState(notice = "相遇同步已关闭"); private set
    fun tokenForUser() = token
    fun addresses(): List<String> = NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
        .filter { !it.isLoopbackAddress && it is java.net.Inet4Address }.map { "http://${it.hostAddress}:${state.port}" }
    fun start() {
        if (socket != null) return
        val config = settings.read()
        token = config.optString("recordSyncToken").ifBlank {
            Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP or Base64.URL_SAFE)
        }
        val server = ServerSocket(config.optInt("recordSyncPort", 8767), 8, InetAddress.getByName("0.0.0.0"))
        socket = server
        config.put("recordSyncToken", token).put("recordSyncEnabled", true); settings.save(config)
        state = AgentServerState(true, server.localPort, "等待电脑相遇同步 · 音频仅按需传输"); changed()
        network.execute {
            try { while (!server.isClosed) {
                val client = server.accept(); clients.add(client)
                network.execute { try { handle(client) } finally { clients.remove(client); client.close() } }
            } } catch (error: java.io.IOException) {
                if (!server.isClosed) main.post { state = state.copy(notice = "同步入口中断：${error.message}"); changed() }
            }
        }
    }
    fun stop() {
        closeSocket()
        val config = settings.read(); config.put("recordSyncEnabled", false); settings.save(config)
        state = AgentServerState(notice = "相遇同步已关闭"); changed()
    }
    fun rotate() { stop(); val config = settings.read(); config.remove("recordSyncToken"); settings.save(config); start() }
    private fun closeSocket() { socket?.close(); socket = null; clients.forEach { it.close() }; clients.clear(); token = "" }
    fun close() { closeSocket(); network.shutdownNow() }
    private fun handle(client: Socket) {
        client.soTimeout = 10_000
        val output = client.getOutputStream()
        fun json(code: Int, data: JSONObject) {
            val bytes = data.toString().toByteArray()
            output.write("HTTP/1.1 $code Result\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${bytes.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
            output.write(bytes); output.flush()
        }
        try {
            val input = BufferedInputStream(client.getInputStream())
            fun line(): String {
                val bytes = java.io.ByteArrayOutputStream()
                while (true) { val value = input.read(); require(value >= 0); if (value == 10) break; bytes.write(value); require(bytes.size() <= 8192) }
                return bytes.toString("US-ASCII").trimEnd('\r')
            }
            val request = line().split(' '); require(request.size == 3)
            val headers = mutableMapOf<String, String>(); var total = 0
            while (true) { val row = line(); if (row.isEmpty()) break; total += row.length; require(total <= 16384)
                headers[row.substringBefore(':').lowercase()] = row.substringAfter(':').trim() }
            if (token.isEmpty() || headers["authorization"] != "Bearer $token") { json(401, JSONObject().put("error", "同步令牌无效")); return }
            if (headers.containsKey("origin")) { json(403, JSONObject().put("error", "不接受网页跨域调用")); return }
            val path = request[1].substringBefore('?')
            if (request[0] == "POST" && path == "/v1/sync/exchange") {
                require(!headers.containsKey("transfer-encoding"))
                val length = headers["content-length"]?.toInt() ?: 0; require(length in 1..2097152)
                val bytes = input.readNBytes(length); require(bytes.size == length)
                val body = JSONObject(bytes.toString(Charsets.UTF_8)); require(body.getInt("protocolVersion") == 1)
                val incoming = body.optJSONArray("derived")?.let { a -> List(a.length()) { RecordDerived.parse(a.getJSONObject(it)) } } ?: emptyList()
                val result = repository.exchange(body.optLong("cursor"), body.optInt("limit", 100), incoming)
                json(200, result)
                main.post { state = state.copy(notice = "上次同步 ${java.time.LocalTime.now().withNano(0)} · 原记录保存在手机"); changed() }
            } else if (request[0] == "GET" && path == "/v1/sync/audio") {
                val args = request[1].substringAfter('?', "").split('&').associate { row -> row.substringBefore('=') to URLDecoder.decode(row.substringAfter('=', ""), "UTF-8") }
                val record = repository.records.firstOrNull { it.id == args["recordId"] }
                if (record == null) { json(404, JSONObject().put("error", "没有可用音频")); return }
                if (record.audioPending) { json(409, JSONObject().put("error", "音频尚在写入")); return }
                if (record.audioSamples == 0L) { json(404, JSONObject().put("error", "没有可用音频")); return }
                output.write("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: ${44 + record.audioSamples * 2 * record.audioChannels}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
                audio.exportWav(record.audioId ?: record.id, record.audioSamples, output); output.flush()
            } else json(404, JSONObject().put("error", "没有这个同步入口"))
        } catch (error: Exception) { if (!client.isClosed) runCatching { json(400, JSONObject().put("error", error.message ?: "同步未完成")) } }
    }
}
