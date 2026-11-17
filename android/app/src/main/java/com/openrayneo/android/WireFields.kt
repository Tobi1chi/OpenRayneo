// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import java.io.ByteArrayOutputStream

/** Protobuf fields used by the already recovered file-transfer protocol. */
internal object WireFields {
    data class Value(val number: Int, val integer: Long? = null, val bytes: ByteArray? = null)
    private fun variable(value: Long): ByteArray {
        var remaining = value
        val out = ByteArrayOutputStream()
        while (remaining and -128L != 0L) { out.write((remaining.toInt() and 127) or 128); remaining = remaining ushr 7 }
        out.write(remaining.toInt()); return out.toByteArray()
    }
    fun integer(number: Int, value: Long) = variable(number.toLong() shl 3) + variable(value)
    fun bytes(number: Int, value: ByteArray) = variable((number.toLong() shl 3) or 2) + variable(value.size.toLong()) + value
    fun string(number: Int, value: String) = bytes(number, value.toByteArray(Charsets.UTF_8))
    fun parse(payload: ByteArray): List<Value> {
        var offset = 0
        fun variable(): Long {
            var result = 0L
            for (shift in 0..63 step 7) { require(offset < payload.size); val next = payload[offset++].toInt() and 255
                result = result or ((next and 127).toLong() shl shift); if (next and 128 == 0) return result }
            error("文件协议字段过长")
        }
        val result = mutableListOf<Value>()
        while (offset < payload.size) {
            val tag = variable().toInt()
            when (tag and 7) {
                0 -> result += Value(tag ushr 3, integer = variable())
                2 -> { val size = variable().toInt(); require(size >= 0 && size <= payload.size - offset)
                    result += Value(tag ushr 3, bytes = payload.copyOfRange(offset, offset + size)); offset += size }
                else -> error("文件协议字段类型不支持")
            }
        }
        return result
    }
}
