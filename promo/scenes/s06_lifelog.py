"""Bars 17–20: all-day LifeLog — dial unrolls into a timeline, chunks, transcript, summaries, calendar."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s05_assistant import CARD

T0 = B(17)
DX, DY, DR = CX, 600, 220
TL_Y = 400
TL_X0, TL_X1 = 210, 1710
RING = S.Shape(S.circle(0, 0, DR - 13))
BAR = S.Shape(S.rrect_c(0, TL_Y - DY, TL_X1 - TL_X0 - 26, 0.6, 0.3))
T_UNROLL = B(17, 3)
T_CAL = B(20, 0)

CHUNKS = [(0.04, 0.10), (0.13, 0.17), (0.2, 0.31), (0.36, 0.40), (0.44, 0.52), (0.56, 0.60), (0.63, 0.74),
          (0.78, 0.83)]
LINES = [('09:12', C.MINTD, '本人', '今天先把同步协议定下来'),
         ('09:13', C.BLUE, '人物 1', '音频要不要默认同步？'),
         ('09:13', C.MINTD, '本人', '文字默认同步，音频按需取'),
         ('10:02', C.GRAY, '未知', '（多人混叠，已标注）')]


def _dial(c, t, a):
    sw = in_out_cubic(prog(t, T0 + 0.2, 1.2))
    with Save(c):
        c.translate(DX, DY)
        for h in range(24):
            ang = math.radians(h * 15 - 90)
            r0 = DR + 26 if h % 6 else DR + 18
            c.drawLine(math.cos(ang) * r0, math.sin(ang) * r0, math.cos(ang) * (DR + 40), math.sin(ang) * (DR + 40),
                       paint(C.INK, 0.35 * a, stroke=4 if h % 6 == 0 else 2))
        arc = skia.Path()
        arc.addArc(skia.Rect.MakeLTRB(-DR + 13, -DR + 13, DR - 13, DR - 13), -90 + 8 * 15, 13.5 * 15 * sw)
        c.drawPath(arc, paint(C.AMBER, a, stroke=26, cap='round'))
        hh = 8 + 13.5 * sw
        T.text(c, f'{int(hh):02d}:{int((hh % 1) * 60):02d}', 0, 30, 88, C.INK, a, family=T.NUM, weight=700,
               align='center')
        T.text(c, '全天智记 · 录制中', 0, 84, 26, C.GRAY2, a, weight=500, align='center')
        dot = 0.5 + 0.5 * math.sin(t * 8)
        c.drawCircle(-104, 76, 7, paint(C.CORAL, a * dot))


def draw(c, t):
    rp = prog(t, B(16, 2.8), 0.6)
    if rp < 1:
        K.circle_reveal_clip(c, CARD[0], CARD[1], lerp(0, 2200, in_out_cubic(rp)))
    K.soft_bg(c, C.PAPER, 0.02)
    K.grid_dots(c, t, C.INK, 0.05)
    K.headline(c, '全天智记', '自动保存 · 增量转写 · 滚动总结 · 日总结', 110, 160, t, T0 + 0.1, T_CAL - 0.2,
               color=C.INK, sub_color=C.GRAY2, size=64, sub_size=30, accent=C.AMBER)

    up = in_out_cubic(prog(t, T_UNROLL, 0.5))
    cal = in_out_cubic(prog(t, T_CAL, 0.5))
    # dial → bar morph
    if up < 1:
        _dial(c, t, 1 - clamp(up * 2.5))
    if t >= T0 and cal < 1:
        with Save(c):
            c.translate(DX, DY)
            s = out_back(prog(t, T0, 0.5), 1.8)
            c.scale(s, s)
            col = mixc(mixc(C.INK, C.INK, 0), C.INK3, up)
            a = 0.12 + 0.88 * up
            c.drawPath(S.morph_path(RING, BAR, up), paint(C.INK, a * (1 - cal), stroke=26))
    # hour labels + chunks on the bar
    if up > 0.95 and cal < 1:
        ka = 1 - cal
        for i, hh in enumerate(range(8, 23, 2)):
            x = lerp(TL_X0, TL_X1, i / 7)
            T.text(c, f'{hh:02d}:00', x, TL_Y + 54, 22, C.GRAY2, 0.8 * ka * clamp(prog(t, T_UNROLL + 0.4 + i * 0.03, 0.3)),
                   family=T.NUM, weight=700, align='center')
        for i, (a0, a1) in enumerate(CHUNKS):
            tc = B(18, 0) + i * 0.25
            p = out_back(prog(t, tc, 0.4), 2.0)
            if p <= 0:
                continue
            x0, x1 = lerp(TL_X0, TL_X1, a0), lerp(TL_X0, TL_X1, a1)
            yy = TL_Y - 90 * (1 - out_cubic(prog(t, tc, 0.3)))
            with Save(c):
                c.translate((x0 + x1) / 2, yy)
                c.scale(1, p)
                rrect_c(c, 0, 0, x1 - x0, 44, 14, paint(C.AMBER, ka))
                K.wave_bars(c, -(x1 - x0) / 2 + 8, (x1 - x0) / 2 - 8, 0, t * 0.2, C.INK, n=max(3, int((x1 - x0) / 14)),
                            hmax=26, a=0.35 * ka, seed=i, speed=0.2)
        K.chip(c, TL_X1 - 90, TL_Y - 72, '自动保存', t, B(18, 2), T_CAL, fg=C.INK, bg=C.WHITE,
               icon=S.ic_check, icon_color=C.MINTD, size=24)

    # transcript list (incremental)
    if cal < 1:
        for i, (tm, col, who, txt) in enumerate(LINES):
            ti = B(18, 1) + i * 0.5
            y = 540 + i * 82
            p = prog(t, ti, 0.4)
            if p <= 0:
                continue
            a = (1 - cal)
            e = out_cubic(p)
            with Save(c):
                c.translate(-40 * (1 - e), 0)
                T.text(c, tm, TL_X0, y, 26, C.GRAY2, a * e, family=T.NUM, weight=700)
                c.drawCircle(TL_X0 + 104, y - 9, 9, paint(col, a * e))
                T.text(c, who, TL_X0 + 124, y, 26, col, a * e, weight=600)
                T.ktext(c, txt, TL_X0 + 230, y, 32, t, ti + 0.05, None, color=C.INK, a=a, mode='type',
                        stagger=0.035)
        T.ktext(c, '增量转写', TL_X0, 900, 26, t, B(18, 1.2), T_CAL - 0.1, color=C.GRAY2, weight=500)

    # summary card
    sp = out_expo(prog(t, B(19, 0), 0.6))
    if sp > 0 and cal < 1:
        x0 = lerp(W + 40, 1060, sp) + 600 * in_cubic(cal)
        y0, w, h = 500, 650, 400
        rrect(c, x0 + 10, y0 + 14, w, h, 30, paint(C.INK, 0.08))
        rrect(c, x0, y0, w, h, 30, paint(C.WHITE))
        day = prog(t, B(19, 3), 0.3)
        hdr = mixc(C.AMBER, C.MINT, day)
        rrect(c, x0, y0, w, 86, 30, paint(hdr))
        c.drawRect(skia.Rect.MakeXYWH(x0, y0 + 50, w, 36), paint(hdr))
        if day < 0.5:
            with Save(c):
                c.translate(x0 + 50, y0 + 43)
                c.rotate(t * 360)
                arc = skia.Path()
                arc.addArc(skia.Rect.MakeLTRB(-15, -15, 15, 15), 0, 270)
                c.drawPath(arc, paint(C.INK, 1, stroke=5))
            T.text(c, '滚动总结 · 更新中', x0 + 86, y0 + 54, 32, C.INK)
        else:
            c.drawPath(S.ic_check(x0 + 50, y0 + 43, 0.75), paint(C.INK))
            T.text(c, '日总结 · 已生成', x0 + 86, y0 + 54, 32, C.INK)
            st = pulse(t, B(19, 3) + 0.15, 0.4)
            if st > 0:
                rrect(c, x0 - 8 * st, y0 - 8 * st, w + 16 * st, h + 16 * st, 34, paint(C.MINT, st, stroke=6))
        bl = ['· 同步协议：文字默认，音频按需', '· 待办：周五前调试声纹分段', '· 参与：本人、人物 1、未知 1']
        for i, s_ in enumerate(bl):
            T.typewriter(c, s_, x0 + 40, y0 + 160 + i * 74, 31, t, B(19, 0.6) + i * 0.55, cps=22, color=C.INK,
                         family=T.ZH, weight=500, cursor=False)

    # calendar month view
    if cal > 0:
        gx0, gy0, cw, chh = CX - 3.5 * 150, 330, 150, 118
        ap = cal
        T.ktext(c, '按天 / 按月浏览记录', CX, 250, 52, t, T_CAL + 0.2, None, color=C.INK, align='center')
        days = ['一', '二', '三', '四', '五', '六', '日']
        for j, d in enumerate(days):
            T.text(c, d, gx0 + cw * j + cw / 2, gy0 - 14, 24, C.GRAY2, ap, weight=500, align='center')
        for k in range(35):
            i, j = k % 7, k // 7
            ts = T_CAL + 0.05 + (i + j) * 0.035
            s = out_back(prog(t, ts, 0.4), 2.0)
            if s <= 0:
                continue
            x, y = gx0 + cw * i + cw / 2, gy0 + chh * j + chh / 2
            hot = k == 17
            fill = C.AMBER if hot else C.WHITE
            with Save(c):
                c.translate(x, y)
                c.scale(s, s)
                rrect_c(c, 0, 0, cw - 14, chh - 14, 18, paint(fill))
                T.text(c, str(k + 1), -cw / 2 + 22, -chh / 2 + 38, 24, C.INK, 0.8, family=T.NUM, weight=700)
                if hash01(k, 3.0) > 0.35 or hot:
                    n = 1 + int(hash01(k, 7.0) * 3)
                    for m in range(n):
                        c.drawCircle(-cw / 2 + 28 + m * 18, chh / 2 - 26, 6,
                                     paint([C.AMBER, C.BLUE, C.MINTD][m] if not hot else C.INK))
