"""Bars 1–4: LED dot → two lenses → glasses; four official capabilities pop; all collapse."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K

GX, GY = CX, CY - 60
GS = 2.25
LW, LH, GAP, TH = 92 * GS, 70 * GS, 30 * GS, 9 * GS
LX = GAP / 2 + LW / 2          # lens centre offset
PILL_W, PILL_H = 82 * 1.6, 36 * 1.6

CIRC_L = S.Shape(S.circle(-LX, 0, 30 * GS))
CIRC_R = S.Shape(S.circle(LX, 0, 30 * GS))
LENS_L = S.Shape(S.rring(-LX, 0, LW, LH, 26 * GS, TH))
LENS_R = S.Shape(S.rring(LX, 0, LW, LH, 26 * GS, TH))


def _bridge():
    p = skia.Path()
    r = GAP / 2 + 2 * GS
    p.addArc(skia.Rect.MakeLTRB(-r, 8 * GS - r, r, 8 * GS + r), 200, 140)
    return p


def _temple(side):
    p = skia.Path()
    x0 = side * (GAP / 2 + LW)
    p.moveTo(x0, -LH / 2 + 14 * GS)
    p.lineTo(x0 + side * 22 * GS, -LH / 2 + 6 * GS)
    return p


BRIDGE, TEMPLE_L, TEMPLE_R = _bridge(), _temple(-1), _temple(1)

CHIPS = [  # label, icon, colour, position, pop time
    ('原生助手', S.ic_mic, C.CORAL, (CX - 640, GY - 190), B(3, 0)),
    ('全天智记', S.ic_clock, C.AMBER, (CX + 640, GY - 190), B(3, 1)),
    ('字幕与提示', S.ic_caption, C.BLUE, (CX - 640, GY + 170), B(3, 2)),
    ('原生录音', S.ic_record, C.VIOLET, (CX + 640, GY + 170), B(3, 3)),
]
SUCK_T = B(4, 1)


def _glasses(c, t):
    # morph progress circles -> lenses, and reverse at the end
    m_in = out_cubic(prog(t, B(2, 0.9), 0.5))
    m_out = in_out_cubic(prog(t, B(4, 2.0), 0.45))
    m = m_in * (1 - m_out)
    if t < B(2, 0.9) or t > B(4, 2.0) + 0.45:
        return
    col = mixc(C.MINT, C.PAPER, clamp(m * 1.4))
    for A, Bs in ((CIRC_L, LENS_L), (CIRC_R, LENS_R)):
        c.drawPath(S.morph_path(A, Bs, m), paint(col))
    # bridge + temples draw on, then retract
    d_in = out_cubic(prog(t, B(2, 1.6), 0.45))
    d_out = in_cubic(prog(t, B(4, 1.6), 0.35))
    d = d_in * (1 - d_out)
    if d > 0:
        K.draw_trim(c, BRIDGE, 0.5 - d / 2, 0.5 + d / 2, C.PAPER, TH)
        K.draw_trim(c, TEMPLE_L, 0, d, C.PAPER, TH)
        K.draw_trim(c, TEMPLE_R, 0, d, C.PAPER, TH)
    # status LED on the frame
    led = out_back(prog(t, B(2, 2.4), 0.4), 3) * (1 - in_cubic(prog(t, B(4, 1.4), 0.3)))
    if led > 0:
        lx, ly = LX + LW / 2 - 34 * GS, -LH / 2
        with Save(c):
            c.translate(lx, ly)
            c.scale(led, led)
            rrect_c(c, 0, 0, 40, 16, 8, paint(C.MINT, 0.6, blur=10))
            rrect_c(c, 0, 0, 40, 16, 8, paint(C.MINT))


def _goo_pill(c, t):
    """Pill LED: pops in, pulses, splits to two circles (gooey), re-merges at the end."""
    t_pop, t_split, t_take = B(1, 1), B(2, 0), B(2, 0.9)
    t_merge = B(4, 2.0) + 0.45
    if t < t_pop or t_take <= t < t_merge:
        return
    s = spring(prog(t, t_pop, 0.7))
    pul = 1 + 0.12 * (pulse(t, B(1, 2), 0.3) + pulse(t, B(1, 3), 0.3) + pulse(t, B(2, 0), 0.3))
    ant = out_cubic(prog(t, B(4, 3.0), 0.4))          # anticipation squash before the drop
    single = t < t_split
    with Layer(c, filt=goo_filter(9)):
        with Save(c):
            c.scale(1 + 0.35 * ant, 1 - 0.4 * ant)
            if single:
                c.scale(s * pul, s * pul)
                rrect_c(c, 0, 0, PILL_W, PILL_H, PILL_H / 2, paint(C.MINT))
            elif t < t_take:
                sp = out_back(prog(t, t_split, t_take - t_split), 1.3)
                r = lerp(PILL_H / 2, 30 * GS, out_cubic(prog(t, t_split, t_take - t_split)))
                for sx in (-1, 1):
                    c.drawCircle(sx * LX * sp, 0, r, paint(C.MINT))
                k = 1 - out_cubic(prog(t, t_split, 0.3))
                rrect_c(c, 0, 0, PILL_W * k, PILL_H * k, PILL_H * k / 2, paint(C.MINT))
            else:
                mp = in_out_cubic(prog(t, t_merge, 0.42))
                r = lerp(30 * GS, PILL_H / 2, mp)
                for sx in (-1, 1):
                    c.drawCircle(sx * LX * (1 - mp), 0, r, paint(C.MINT))
                rrect_c(c, 0, 0, PILL_W * mp, PILL_H * mp, PILL_H * mp / 2 + 0.01, paint(C.MINT))
    if single or t > t_merge + 0.3:
        a = 0.4 * s * pul
        rrect_c(c, 0, 0, PILL_W * 1.15, PILL_H * 1.15, PILL_H / 2, paint(C.MINT, a, blur=26))


def _chips(c, t):
    for i, (label, icon, col, (x, y), t0) in enumerate(CHIPS):
        if t < t0:
            continue
        ts = SUCK_T + i * 0.07
        q = in_back(prog(t, ts, 0.55), 1.6)
        gx, gy = GX, GY
        # connector line from glasses to chip
        la = out_cubic(prog(t, t0, 0.35)) * (1 - clamp(q * 3))
        if la > 0:
            sx = gx + (LX + LW / 2 + 30) * (1 if x > gx else -1)
            K.draw_trim(c, K.curve(sx, gy, x - (1 if x > gx else -1) * 150, y, 0, vertical=False),
                        0, la, C.PAPER, 3, 0.25)
        px, py = lerp(x, gx, q), lerp(y, gy, q)
        with Save(c):
            c.translate(px, py)
            sc = 1 - clamp(q) * 0.9
            c.scale(sc, sc)
            K.chip(c, 0, 0, label, t, t0, None, fg=C.INK, bg=col, icon=icon, icon_color=C.INK, size=40)
        # beat burst
        K.burst(c, x, y, t, t0, col, n=12, r0=170, r1=260, dur=0.45, width=6)


def draw(c, t):
    K.soft_bg(c, C.INK, 0.025)
    K.grid_dots(c, t, C.PAPER, 0.05)
    with Save(c):
        z = 1.0 + 0.04 * in_out_sine(prog(t, 0, B(5)))
        c.translate(CX, CY)
        c.scale(z, z)
        c.translate(-CX, -CY)
        _chips(c, t)
        with Save(c):
            c.translate(GX, GY)
            for k, tb in enumerate([B(1, 1), B(1, 2), B(1, 3), B(2, 0)]):
                p = prog(t, tb, 1.2)
                if 0 < p < 1:
                    r = lerp(70, 520, out_cubic(p))
                    c.drawCircle(0, 0, r, paint(C.MINT, 0.22 * (1 - p) ** 2, stroke=3))
            _glasses(c, t)
            _goo_pill(c, t)
    ty = GY + 360
    T.ktext(c, '你的雷鸟 iO 眼镜', CX, ty, 66, t, B(1, 2), B(2, 3.4), color=C.PAPER, align='center')
    words = '早已能听、能显示、能记录'
    cols = [C.PAPER] * len(words)
    for i in (3,):
        cols[i] = C.CORAL
    for i in (6, 7):
        cols[i] = C.BLUE
    for i in (10, 11):
        cols[i] = C.AMBER
    T.ktext(c, words, CX, ty, 58, t, B(3, 0), B(4, 0), color=C.PAPER, align='center', colors=cols,
            stagger=0.04)
    s3 = '现在，把它们交给你的 Agent'
    cols3 = [C.PAPER] * len(s3)
    for i in range(len(s3) - 5, len(s3)):
        cols3[i] = C.MINT
    T.ktext(c, s3, CX, ty, 66, t, B(4, 0.75), B(4, 3.0), color=C.PAPER, align='center', colors=cols3,
            stagger=0.035)
