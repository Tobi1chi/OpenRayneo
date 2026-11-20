// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLanguageTest {
    @Test
    fun resolvesSystemAndExplicitLanguageModes() {
        assertFalse(AppLanguage.resolveIsEnglish(AppLanguageMode.ZH, "en"))
        assertTrue(AppLanguage.resolveIsEnglish(AppLanguageMode.EN, "zh"))
        assertFalse(AppLanguage.resolveIsEnglish(AppLanguageMode.SYSTEM, "zh"))
        assertFalse(AppLanguage.resolveIsEnglish(AppLanguageMode.SYSTEM, "zh-CN"))
        assertTrue(AppLanguage.resolveIsEnglish(AppLanguageMode.SYSTEM, "en"))
        assertTrue(AppLanguage.resolveIsEnglish(AppLanguageMode.SYSTEM, "en-US"))
        assertTrue(AppLanguage.resolveIsEnglish(AppLanguageMode.SYSTEM, "ja"))
    }

    @Test
    fun helperTranslatesByCurrentMode() {
        try {
            AppLanguage.setForTest(AppLanguageMode.ZH)
            assertEquals("设置", L("设置", "Settings"))
            assertEquals("zh-CN", AppLanguage.speechLocale)

            AppLanguage.setForTest(AppLanguageMode.EN)
            assertEquals("Settings", L("设置", "Settings"))
            assertEquals("en-US", AppLanguage.speechLocale)
        } finally {
            AppLanguage.setForTest(AppLanguageMode.SYSTEM)
        }
    }

    @Test
    fun mapsAppAndGlassesLanguagesSafely() {
        val supported = listOf("zh-CN", "en-US", "ja-JP")
        assertEquals("en-US", AppLanguage.preferredGlassesLanguage(isEnglish = true, supported = supported))
        assertEquals("zh-CN", AppLanguage.preferredGlassesLanguage(isEnglish = false, supported = supported))
        assertEquals("en-GB", AppLanguage.preferredGlassesLanguage(isEnglish = true, supported = listOf("en-GB")))
        assertNull(AppLanguage.preferredGlassesLanguage(isEnglish = true, supported = listOf("zh-CN")))
        assertNull(AppLanguage.preferredGlassesLanguage(isEnglish = false, supported = emptyList()))

        assertEquals(AppLanguageMode.ZH, AppLanguage.appModeForGlassesLanguage("zh-CN"))
        assertEquals(AppLanguageMode.EN, AppLanguage.appModeForGlassesLanguage("en-US"))
        assertNull(AppLanguage.appModeForGlassesLanguage("ja-JP"))

        assertEquals(1, AppLanguage.preferredWakeWordMode(isEnglish = false))
        assertEquals(2, AppLanguage.preferredWakeWordMode(isEnglish = true))
    }
}
