// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolCodecTest {
    private fun loadVectors(): JSONObject {
        val stream = checkNotNull(javaClass.getResourceAsStream("/protocol-vectors.json")) {
            "Missing shared protocol-vectors.json resource"
        }
        return stream.bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
    }

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "Hex string must have even length" }
        return ByteArray(hex.length / 2) { index ->
            hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @Test
    fun crc16MatchesGoldenVectors() {
        val cases = loadVectors().getJSONArray("crc16_xmodem")
        for (index in 0 until cases.length()) {
            val item = cases.getJSONObject(index)
            val input = hexToBytes(item.getString("hex"))
            assertEquals(
                "CRC mismatch for ${item.getString("name")}",
                item.getInt("crc16"),
                ProtocolCodec.crc16(input),
            )
        }
    }

    @Test
    fun frameEncodersMatchGoldenVectors() {
        val frames = loadVectors().getJSONObject("frames")

        val notification = frames.getJSONObject("notification")
        assertEquals(
            notification.getString("hex"),
            bytesToHex(
                ProtocolCodec.notification(
                    notification.getInt("sequence"),
                    notification.getString("json"),
                ),
            ),
        )

        val display = frames.getJSONObject("display")
        assertEquals(
            display.getString("hex"),
            bytesToHex(
                ProtocolCodec.display(
                    display.getInt("protocol"),
                    display.getInt("sequence"),
                    display.getInt("type"),
                    display.getString("json"),
                ),
            ),
        )

        val pairing = frames.getJSONObject("pairing")
        val pairingBytes = ProtocolCodec.pairing(
            pairing.getInt("sequence"),
            pairing.getInt("command"),
            listOf(
                0x10 to byteArrayOf(0x01, 0x02, 0x03, 0x04),
                0x11 to byteArrayOf(0xaa.toByte(), 0xbb.toByte()),
            ),
        )
        assertEquals(pairing.getString("hex"), bytesToHex(pairingBytes))
        val decodedPairing = ProtocolCodec.StreamDecoder().append(pairingBytes).single()
        val parsedTlvs = ProtocolCodec.pairingFields(decodedPairing.payload)
        assertArrayEquals(byteArrayOf(0x01, 0x02, 0x03, 0x04), parsedTlvs[0x10])
        assertArrayEquals(byteArrayOf(0xaa.toByte(), 0xbb.toByte()), parsedTlvs[0x11])

        val ack = frames.getJSONObject("acknowledgement")
        val ackFrame = ProtocolCodec.acknowledgement(
            ProtocolCodec.Frame(
                protocol = ack.getInt("protocol"),
                sequence = ack.getInt("sequence"),
                payload = byteArrayOf(),
            ),
        )
        assertEquals(ack.getString("hex"), bytesToHex(ackFrame))
    }

    @Test
    fun extendedFlagsAndMessageActionDecodeCorrectly() {
        val ext = loadVectors().getJSONObject("frames").getJSONObject("extended_flags")
        val decoded = ProtocolCodec.StreamDecoder().append(hexToBytes(ext.getString("hex"))).single()
        assertEquals(ext.getInt("protocol"), decoded.protocol)
        assertEquals(ext.getInt("sequence"), decoded.sequence)
        assertEquals(ext.getInt("flags"), decoded.flags)
        assertEquals(ext.getBoolean("needs_ack"), decoded.requiresAcknowledgement)
        assertFalse(decoded.acknowledgement)

        val message = ProtocolCodec.message(decoded.payload)
        assertEquals(ext.getInt("action"), message.action)
        assertEquals(ext.getInt("type"), message.type)
        assertEquals(ext.getString("json"), message.json)
    }

    @Test
    fun streamDecoderRecoversFromCorruptedAndFragmentedStreams() {
        val recovery = loadVectors().getJSONObject("stream_recovery")
        val raw = hexToBytes(recovery.getString("hex"))
        val expected = recovery.getJSONArray("expected_frames")

        val bulkFrames = ProtocolCodec.StreamDecoder().append(raw)
        assertEquals(expected.length(), bulkFrames.size)

        val byteByByteDecoder = ProtocolCodec.StreamDecoder()
        val trickleFrames = raw.flatMap { byte ->
            byteByByteDecoder.append(byteArrayOf(byte))
        }
        assertEquals(expected.length(), trickleFrames.size)

        for (index in 0 until expected.length()) {
            val exp = expected.getJSONObject(index)
            for (actual in listOf(bulkFrames[index], trickleFrames[index])) {
                assertEquals(exp.getInt("protocol"), actual.protocol)
                assertEquals(exp.getInt("sequence"), actual.sequence)
                assertEquals(exp.getInt("flags"), actual.flags)
                assertEquals(exp.getBoolean("acknowledgement"), actual.acknowledgement)
            }
        }
        assertFalse(bulkFrames[0].requiresAcknowledgement)
        assertTrue(bulkFrames[1].requiresAcknowledgement)
        assertFalse(bulkFrames[2].requiresAcknowledgement)
    }

    @Test
    fun streamDecoderRejectsImpossibleExtendedHeaderLengthWithoutSwallowingNextFrame() {
        // flags = 0xE2 requires protocolHeaderOffset = 11 bytes, so length = 5 is impossible.
        val bogusHeader = hexToBytes("aa5500050001e21700")
        val validAck = ProtocolCodec.acknowledgement(
            ProtocolCodec.Frame(protocol = 0x17, sequence = 99, payload = byteArrayOf()),
        )
        val decoded = ProtocolCodec.StreamDecoder().append(bogusHeader + validAck)
        assertEquals(1, decoded.size)
        assertTrue(decoded[0].acknowledgement)
        assertEquals(0x17, decoded[0].protocol)
        assertEquals(99, decoded[0].sequence)
    }
}
