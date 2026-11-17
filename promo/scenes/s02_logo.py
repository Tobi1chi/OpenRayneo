"""Bars 5–6: drop — logo assembles, wordmark + subtitle, then zoom through the O."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K

T0 = B(5)                     # the drop
O_PATH, R_PATH, PILL = S.logo_parts(0, 0, 1.0)
R_PIECES = [S.inter(R_PATH, S.rrect(-400, y0, 900, y1 - y0, 0))
            for y0, y1 in ((-160, -93), (-93, 3), (3, 160))]
HOLE_R = 94.0


def draw_logo(c, t, t0, a=1.0, pill_glow=1.0, assemble=True, led_blink=0.0):
    """Logo in local coords (O centre = origin, O radius 144). Assembly anchored at t0."""
    if not assemble:
        c.drawPath(O_PATH, paint(C.WHITE, a))
        c.drawPath(R_PATH, paint(C.WHITE, a))
        _pill(c, 1.0, 0.0, a, pill_glow, led_blink)
        return
    # --- O: radial sweep reveal from the slot side
    sw = in_out_cubic(prog(t, t0, 0.42))
    if sw > 0:
        with Save(c):
            if sw < 1:
                wedge = skia.Path()
                wedge.moveTo(0, 0)
                wedge.arcTo(skia.Rect.MakeLTRB(-400, -400, 400, 400), 180, 360 * sw, False)
                wedge.close()
                c.clipPath(wedge, skia.ClipOp.kIntersect, True)
            c.drawPath(O_PATH, paint(C.WHITE, a))
    # --- R: three slices fly in
    done = t >= t0 + 0.75
    if done:
        c.drawPath(R_PATH, paint(C.WHITE, a))
    else:
        starts = (t0 + 0.12, t0 + 0.22, t0 + 0.32)
        offs = ((300, -40), (340, 0), (180, 260))
        for piece, ts, (dx, dy) in zip(R_PIECES, starts, offs):
            p = prog(t, ts, 0.38)
            if p <= 0:
                continue
            e = out_expo(p)
            with Save(c):
                c.translate(dx * (1 - e), dy * (1 - e))
                c.drawPath(piece, paint(C.WHITE, a * clamp(p * 4)))
    # --- pill slides into the slot
    p = prog(t, t0 + 0.42, 0.34)
    if p > 0:
        e = out_expo(p)
        stretch = 1 + 1.6 * (1 - e) ** 1.5
        _pill(c, e, stretch, a, pill_glow, led_blink, land=t0 + 0.42 + 0.3, t=t)


def _pill(c, e, stretch, a, glow, blink, land=None, t=0.0):
    x0, y0, w, h = S._LOGO['pill']
    cx, cy = x0 + w / 2, y0 + h / 2
    sx, sy = 1.0, 1.0
    if land is not None:
        sx, sy = K.squash(t, land, 0.55)
    with Save(c):
        c.translate(lerp(cx - 760, cx, e), cy)
        c.scale(max(stretch, 1.0) * sx, sy / math.sqrt(max(stretch, 1.0)))
        lit = 1.0 - 0.75 * blink
        if glow > 0:
            rrect_c(c, 0, 0, w * 1.25, h * 1.25, h / 2, paint(C.MINT, 0.55 * glow * a * lit, blur=22))
        rrect_c(c, 0, 0, w, h, h / 2, paint(mixc(C.MINTD, C.MINT, lit), a))


def logo_xform(t):
    """O-centre position and scale through hero → lockup."""
    LSh, LSl = 1.9, 1.0
    hero = (CX - LOGO_DX * LSh, CY - 10, LSh)
    lock = (CX - LOGO_DX * LSl, CY - 175, LSl)
    p = in_out_quart(prog(t, T0 + 1.3, 0.6))
    return tuple(lerp(a, b, p) for a, b in zip(hero, lock))


LOGO_DX = S.LOGO_CENTER_DX


def zoom_state(t):
    """Camera zoom into the O hole at the end of the scene."""
    p = prog(t, B(6, 2.8), 0.6)
    z = 34 ** in_cubic(p)
    return p, z


def draw(c, t):
    ox, oy, ls = logo_xform(t)
    zp, z = zoom_state(t)
    hx, hy = ox, oy                       # hole centre
    if zp > 0:
        hole = skia.Path()
        hole.addCircle(hx, hy, HOLE_R * ls * z - 0.5)
        c.clipPath(hole, skia.ClipOp.kDifference, True)
    # camera: zoom about the hole + impact shake
    shake = 16 * math.exp(-7 * max(0, t - T0)) if t >= T0 else 0
    sx = shake * math.sin(t * 91.0)
    sy = shake * math.cos(t * 77.0)
    c.translate(sx, sy)
    if zp > 0:
        c.translate(hx, hy)
        c.rotate(18 * in_cubic(zp))
        c.scale(z, z)
        c.translate(-hx, -hy)
    K.soft_bg(c, C.INK, 0.03)
    K.grid_dots(c, t, C.PAPER, 0.045)

    # impact: mint wave ring + shockwaves from the logo centre
    lx, ly = CX, CY - 10
    p1 = prog(t, T0, 0.5)
    if 0 < p1 < 1:
        r1 = 1500 * out_cubic(p1)
        r2 = 1500 * out_cubic(prog(t, T0 + 0.07, 0.55))
        ring = S.diff(S.circle(lx, ly, r1), S.circle(lx, ly, r2))
        c.drawPath(ring, paint(C.MINT, 1 - p1 * 0.3))
    K.shockwave(c, lx, ly, t, T0 + 0.05, C.WHITE, rmax=1100, dur=1.0, width=18, n=3)

    with Save(c):
        c.translate(ox, oy)
        sp = spring(prog(t, T0, 0.9))
        sc = ls * lerp(0.72, 1.0, sp)
        c.scale(sc, sc)
        draw_logo(c, t, T0)
    # landing burst at the pill
    px = ox + (S._LOGO['pill'][0] + S._LOGO['pill'][2] / 2) * ls
    K.burst(c, px - 30, oy, t, T0 + 0.72, C.MINT, n=10, r0=70, r1=190, dur=0.45, width=7, rot=0.3)

    # wordmark + subtitle + tags
    t_w = T0 + 1.55
    t_out = B(6, 2.3)
    wy = CY + 105
    size = 138
    w_open = T.width('Open', size, T.EN, 500)
    w_ray = T.width('Rayneo', size, T.EN, 700)
    x0 = CX - (w_open + w_ray) / 2
    T.ktext(c, 'Open', x0, wy, size, t, t_w, t_out, color=C.WHITE, family=T.EN, weight=500, a=0.82,
            stagger=0.035, dur=0.6)
    T.ktext(c, 'Rayneo', x0 + w_open, wy, size, t, t_w + 0.12, t_out, color=C.WHITE, family=T.EN,
            weight=700, stagger=0.035, dur=0.6)
    T.ktext(c, '雷鸟 iO 眼镜的开源伴侣工作台', CX, wy + 92, 46, t, B(6, 0), t_out + 0.05,
            color=C.PAPER, a=0.85, weight=500, align='center', stagger=0.025)
    tags = [('macOS', C.BLUE), ('Android', C.MINT), ('本机 Agent', C.AMBER), ('Apache-2.0', C.CORAL)]
    widths = [T.width(s, 28, weight=600) + 52 for s, _ in tags]
    gap = 22
    x = CX - (sum(widths) + gap * (len(tags) - 1)) / 2
    for i, ((s, col), wdt) in enumerate(zip(tags, widths)):
        K.chip(c, x + wdt / 2, wy + 180, s, t, B(6, 1) + i * 0.125, t_out + 0.1 + i * 0.04,
               fg=col, bg=C.INK2, stroke=col, size=28, pad=26)
        x += wdt + gap
