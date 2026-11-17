// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Stateful 48kHz→16kHz low-pass decimator; both timestamps and filter history span Opus packets. */
internal class ConversationAudio {
    private val taps = FloatArray(63) { index ->
        val x = index - 31
        val ideal = if (x == 0) 0.3 else sin(0.3 * PI * x) / (PI * x)
        (ideal * (0.54 - 0.46 * cos(2 * PI * index / 62))).toFloat()
    }.let { values -> val sum = values.sum(); FloatArray(values.size) { values[it] / sum } }
    private val history = FloatArray(63)
    private var cursor = 0
    private var phase = 0
    fun convert(left: ShortArray): FloatArray {
        val output = FloatArray((left.size + 2) / 3); var count = 0
        for (index in left.indices) {
            val value = left[index].toFloat()
            history[cursor] = value / 32768
            if (++phase == 3) {
                phase = 0; var sum = 0f
                for (tap in taps.indices) sum += taps[tap] * history[(cursor - tap + 63) % 63]
                output[count++] = sum
            }
            cursor = (cursor + 1) % 63
        }
        return output.copyOf(count)
    }
}
