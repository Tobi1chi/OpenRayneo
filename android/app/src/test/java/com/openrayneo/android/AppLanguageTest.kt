// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
