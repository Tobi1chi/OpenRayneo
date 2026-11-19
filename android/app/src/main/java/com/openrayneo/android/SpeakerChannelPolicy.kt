// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

/** Source and actual channel count decide roles; mono is self only for the user's own native wake, never by position. */
internal object SpeakerChannelPolicy {
    const val DUAL_SELF = "dual_channel1_self"
    // User decision 2026-11-20: only the wearer says the wake word, so the native round is the wearer's request.
    const val NATIVE_SELF = "native_wake_self"
    const val FULL_SPEAKER = "full_speaker"
    fun policy(source: ConversationSource, channels: Int) = when {
        source == ConversationSource.REALTIME && channels == 2 -> DUAL_SELF
        source == ConversationSource.NATIVE -> NATIVE_SELF
        else -> FULL_SPEAKER
    }
    fun fixedSelf(policy: String, channel: Int) = channel == 1 && (policy == DUAL_SELF || policy == NATIVE_SELF)
    fun selfBasis(policy: String) = if (policy == NATIVE_SELF) "native_wake_self" else "channel1_default_self"
}
internal data class ConversationPCM(val channels: List<FloatArray>) {
    val frames get() = channels.firstOrNull()?.size ?: 0
    fun interleavedPCM16(): ByteArray {
        val bytes = java.nio.ByteBuffer.allocate(frames * channels.size * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until frames) channels.forEach { bytes.putShort((it[frame] * 32768).toInt().coerceIn(-32768, 32767).toShort()) }
        return bytes.array()
    }
    companion object {
        fun decode(bytes: ByteArray, channels: Int): ConversationPCM {
            val data = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            val result = List(channels) { FloatArray(bytes.size / 2 / channels) }
            for (frame in result[0].indices) result.forEach { it[frame] = data.short / 32768f }
            return ConversationPCM(result)
        }
    }
}
