// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Colors come only from the generated ColorTokens (assets/design-tokens, VS Code-style semantic keys).
// Material components read the scheme mapped below; custom components read `tokens` directly.
private fun ColorTokens.scheme(dark: Boolean): ColorScheme =
    (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = buttonBackground,
        onPrimary = buttonForeground,
        primaryContainer = badgeBackground,
        onPrimaryContainer = badgeForeground,
        secondary = descriptionForeground,
        onSecondary = buttonForeground,
        secondaryContainer = buttonSecondaryBackground,
        onSecondaryContainer = buttonSecondaryForeground,
        tertiary = textLinkForeground,
        onTertiary = buttonForeground,
        tertiaryContainer = bannerWarningBackground,
        onTertiaryContainer = bannerWarningForeground,
        error = errorForeground,
        background = pageBackground,
        onBackground = foreground,
        surface = pageBackground,
        onSurface = foreground,
        surfaceContainerLowest = cardBackground,
        surfaceContainerLow = inputBackground,
        surfaceContainer = cardIconBackground,
        surfaceContainerHigh = buttonSecondaryBackground,
        surfaceContainerHighest = buttonSecondaryBackground,
        surfaceVariant = buttonSecondaryBackground,
        onSurfaceVariant = descriptionForeground,
        outline = inputBorder,
        outlineVariant = widgetBorder,
    )

@Composable
internal fun CompanionTheme(appearance: String, content: @Composable () -> Unit) {
    val dark = appearance == "dark" || appearance == "system" && isSystemInDarkTheme()
    val view = LocalView.current
    if (!view.isInEditMode)
        SideEffect {
            (view.context as? ComponentActivity)?.enableEdgeToEdge(
                statusBarStyle =
                    if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                    else
                        SystemBarStyle.light(
                            android.graphics.Color.TRANSPARENT,
                            android.graphics.Color.TRANSPARENT,
                        ),
                navigationBarStyle =
                    if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
                    else
                        SystemBarStyle.light(
                            android.graphics.Color.TRANSPARENT,
                            android.graphics.Color.TRANSPARENT,
                        ),
            )
        }
    val colorTokens = if (dark) DarkColorTokens else LightColorTokens
    CompositionLocalProvider(LocalColorTokens provides colorTokens) {
    MaterialTheme(
        colorScheme = colorTokens.scheme(dark),
        shapes =
            Shapes(
                extraSmall = RoundedCornerShape(6.dp),
                small = RoundedCornerShape(10.dp),
                medium = RoundedCornerShape(14.dp),
                large = RoundedCornerShape(16.dp),
                extraLarge = RoundedCornerShape(24.dp),
            ),
        typography =
            Typography().let {
                it.copy(
                    headlineLarge =
                        it.headlineLarge.copy(
                            fontSize = 28.sp,
                            lineHeight = 36.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = (-0.4).sp,
                        ),
                    headlineMedium =
                        it.headlineMedium.copy(
                            fontSize = 24.sp,
                            lineHeight = 32.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = (-0.3).sp,
                        ),
                    headlineSmall =
                        it.headlineSmall.copy(
                            fontSize = 22.sp,
                            lineHeight = 30.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = (-0.2).sp,
                        ),
                    titleLarge =
                        it.titleLarge.copy(
                            fontSize = 20.sp,
                            lineHeight = 28.sp,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    titleMedium = it.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    titleSmall = it.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    labelLarge = it.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                    bodyMedium = it.bodyMedium.copy(lineHeight = 21.sp),
                )
            },
        content = content,
    )
    }
}

@Composable
internal fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge.copy(letterSpacing = 0.4.sp),
        color = tokens.descriptionForeground,
        modifier = Modifier.padding(start = 4.dp, top = 12.dp, bottom = 0.dp),
    )
}

@Composable
internal fun Note(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier,
        style = MaterialTheme.typography.bodyMedium,
        color = tokens.descriptionForeground,
    )
}

@Composable
internal fun ContentCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = tokens.cardBackground,
    ) {
        Column(
            Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            content = content,
        )
    }
}

/** Brand-green dot plus label; the dot dims when nothing is live. */
@Composable
internal fun StatusPill(text: String, modifier: Modifier = Modifier, active: Boolean = true) {
    Surface(
        modifier,
        shape = CircleShape,
        color = if (active) tokens.badgeBackground else tokens.badgeInactiveBackground,
    ) {
        Row(
            Modifier.padding(start = 10.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            SignalDot(active)
            Text(
                text,
                style = MaterialTheme.typography.labelMedium,
                color = if (active) tokens.badgeForeground else tokens.badgeInactiveForeground,
            )
        }
    }
}

@Composable
internal fun SignalDot(active: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(7.dp)
            .background(
                if (active) tokens.statusIndicatorActive else tokens.statusIndicatorInactive,
                CircleShape,
            )
    )
}

@Composable
internal fun ToolButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    Button(
        onClick,
        modifier.heightIn(min = 48.dp),
        enabled,
        shape = MaterialTheme.shapes.small,
        contentPadding = PaddingValues(horizontal = 22.dp, vertical = 12.dp),
        content = content,
    )
}

@Composable
internal fun ToolOutlinedButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    FilledTonalButton(
        onClick,
        modifier.heightIn(min = 44.dp),
        enabled,
        shape = MaterialTheme.shapes.small,
        colors =
            ButtonDefaults.filledTonalButtonColors(
                containerColor = tokens.buttonSecondaryBackground,
                contentColor = tokens.buttonSecondaryForeground,
            ),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
        content = content,
    )
}
