// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationParserAndGridTest {
    @Test
    fun parserRecognizesStandardTurnsAndKilometerDistances() {
        assertEquals(
            GaodeNotificationParser.Instruction("直行", 314),
            GaodeNotificationParser.parse(listOf("直行314米｜高德导航中")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("右前", 1200),
            GaodeNotificationParser.parse(listOf("前方1.2公里向右前方行驶进入辅路")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("掉头", 150),
            GaodeNotificationParser.parse(listOf("150米后左转掉头")),
        )
    }

    @Test
    fun parserRecognizesRoundaboutsRampsKeepLaneAndArrival() {
        assertEquals(
            GaodeNotificationParser.Instruction("环岛", 200),
            GaodeNotificationParser.parse(listOf("前方200米进入环岛")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("环岛", 300),
            GaodeNotificationParser.parse(listOf("300米后进入环岛，从第2出口驶出")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("环岛", 180),
            GaodeNotificationParser.parse(listOf("环岛第3出口180米｜高德导航中")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("环岛", 0),
            GaodeNotificationParser.parse(listOf("请从第2个出口驶出环岛")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("靠右", 200),
            GaodeNotificationParser.parse(listOf("200米后，靠右行驶进入辅路")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("靠左", 350),
            GaodeNotificationParser.parse(listOf("350米走左侧辅路")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("靠右", 500),
            GaodeNotificationParser.parse(listOf("前方500米右侧上匝道")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("靠左", 180),
            GaodeNotificationParser.parse(listOf("180米后进入左转专用道")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("到达", 50),
            GaodeNotificationParser.parse(listOf("前方50米到达目的地")),
        )
        assertEquals(
            GaodeNotificationParser.Instruction("到达", 0),
            GaodeNotificationParser.parse(listOf("即将到达目的地｜高德导航中")),
        )
        assertNull(GaodeNotificationParser.parse(listOf("高德地图正在后台持续导航")))
        assertNull(GaodeNotificationParser.parse(listOf("前方15公里直行")))
    }

    @Test
    fun navigationFramePreservesStrict20x5GridAcrossManeuversAndComplexUnicode() {
        val directions = listOf("左转", "右转", "左前", "右前", "靠左", "靠右", "环岛", "到达", "掉头", "直行", "其他")
        for (direction in directions) {
            val rendered = NavigationFrame.render(direction, 260, "北四环西路")
            assertTrue("Grid invariant failed for $direction", NavigationFrame.isGrid(rendered))
        }

        val noisyLabel = "🚀🅿️北四环·辅路(12号)—直达\n\t👨‍👩‍👧‍👦超长道路名称测试不会越界"
        val rendered = NavigationFrame.render("靠右", 0, noisyLabel)
        assertTrue(NavigationFrame.isGrid(rendered))
        val rows = rendered.split('\n')
        assertEquals(5, rows.size)
        assertTrue(rows[1].contains("现在"))
        // Road label starts at column 12 (8 cells: columns 12..19).
        assertEquals("北四环．辅路（１", rows[4].substring(12, 20))

        val statusGrid = NavigationFrame.status("🚀路线·更新(1)—A\nB")
        assertTrue(NavigationFrame.isGrid(statusGrid))
        assertTrue(statusGrid.split('\n')[1].contains("路线．更新（１）－Ａ　Ｂ"))
    }
}
