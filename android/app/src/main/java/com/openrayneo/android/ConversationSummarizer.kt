// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

internal class ConversationSummarizer {
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
    @Volatile private var call: Call? = null
    fun summarize(record: ConversationRecord, people: List<VoicePerson>, config: JSONObject): ConversationRecord {
        val endpoint = MobileModelEndpoint.resolve(config.optString("modelUrl"), config.optString("modelKey"))
        val body = JSONObject().put("model", config.getString("modelName")).put("stream", false)
            .put("messages", JSONArray().put(JSONObject().put("role", "system").put("content",
                ConversationPrompts.render(config.optString("memoryPrompt"), ConversationPrompts.memory) +
                    "\n返回JSON：summary字符串，memories数组；每项含source_ids数组、subject、text、kind，可选subject_id。每项必须引用已有原句ID。"))
                .put(JSONObject().put("role", "user").put("content", JSONObject().put("mode", record.mode.name)
                    .put("people", JSONArray(people.map { JSONObject().put("id", it.id).put("name", it.name).put("self", it.self) }))
                    .put("segments", JSONArray(record.segments.map { it.json() })).toString())))
        val request = Request.Builder().url(endpoint).apply {
            config.optString("modelKey").takeIf { it.isNotBlank() }?.let { header("Authorization", "Bearer $it") }
        }.post(body.toString().toRequestBody("application/json".toMediaType())).build()
        val current = http.newCall(request); call = current
        return current.execute().use { response ->
            check(response.isSuccessful) { "记忆整理失败：HTTP ${response.code}" }
            val objectBody = JSONObject(checkNotNull(response.body).string())
            val choice = objectBody.getJSONArray("choices").getJSONObject(0)
            check(choice.optString("finish_reason") == "stop") { "记忆整理未完整返回" }
            val content = choice.getJSONObject("message").getString("content").trim()
                .removePrefix("```json").removePrefix("```").removeSuffix("```").trim()
            val result = JSONObject(content); val sources = record.segments.associateBy { it.id }
            val memories = result.getJSONArray("memories")
            val facts = (0 until memories.length()).map { index ->
                val item = memories.getJSONObject(index)
                val ids = item.getJSONArray("source_ids").let { list -> List(list.length()) { list.getString(it) } }
                check(ids.isNotEmpty() && ids.all { it in sources }) { "模型记忆引用了不存在的原文，未保存" }
                val speakerIds = ids.map { sources[it]?.personId }.distinct()
                val subjectId = item.optString("subject_id").takeIf { id -> people.any { it.id == id } }
                AttributedMemory(sourceIds = ids, speakerId = speakerIds.singleOrNull(), subjectId = subjectId,
                    subject = item.getString("subject"), text = item.getString("text"), kind = item.optString("kind", "陈述"))
            }
            record.copy(memories = facts, summary = result.getString("summary"), summaryStale = false)
        }
    }
    fun cancel() { call?.cancel() }
    fun close() { cancel(); http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
}
