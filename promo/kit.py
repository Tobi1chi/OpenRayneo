"""Reusable scene widgets: chips, cards, flows, HUD panels, headlines, wipes."""
import math
import skia

from core import (C, W, H, CX, CY, clamp, lerp, prog, E, kf, out_cubic, out_back, out_quart, out_expo,
                  in_cubic, in_quart, in_out_cubic, spring, paint, Save, Layer, rrect, rrect_c, mixc,
                  hash01, pulse)
import shapes as S
import typo as T


def draw_path(c, path, color, a=1.0):
    if a > 0.001:
        c.drawPath(path, paint(color, a))


def pop_scale(t, t0, dur=0.5, amt=2.4):
    return out_back(prog(t, t0, dur), amt)


def squash(t, t0, dur=0.6):
    """(sx, sy) squash-and-stretch on landing."""
    p = prog(t, t0, dur)
    if p <= 0 or p >= 1:
        return 1.0, 1.0
    k = math.exp(-5 * p) * math.sin(p * math.pi * 3.2) * 0.22
    return 1 + k, 1 - k


def headline(c, title, sub, x, y, t, t_in, t_out=None, color=C.WHITE, sub_color=None, size=66,
             sub_size=30, accent=None, align='left'):
    """Title + subtitle with an accent bar."""
    if t < t_in:
        return
    sub_color = sub_color or color
    if accent is not None:
        bw = 64 * out_expo(prog(t, t_in, 0.5))
        if t_out is not None:
            bw *= 1 - in_cubic(prog(t, t_out, 0.3))
        if bw > 0.5:
            bx = x if align == 'left' else x - 32
            rrect(c, bx, y - size - 30, bw, 10, 5, paint(accent))
    T.ktext(c, title, x, y, size, t, t_in + 0.05, t_out, color=color, weight=600, align=align,
            mode='rise', stagger=0.03, dur=0.6)
    if sub:
        T.ktext(c, sub, x, y + sub_size + 30, sub_size, t, t_in + 0.25,
                None if t_out is None else t_out + 0.05, color=sub_color, a=0.72, weight=500,
                align=align, mode='rise', stagger=0.012, dur=0.5)


def chip(c, x, y, label, t, t_in, t_out=None, fg=C.INK, bg=C.WHITE, icon=None, icon_color=None,
         size=30, pad=26, h=None, a=1.0, align='center', weight=600, stroke=None):
    """Pill label with optional icon path factory (called with cx, cy, s)."""
    if t < t_in:
        return 0
    s = pop_scale(t, t_in, 0.55)
    if t_out is not None:
        s *= 1 - in_quart(prog(t, t_out, 0.3))
    if s <= 0.001:
        return 0
    h = h or size * 2.0
    tw = T.width(label, size, weight=weight)
    iw = h * 0.9 if icon else 0
    w = tw + pad * 2 + iw
    with Save(c):
        c.translate(x, y)
        c.scale(s, s)
        ox = -w / 2 if align == 'center' else 0
        rrect(c, ox, -h / 2, w, h, h / 2, paint(bg, a))
        if stroke:
            rrect(c, ox, -h / 2, w, h, h / 2, paint(stroke, a, stroke=3))
        if icon:
            ip = icon(ox + pad + iw * 0.38, 0, h / 150)
            c.drawPath(ip, paint(icon_color or fg, a))
        T.text(c, label, ox + pad + iw, size * 0.36, size, fg, a, weight=weight)
    return w


def flow_dots(c, path, t, color, speed=0.6, n=4, r=7, a=1.0, phase=0.0, t0=None, t1=None):
    """Dots travelling along a path (fraction/second = speed)."""
    if t0 is not None and t < t0:
        return
    if t1 is not None and t > t1:
        return
    pm = skia.PathMeasure(path, False, 1)
    L = pm.getLength()
    if L <= 0:
        return
    for i in range(n):
        f = ((t - (t0 or 0)) * speed + i / n + phase) % 1.0
        pos, _ = pm.getPosTan(f * L)
        edge = clamp(min(f, 1 - f) * 8)
        c.drawCircle(pos.x(), pos.y(), r, paint(color, a * edge))


def draw_trim(c, path, a0, a1, color, width, alpha=1.0, cap='round'):
    if a1 <= a0 + 1e-4 or alpha <= 0.001:
        return
    c.drawPath(_trim(path, a0, a1), paint(color, alpha, stroke=width, cap=cap))


def _trim(path, a, b):
    pm = skia.PathMeasure(path, False, 1)
    L = pm.getLength()
    dst = skia.Path()
    if L > 0:
        pm.getSegment(L * clamp(a), L * clamp(b), dst, True)
    return dst


def curve(x0, y0, x1, y1, bend=0.0, vertical=True):
    p = skia.Path()
    p.moveTo(x0, y0)
    if vertical:
        my = (y0 + y1) / 2
        p.cubicTo(x0, my + bend, x1, my - bend, x1, y1)
    else:
        mx = (x0 + x1) / 2
        p.cubicTo(mx + bend, y0, mx - bend, y1, x1, y1)
    return p


def arc_path(x0, y0, x1, y1, lift):
    p = skia.Path()
    p.moveTo(x0, y0)
    p.quadTo((x0 + x1) / 2, (y0 + y1) / 2 - lift, x1, y1)
    return p


def shockwave(c, x, y, t, t0, color=C.WHITE, rmax=900, dur=0.9, width=26, n=3, gap=0.09):
    for k in range(n):
        p = prog(t, t0 + k * gap, dur)
        if 0 < p < 1:
            r = rmax * out_expo(p) * (1 - 0.18 * k)
            c.drawCircle(x, y, r, paint(color, (1 - p) ** 1.5 * (0.9 - 0.25 * k), stroke=width * (1 - p) + 1))


def burst(c, x, y, t, t0, color=C.WHITE, n=12, r0=40, r1=220, dur=0.5, width=8, rot=0.0):
    p = prog(t, t0, dur)
    if p <= 0 or p >= 1:
        return
    a = out_cubic(p)
    b = out_cubic(clamp(p * 1.6 - 0.35))
    for i in range(n):
        ang = rot + i * 2 * math.pi / n
        ca, sa = math.cos(ang), math.sin(ang)
        ra, rb = lerp(r0, r1, b), lerp(r0, r1, a)
        if rb - ra > 0.5:
            c.drawLine(x + ca * ra, y + sa * ra, x + ca * rb, y + sa * rb,
                       paint(color, 1 - p * 0.5, stroke=width * (1 - p) + 1))


def circle_reveal_clip(c, x, y, r):
    p = skia.Path()
    p.addCircle(x, y, max(0.0, r))
    c.clipPath(p, skia.ClipOp.kIntersect, True)


def glow_text(c, s, x, y, size, color=C.HUD, a=1.0, align='left', weight=500, family=None, glow=10):
    if a <= 0.001:
        return
    f = T.font(size, family, weight, s)
    w = T.width(s, size, family, weight)
    if align == 'center':
        x -= w / 2
    elif align == 'right':
        x -= w
    c.drawString(s, x, y, f, paint(color, a * 0.55, blur=glow))
    c.drawString(s, x, y, f, paint(color, a))


def hud_panel(c, x, y, w, h, t, t_in, a=1.0, r=36, fill=C.INK2, edge=C.HUD):
    """Dark rounded HUD 'lens' with corner brackets."""
    s = out_back(prog(t, t_in, 0.55), 1.4)
    if s <= 0:
        return
    with Save(c):
        c.translate(x + w / 2, y + h / 2)
        c.scale(lerp(0.6, 1, s), s)
        rrect(c, -w / 2, -h / 2, w, h, r, paint(fill, a))
        rrect(c, -w / 2, -h / 2, w, h, r, paint(edge, a * 0.18, stroke=2))
        L = 46
        bp = paint(edge, a * 0.8, stroke=5, cap='round')
        for sx in (-1, 1):
            for sy in (-1, 1):
                px, py = sx * (w / 2 - 22), sy * (h / 2 - 22)
                c.drawLine(px, py, px - sx * L, py, bp)
                c.drawLine(px, py, px, py - sy * L, bp)


def grid_dots(c, t, color, a=0.08, step=48, r=2.2, drift=10.0):
    """Subtle dot grid background that drifts slowly."""
    ox = (t * drift) % step
    oy = (t * drift * 0.5) % step
    p = paint(color, a)
    pts = []
    y = -step + oy
    while y < H + step:
        x = -step + ox
        while x < W + step:
            pts.append(skia.Point(x, y))
            x += step
        y += step
    p.setStrokeWidth(r * 2)
    p.setStrokeCap(skia.Paint.kRound_Cap)
    c.drawPoints(skia.Canvas.kPoints_PointMode, pts, p)


def vignette(c, color=(0, 0, 0), a=0.35):
    sh = skia.GradientShader.MakeRadial(
        skia.Point(CX, CY), W * 0.75,
        [skia.Color4f(color[0], color[1], color[2], 0).toColor(),
         skia.Color4f(color[0], color[1], color[2], a).toColor()],
        [0.55, 1.0])
    p = skia.Paint()
    p.setShader(sh)
    c.drawRect(skia.Rect.MakeWH(W, H), p)


def soft_bg(c, base, light=0.04):
    """Flat background with a gentle radial lift."""
    c.drawColor(skia.Color4f(base[0], base[1], base[2], 1.0))
    hi = tuple(min(1, v + light) for v in base)
    sh = skia.GradientShader.MakeRadial(
        skia.Point(CX, CY * 0.8), W * 0.7,
        [skia.Color4f(hi[0], hi[1], hi[2], 1).toColor(), skia.Color4f(base[0], base[1], base[2], 1).toColor()],
        [0.0, 1.0])
    p = skia.Paint()
    p.setShader(sh)
    c.drawRect(skia.Rect.MakeWH(W, H), p)


def wave_bars(c, x0, x1, y, t, color, n=48, hmax=90, bw=None, a=1.0, seed=0.0, speed=1.0,
              reveal=1.0, colors=None, energy=1.0):
    span = x1 - x0
    step = span / n
    bw = bw or step * 0.55
    for i in range(n):
        if i / n > reveal:
            break
        ph = hash01(i, seed)
        v = 0.25 + 0.75 * abs(math.sin(t * 6.0 * speed + ph * 9 + i * 0.35)) * (0.5 + 0.5 * hash01(i * 3.1, seed))
        h = max(bw, hmax * v * energy)
        col = colors[i] if colors else color
        rrect_c(c, x0 + (i + 0.5) * step, y, bw, h, bw / 2, paint(col, a))
