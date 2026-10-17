// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Renders the logical cells from the exact payload, without generating a second arrow or road
 * label.
 */
@Composable
internal fun NavigationGrid(frame: String, modifier: Modifier = Modifier) {
    val paint = remember {
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            textAlign = Paint.Align.CENTER
        }
    }
    Canvas(
        modifier.fillMaxWidth().aspectRatio(20f / 7f).semantics {
            contentDescription =
                "眼镜导航布局，20 列 5 行。" + frame.replace('█', ' ').replace('　', ' ').trim()
        }
    ) {
        val cellWidth = size.width / 20
        val cellHeight = size.height / 5
        paint.color = SignalGreen.toArgb()
        paint.textSize = cellWidth * .95f
        val baselineOffset = -(paint.ascent() + paint.descent()) / 2
        frame.split('\n').forEachIndexed { row, text ->
            text.forEachIndexed { column, character ->
                if (character == '█') {
                    drawRect(
                        SignalGreen,
                        Offset(column * cellWidth, row * cellHeight),
                        Size(cellWidth, cellHeight),
                    )
                } else if (character != '　' && character != ' ') {
                    drawContext.canvas.nativeCanvas.drawText(
                        character.toString(),
                        (column + .5f) * cellWidth,
                        (row + .5f) * cellHeight + baselineOffset,
                        paint,
                    )
                }
            }
        }
    }
}

@Composable
internal fun GridPreview(frame: String, label: String) {
    Surface(
        color = LensBlack,
        contentColor = SignalGreen,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(label, style = MaterialTheme.typography.labelMedium)
            NavigationGrid(frame)
        }
    }
}

@Composable
internal fun GlassesOutputPreview(state: GlassesState) {
    val session = state.session
    val content = session?.writtenContent
    val available =
        state.link.phase == LinkPhase.FULL &&
            state.ownership == DisplayOwnership.APP &&
            content != null
    val title =
        when {
            state.ownership == DisplayOwnership.YIELDED -> "已让出显示"
            state.link.phase != LinkPhase.FULL -> "尚未同步到眼镜"
            session == null -> "未开启应用显示"
            session.phase == PagePhase.CLOSING ->
                if (state.intent == DisplayIntent.Idle) "正在关闭画面" else "正在切换画面"
            content == null -> "等待首个画面写出"
            session.content != content -> "正在更新 · 下方为上次写出内容"
            session.mode == PageMode.NAVIGATION -> "导航 · 已写出内容"
            else -> "实时提示 · 已写出内容"
        }
    Surface(
        color = LensBlack,
        contentColor = SignalGreen,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium)
            if (available) {
                if (session.mode == PageMode.NAVIGATION) NavigationGrid(content.text)
                else
                    Column(
                        Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(content.text, style = MaterialTheme.typography.titleMedium)
                        HorizontalDivider(color = SignalGreen.copy(alpha = .2f))
                        Text(content.answer.orEmpty(), style = MaterialTheme.typography.bodyLarge)
                    }
            } else {
                Text(
                    when {
                        state.ownership == DisplayOwnership.YIELDED -> "眼镜当前页面由设备控制，手机无法读取。"
                        state.link.phase != LinkPhase.FULL -> "完整连接后，显示本次会话写出的内容。"
                        session != null -> state.displayDescription
                        else -> "选择导航或打开实时提示。"
                    },
                    Modifier.padding(vertical = 20.dp),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
    Note("发送记录预览，非实时屏幕截图。", Modifier.padding(top = 8.dp))
}
