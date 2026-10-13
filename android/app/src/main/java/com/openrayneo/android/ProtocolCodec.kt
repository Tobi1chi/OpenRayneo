// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import java.io.ByteArrayOutputStream

internal object ProtocolCodec {
    data class Frame(val protocol: Int, val sequence: Int, val payload: ByteArray,
                     val flags: Int = 0, val acknowledgement: Boolean = false)

    fun crc16(bytes: ByteArray): Int {
        var crc = 0
        for (byte in bytes) {
            crc = crc xor ((byte.toInt() and 255) shl 8)
            repeat(8) { crc = ((crc shl 1) xor if (crc and 0x8000 != 0) 0x1021 else 0) and 0xffff }
        }
        return crc
    }

    fun frame(protocol: Int, sequence: Int, payload: ByteArray, acknowledgement: Boolean = false): ByteArray {
        require(payload.size <= 65531) { "协议载荷超过 65531 字节" }
        val body = be16(sequence) + byteArrayOf(0, protocol.toByte()) + payload
        val magic = if (acknowledgement) byteArrayOf(0x55, 0xaa.toByte()) else byteArrayOf(0xaa.toByte(), 0x55)
        return magic + be16(body.size) + body + be16(crc16(body))
    }

    fun acknowledgement(frame: Frame) = frame(frame.protocol, frame.sequence, byteArrayOf(), acknowledgement = true)

    fun pairing(sequence: Int, command: Int, fields: List<Pair<Int, ByteArray>>): ByteArray {
        val tlvs = ByteArrayOutputStream()
        fields.forEach { (tag, value) ->
            tlvs.write(tag)
            tlvs.write(be16(value.size))
            tlvs.write(value)
        }
        val body = tlvs.toByteArray()
        return frame(0x10, sequence, byteArrayOf(command.toByte()) + be16(body.size) + body)
    }

    fun pairingFields(payload: ByteArray): Map<Int, ByteArray> {
        require(payload.size >= 3 && u16(payload, 1) == payload.size - 3) { "无效的认证消息长度" }
        val fields = mutableMapOf<Int, ByteArray>()
        var offset = 3
        while (offset < payload.size) {
            require(offset + 3 <= payload.size) { "认证 TLV 不完整" }
            val tag = payload[offset].toInt() and 255
            val size = u16(payload, offset + 1)
            offset += 3
            require(offset + size <= payload.size) { "认证 TLV 内容不完整" }
            fields[tag] = payload.copyOfRange(offset, offset + size)
            offset += size
        }
        return fields
    }

    fun notification(sequence: Int, json: String): ByteArray {
        val text = json.toByteArray(Charsets.UTF_8)
        // AssistantMsg: action=1, type=2, JSON field 3, empty binary field 4.
        val protobuf = byteArrayOf(8, 1, 16, 2, 26) + varint(text.size) + text + byteArrayOf(34, 0)
        return frame(0x15, sequence, protobuf)
    }

    fun display(protocol: Int, sequence: Int, type: Int, json: String): ByteArray {
        val bytes = json.toByteArray(Charsets.UTF_8)
        return frame(protocol, sequence, byteArrayOf(8, 1, 16) + varint(type) + byteArrayOf(26) + varint(bytes.size) + bytes)
    }

    data class Message(val type: Int, val json: String?, val audio: ByteArray?)

    fun message(payload: ByteArray): Message {
        var offset = 0
        fun variable(): Int {
            var result = 0
            for (shift in 0..28 step 7) {
                require(offset < payload.size) { "Protobuf 字段不完整" }
                val value = payload[offset++].toInt() and 255
                result = result or ((value and 127) shl shift)
                if (value and 128 == 0) return result
            }
            error("Protobuf 字段过长")
        }
        var type = -1
        var json: String? = null
        var audio: ByteArray? = null
        while (offset < payload.size) {
            val tag = variable()
            when (tag and 7) {
                0 -> { val value = variable(); if (tag ushr 3 == 2) type = value }
                2 -> {
                    val size = variable()
                    require(size >= 0 && size <= payload.size - offset) { "Protobuf 内容不完整" }
                    if (tag ushr 3 == 3) json = String(payload, offset, size, Charsets.UTF_8)
                    if (tag ushr 3 == 4) audio = payload.copyOfRange(offset, offset + size)
                    offset += size
                }
                1 -> { require(payload.size - offset >= 8); offset += 8 }
                5 -> { require(payload.size - offset >= 4); offset += 4 }
                else -> error("不支持的 Protobuf 类型")
            }
        }
        return Message(type, json, audio)
    }

    private fun varint(value: Int): ByteArray {
        var remaining = value
        val output = ByteArrayOutputStream()
        while (remaining >= 128) {
            output.write((remaining and 127) or 128)
            remaining = remaining ushr 7
        }
        output.write(remaining)
        return output.toByteArray()
    }

    private fun be16(value: Int) = byteArrayOf((value ushr 8).toByte(), value.toByte())
    private fun u16(bytes: ByteArray, offset: Int) =
        ((bytes[offset].toInt() and 255) shl 8) or (bytes[offset + 1].toInt() and 255)

    class StreamDecoder {
        private var pending = byteArrayOf()

        fun append(bytes: ByteArray): List<Frame> {
            pending += bytes
            val frames = mutableListOf<Frame>()
            while (pending.size >= 4) {
                val start = (0 until pending.size - 1).firstOrNull {
                    (pending[it] == 0xaa.toByte() && pending[it + 1] == 0x55.toByte()) ||
                        (pending[it] == 0x55.toByte() && pending[it + 1] == 0xaa.toByte())
                }
                if (start == null) {
                    pending = pending.takeLast(1).toByteArray()
                    break
                }
                pending = pending.copyOfRange(start, pending.size)
                if (pending.size < 4) break
                val length = u16(pending, 2)
                if (length < 4) {
                    pending = pending.copyOfRange(1, pending.size)
                    continue
                }
                val total = length + 6
                if (pending.size < total) break
                val body = pending.copyOfRange(4, 4 + length)
                if (crc16(body) != u16(pending, 4 + length)) {
                    pending = pending.copyOfRange(1, pending.size)
                    continue
                }
                val flags = body[2].toInt() and 255
                val protocolOffset = 3 + (if (flags and 2 != 0) 1 else 0) + ((flags ushr 5) and 7)
                if (protocolOffset < body.size) {
                    frames += Frame(body[protocolOffset].toInt() and 255, u16(body, 0),
                        body.copyOfRange(protocolOffset + 1, body.size), flags, pending[0] == 0x55.toByte())
                }
                pending = pending.copyOfRange(total, pending.size)
            }
            return frames
        }
    }
}
