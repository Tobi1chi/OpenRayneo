// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import kotlin.math.sqrt

/** Registration uses a consistent set of utterances, not the meeting cluster count. */
internal object VoiceEnrollment {
    data class Sample(val beginMS: Long, val endMS: Long, val vector: FloatArray)
    data class Assessment(val seconds: Float, val totalSeconds: Float, val vectors: List<FloatArray>, val ready: Boolean, val message: String, val confirmationVectors: List<FloatArray> = emptyList())
    fun assess(samples: List<Sample>): Assessment {
        if (samples.isEmpty()) return Assessment(0f, 0f, emptyList(), false, "尚未提取到清晰人声；请确认音量有变化，再自然说几句话")
        val total = duration(samples) / 1000f
        // A short outlier must not poison the entire enrollment. Keep a mutually consistent set,
        // rather than lowering the separate identity-match threshold used by daily memory.
        val selected = samples.map { seed ->
            val compatible = samples.sortedByDescending { cosine(seed.vector, it.vector) }
            val group = mutableListOf(seed)
            for (sample in compatible) if (sample !== seed && group.all { cosine(it.vector, sample.vector) >= 0.5f }) group += sample
            group
        }.maxBy { duration(it) }
        val seconds = duration(selected) / 1000f
        val consistent = seconds >= total * 0.8f
        val ready = seconds >= 10 && selected.size >= 3 && consistent
        val message = when {
            ready -> "已取得${seconds.toInt()}秒一致人声，可以保存我的声音"
            !consistent && total >= 10 -> "人声一致性不足：一致${seconds.toInt()}秒／共${total.toInt()}秒。请只由本人说话，或重新登记"
            seconds < 10 -> "已取得${seconds.toInt()}／10秒一致人声；请继续说话，每句话后稍作停顿"
            else -> "请再说一句，登记需要至少三段可对照的人声"
        }
        return Assessment(seconds, total, selected.sortedByDescending { it.endMS - it.beginMS }.take(10).map { it.vector }, ready, message,
            if (total >= 10 && samples.size >= 3) samples.sortedByDescending { it.endMS - it.beginMS }.take(10).map { it.vector } else emptyList())
    }
    private fun duration(samples: List<Sample>): Long {
        var end = Long.MIN_VALUE; var total = 0L
        for (sample in samples.sortedBy { it.beginMS }) { total += (sample.endMS - maxOf(sample.beginMS, end)).coerceAtLeast(0); end = maxOf(end, sample.endMS) }
        return total
    }
    private fun cosine(a: FloatArray, b: FloatArray): Float {
        require(a.size == b.size)
        var dot = 0.0; var aa = 0.0; var bb = 0.0
        for (i in a.indices) { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        return (dot / sqrt(aa * bb).coerceAtLeast(1e-12)).toFloat()
    }
}
