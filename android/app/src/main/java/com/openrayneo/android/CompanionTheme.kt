// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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

/**
 * Flat front view of the AR glasses: brow-line frame, tinted lenses with reflection bands, the bridge camera,
 * and the waveguide display in the right lens. [live] lights the display and the hinge LED. Geometry is laid
 * out on a 300 x 112 grid and scaled to fit.
 */
@Composable
internal fun GlassesArtwork(modifier: Modifier = Modifier, live: Boolean = true) {
    val t = tokens
    Canvas(modifier.semantics { contentDescription = "RayNeo 智能眼镜" }) {
        val unit = minOf(size.width / 300f, size.height / 112f)
        val origin = Offset((size.width - 300f * unit) / 2, (size.height - 112f * unit) / 2)
        fun p(x: Float, y: Float) = Offset(origin.x + x * unit, origin.y + y * unit)
        fun sz(w: Float, h: Float) = Size(w * unit, h * unit)
        // Wayfarer lens: flat top, sides easing into a rounded bottom.
        fun lens(l: Float, r: Float, top: Float, bottom: Float) =
            Path().apply {
                val inset = (r - l) * .14f
                val shoulder = top + (bottom - top) * .72f
                moveTo(p(l, top).x, p(l, top).y)
                lineTo(p(r, top).x, p(r, top).y)
                val m = (l + r) / 2
                cubicTo(p(r, shoulder).x, p(r, shoulder).y, p(r - inset, bottom).x, p(r - inset, bottom).y, p(m, bottom).x, p(m, bottom).y)
                cubicTo(p(l + inset, bottom).x, p(l + inset, bottom).y, p(l, shoulder).x, p(l, shoulder).y, p(l, top).x, p(l, top).y)
                close()
            }

        drawOval(t.illustrationShadow, p(40f, 101f), sz(220f, 9f))
        val sides = listOf(20f to 144f, 156f to 280f)
        sides.forEach { (l, r) -> drawPath(lens(l, r, 18f, 96f), t.illustrationFrame) }
        drawRoundRect(t.illustrationFrame, p(6f, 11f), sz(288f, 24f), CornerRadius(10f * unit))
        drawLine(t.illustrationFrameHighlight, p(16f, 13.5f), p(284f, 13.5f), 1.5f * unit, StrokeCap.Round)

        sides.forEach { (l, r) ->
            val glass = lens(l + 7f, r - 7f, 35f, 89f)
            drawPath(glass, t.illustrationLens)
            clipPath(glass) {
                val w = r - l
                fun band(from: Float, width: Float) =
                    Path().apply {
                        moveTo(p(l + w * from, 35f).x, p(l + w * from, 35f).y)
                        lineTo(p(l + w * (from + width), 35f).x, p(l + w * (from + width), 35f).y)
                        lineTo(p(l + w * (from + width - .3f), 89f).x, p(l + w * (from + width - .3f), 89f).y)
                        lineTo(p(l + w * (from - .3f), 89f).x, p(l + w * (from - .3f), 89f).y)
                        close()
                    }
                drawPath(band(.2f, .16f), t.illustrationLensHighlight)
                drawPath(band(.42f, .05f), t.illustrationLensHighlight)
            }
        }

        // Waveguide display: a small phosphor panel floating in the right lens.
        val glyph = if (live) t.hudForeground else t.hudIndicatorInactive
        drawRoundRect(glyph.copy(alpha = if (live) .16f else .1f), p(184f, 47f), sz(68f, 28f), CornerRadius(5f * unit))
        drawLine(glyph, p(192f, 56f), p(226f, 56f), 2.6f * unit, StrokeCap.Round)
        drawLine(glyph.copy(alpha = glyph.alpha * .55f), p(192f, 66f), p(240f, 66f), 2.6f * unit, StrokeCap.Round)
        drawCircle(glyph, 2.2f * unit, p(243f, 56f))

        // Bridge camera and hinge LED.
        drawCircle(t.illustrationLens, 4.2f * unit, p(150f, 23f))
        drawCircle(t.illustrationLensHighlight, 1.4f * unit, p(148.8f, 21.8f))
        drawCircle(if (live) t.statusIndicatorActive else t.statusIndicatorInactive, 2.4f * unit, p(281f, 23f))
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
