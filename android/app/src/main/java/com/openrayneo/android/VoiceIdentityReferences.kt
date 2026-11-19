// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

/** A copied reference is one vote, even if a legacy unnamed profile still holds it. */
internal fun voiceIdentityReferences(people: List<VoicePerson>, model: String): List<Pair<VoicePerson, List<FloatArray>>> {
    val active = people.filter { it.mergedInto == null && it.model == model }
    val namedSamples = active.filter { !it.unnamed }.flatMap { it.samples }
    return active.mapNotNull { person ->
        val samples = if (person.unnamed) person.samples.filterNot { sample -> namedSamples.any { it.contentEquals(sample) } }
            else person.references
        samples.takeIf { it.isNotEmpty() }?.let { person to it }
    }
}
