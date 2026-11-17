"""Kinetic typography on Skia: per-character reveals, typewriter, scramble."""
import math
import skia

from core import (C, clamp, lerp, prog, out_cubic, out_quart, out_back, in_cubic, in_quart,
                  out_expo, paint, hash01, Save)
from shapes import typeface

ZH = 'PingFang SC'
EN = 'Avenir Next'
MONO = 'Menlo'
NUM = 'DIN Alternate'

_FONTS = {}


def is_cjk(s):
    return any('⺀' <= ch <= '￯' for ch in s)


def font(size, family=None, weight=600, s=''):
    fam = family or (ZH if is_cjk(s) else EN)
    if fam == EN and is_cjk(s):
        fam = ZH
    key = (fam, weight, round(size, 2))
    f = _FONTS.get(key)
    if f is None:
        f = skia.Font(typeface(fam, weight), size)
        f.setSubpixel(True)
        f.setEdging(skia.Font.Edging.kAntiAlias)
        f.setHinting(skia.FontHinting.kNone)
        f.setLinearMetrics(True)
        if len(_FONTS) > 4000:
            _FONTS.clear()
        _FONTS[key] = f
    return f


def advances(s, f, tracking=0.0):
    glyphs = f.textToGlyphs(s)
    ws = f.getWidths(glyphs)
    return [w + tracking * f.getSize() for w in ws]


def width(s, size, family=None, weight=600, tracking=0.0):
    f = font(size, family, weight, s)
    adv = advances(s, f, tracking)
    return sum(adv) - (tracking * size if s else 0)


def text(c, s, x, y, size, color=C.INK, a=1.0, family=None, weight=600, align='left',
         tracking=0.0):
    """Static line. (x, y) is the baseline anchor."""
    if not s or a <= 0.001:
        return
    f = font(size, family, weight, s)
    w = width(s, size, family, weight, tracking)
    if align == 'center':
        x -= w / 2
    elif align == 'right':
        x -= w
    p = paint(color, a)
    if tracking == 0:
        c.drawString(s, x, y, f, p)
        return
    adv = advances(s, f, tracking)
    for ch, aw in zip(s, adv):
        c.drawString(ch, x, y, f, p)
        x += aw


def ktext(c, s, x, y, size, t, t_in, t_out=None, color=C.INK, a=1.0, family=None, weight=600,
          align='left', mode='rise', stagger=0.028, dur=0.55, tracking=0.0, out_mode='rise',
          out_dur=0.4, colors=None):
    """Animated line.

    mode: rise | pop | type | scramble | fade | drop
    colors: optional per-character color list (for highlighted words)
    """
    if not s or t < t_in:
        return
    f = font(size, family, weight, s)
    adv = advances(s, f, tracking)
    total = sum(adv) - tracking * size
    if align == 'center':
        x -= total / 2
    elif align == 'right':
        x -= total
    m = f.getMetrics()
    asc, desc = -m.fAscent, m.fDescent
    n = len(s)
    clip_rect = skia.Rect.MakeLTRB(x - size, y - asc * 1.15, x + total + size, y + desc * 1.4)
    with Save(c):
        if mode in ('rise',) or out_mode == 'rise':
            c.clipRect(clip_rect, skia.ClipOp.kIntersect, True)
        cx = x
        for i, ch in enumerate(s):
            aw = adv[i]
            col = colors[i] if colors else color
            if mode == 'type':
                p = 1.0 if t >= t_in + i * stagger else 0.0
            else:
                p = prog(t, t_in + i * stagger, dur)
            if t_out is not None:
                q = prog(t, t_out + i * stagger * 0.6, out_dur)
            else:
                q = 0.0
            if p <= 0 or q >= 1:
                cx += aw
                continue
            alpha = a
            dy = 0.0
            sc = 1.0
            glyph = ch
            if mode == 'rise':
                e = out_quart(p)
                dy = (1 - e) * (asc + desc) * 1.05
            elif mode == 'drop':
                e = out_back(p, 2.2)
                dy = -(1 - e) * size * 0.6
                alpha *= clamp(p * 3)
            elif mode == 'pop':
                sc = out_back(p, 2.6)
                alpha *= clamp(p * 4)
            elif mode == 'fade':
                alpha *= out_cubic(p)
                dy = (1 - out_cubic(p)) * size * 0.25
            elif mode == 'scramble':
                if p < 1.0 and ch.strip():
                    pool = '01ABCDEFGHJKLMNOPQRSTUVWXYZ#$%&*+=<>/\\'
                    k = int(hash01(i, math.floor(t * 30)) * len(pool))
                    glyph = pool[k] if p < 0.85 else ch
                alpha *= clamp(p * 5)
            if q > 0:
                if out_mode == 'rise':
                    dy -= in_quart(q) * (asc + desc) * 1.05
                elif out_mode == 'fade':
                    alpha *= 1 - q
                elif out_mode == 'pop':
                    sc *= 1 - in_cubic(q)
            if sc <= 0.001 or alpha <= 0.001:
                cx += aw
                continue
            pnt = paint(col, alpha)
            if glyph != ch:
                # scrambled glyph: centre it in the real glyph's advance and squeeze if wider
                gw = f.measureText(glyph)
                sx = min(1.0, aw * 0.92 / max(gw, 1e-3))
                with Save(c):
                    c.translate(cx + aw / 2, y + dy)
                    c.scale(sx * sc, sc)
                    c.drawString(glyph, -gw / 2, 0, f, pnt)
            elif sc != 1.0:
                with Save(c):
                    c.translate(cx + aw / 2, y - asc * 0.38)
                    c.scale(sc, sc)
                    c.drawString(glyph, -aw / 2, asc * 0.38 + dy, f, pnt)
            else:
                c.drawString(glyph, cx, y + dy, f, pnt)
            cx += aw
    return total


def typewriter(c, s, x, y, size, t, t0, cps=28.0, color=C.WHITE, family=MONO, weight=400,
               cursor=True, cursor_color=None, a=1.0):
    """Characters appear at cps; returns (visible_count, done)."""
    n = len(s)
    k = int(clamp((t - t0) * cps, 0, n)) if t >= t0 else 0
    f = font(size, family, weight, s[:1] if family != MONO else 'a')
    vis = s[:k]
    w = 0.0
    if vis:
        # draw runs, falling back to PingFang for CJK in non-CJK fonts
        run, cjk = '', None
        for ch in vis + '\0':
            cj = is_cjk(ch)
            if ch == '\0' or (cjk is not None and cj != cjk):
                if run:
                    rf = font(size, ZH if cjk else family, weight if cjk is False else max(weight, 400), run) if cjk else f
                    c.drawString(run, x + w, y, rf, paint(color, a))
                    w += sum(advances(run, rf))
                run = ''
            run += ch
            cjk = cj
    if cursor and t >= t0 - 0.3:
        blink = 1.0 if (k < n or math.floor(t * 2.5) % 2 == 0) else 0.0
        if blink:
            m = f.getMetrics()
            c.drawRect(skia.Rect.MakeXYWH(x + w + 2, y + m.fAscent * 0.85, size * 0.55, -m.fAscent * 1.0),
                       paint(cursor_color or color, a * 0.9))
    return k, k >= n
