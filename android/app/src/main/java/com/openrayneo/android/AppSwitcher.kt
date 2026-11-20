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

    sealed interface HelperOutcome {
        data object NotConfigured : HelperOutcome
        data object Succeeded : HelperOutcome
        data class Failed(val message: String) : HelperOutcome
    }

    fun findOfficialLaunchIntent(packageManager: PackageManager): Intent? {
        for (pkg in OFFICIAL_PACKAGES) {
            packageManager.getLaunchIntentForPackage(pkg)?.let { return it }
        }
        return null
    }

    /**
     * Requires dedicated switchHelperUrl (loopback HTTP) and switchHelperToken settings;
     * never reuses or transmits the desktop Codex capability token.
     */
    fun hasPcSwitchHelper(config: JSONObject): Boolean {
        val rawUrl = config.optString("switchHelperUrl").trim()
        val token = config.optString("switchHelperToken").trim()
        if (rawUrl.isEmpty() || token.isEmpty()) return false
        val uri = runCatching { URI(rawUrl) }.getOrNull() ?: return false
        return uri.scheme == "http" && uri.host in setOf("127.0.0.1", "localhost", "::1") && uri.port in 1..65535
    }

    suspend fun notifyPcHelperIfConfigured(config: JSONObject, official: Boolean): HelperOutcome =
        withContext(Dispatchers.IO) {
            if (!hasPcSwitchHelper(config)) return@withContext HelperOutcome.NotConfigured
            val rawUrl = config.optString("switchHelperUrl").trim().trimEnd('/')
            val token = config.optString("switchHelperToken").trim()
            val body = JSONObject().put("owner", if (official) "official" else "openrayneo").toString()
            val request = Request.Builder()
                .url("$rawUrl/switch")
                .header("Authorization", "Bearer $token")
                .post(body.toRequestBody("application/json".toMediaType()))
                .build()
            runCatching {
                http.newCall(request).execute().use { response ->
                    if (response.isSuccessful) HelperOutcome.Succeeded
                    else HelperOutcome.Failed("HTTP ${response.code}")
                }
            }.getOrElse { error ->
                HelperOutcome.Failed(error.message ?: error.javaClass.simpleName)
            }
        }
}
