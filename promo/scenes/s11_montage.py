"""Bars 33–34: one keyword per beat; background shapes morph on the beat."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s10_sync import Y as SYNC_Y

T0 = B(33)
WORDS = [('Swift', C.BLUE, C.WHITE), ('Kotlin', C.VIOLET, C.WHITE), ('macOS 13+', C.INK, C.WHITE),
         ('Android 13+', C.MINT, C.INK), ('本机 API', C.CORAL, C.WHITE), ('Agent Skill', C.AMBER, C.INK),
         ('Apache-2.0', C.INK2, C.MINT), ('开源', C.MINT, C.INK)]


def _star(r):
    pts = []
    for i in range(16):
        a = -math.pi / 2 + i * math.pi / 8
        rr = r if i % 2 == 0 else r * 0.62
        pts.append((math.cos(a) * rr, math.sin(a) * rr))
    return S.union(S.poly(pts), S.stroke_to_fill(S.poly(pts), 60))


def _hex(r):
    pts = [(math.cos(math.radians(60 * i)) * r, math.sin(math.radians(60 * i)) * r) for i in range(6)]
    return S.union(S.poly(pts), S.stroke_to_fill(S.poly(pts), 80))


SHAPES = [S.Shape(S.circle(0, 0, 300)), S.Shape(S.rrect_c(0, 0, 520, 520, 120)), S.Shape(_hex(300)),
          S.Shape(_star(320)), S.Shape(S.rrect_c(0, 0, 760, 300, 150)), S.Shape(S.circle(0, 0, 300)),
          S.Shape(_hex(300)), S.Shape(S.rrect_c(0, 0, 520, 520, 120))]


def _beat(t):
    return (t - T0) / BEAT


def draw(c, t):
    b = _beat(t)
    k = int(math.floor(b))
    # entry: the sync dot grows into the first colour
    if t < T0:
        p = in_out_cubic(prog(t, B(32, 3.2) + 0.2, 0.2))
        c.drawCircle(CX, lerp(SYNC_Y, CY, p), lerp(26, 0, 0), paint(C.INK))
        return
    k = clamp(k, 0, 7)
    k = int(k)
    word, col, fg = WORDS[k]
    prev_col = WORDS[k - 1][1] if k > 0 else C.PAPER
    f = b - k
    # background: previous colour, new colour floods from a morphing shape
    c.drawColor(c4(prev_col))
    grow = out_cubic(clamp(f / 0.55))
    sc = lerp(0.0, 6.5, grow)
    with Save(c):
        c.translate(CX, CY)
        c.rotate(k * 37 + grow * 40)
        c.scale(sc, sc)
        c.drawPath(SHAPES[k].path, paint(col))
    # accent shape that morphs from beat to beat (outline)
    with Save(c):
        c.translate(CX, CY)
        mp = in_out_cubic(clamp(f / 0.35))
        idx = min(k + mp, 7.0)
        c.rotate(-k * 25 - mp * 25)
        s = 1.0 + 0.08 * math.exp(-6 * f)
        c.scale(s, s)
        c.drawPath(S.morph_chain(SHAPES, idx), paint(fg, 0.14))
    # orbiting confetti
    for i in range(10):
        ang = i * 2 * math.pi / 10 + t * 0.9
        rr = 430 + 40 * math.sin(t * 3 + i)
        x, y = CX + math.cos(ang) * rr * 1.25, CY + math.sin(ang) * rr * 0.75
        sz = 10 + 8 * hash01(i, 2.0)
        if i % 3 == 0:
            c.drawCircle(x, y, sz, paint(fg, 0.6))
        elif i % 3 == 1:
            rrect_c(c, x, y, sz * 2.4, sz * 1.0, sz * 0.5, paint(fg, 0.6))
        else:
            c.drawPath(S.ic_spark(x, y, sz / 40), paint(fg, 0.6))
    # the word
    size = 168 if T.width(word, 168) < 1500 else 140
    mode = 'pop' if T.is_cjk(word) else 'scramble'
    T.ktext(c, word, CX, CY + 58, size, t, T0 + k * BEAT, None, color=fg, family=None, weight=700,
            align='center', mode=mode, stagger=0.012, dur=0.16 if mode == 'scramble' else 0.3)
    # counter
    T.text(c, f'{k + 1:02d} / 08', CX, CY + 230, 28, fg, 0.6, family=T.NUM, weight=700, align='center')
    # final implode into the pill
    imp = in_cubic(prog(t, B(34, 3.0), 0.42))
    if imp > 0:
        r = lerp(1400, 0, imp)
        hole = S.diff(S.rrect(-50, -50, W + 100, H + 100, 0), S.circle(CX, CY, r))
        c.drawPath(hole, paint(C.INK))
        pl = out_back(prog(t, B(34, 3.0) + 0.3, 0.15), 2.0)
        if pl > 0:
            rrect_c(c, CX, CY, 110 * pl, 48 * pl, 24 * pl, paint(C.MINT))
