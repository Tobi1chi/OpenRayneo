"""Bars 31–32: phone ⇄ Mac meet-up sync; agent results flow back."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K

T0 = B(31)
Y = 610
T_MEET = T0 + 0.9
T_IMPLODE = B(32, 3.2)
STRIPES = [(C.MINT, 0.0), (C.AMBER, 0.06), (C.PAPER, 0.12)]


def _stripe_clip(t, delay):
    """Diagonal band sweeping left → right; returns progress."""
    return in_out_cubic(prog(t, B(30, 3.0) + delay, 0.45))


def _band_path(p):
    # a wide band rotated 20°, whose right edge moves across the screen
    x = lerp(-700, W + 700, p)
    return S.xform(S.rrect(-2600, -1400, 2600 + 0, 2800, 0), x, CY, rot=20)


def _card(c, x, y, w, h, col, icon, label, a=1.0, s=1.0):
    with Save(c):
        c.translate(x, y)
        c.scale(s, s)
        rrect_c(c, 0, 0, w, h, 18, paint(col, a))
        c.drawPath(icon(-w / 2 + 34, 0, 0.42), paint(C.WHITE, a))
        T.text(c, label, -w / 2 + 62, 10, 26, C.WHITE, a)


def draw(c, t):
    # striped wipe in
    for col, d in STRIPES:
        p = _stripe_clip(t, d)
        if p < 1 and col is not C.PAPER:
            c.drawPath(_band_path(p), paint(col))
    pp = _stripe_clip(t, STRIPES[-1][1])
    if pp < 1:
        c.clipPath(_band_path(pp), skia.ClipOp.kIntersect, True)
    K.soft_bg(c, C.PAPER, 0.02)
    K.grid_dots(c, t, C.INK, 0.05)
    imp = in_back(prog(t, T_IMPLODE, 0.4), 1.5)
    K.headline(c, '相遇同步', '离线各自积累 · 见面自动补齐 · 音频按需获取', 110, 160, t, T0 + 0.05, T_IMPLODE - 0.2,
               color=C.INK, sub_color=C.GRAY2, size=60, sub_size=30, accent=C.AMBER)
    with Save(c):
        c.translate(CX, Y)
        c.scale(1 - imp, 1 - imp)
        c.translate(-CX, -Y)
        app = out_cubic(prog(t, T0, 0.9))
        mx = lerp(260, 560, app)
        px = lerp(W - 260, W - 560, app)
        c.drawPath(S.ic_laptop(mx, Y, 2.1), paint(C.INK))
        c.drawPath(S.ic_phone(px, Y, 1.75), paint(C.INK))
        T.text(c, 'Mac', mx, Y + 150, 36, C.INK, family=T.EN, weight=700, align='center')
        T.text(c, '本机 Agent 读取 / 回写', mx, Y + 196, 26, C.GRAY2, weight=500, align='center')
        T.text(c, '手机', px, Y + 150, 36, C.INK, align='center')
        T.text(c, '采集 · 转写 · 总结', px, Y + 196, 26, C.GRAY2, weight=500, align='center')
        # meet-up: wifi + rings
        ms = out_back(prog(t, T_MEET, 0.45), 2.2)
        if ms > 0:
            for k in range(3):
                p = ((t - T_MEET) * 0.9 - k * 0.33) % 1.0
                c.drawCircle(CX, Y - 40, 60 + 160 * p, paint(C.AMBER, 0.5 * (1 - p), stroke=4))
            with Save(c):
                c.translate(CX, Y - 40)
                c.scale(ms, ms)
                c.drawCircle(0, 0, 62, paint(C.AMBER))
                c.drawPath(S.ic_wifi(0, -6, 0.85), paint(C.INK))
            T.ktext(c, '同一局域网 · 相遇即同步', CX, Y + 80, 28, t, T_MEET + 0.1, None, color=C.INK,
                    align='center', stagger=0.015)
        # records phone → Mac (upper arc)
        recs = [(C.AMBER, S.ic_doc, '转写'), (C.BLUE, S.ic_chat, '总结'), (C.VIOLET, S.ic_person, '人物')]
        for i, (col, icon, lab) in enumerate(recs):
            ts = T_MEET + 0.25 + i * 0.22
            p = prog(t, ts, 0.75)
            if p <= 0:
                continue
            e = in_out_cubic(p)
            path = K.arc_path(px - 60, Y - 120, mx + 80, Y - 120, 300)
            pm = skia.PathMeasure(path, False, 1)
            pos, _ = pm.getPosTan(pm.getLength() * e)
            land = p >= 1
            if land:
                k = i
                _card(c, mx + 210, Y - 210 + k * 0, 150, 52, col, icon, lab, a=0.0)
                # stack near the laptop
                _card(c, mx - 10 + (k - 1) * 0, Y - 150 - 62 * k, 170, 54, col, icon, lab)
            else:
                _card(c, pos.x(), pos.y(), 170, 54, col, icon, lab, s=lerp(0.6, 1, math.sin(e * math.pi) * 0.5 + 0.5))
        # agent results Mac → phone (lower arc)
        res = ['分析', '标签', '笔记']
        for i, lab in enumerate(res):
            ts = B(32, 0.5) + i * 0.22
            p = prog(t, ts, 0.75)
            if p <= 0:
                continue
            e = in_out_cubic(p)
            path = K.arc_path(mx + 80, Y + 40, px - 60, Y + 40, -230)
            pm = skia.PathMeasure(path, False, 1)
            pos, _ = pm.getPosTan(pm.getLength() * e)
            if p >= 1:
                x, y = px + 6, Y - 150 - 62 * i
            else:
                x, y = pos.x(), pos.y()
            with Save(c):
                c.translate(x, y)
                rrect_c(c, 0, 0, 150, 52, 26, paint(C.MINT))
                c.drawPath(S.ic_spark(-48, 0, 0.3), paint(C.INK))
                T.text(c, lab, 14, 10, 26, C.INK, align='center')
        # audio on demand (dashed)
        ap = out_cubic(prog(t, B(32, 1.5), 0.9))
        if ap > 0:
            x = lerp(px - 40, CX + 120, ap)
            y = Y + 300
            p = paint(C.GRAY2, 0.9, stroke=3)
            p.setPathEffect(skia.DashPathEffect.Make([10, 8], t * 20))
            rrect_c(c, x, y, 220, 58, 29, p)
            K.wave_bars(c, x - 90, x - 20, y, t, C.GRAY2, n=6, hmax=26, a=0.9, seed=4)
            T.text(c, '音频 · 按需', x + 34, y + 10, 26, C.GRAY2, weight=600, align='center')
    # implode into a dot
    if imp > 0.7:
        r = 26 * (imp - 0.7) / 0.3
        c.drawCircle(CX, Y, r, paint(C.INK))
