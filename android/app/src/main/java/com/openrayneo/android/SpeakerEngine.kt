// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import com.k2fsa.sherpa.onnx.*
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** All native inference runs on the conversation worker, never on the decoder or UI thread. */
internal class SpeakerEngine(context: Context, private val people: () -> List<VoicePerson>,
    private val threshold: () -> Float, private val classified: (Long, Long) -> Unit) {
    companion object {
        const val MODEL = "campplus-zh-16k-common/sherpa-2.0.1"
        // Top-3 mean against <=3 s enrollment windows; same-speaker CAM++ queries measure ~0.56-0.64, others <=0.20.
        const val DEFAULT_THRESHOLD = 0.5f
    }
    data class Evidence(val beginMS: Long, val endMS: Long, val speaker: String,
                        val personId: String?, val score: Float?, val mixed: Boolean, val embedding: FloatArray?)
    data class Assignment(val speaker: String = "未知", val personId: String? = null,
                          val score: Float? = null, val stable: Boolean = false, val mixed: Boolean = false,
                          val candidates: List<VoiceMatch> = emptyList(), val reason: String = "尚未取得足够清晰人声")
    private data class Cluster(val label: String, val samples: MutableList<FloatArray>, var lastSeenMS: Long)
    private val extractor = SpeakerEmbeddingExtractor(context.assets,
        SpeakerEmbeddingExtractorConfig("voice-models/campplus-zh-16k.onnx", numThreads = 1))
    private val vad = Vad(context.assets, VadModelConfig(
        sileroVadModelConfig = SileroVadModelConfig("voice-models/silero-vad.onnx", minSilenceDuration = 0.4f, maxSpeechDuration = 8f),
        sampleRate = 16000, numThreads = 1))
    private val diarizer = OfflineSpeakerDiarization(context.assets, OfflineSpeakerDiarizationConfig(
        segmentation = OfflineSpeakerSegmentationModelConfig(
            pyannote = OfflineSpeakerSegmentationPyannoteModelConfig("voice-models/segmentation.int8.onnx"), numThreads = 1),
        embedding = SpeakerEmbeddingExtractorConfig("voice-models/campplus-zh-16k.onnx", numThreads = 1),
        clustering = FastClusteringConfig(threshold = 0.65f), minDurationOn = 0.25f, minDurationOff = 0.3f))
    private var nextLabel = 0
    private var labelPrefix = ""
    private val clusters = mutableListOf<Cluster>()
    val evidence = mutableListOf<Evidence>()
    private var offsetMS = 0L
    private var keepHistory = false
    private var enrolling = false
    private val vadWindow = FloatArray(512)
    private var vadWindowSize = 0
    private var acceptedSamples = 0L
    var analyzedThroughMS = 0L; private set

    fun reset(offsetMS: Long = 0, meeting: Boolean = false, enrollment: Boolean = false, labelPrefix: String = "") {
        vad.reset(); vadWindowSize = 0; acceptedSamples = 0; analyzedThroughMS = offsetMS; evidence.clear(); clusters.clear(); nextLabel = 0; this.offsetMS = offsetMS; this.labelPrefix = labelPrefix; keepHistory = meeting; enrolling = enrollment
    }
    fun beginRound(offsetMS: Long) { flush(); vad.reset(); vadWindowSize = 0; acceptedSamples = 0; this.offsetMS = offsetMS; analyzedThroughMS = offsetMS }
    fun accept(samples: FloatArray) {
        acceptedSamples += samples.size
        // Native VAD merges multiple windows in one call. A fixed model window keeps
        // packet batches and desktop file imports on the same segmentation baseline.
        var first = 0
        while (first < samples.size) {
            val count = minOf(512 - vadWindowSize, samples.size - first)
            samples.copyInto(vadWindow, vadWindowSize, first, first + count)
            vadWindowSize += count; first += count
            if (vadWindowSize == 512) { vad.acceptWaveform(vadWindow); drain(); vadWindowSize = 0 }
        }
        val safe = if (vad.isSpeechDetected()) evidence.maxOfOrNull { it.endMS } ?: offsetMS
            else (offsetMS + acceptedSamples * 1000 / 16000 - 1000).coerceAtLeast(offsetMS)
        analyzedThroughMS = maxOf(analyzedThroughMS, safe)
    }
        // A completed VAD chunk is fully classified before this watermark advances.
    fun flush() {
        if (vadWindowSize > 0) { vad.acceptWaveform(FloatArray(512).also { vadWindow.copyInto(it, endIndex = vadWindowSize) }); vadWindowSize = 0 }
        vad.flush(); drain(); analyzedThroughMS = offsetMS + acceptedSamples * 1000 / 16000
    }

    private fun drain() {
        while (!vad.empty()) {
            val speech = vad.front()
            val samples = speech.samples
            val begin = offsetMS + speech.start * 1000 / 16000
            val end = begin + samples.size * 1000L / 16000
            vad.pop()
            if (enrolling) {
                if (samples.size < 12_800) {
                    evidence += Evidence(begin, end, "未知", null, null, false, null)
                    classified(begin, end); continue
                }
                // Guided, single-speaker registration: use VAD utterances directly. Meeting
                // diarization on sub-second/short utterances can invent extra speakers or discard
                // most of an otherwise useful utterance; it must not gate enrollment.
                for (first in samples.indices step 48000) {
                    val last = minOf(first + 48000, samples.size)
                    if (last - first < 12800) continue
                    val vector = embedding(samples.copyOfRange(first, last)) ?: continue
                    evidence += Evidence(begin + first * 1000L / 16000, begin + last * 1000L / 16000, "登记", null, null, false, vector)
                }
                evidence.removeAll { it.endMS < end - 60_000 }
                if (evidence.size > 30) evidence.subList(0, evidence.size - 30).clear()
                classified(begin, end); continue
            }
            val intervals = diarizer.process(samples).mapNotNull { turn ->
                val first = (turn.start * 16000).toInt().coerceIn(0, samples.size)
                val last = (turn.end * 16000).toInt().coerceIn(first, samples.size)
                if (last > first) SpeakerInterval(first, last, turn.speaker) else null
            }
            val regions = speakerRegions(intervals)
            val vectors = mutableMapOf<Int, FloatArray>()
            val labels = mutableMapOf<Int, String>()
            val matches = mutableMapOf<Int, Pair<String?, Float>?>()
            intervals.map { it.speaker }.distinct().forEach { speaker ->
                val clean = regions.filter { it.speakers == setOf(speaker) }
                val count = clean.sumOf { it.last - it.first }
                val vector = if (count >= 12_800) {
                    val audio = FloatArray(count)
                    var position = 0
                    clean.forEach { region ->
                        samples.copyInto(audio, position, region.first, region.last)
                        position += region.last - region.first
                    }
                    embedding(audio)
                } else null
                if (vector != null) vectors[speaker] = vector
                labels[speaker] = vector?.let { cluster(it, end).label } ?: "${labelPrefix}短段$begin-$speaker"
                matches[speaker] = vector?.let(::person)
            }
            regions.forEach { region ->
                val mixed = region.speakers.size > 1
                val speaker = region.speakers.first()
                val match = if (mixed) null else matches[speaker]
                evidence += Evidence(offsetMS + (speech.start.toLong() + region.first) * 1000 / 16000,
                    offsetMS + (speech.start.toLong() + region.last) * 1000 / 16000,
                    if (mixed) "未知" else labels.getValue(speaker), match?.first, match?.second, mixed,
                    if (mixed) null else vectors[speaker])
            }
            if (!keepHistory) { evidence.removeAll { it.endMS < end - 120_000 }; clusters.removeAll { it.lastSeenMS < end - 120_000 } }
            classified(begin, end)
        }
    }
    fun embedding(samples: FloatArray): FloatArray? {
        val stream = extractor.createStream()
        return try {
            stream.acceptWaveform(samples, 16000); stream.inputFinished()
            if (extractor.isReady(stream)) extractor.compute(stream) else null
        } finally { stream.release() }
    }
    private fun candidates(vector: FloatArray): List<VoiceMatch> = voiceIdentityReferences(people(), MODEL)
        .map { (person, samples) -> VoiceMatch(person.id, samples.map { cosine(vector, it) }
            .sortedDescending().take(3).average().toFloat()) }.sortedByDescending { it.score }
    private fun accepted(matches: List<VoiceMatch>): VoiceMatch? = matches.firstOrNull()?.takeIf {
        it.score >= threshold() && (matches.size < 2 || it.score - matches[1].score >= 0.08f)
    }
    private fun person(vector: FloatArray): Pair<String?, Float>? {
        val matches = candidates(vector)
        return matches.firstOrNull()?.let { accepted(matches)?.personId to it.score }
    }
    private fun cluster(vector: FloatArray, endMS: Long): Cluster {
        val nearest = clusters.map { cluster -> cluster to cluster.samples.maxOf { cosine(vector, it) } }.maxByOrNull { it.second }
        if (nearest != null && nearest.second >= 0.6f) {
            nearest.first.lastSeenMS = endMS
            if (nearest.first.samples.size < 5) nearest.first.samples += vector
            return nearest.first
        }
        val count = nextLabel++
        return Cluster(labelPrefix + if (count < 26) ('A'.code + count).toChar().toString() else "S${count + 1}", mutableListOf(vector), endMS).also { clusters += it }
    }
    fun assignment(beginMS: Long, endMS: Long, wordLevel: Boolean = false): Assignment {
        val covered = evidence.filter { min(it.endMS, endMS) > max(it.beginMS, beginMS) }
        if (covered.isEmpty()) return Assignment()
        fun duration(e: Evidence) = (min(e.endMS, endMS) - max(e.beginMS, beginMS)).coerceAtLeast(0)
        val mixed = covered.any { it.mixed } || (!wordLevel && covered.map { it.speaker }.filter { it != "未知" }.distinct().size > 1)
        val total = covered.sumOf(::duration).coerceAtLeast(1)
        val speaker = covered.groupBy { it.speaker }.maxBy { (_, list) -> list.sumOf(::duration) }
        // ASR timestamps include pauses. Identity coverage is measured over voiced evidence,
        // otherwise a clearly matched voice is discarded just because a sentence has silence.
        val stable = !mixed && speaker.key != "未知" && speaker.value.sumOf(::duration).toDouble() / total >= 0.85 && (wordLevel || total >= 700)
        val ranked = speaker.value.filter { !it.mixed && it.embedding != null }.flatMap { e ->
            candidates(e.embedding!!).map { it to duration(e) }
        }.groupBy { it.first.personId }.map { (id, votes) ->
            VoiceMatch(id, (votes.sumOf { it.first.score.toDouble() * it.second } / votes.sumOf { it.second }.coerceAtLeast(1)).toFloat())
        }.sortedByDescending { it.score }
        val known = speaker.value.filter { !it.mixed && it.embedding != null }
            .mapNotNull { e -> accepted(candidates(e.embedding!!))?.let { it.personId to duration(e) } }
            .groupBy { it.first }.maxByOrNull { (_, votes) -> votes.sumOf { it.second } }
        val identity = known?.takeIf { stable && it.value.sumOf { vote -> vote.second }.toDouble() / total >= 0.85 }?.key
        val reason = when {
            mixed -> "多人重叠，暂不确认身份"
            !stable -> "人声过短或同句包含多个说话人"
            ranked.isEmpty() -> "尚无已登记声音可比对"
            ranked.first().score < threshold() -> "最高相似度未达到确认阈值 ${"%.2f".format(threshold())}"
            ranked.size > 1 && ranked[0].score - ranked[1].score < 0.08f -> "两个候选声音接近，等待更多发言"
            identity == null -> "各片段匹配不一致，等待更多发言"
            else -> "已匹配登记声音"
        }
        return Assignment(speaker.key, identity, ranked.firstOrNull()?.score, stable, mixed, ranked.take(2), reason)
    }
    fun enrollment(): VoiceEnrollment.Assessment = VoiceEnrollment.assess(evidence.filter { !it.mixed && it.embedding != null }
        .map { VoiceEnrollment.Sample(it.beginMS, it.endMS, it.embedding!!) })
    fun speakerSamples(): Map<String, List<FloatArray>> = evidence.filter { !it.mixed && it.embedding != null && it.speaker != "未知" }
        .groupBy { it.speaker }.mapValues { (_, turns) -> turns.sortedByDescending { it.endMS - it.beginMS }.take(5).map { it.embedding!! } }
    fun close() { vad.release(); diarizer.release(); extractor.release() }
    private fun cosine(a: FloatArray, b: FloatArray): Float {
        if (a.size != b.size) return -1f
        var dot = 0.0; var aa = 0.0; var bb = 0.0
        for (i in a.indices) { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        return (dot / sqrt(aa * bb).coerceAtLeast(1e-12)).toFloat()
    }
}
