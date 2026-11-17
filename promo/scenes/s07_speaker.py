"""Bars 21–24: dual-channel speaker processing; segments flow into unnamed person profiles."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K

T0 = B(21)
BG = hexrgb('#1F1A42')
BG2 = hexrgb('#2C2660')
L1_Y, L2_Y = 430, 650
WX0, WX1 = 430, 1790
N_BARS = 64
SCAN = (B(21, 2.5), B(22, 2.5))
T_FLY = B(22, 3)
SEGS = [(0.0, 0.22, C.BLUE, '人物 1'), (0.22, 0.38, C.CORAL, '人物 2'), (0.38, 0.5, C.GRAY, '未知'),
        (0.5, 0.62, None, '混叠'), (0.62, 0.84, C.BLUE, None), (0.84, 1.0, C.CORAL, None)]
PROF = [(860, 600, C.BLUE, '人物 1'), (1320, 600, C.CORAL, '人物 2')]


def _seg_color(f, i):
    for a, b, col, _ in SEGS:
        if a <= f < b:
            if col is None:
                return C.BLUE if i % 2 == 0 else C.CORAL
            return col
    return C.CORAL


def _lane_label(c, t, y, t0, name, tag, tag_col, note, a):
    T.ktext(c, name, 110, y + 12, 38, t, t0, None, color=C.WHITE, a=a)
    K.chip(c, 300, y, tag, t, t0 + 0.15, None, fg=C.INK, bg=tag_col, size=26, a=a)
    T.ktext(c, note, 110, y + 64, 22, t, t0 + 0.25, None, color=C.GRAY, a=a, weight=500, stagger=0.01)


def draw(c, t):
    rp = prog(t, B(20, 2.8), 0.6)
    if rp < 1:
        K.circle_reveal_clip(c, CX, 625, lerp(0, 2200, in_out_cubic(rp)))
    K.soft_bg(c, BG, 0.05)
    K.grid_dots(c, t, C.WHITE, 0.05)
    K.headline(c, '双通道说话人处理', '通道 1 默认本人 · 通道 2 声纹识别与分段', 110, 160, t, T0 + 0.1, None,
               color=C.WHITE, sub_color=C.PAPER, size=60, sub_size=30, accent=C.VIOLET)

    fly = prog(t, T_FLY, 0.9)
    lanes_a = 1 - out_cubic(prog(t, T_FLY + 0.3, 0.5))
    step = (WX1 - WX0) / N_BARS
    if lanes_a > 0:
        _lane_label(c, t, L1_Y, T0 + 0.3, '通道 1', '本人', C.MINT, '默认本人 · 跳过声纹', lanes_a)
        _lane_label(c, t, L2_Y, T0 + 0.6, '通道 2', '环境', C.GRAY, '声纹识别 + 说话人分段', lanes_a)
        r1 = out_cubic(prog(t, T0 + 0.4, 0.8))
        K.wave_bars(c, WX0, WX1, L1_Y, t, C.MINT, n=N_BARS, hmax=110, a=lanes_a, seed=1.0, reveal=r1)
        # lane 2: grey until the scan colours it
        r2 = out_cubic(prog(t, T0 + 0.7, 0.8))
        sp = in_out_sine(prog(t, *SCAN)) if t < SCAN[1] else 1.0
        sp = prog(t, SCAN[0], SCAN[1] - SCAN[0])
        cols = []
        for i in range(N_BARS):
            f = (i + 0.5) / N_BARS
            cols.append(_seg_color(f, i) if f < sp else mixc(C.GRAY2, C.GRAY, 0.3))
        # bars of lane 2 that are flying away are hidden here
        K.wave_bars(c, WX0, WX1, L2_Y, t + 0.7, C.GRAY, n=N_BARS, hmax=120, a=lanes_a if fly <= 0 else 0.0,
                    seed=2.0, reveal=r2, colors=cols)
        if SCAN[0] <= t < SCAN[1] + 0.2:
            x = lerp(WX0, WX1, sp)
            sa = 1 - clamp((t - SCAN[1]) / 0.2)
            c.drawLine(x, L2_Y - 110, x, L2_Y + 110, paint(C.WHITE, 0.9 * sa, stroke=4))
            c.drawRect(skia.Rect.MakeLTRB(x - 60, L2_Y - 110, x, L2_Y + 110), paint(C.WHITE, 0.06 * sa))
        # segment labels
        for a0, a1, col, lab in SEGS:
            if lab is None:
                continue
            tl = SCAN[0] + (a0 + a1) / 2 * (SCAN[1] - SCAN[0])
            xm = lerp(WX0, WX1, (a0 + a1) / 2)
            K.chip(c, xm, L2_Y - 118, lab, t, tl, T_FLY, fg=C.WHITE if col else C.INK,
                   bg=col if col else C.PAPER, size=22)

    # flying segments → profiles (gooey per colour)
    if fly > 0:
        for (px, py, col, name) in PROF:
            with Layer(c, filt=goo_filter(14)):
                for i in range(N_BARS):
                    f = (i + 0.5) / N_BARS
                    sc = _seg_color(f, i)
                    if sc != col:
                        continue
                    x0 = WX0 + (i + 0.5) * step
                    d = clamp(fly * 1.35 - hash01(i, 5.0) * 0.35)
                    e = in_out_cubic(d)
                    x = lerp(x0, px, e)
                    y = lerp(L2_Y, py, e) - math.sin(e * math.pi) * 120
                    r = lerp(step * 0.32, 26, e)
                    c.drawCircle(x, y, r, paint(col))
                g = out_back(prog(t, T_FLY + 0.55, 0.5), 1.6)
                if g > 0:
                    c.drawCircle(px, py, 108 * g, paint(col))
        # unknown / mixed stay marked
        um = out_back(prog(t, T_FLY + 0.6, 0.45), 2.0)
        if um > 0:
            with Save(c):
                c.translate(1700, 600)
                c.scale(um, um)
                p = paint(C.GRAY, 0.9, stroke=5)
                p.setPathEffect(skia.DashPathEffect.Make([16, 12], t * 30))
                c.drawCircle(0, 0, 78, p)
                T.text(c, '?', 0, 26, 74, C.GRAY, family=T.EN, weight=700, align='center')
            T.ktext(c, '未知 / 混叠', 1700, 760, 30, t, T_FLY + 0.75, None, color=C.GRAY, align='center')
            T.ktext(c, '如实标注 · 照常交付', 1700, 814, 22, t, T_FLY + 0.85, None, color=C.GRAY, weight=500,
                    align='center', stagger=0.01)

    # profile icons, names, renaming
    for k, (px, py, col, name) in enumerate(PROF):
        ia = out_back(prog(t, T_FLY + 0.75, 0.45), 2.2)
        if ia <= 0:
            continue
        with Save(c):
            c.translate(px, py)
            c.scale(ia, ia)
            c.drawPath(S.ic_person(0, 6, 1.35), paint(C.WHITE))
        if k == 0:
            # rename 人物 1 → 导师
            t_ren = B(23, 3)
            if t < t_ren:
                T.ktext(c, name, px, py + 160, 34, t, T_FLY + 0.85, t_ren - 0.1, color=C.WHITE, align='center')
            else:
                bw = out_back(prog(t, t_ren, 0.4), 1.8)
                rrect_c(c, px, py + 148, 220 * bw, 64, 32, paint(C.WHITE, 0.12 + 0.1 * bw))
                rrect_c(c, px, py + 148, 220 * bw, 64, 32, paint(col, bw, stroke=3))
                k_, done = T.typewriter(c, '导师', px - 36, py + 160, 36, t, t_ren + 0.25, cps=6,
                                        color=C.WHITE, family=T.ZH, weight=600, cursor=True,
                                        cursor_color=col)
            T.ktext(c, '来自 3 条记录 · 自动关联', px, py + 214, 22, t, T_FLY + 1.0, None, color=C.PAPER,
                    a=0.7, weight=500, align='center', stagger=0.01)
        else:
            T.ktext(c, name, px, py + 160, 34, t, T_FLY + 0.95, None, color=C.WHITE, align='center')
            T.ktext(c, '来自 2 条记录 · 自动关联', px, py + 214, 22, t, T_FLY + 1.1, None, color=C.PAPER,
                    a=0.7, weight=500, align='center', stagger=0.01)
    # correction tools
    tools = [('命名', C.WHITE), ('合并', C.WHITE), ('拆分', C.WHITE), ('批量纠正历史', C.WHITE)]
    for i, (lab, col) in enumerate(tools):
        K.chip(c, 110, 500 + i * 84, lab, t, B(24, 0) + i * 0.12, None, fg=C.INK, bg=col, size=28,
               align='left')
    T.ktext(c, '跨记录人物档案', 110, 420, 42, t, B(23, 2.5), None, color=C.WHITE)
    T.ktext(c, '自动关联未命名人物 · 可随时纠正', 110, 900, 26, t, B(24, 0.8), None, color=C.PAPER, a=0.7,
            weight=500, stagger=0.012)
