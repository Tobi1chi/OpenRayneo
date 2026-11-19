// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import kotlin.math.sqrt

/**
 * Native wake rounds are the wearer's by user policy, so their speech refreshes the self profile.
 * Mirrors Mac LocalVoiceSelfLearning: bootstrap needs an enrollment-grade consistent group; afterwards a
 * window must already match the profile, which keeps occasional bystander speech out.
 */
internal object SelfVoiceLearning {
    const val KEY = "selfVoiceAutoLearn"
    const val MAX_AUTO = 10
    const val MAX_PENDING = 30
    data class Outcome(val accepted: Int = 0, val bootstrapped: Boolean = false, val pendingSeconds: Float = 0f)

    fun apply(person: VoicePerson, windows: List<Pair<FloatArray, Float>>, now: Long = System.currentTimeMillis()): Pair<VoicePerson, Outcome> {
        if (person.model != SpeakerEngine.MODEL || windows.isEmpty()) return person to Outcome()
        val fresh = windows.map { (vector, seconds) -> AutoVoiceSample(vector, seconds, now) }
        val references = person.references
        if (references.isNotEmpty()) {
            val accepted = fresh.filter { top3(it.vector, references) >= SpeakerEngine.DEFAULT_THRESHOLD }
            if (accepted.isEmpty() && person.autoPending.isEmpty()) return person to Outcome()
            return person.copy(autoSamples = (person.autoSamples + accepted).takeLast(MAX_AUTO), autoPending = emptyList()) to Outcome(accepted.size)
        }
        val pending = (person.autoPending + fresh).takeLast(MAX_PENDING)
        val total = pending.sumOf { it.seconds.toDouble() }.toFloat()
        var best = emptyList<AutoVoiceSample>(); var bestSeconds = -1f
        for (seed in pending.indices) {
            val group = mutableListOf(seed)
            pending.indices.sortedByDescending { cosine(pending[seed].vector, pending[it].vector) }.forEach { index ->
                if (index != seed && group.all { cosine(pending[it].vector, pending[index].vector) >= 0.5f }) group += index
            }
            val seconds = group.sumOf { pending[it].seconds.toDouble() }.toFloat()
            if (seconds > bestSeconds) { bestSeconds = seconds; best = group.sorted().map { pending[it] } }
        }
        // Same 10 s / 3 window bar as manual enrollment; the wearer must be the majority of the pooled wake speech.
        return if (bestSeconds >= 10f && best.size >= 3 && bestSeconds >= total * 0.5f) {
            // Keep the longest windows but in capture order, so later FIFO eviction drops the oldest first.
            val keep = best.indices.sortedByDescending { best[it].seconds }.take(MAX_AUTO).toSet()
            val auto = best.filterIndexed { index, _ -> index in keep }
            person.copy(autoSamples = auto, autoPending = emptyList()) to Outcome(auto.size, bootstrapped = true)
        } else person.copy(autoPending = pending) to Outcome(pendingSeconds = total)
    }

    private fun top3(vector: FloatArray, references: List<FloatArray>) =
        references.map { cosine(vector, it) }.sortedDescending().take(3).average().toFloat()
    private fun cosine(a: FloatArray, b: FloatArray): Float {
        if (a.size != b.size) return -1f
        var dot = 0.0; var aa = 0.0; var bb = 0.0
        for (i in a.indices) { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        return (dot / sqrt(aa * bb).coerceAtLeast(1e-12)).toFloat()
    }
}
