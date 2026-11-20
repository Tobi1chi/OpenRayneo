// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

internal enum class AppLanguageMode(val key: String) {
    SYSTEM("system"),
    ZH("zh"),
    EN("en");

    companion object {
        fun fromKey(key: String?): AppLanguageMode =
            entries.firstOrNull { it.key == key } ?: SYSTEM
    }
}

internal object AppLanguage {
    private const val PREF_NAME = "companion_ui"
    private const val PREF_KEY = "language"
    private const val SYNC_GLASSES_KEY = "syncGlassesLanguage"

    var mode by mutableStateOf(AppLanguageMode.SYSTEM)
        private set

    var syncGlassesLanguage by mutableStateOf(true)
        private set

    fun init(context: Context) {
        val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        mode = AppLanguageMode.fromKey(prefs.getString(PREF_KEY, AppLanguageMode.SYSTEM.key))
        syncGlassesLanguage = prefs.getBoolean(SYNC_GLASSES_KEY, true)
    }

    fun set(context: Context, key: String) {
        val next = AppLanguageMode.fromKey(key)
        mode = next
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PREF_KEY, next.key)
            .apply()
    }

    fun setSyncGlassesLanguage(context: Context, enabled: Boolean) {
        syncGlassesLanguage = enabled
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(SYNC_GLASSES_KEY, enabled)
            .apply()
    }

    internal fun setForTest(next: AppLanguageMode) {
        mode = next
    }

    internal fun resolveIsEnglish(
        selected: AppLanguageMode,
        systemLanguage: String = Locale.getDefault().language,
    ): Boolean = when (selected) {
        AppLanguageMode.ZH -> false
        AppLanguageMode.EN -> true
        AppLanguageMode.SYSTEM -> !systemLanguage.lowercase(Locale.ROOT).startsWith("zh")
    }

    internal fun preferredGlassesLanguage(isEnglish: Boolean, supported: List<String>): String? {
        if (supported.isEmpty()) return null
        val exact = if (isEnglish) "en-us" else "zh-cn"
        val prefix = if (isEnglish) "en" else "zh"
        supported.firstOrNull { it.lowercase(Locale.ROOT) == exact }?.let { return it }
        return supported.firstOrNull { it.lowercase(Locale.ROOT).startsWith(prefix) }
    }

    internal fun appModeForGlassesLanguage(code: String): AppLanguageMode? {
        val normalized = code.trim().lowercase(Locale.ROOT)
        return when {
            normalized.startsWith("zh") -> AppLanguageMode.ZH
            normalized.startsWith("en") -> AppLanguageMode.EN
            else -> null
        }
    }

    /** 1 = 小雷小雷 (Chinese), 2 = OK RayNeo / Hey RayNeo (English) */
    internal fun preferredWakeWordMode(isEnglish: Boolean): Int = if (isEnglish) 2 else 1

    val isEnglish: Boolean
        get() = resolveIsEnglish(mode)

    val speechLocale: String
        get() = if (isEnglish) "en-US" else "zh-CN"

    fun t(zh: String, en: String): String = if (isEnglish) en else zh
}

internal fun L(zh: String, en: String): String = AppLanguage.t(zh, en)
