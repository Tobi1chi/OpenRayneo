// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class AppSettings(context: Context) {
    private val preferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val alias = "openrayneo.settings"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    private fun resetKeyAndData(reason: String, error: Throwable) {
        Log.w("OpenRayneo", "$reason：${error.javaClass.simpleName}")
        preferences.edit().remove("data").apply()
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply {
                load(null)
                if (containsAlias(alias)) deleteEntry(alias)
            }
        }
    }

    private fun encrypt(payload: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(payload)
    }

    fun read(): JSONObject {
        val encrypted = preferences.getString("data", null) ?: return JSONObject()
        return try {
            val bytes = Base64.decode(encrypted, Base64.NO_WRAP)
            require(bytes.size > 12) { "加密设置长度无效" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        } catch (error: Exception) {
            resetKeyAndData("加密设置不可读取，已重置本机密钥与设置", error)
            JSONObject()
        }
    }

    fun save(settings: JSONObject) {
        val payload = settings.toString().toByteArray(Charsets.UTF_8)
        val bytes = try {
            encrypt(payload)
        } catch (error: Exception) {
            resetKeyAndData("加密密钥已失效，重建密钥后重试保存", error)
            encrypt(payload)
        }
        check(preferences.edit().putString("data", Base64.encodeToString(bytes, Base64.NO_WRAP)).commit())
    }
}
