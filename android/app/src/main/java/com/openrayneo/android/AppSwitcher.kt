// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Intent
import android.content.pm.PackageManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.TimeUnit

internal object AppSwitcher {
    val OFFICIAL_PACKAGES = listOf("com.rayneo.venus", "com.rayneo.venus.pub")
    private val http = OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).build()

    fun findOfficialLaunchIntent(packageManager: PackageManager): Intent? {
        for (pkg in OFFICIAL_PACKAGES) {
            packageManager.getLaunchIntentForPackage(pkg)?.let { return it }
        }
        return null
    }

    fun hasPcSwitchHelper(config: JSONObject): Boolean {
        val rawUrl = config.optString("codexUrl").trim()
        val token = config.optString("codexToken").trim()
        if (rawUrl.isEmpty() || token.isEmpty()) return false
        val uri = runCatching { URI(rawUrl) }.getOrNull() ?: return false
        return uri.scheme == "ws" && uri.host in setOf("127.0.0.1", "localhost") && uri.port == 4500
    }

    /**
     * Notifies the optional local PC/ADB helper on port 4501 when configured; returns true if
     * the helper accepted the switch, or false if no helper is configured (standalone mode).
     */
    suspend fun notifyPcHelperIfConfigured(config: JSONObject, official: Boolean): Boolean =
        withContext(Dispatchers.IO) {
            if (!hasPcSwitchHelper(config)) return@withContext false
            val uri = URI(config.optString("codexUrl").trim())
            val token = config.optString("codexToken").trim()
            val body = JSONObject().put("owner", if (official) "official" else "openrayneo").toString()
            val request = Request.Builder()
                .url("http://${uri.host}:4501/switch")
                .header("Authorization", "Bearer $token")
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            runCatching {
                http.newCall(request).execute().use { it.isSuccessful }
            }.getOrDefault(false)
        }
}
