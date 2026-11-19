// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal enum class ConversationMode(val title: String) { DAILY("日常"), MEETING("会议"), ENROLL("声音登记") }
internal enum class ConversationSource(val title: String) { REALTIME("实时双麦"), NATIVE("小雷小雷"), ALWAYS_ON("全天智记") }
internal data class VoiceMatch(val personId: String, val score: Float) {
    fun json() = JSONObject().put("personId", personId).put("score", score)
}
/** One automatically learned self reference window (<=3 s, production enrollment chunking). */
internal data class AutoVoiceSample(val vector: FloatArray, val seconds: Float, val at: Long) {
    fun json() = JSONObject().put("vector", JSONArray(vector.toList())).put("seconds", seconds.toDouble()).put("at", at)
    companion object {
        fun parse(v: JSONObject) = AutoVoiceSample(v.getJSONArray("vector").let { row -> FloatArray(row.length()) { row.getDouble(it).toFloat() } },
            v.getDouble("seconds").toFloat(), v.getLong("at"))
        fun list(a: JSONArray?) = a?.let { List(it.length()) { i -> parse(it.getJSONObject(i)) } } ?: emptyList()
    }
}
internal data class VoicePerson(
    val id: String = UUID.randomUUID().toString(), val name: String, val self: Boolean = false,
    val contactUri: String? = null, val model: String = SpeakerEngine.MODEL,
    val samples: List<FloatArray> = emptyList(), val unnamed: Boolean = false,
    val revision: Int = 1, val changeSequence: Long = 0, val mergedInto: String? = null,
    /** Self only: references learned from native wake rounds (never replace manual [samples]) and windows awaiting a first consistent profile. */
    val autoSamples: List<AutoVoiceSample> = emptyList(), val autoPending: List<AutoVoiceSample> = emptyList(),
) {
    val references: List<FloatArray> get() = samples + autoSamples.map { it.vector }
    /** Voice vectors stay on the device: sync and local API rows carry identity fields only. */
    fun publicJson() = json().apply { remove("samples"); remove("autoSamples"); remove("autoPending") }
    fun json() = JSONObject().put("id", id).put("name", name).put("self", self).put("contactUri", contactUri)
        .put("model", model).put("samples", JSONArray(samples.map { JSONArray(it.toList()) }))
        .put("unnamed", unnamed).put("revision", revision).put("changeSequence", changeSequence).put("mergedInto", mergedInto)
        .put("autoSamples", JSONArray(autoSamples.map { it.json() })).put("autoPending", JSONArray(autoPending.map { it.json() }))
    companion object {
        fun parse(value: JSONObject) = VoicePerson(value.getString("id"), value.getString("name"), value.optBoolean("self"),
            value.optString("contactUri").takeIf { it.isNotBlank() && it != "null" }, value.getString("model"),
            value.optJSONArray("samples")?.let { list -> List(list.length()) { i -> list.getJSONArray(i).let { row -> FloatArray(row.length()) { row.getDouble(it).toFloat() } } } } ?: emptyList(), value.optBoolean("unnamed"), value.optInt("revision", 1), value.optLong("changeSequence"),
            value.optString("mergedInto").takeUnless { it.isBlank() || it == "null" },
            AutoVoiceSample.list(value.optJSONArray("autoSamples")), AutoVoiceSample.list(value.optJSONArray("autoPending")))
    }
}
/** PCM offsets remain continuous; official input rounds retain their independent wall-clock anchors. */
internal data class AudioAnchor(val offsetMS: Long, val receivedAt: Long) {
    fun json() = JSONObject().put("offsetMS", offsetMS).put("receivedAt", receivedAt).put("timeBasis", "received")
    companion object { fun parse(v: JSONObject) = AudioAnchor(v.getLong("offsetMS"), v.getLong("receivedAt")) }
}
internal data class SpeechWord(val text: String, val beginMS: Long, val endMS: Long) {
    fun json() = JSONObject().put("text", text).put("beginMS", beginMS).put("endMS", endMS)
    companion object { fun parse(v: JSONObject) = SpeechWord(v.getString("text"), v.getLong("beginMS"), v.getLong("endMS")) }
}
internal data class RecordDerived(
    val id: String = UUID.randomUUID().toString(), val recordId: String, val revision: Int = 1,
    val sourceRevision: Int, val kind: String, val text: String = "", val tags: List<String> = emptyList(),
    val agent: String = "local-agent", val updatedAt: Long = System.currentTimeMillis(), val stale: Boolean = false,
) {
    fun json() = JSONObject().put("id", id).put("recordId", recordId).put("revision", revision).put("sourceRevision", sourceRevision)
        .put("kind", kind).put("text", text).put("tags", JSONArray(tags)).put("agent", agent).put("updatedAt", updatedAt).put("stale", stale)
    companion object {
        fun parse(v: JSONObject) = RecordDerived(v.optString("id").ifBlank { UUID.randomUUID().toString() }, v.getString("recordId"),
            v.optInt("revision", 1), v.getInt("sourceRevision"), v.getString("kind"), v.optString("text"),
            v.optJSONArray("tags")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList(),
            v.optString("agent", "local-agent"), v.optLong("updatedAt", System.currentTimeMillis()), v.optBoolean("stale"))
    }
}
internal data class RecordSummary(val kind: String, val text: String, val createdAt: Long = System.currentTimeMillis(),
                                  val recordIds: List<String> = emptyList(), val stale: Boolean = false, val day: String = "") {
    fun json() = JSONObject().put("kind", kind).put("text", text).put("createdAt", createdAt).put("recordIds", JSONArray(recordIds)).put("stale", stale).put("day", day)
    companion object { fun parse(v: JSONObject) = RecordSummary(v.getString("kind"), v.getString("text"), v.getLong("createdAt"),
        v.optJSONArray("recordIds")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList(), v.optBoolean("stale"), v.optString("day")) }
}
internal data class SpeechSegment(
    val id: String, val beginMS: Long, val endMS: Long, val text: String,
    val speaker: String = "未知", val personId: String? = null, val matchScore: Float? = null,
    val stable: Boolean = false, val mixed: Boolean = false, val revision: Int = 0,
    val receivedAt: Long = System.currentTimeMillis(), val roundId: String? = null,
    val candidates: List<VoiceMatch> = emptyList(), val matchReason: String = "", val words: List<SpeechWord> = emptyList(), val timelineAt: Long = 0, val timeBasis: String = "received", val processingMode: String = "live", val timelineEndAt: Long = 0, val sourceChannel: Int = 1, val identityBasis: String = "unknown",
) {
    fun json() = JSONObject().put("id", id).put("beginMS", beginMS).put("endMS", endMS).put("text", text)
        .put("speaker", speaker).put("personId", personId).put("matchScore", matchScore)
        .put("stable", stable).put("mixed", mixed).put("revision", revision).put("receivedAt", receivedAt).put("roundId", roundId)
        .put("candidates", JSONArray(candidates.map { it.json() })).put("matchReason", matchReason).put("words", JSONArray(words.map { it.json() })).put("timelineAt", timelineAt).put("timeBasis", timeBasis).put("processingMode", processingMode).put("timelineEndAt", timelineEndAt).put("sourceChannel", sourceChannel).put("identityBasis", identityBasis)
    companion object {
        fun parse(v: JSONObject) = SpeechSegment(v.getString("id"), v.getLong("beginMS"), v.getLong("endMS"), v.getString("text"),
            v.optString("speaker", "未知"), v.optString("personId").takeIf { it.isNotBlank() && it != "null" },
            if (v.has("matchScore") && !v.isNull("matchScore")) v.getDouble("matchScore").toFloat() else null,
            v.optBoolean("stable"), v.optBoolean("mixed"), v.optInt("revision"), v.optLong("receivedAt"), v.optString("roundId").takeUnless { it.isBlank() || it == "null" },
            v.optJSONArray("candidates")?.let { a -> List(a.length()) { a.getJSONObject(it).let { c -> VoiceMatch(c.getString("personId"), c.getDouble("score").toFloat()) } } } ?: emptyList(), v.optString("matchReason"),
            v.optJSONArray("words")?.let { a -> List(a.length()) { SpeechWord.parse(a.getJSONObject(it)) } } ?: emptyList(), v.optLong("timelineAt"), v.optString("timeBasis", "legacy-estimate"), v.optString("processingMode", "live"), v.optLong("timelineEndAt"), v.optInt("sourceChannel", 1), v.optString("identityBasis", if (v.optString("matchReason") == "手动标注") "manual" else if (v.optBoolean("mixed")) "mixed" else if (!v.isNull("personId") && v.optString("personId").isNotBlank()) "voiceprint" else "unknown"))
    }
}
internal data class AttributedMemory(
    val id: String = UUID.randomUUID().toString(), val sourceIds: List<String>,
    val speakerId: String?, val subjectId: String?, val subject: String,
    val text: String, val kind: String = "陈述", val updatedAt: Long = System.currentTimeMillis(),
) {
    fun json() = JSONObject().put("id", id).put("sourceIds", JSONArray(sourceIds)).put("speakerId", speakerId)
        .put("subjectId", subjectId).put("subject", subject).put("text", text).put("kind", kind).put("updatedAt", updatedAt)
    companion object {
        fun parse(v: JSONObject) = AttributedMemory(v.getString("id"), v.getJSONArray("sourceIds").let { a -> List(a.length()) { a.getString(it) } },
            v.optString("speakerId").takeUnless { it.isBlank() || it == "null" }, v.optString("subjectId").takeUnless { it.isBlank() || it == "null" },
            v.getString("subject"), v.getString("text"), v.optString("kind", "陈述"), v.getLong("updatedAt"))
    }
}
internal data class ConversationRecord(
    val id: String = UUID.randomUUID().toString(), val mode: ConversationMode,
    val createdAt: Long = System.currentTimeMillis(), val title: String = mode.title + "记录",
    val segments: List<SpeechSegment> = emptyList(), val memories: List<AttributedMemory> = emptyList(),
    val summary: String = "", val summaryStale: Boolean = false,
    val speakerSamples: Map<String, List<FloatArray>> = emptyMap(), val audioSamples: Long = 0, val audioId: String? = null, val audioPending: Boolean = false,
    val speakerPeople: Map<String, String> = emptyMap(),
    val source: ConversationSource = ConversationSource.REALTIME, val endedAt: Long? = null,
    val revision: Int = 1, val changeSequence: Long = 0, val processingPending: Boolean = false,
    val derived: List<RecordDerived> = emptyList(), val summaries: List<RecordSummary> = emptyList(),
    val audioAnchors: List<AudioAnchor> = emptyList(), val audioChannels: Int = 1,
    val channelPolicy: String = "legacy_selected_mono", val processingCursors: Map<String, Long> = emptyMap(),
) {
    fun completedFrames(channel: Int): Long = processingCursors[channel.toString()] ?: segments.filter { it.sourceChannel == channel }.maxOfOrNull { it.endMS * 16 } ?: 0L
    fun anchorAt(offsetMS: Long): AudioAnchor? = audioAnchors.filter { it.offsetMS <= offsetMS }.maxByOrNull { it.offsetMS }
    fun timelineAt(offsetMS: Long): Long = anchorAt(offsetMS)
        ?.let { it.receivedAt + offsetMS - it.offsetMS } ?: createdAt + offsetMS
    fun timeOf(segment: SpeechSegment): Long = segment.timelineAt.takeIf { it > 0 } ?: timelineAt(segment.beginMS)
    fun endTimeOf(segment: SpeechSegment): Long = segment.timelineEndAt.takeIf { it > 0 }
        ?: if (audioAnchors.isNotEmpty()) timelineAt((segment.endMS - 1).coerceAtLeast(segment.beginMS)) + 1 else timeOf(segment) + segment.endMS - segment.beginMS
    fun json() = JSONObject().put("id", id).put("mode", mode.name).put("createdAt", createdAt).put("title", title)
        .put("segments", JSONArray(segments.map { it.json() })).put("memories", JSONArray(memories.map { it.json() }))
        .put("summary", summary).put("summaryStale", summaryStale).put("audioSamples", audioSamples).put("audioId", audioId).put("audioPending", audioPending)
        .put("speakerPeople", JSONObject(speakerPeople)).put("source", source.name).put("endedAt", endedAt ?: JSONObject.NULL)
        .put("revision", revision).put("changeSequence", changeSequence).put("processingPending", processingPending)
        .put("derived", JSONArray(derived.map { it.json() })).put("summaries", JSONArray(summaries.map { it.json() }))
        .put("audioAnchors", JSONArray(audioAnchors.map { it.json() })).put("audioChannels", audioChannels)
        .put("channelPolicy", channelPolicy).put("processingCursors", JSONObject(processingCursors))
        .put("speakerSamples", JSONObject().apply { speakerSamples.forEach { (id, samples) -> put(id, JSONArray(samples.map { JSONArray(it.toList()) })) } })
    companion object {
        fun parse(v: JSONObject) = ConversationRecord(v.getString("id"), ConversationMode.valueOf(v.getString("mode")), v.getLong("createdAt"), v.getString("title"),
            v.getJSONArray("segments").let { a -> List(a.length()) { SpeechSegment.parse(a.getJSONObject(it)) } },
            v.optJSONArray("memories")?.let { a -> List(a.length()) { AttributedMemory.parse(a.getJSONObject(it)) } } ?: emptyList(),
            v.optString("summary"), v.optBoolean("summaryStale"),
            v.optJSONObject("speakerSamples")?.let { rows -> rows.keys().asSequence().associateWith { key ->
                rows.getJSONArray(key).let { a -> List(a.length()) { i -> a.getJSONArray(i).let { row -> FloatArray(row.length()) { row.getDouble(it).toFloat() } } } }
            } } ?: emptyMap(), v.optLong("audioSamples"), v.optString("audioId").takeUnless { it.isBlank() || it == "null" }, v.optBoolean("audioPending"),
            v.optJSONObject("speakerPeople")?.let { rows -> rows.keys().asSequence().associateWith { rows.getString(it) } } ?: emptyMap(),
            ConversationSource.valueOf(v.optString("source", "REALTIME")), if (v.has("endedAt") && !v.isNull("endedAt")) v.getLong("endedAt") else null,
            v.optInt("revision", 1), v.optLong("changeSequence"), v.optBoolean("processingPending"),
            v.optJSONArray("derived")?.let { a -> List(a.length()) { RecordDerived.parse(a.getJSONObject(it)) } } ?: emptyList(),
            v.optJSONArray("summaries")?.let { a -> List(a.length()) { RecordSummary.parse(a.getJSONObject(it)) } } ?: emptyList(),
            v.optJSONArray("audioAnchors")?.let { a -> List(a.length()) { AudioAnchor.parse(a.getJSONObject(it)) } } ?: emptyList(), v.optInt("audioChannels", 1), v.optString("channelPolicy", "legacy_selected_mono"),
            v.optJSONObject("processingCursors")?.let { rows -> rows.keys().asSequence().associateWith { rows.getLong(it) } } ?: emptyMap())
    }
}
internal data class ConversationState(
    val activeRecord: ConversationRecord? = null,
    val lastHint: String = "",
    val running: Boolean = false, val mode: ConversationMode = ConversationMode.DAILY,
    val source: ConversationSource = ConversationSource.REALTIME, val status: String = "选择日常或会议后开始",
    val segments: List<SpeechSegment> = emptyList(), val people: List<VoicePerson> = emptyList(),
    val records: List<ConversationRecord> = emptyList(), val error: String? = null,
    val enrollmentSeconds: Float = 0f, val enrollmentReady: Boolean = false, val enrollmentCanConfirm: Boolean = false, val enrollmentTotalSeconds: Float = 0f, val decodedSeconds: Double = 0.0,
    val modelReady: Boolean = false, val summarizing: Boolean = false, val stopping: Boolean = false,
)
