// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** ORPCM1 mono remains readable; ORPCM2 retains both channels with a frame-based time cursor. */
internal class MeetingAudioStore(context: Context) {
    private val folder = File(context.filesDir, "meeting-audio").apply { mkdirs() }
    private fun file(id: String): File { require(id.matches(Regex("[A-Za-z0-9-]{1,80}"))); return File(folder, "$id.pcm.enc") }
    private val secret by lazy { key() }
    private var output: DataOutputStream? = null
    private val buffer = ByteArrayOutputStream(64000)
    private var recordingId: String? = null
    private var channels = 1
    private var samples = 0L
    @JvmOverloads fun start(id: String, channels: Int = 1) {
        check(output == null); require(channels in 1..2)
        this.channels = channels
        output = DataOutputStream(file(id).outputStream().buffered()).also {
            it.write((if (channels == 1) "ORPCM1" else "ORPCM2").toByteArray())
            if (channels == 2) it.writeInt(channels)
            it.flush()
        }
        recordingId = id; samples = 0; buffer.reset()
    }
    fun append(pcm: FloatArray) = appendChannels(ConversationPCM(listOf(pcm)))
    fun appendChannels(pcm: ConversationPCM) {
        if (output == null) return
        require(pcm.channels.size == channels && pcm.channels.all { it.size == pcm.frames })
        var first = 0
        val blockBytes = 32000 * channels
        while (first < pcm.frames) {
            val count = minOf((blockBytes - buffer.size()) / (2 * channels), pcm.frames - first)
            val bytes = ByteBuffer.allocate(count * 2 * channels).order(ByteOrder.LITTLE_ENDIAN)
            for (frame in first until first + count) pcm.channels.forEach {
                bytes.putShort((it[frame] * 32768).toInt().coerceIn(-32768,32767).toShort())
            }
            buffer.write(bytes.array()); samples += count; first += count
            if (buffer.size() == blockBytes) flush()
        }
    }
    private fun flush() {
        if (buffer.size() == 0) return
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, secret) }
        val bytes = cipher.iv + cipher.doFinal(buffer.toByteArray())
        output!!.writeInt(bytes.size); output!!.write(bytes); output!!.flush(); buffer.reset()
    }
    fun finish(): Long {
        if (output != null) { flush(); output!!.writeInt(0); output!!.close() }
        output = null; recordingId = null; return samples
    }
    private fun header(input: DataInput): Int {
        val magic = ByteArray(6); input.readFully(magic)
        return when (magic.toString(Charsets.US_ASCII)) {
            "ORPCM1" -> 1
            "ORPCM2" -> input.readInt().also { require(it in 1..2) }
            else -> error("不支持的本地录音格式")
        }
    }
    fun channelCount(id: String): Int = DataInputStream(file(id).inputStream().buffered()).use(::header)
    private fun decrypt(bytes: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, bytes.copyOfRange(0,12))) }
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size))
    }
    fun recover(id: String): Long {
        val target = file(id); if (!target.exists()) return 0
        RandomAccessFile(target, "rw").use { input ->
            val count = header(input)
            var total = 0L; var boundary = input.filePointer
            while (input.length() - input.filePointer >= 4) {
                val length = input.readInt(); if (length == 0) return total
                if (length !in 28..128000 || input.length() - input.filePointer < length) break
                val bytes = ByteArray(length); input.readFully(bytes)
                val decoded = try { decrypt(bytes) } catch (_: javax.crypto.AEADBadTagException) { break }
                total += decoded.size / (2 * count); boundary = input.filePointer
            }
            input.setLength(boundary); input.seek(boundary); input.writeInt(0)
            return total
        }
    }
    fun open(id: String): InputStream {
        check(id != recordingId) { "请先停止录音" }
        val input = DataInputStream(file(id).inputStream().buffered()); header(input)
        return object : InputStream() {
            private var current = ByteArrayInputStream(byteArrayOf())
            private var ended = false
            private fun advance(): Boolean {
                if (ended) return false
                if (current.available() > 0) return true
                val length = input.readInt(); if (length == 0) { ended = true; return false }
                require(length in 28..128000)
                val bytes = input.readNBytes(length); check(bytes.size == length) { "音频未完整保存" }
                current = ByteArrayInputStream(decrypt(bytes)); return true
            }
            override fun read(): Int = if (advance()) current.read() else -1
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int = if (length == 0) 0 else if (advance()) current.read(bytes, offset, length) else -1
            override fun close() = input.close()
        }
    }
    /** Decrypts complete blocks independently of the live writer. */
    inner class GrowingReader(id: String, offsetFrames: Long) : Closeable {
        private val input = RandomAccessFile(file(id), "r")
        val channelCount = header(input)
        private var skip = offsetFrames * 2 * channelCount
        private var current = ByteArray(0)
        private var offset = 0
        var finished = false; private set
        fun nextBlock(maxFrames: Int = 1600): ConversationPCM? {
            while (offset >= current.size) {
                val boundary = input.filePointer
                if (input.length() - boundary < 4) return null
                val length = input.readInt()
                if (length == 0) { finished = true; input.seek(boundary); return null }
                if (input.length() - input.filePointer < length) { input.seek(boundary); return null }
                require(length in 28..128000)
                val bytes = ByteArray(length); input.readFully(bytes)
                current = decrypt(bytes); offset = minOf(skip, current.size.toLong()).toInt(); skip -= offset
            }
            val count = minOf(maxFrames * 2 * channelCount, current.size - offset)
            val block = ConversationPCM.decode(current.copyOfRange(offset, offset + count), channelCount)
            offset += count; return block
        }
        fun next(maxSamples: Int = 1600): FloatArray? = nextBlock(maxSamples)?.channels?.first()
        override fun close() = input.close()
    }
    fun growing(id: String, offsetSamples: Long) = GrowingReader(id, offsetSamples)
    fun openAt(id: String, offsetSamples: Long): InputStream = open(id).apply {
        var remaining = offsetSamples * 2 * channelCount(id)
        val bytes = ByteArray(32768)
        while (remaining > 0) { val count = read(bytes, 0, minOf(remaining, bytes.size.toLong()).toInt()); check(count > 0) { "音频偏移超出已保存范围" }; remaining -= count }
    }
    @JvmOverloads fun readSamples(id: String, beginMS: Long, endMS: Long, sourceChannel: Int = 1): FloatArray = openAt(id, beginMS * 16).use { input ->
        val count = channelCount(id); require(sourceChannel in 1..count)
        val bytes = input.readNBytes(((endMS - beginMS) * 32 * count).toInt())
        ConversationPCM.decode(bytes, count).channels[sourceChannel - 1]
    }
    fun exportWav(id: String, samples: Long, destination: OutputStream) {
        val count = channelCount(id); val size = samples * 2 * count; require(size < Int.MAX_VALUE - 44)
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray()).putInt(size.toInt() + 36).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(count.toShort())
            .putInt(16000).putInt(32000 * count).putShort((2 * count).toShort()).putShort(16).put("data".toByteArray()).putInt(size.toInt()).array()
        destination.write(header); open(id).use { check(it.copyTo(destination) == size) { "音频长度与记录不符" } }
    }
    private fun key(): SecretKey {
        val alias = "openrayneo.meeting-audio"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
}
