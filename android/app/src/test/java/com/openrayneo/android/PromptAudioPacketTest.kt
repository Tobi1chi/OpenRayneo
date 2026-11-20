// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PromptAudioPacketTest {
    @Test
    fun rejectsEmptyAndMalformedCode3PacketsWithoutThrowing() {
        assertNull(PromptAudio.packetDurationUs(byteArrayOf()))
        // Code-3 packet missing mandatory frame-count byte (previously threw IndexOutOfBoundsException).
        assertNull(PromptAudio.packetDurationUs(byteArrayOf(0x03)))
        assertNull(PromptAudio.packetDurationUs(byteArrayOf(0xfb.toByte())))
        // Code-3 packet with 0 or >48 frames (invalid per RFC 6716).
        assertNull(PromptAudio.packetDurationUs(byteArrayOf(0x03, 0x00)))
        assertNull(PromptAudio.packetDurationUs(byteArrayOf(0x03, 49)))
    }

    @Test
    fun computesExpectedOpusPacketDurations() {
        // CELT FB 20ms stereo, code 0 (1 frame) -> 20,000 us.
        assertEquals(20_000L, PromptAudio.packetDurationUs(byteArrayOf(0xfc.toByte(), 0x01)))
        // CELT FB 20ms stereo, code 1 (2 frames) -> 40,000 us.
        assertEquals(40_000L, PromptAudio.packetDurationUs(byteArrayOf(0xfd.toByte(), 0x01, 0x02)))
        // CELT FB 20ms stereo, code 3 (3 frames) -> 60,000 us.
        assertEquals(60_000L, PromptAudio.packetDurationUs(byteArrayOf(0xff.toByte(), 0x03, 0x01)))
        // Hybrid FB 10ms mono, code 0 -> 10,000 us.
        assertEquals(10_000L, PromptAudio.packetDurationUs(byteArrayOf(0x70, 0x01)))
        // SILK NB 60ms mono, code 0 -> 60,000 us.
        assertEquals(60_000L, PromptAudio.packetDurationUs(byteArrayOf(0x18, 0x01)))
    }
}
