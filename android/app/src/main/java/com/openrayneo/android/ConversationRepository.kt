// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypted authoritative phone records; every available voice is retained while capture is enabled. */
internal class ConversationRepository(context: Context) {
    private val folder = File(context.filesDir, "conversations").apply { mkdirs() }
    private val alias = "openrayneo.conversations"
    var people = read("people")?.optJSONArray("people")?.let { a -> List(a.length()) { VoicePerson.parse(a.getJSONObject(it)) } } ?: emptyList()
        private set
    var records: List<ConversationRecord> = folder.listFiles().orEmpty().filter { it.name.startsWith("session-") && it.name.endsWith(".enc") }
        .map { ConversationRecord.parse(checkNotNull(read(it.name.removeSuffix(".enc")))) }.sortedByDescending { it.createdAt }
        private set

    private var sequence = (records.map { it.changeSequence } + people.map { it.changeSequence }).maxOrNull() ?: 0L
    init {
        // Older encrypted records keep their IDs/audio references and join the first full sync.
        people.filter { it.changeSequence == 0L }.forEach { savePerson(it) }
        records.filter { it.changeSequence == 0L }.forEach { save(it) }
    }
    private fun writePeople() = write("people", JSONObject().put("people", JSONArray(people.map { it.json() })))
    @Synchronized fun savePerson(person: VoicePerson) {
        val old = people.firstOrNull { it.id == person.id }
        // Automatic samples are the wearer's voice and only live on the current self.
        val updated = person.copy(revision = (old?.revision ?: 0) + 1, changeSequence = ++sequence,
            autoSamples = if (person.self) person.autoSamples else emptyList(), autoPending = if (person.self) person.autoPending else emptyList())
        // Automatic samples belong to whoever is self; a replaced self must not keep them.
        people = people.filter { it.id != person.id }.map { if (person.self && it.self) it.copy(self = false, autoSamples = emptyList(), autoPending = emptyList(),
            revision = it.revision + 1, changeSequence = ++sequence) else it } + updated
        writePeople()
    }
    @Synchronized fun removeVoice(personId: String) { people.firstOrNull { it.id == personId }?.let { savePerson(it.copy(samples = emptyList(), autoSamples = emptyList(), autoPending = emptyList())) } }
    @Synchronized fun clearAutoSamples(personId: String) { people.firstOrNull { it.id == personId }?.let { savePerson(it.copy(autoSamples = emptyList(), autoPending = emptyList())) } }
    @Synchronized fun learnSelf(windows: List<Pair<FloatArray, Float>>): SelfVoiceLearning.Outcome {
        val self = ensureSelf()
        val (updated, outcome) = SelfVoiceLearning.apply(self, windows)
        if (updated !== self) savePerson(updated)
        return outcome
    }
    @Synchronized fun ensureSelf(): VoicePerson = people.firstOrNull { it.self && it.mergedInto == null } ?: VoicePerson(name = "我", self = true).let {
        savePerson(it); people.first { person -> person.id == it.id }
    }
    @Synchronized fun rememberUnnamed(samples: List<FloatArray>): VoicePerson {
        val person = VoicePerson(name = "未命名人物${people.count { it.unnamed } + 1}", samples = samples.takeLast(10), unnamed = true)
        savePerson(person)
        return people.first { it.id == person.id }
    }
    @Synchronized fun bindSpeakerVoice(record: ConversationRecord, label: String, person: VoicePerson, rememberVoice: Boolean): VoicePerson {
        val target = people.firstOrNull { it.id == person.id } ?: person
        val samples = record.speakerSamples[label].orEmpty()
        val source = people.firstOrNull { it.id == record.speakerPeople[label] }
        savePerson(if (rememberVoice) target.copy(samples = (target.samples + samples).takeLast(20), unnamed = false) else target)
        // This source ID was captured before the explicit binding replaces the record map.
        // Keep historical IDs and samples; only retire the anonymous identity reference.
        if (rememberVoice && samples.isNotEmpty() && source != null && source.id != target.id &&
            source.unnamed && !source.self && source.mergedInto == null) {
            savePerson(source.copy(mergedInto = target.id))
        }
        return people.first { it.id == target.id }
    }
    private fun sourceJSON(record: ConversationRecord) = record.json().apply {
        listOf("revision", "changeSequence", "derived").forEach(::remove)
    }.toString()
    @Synchronized fun save(record: ConversationRecord): ConversationRecord {
        require(record.mode != ConversationMode.ENROLL)
        val old = records.firstOrNull { it.id == record.id }
        val sourceChanged = old == null || sourceJSON(old) != sourceJSON(record)
        val version = if (sourceChanged) (old?.revision ?: 0) + 1 else old!!.revision
        val derived = (old?.derived.orEmpty() + record.derived).groupBy { it.id }.values.map { entries -> entries.maxBy { it.revision } }
            .map { if (it.sourceRevision != version) it.copy(stale = true) else it }
        val segmentsChanged = old?.segments?.map { it.json().toString() } != record.segments.map { it.json().toString() }
        val changedDays = if (segmentsChanged) (old?.segments.orEmpty().map { old!!.timeOf(it) } + record.segments.map { record.timeOf(it) })
            .map { java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString() }.toSet() else emptySet()
        val saved = record.copy(revision = version, changeSequence = ++sequence, derived = derived,
            summaries = record.summaries.map { if (it.kind == "day_end" && it.day in changedDays) it.copy(stale = true) else it })
        write("session-" + saved.id, saved.json())
        records = (records.filter { it.id != saved.id } + saved).sortedByDescending { it.createdAt }
        if (changedDays.isNotEmpty()) records.filter { row -> row.id != saved.id && row.summaries.any { it.kind == "day_end" && it.day in changedDays && !it.stale } }.forEach { row ->
            save(row.copy(summaries = row.summaries.map { if (it.kind == "day_end" && it.day in changedDays) it.copy(stale = true) else it }))
        }
        return saved
    }
    @Synchronized fun correctSpeaker(recordId: String, segmentIds: Set<String>, personId: String?) {
        val old = records.first { it.id == recordId }
        val person = people.firstOrNull { it.id == personId }
        val changed = old.segments.map { if (it.id in segmentIds) it.copy(personId = person?.id,
            stable = true, mixed = false, matchScore = null, candidates = emptyList(), matchReason = "手动标注", identityBasis = "manual", revision = it.revision + 1) else it }
        save(old.copy(segments = changed, summaryStale = true, summaries = old.summaries.map { it.copy(stale = true) }))
        // Day summaries may include multiple source records.
        records.filter { row -> row.id != recordId && row.summaries.any { recordId in it.recordIds } }.forEach { row ->
            save(row.copy(summaryStale = true, summaries = row.summaries.map { if (recordId in it.recordIds) it.copy(stale = true) else it }))
        }
    }
    @Synchronized fun correctMemory(recordId: String, memoryId: String, subject: String, text: String) {
        val old = records.first { it.id == recordId }
        save(old.copy(memories = old.memories.map { if (it.id == memoryId) it.copy(subjectId = null, subject = subject, text = text,
            updatedAt = System.currentTimeMillis()) else it }, summaryStale = true))
    }
    @Synchronized fun mergePeople(sourceIds: Set<String>, targetId: String, recordIds: Set<String>) {
        val target = people.first { it.id == targetId }
        val sources = people.filter { it.id in sourceIds && it.id != targetId }
        val self = target.self || sources.any { it.self }
        val auto = if (self) (target.autoSamples + sources.flatMap { it.autoSamples }).sortedBy { it.at }.takeLast(SelfVoiceLearning.MAX_AUTO) else emptyList()
        sources.forEach { savePerson(it.copy(mergedInto = targetId, self = false, autoSamples = emptyList(), autoPending = emptyList())) }
        savePerson(people.first { it.id == targetId }.copy(samples = (target.samples + sources.flatMap { it.samples }).takeLast(20), self = self, autoSamples = auto))
        records.filter { it.id in recordIds }.forEach { row ->
            correctSpeaker(row.id, row.segments.filter { it.personId in sourceIds }.map { it.id }.toSet(), targetId)
        }
    }
    @Synchronized fun applyDerived(item: RecordDerived): Boolean {
        require(item.kind in setOf("analysis", "note", "tags")) { "kind应为analysis/note/tags" }
        val old = records.firstOrNull { it.id == item.recordId } ?: return false
        if (old.derived.any { it.id == item.id && it.revision >= item.revision }) return true
        val updated = item.copy(stale = item.stale || item.sourceRevision != old.revision)
        val saved = old.copy(derived = old.derived.filter { it.id != item.id } + updated, changeSequence = ++sequence)
        write("session-" + saved.id, saved.json())
        records = records.map { if (it.id == saved.id) saved else it }
        return true
    }
    @Synchronized fun exchange(cursor: Long, limit: Int, incoming: List<RecordDerived>): JSONObject {
        val accepted = incoming.filter { applyDerived(it) }.map { it.id }
        val changes = (records.filter { it.changeSequence > cursor }.map { it.changeSequence to it.json().apply { remove("speakerSamples") } } +
            people.filter { it.changeSequence > cursor }.map { it.changeSequence to it.publicJson() }).sortedBy { it.first }
        val page = changes.take(limit.coerceIn(1, 100))
        return JSONObject().put("protocolVersion", 1).put("cursor", page.lastOrNull()?.first ?: cursor).put("hasMore", page.size < changes.size)
            .put("records", JSONArray(page.filter { it.second.has("segments") }.map { it.second }))
            .put("people", JSONArray(page.filter { !it.second.has("segments") }.map { it.second }))
            .put("acceptedDerivedIds", JSONArray(accepted))
    }
    @Synchronized fun query(from: Long = Long.MIN_VALUE, to: Long = Long.MAX_VALUE, id: String = "", text: String = ""): JSONArray =
        JSONArray(records.filter { row -> row.createdAt < to && (row.endedAt ?: if (row.audioPending) System.currentTimeMillis() else row.segments.maxOfOrNull { row.endTimeOf(it) } ?: row.createdAt) > from &&
            (id.isBlank() || row.id == id) && (text.isBlank() || row.title.contains(text, true) || row.segments.any { it.text.contains(text, true) } ||
            row.derived.any { it.text.contains(text, true) || it.tags.any { tag -> tag.contains(text, true) } }) }.map { it.json().apply { remove("speakerSamples") } })
    private fun Long?.orEmptyLong() = this ?: 0L
    @Synchronized fun readAgentOutbox(): JSONArray = read("agent-outbox")?.optJSONArray("items") ?: JSONArray()
    @Synchronized fun saveAgentOutbox(items: JSONArray) = write("agent-outbox", JSONObject().put("items", items))
    @Synchronized private fun read(name: String): JSONObject? {
        val file = AtomicFile(File(folder, "$name.enc"))
        if (!file.baseFile.exists() && !File(folder, "$name.enc.bak").exists()) return null
        val bytes = file.openRead().use { it.readBytes() }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }
    private fun write(name: String, data: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val bytes = cipher.iv + cipher.doFinal(data.toString().toByteArray(Charsets.UTF_8))
        val file = AtomicFile(File(folder, "$name.enc"))
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
}
