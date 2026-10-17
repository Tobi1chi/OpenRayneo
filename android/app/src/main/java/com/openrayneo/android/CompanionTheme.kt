// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal val Pine = Color(0xFF256B52)
internal val SignalGreen = Color(0xFFB8EFCD)
internal val LensBlack = Color(0xFF13251D)
private val Day =
    lightColorScheme(
        primary = Color(0xFF252B28),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFE8EBE9),
        onPrimaryContainer = Color(0xFF252B28),
        secondary = Color(0xFF515955),
        secondaryContainer = Color(0xFFEBEEEC),
        onSecondaryContainer = Color(0xFF303733),
        background = Color(0xFFF7F8F7),
        onBackground = Color(0xFF202623),
        surface = Color(0xFFF7F8F7),
        onSurface = Color(0xFF202623),
        surfaceContainer = Color(0xFFEFF1F0),
        surfaceContainerLow = Color.White,
        surfaceContainerHigh = Color(0xFFE5E8E6),
        surfaceVariant = Color(0xFFE5E8E6),
        onSurfaceVariant = Color(0xFF5B645F),
        outline = Color(0xFF818B85),
        outlineVariant = Color(0xFFDCE1DD),
        tertiaryContainer = Color(0xFFFFF0CD),
        onTertiaryContainer = Color(0xFF4B3C0A),
    )
private val Night =
    darkColorScheme(
        primary = Color(0xFFE1E7E3),
        onPrimary = Color(0xFF1B211E),
        primaryContainer = Color(0xFF2A302C),
        onPrimaryContainer = Color(0xFFE1E7E3),
        secondary = Color(0xFFBAC4BD),
        secondaryContainer = Color(0xFF303732),
        onSecondaryContainer = Color(0xFFDCE4DF),
        background = Color(0xFF121614),
        onBackground = Color(0xFFE2E8E4),
        surface = Color(0xFF121614),
        onSurface = Color(0xFFE2E8E4),
        surfaceContainer = Color(0xFF242A26),
        surfaceContainerLow = Color(0xFF1B211D),
        surfaceContainerHigh = Color(0xFF2D342F),
        onSurfaceVariant = Color(0xFFB5BFB8),
        outline = Color(0xFF7E8981),
        outlineVariant = Color(0xFF3B453D),
        tertiaryContainer = Color(0xFF4D3C17),
        onTertiaryContainer = Color(0xFFFFE0A0),
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
    MaterialTheme(
        colorScheme = if (dark) Night else Day,
        shapes =
            Shapes(
                extraSmall = RoundedCornerShape(4.dp),
                small = RoundedCornerShape(6.dp),
                medium = RoundedCornerShape(8.dp),
                large = RoundedCornerShape(10.dp),
                extraLarge = RoundedCornerShape(12.dp),
            ),
        typography =
            Typography().let {
                it.copy(
                    headlineLarge =
                        it.headlineLarge.copy(
                            fontSize = 24.sp,
                            lineHeight = 32.sp,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    headlineMedium =
                        it.headlineMedium.copy(
                            fontSize = 22.sp,
                            lineHeight = 30.sp,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    titleLarge =
                        it.titleLarge.copy(
                            fontSize = 20.sp,
                            lineHeight = 28.sp,
                            fontWeight = FontWeight.SemiBold,
                        ),
                )
            },
        content = content,
    )
}

@Composable
internal fun GlassesArtwork(modifier: Modifier = Modifier, color: Color = Pine) {
    Canvas(modifier.semantics { contentDescription = "RayNeo 智能眼镜轮廓" }) {
        val w = size.width
        val h = size.height
        drawCircle(color.copy(alpha = .055f), minOf(w * .32f, h * .46f), Offset(w * .5f, h * .5f))
        val stroke = Stroke(3.dp.toPx())
        drawRoundRect(
            color,
            Offset(w * .14f, h * .4f),
            Size(w * .31f, h * .34f),
            androidx.compose.ui.geometry.CornerRadius(w * .05f),
            style = stroke,
        )
        drawRoundRect(
            color,
            Offset(w * .55f, h * .4f),
            Size(w * .31f, h * .34f),
            androidx.compose.ui.geometry.CornerRadius(w * .05f),
            style = stroke,
        )
        val bridge =
            Path().apply {
                moveTo(w * .45f, h * .49f)
                quadraticTo(w * .5f, h * .38f, w * .55f, h * .49f)
            }
        drawPath(bridge, color, style = stroke)
        drawLine(color, Offset(w * .14f, h * .46f), Offset(w * .04f, h * .22f), stroke.width)
        drawLine(color, Offset(w * .86f, h * .46f), Offset(w * .96f, h * .22f), stroke.width)
        drawLine(
            color.copy(alpha = .3f),
            Offset(w * .2f, h * .49f),
            Offset(w * .31f, h * .49f),
            2.dp.toPx(),
        )
        drawCircle(color, 2.8.dp.toPx(), Offset(w * .8f, h * .46f))
    }
}

@Composable
internal fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.padding(top = 8.dp, bottom = 2.dp),
    )
}

@Composable
internal fun Note(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
internal fun ContentCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    OutlinedCard(
        modifier.fillMaxWidth(),
        colors =
            CardDefaults.outlinedCardColors(
                containerColor = MaterialTheme.colorScheme.surfaceContainerLow
            ),
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

@Composable
internal fun StatusPill(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier,
        shape = RoundedCornerShape(4.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
    ) {
        Text(
            text,
            Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
        )
    }
}

@Composable
internal fun ToolButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    Button(onClick, modifier, enabled, shape = MaterialTheme.shapes.small, content = content)
}

@Composable
internal fun ToolOutlinedButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    OutlinedButton(
        onClick,
        modifier,
        enabled,
        shape = MaterialTheme.shapes.small,
        content = content,
    )
}
