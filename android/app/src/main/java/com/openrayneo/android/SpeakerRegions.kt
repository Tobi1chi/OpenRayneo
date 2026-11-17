// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

internal data class SpeakerInterval(val first: Int, val last: Int, val speaker: Int)
internal data class SpeakerRegion(val first: Int, val last: Int, val speakers: Set<Int>)

/** Preserve SDK coverage and mark only the actual overlap, once. Offsets are PCM frames. */
internal fun speakerRegions(intervals: List<SpeakerInterval>): List<SpeakerRegion> {
    val edges = intervals.flatMap { listOf(it.first, it.last) }.distinct().sorted()
    val regions = mutableListOf<SpeakerRegion>()
    edges.zipWithNext().forEach { (first, last) ->
        val speakers = intervals.filter { it.first < last && it.last > first }.map { it.speaker }.toSet()
        if (speakers.isNotEmpty()) {
            val previous = regions.lastOrNull()
            if (previous?.last == first && previous.speakers == speakers) regions[regions.lastIndex] = previous.copy(last = last)
            else regions += SpeakerRegion(first, last, speakers)
        }
    }
    return regions
}
