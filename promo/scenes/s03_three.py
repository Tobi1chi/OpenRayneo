"""Bars 7–8: 接入 → 处理 → 开放, one morphing hero; then the three-node chain."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s02_logo import O_PATH, R_PATH

HX, HY = CX, CY - 70
T1, T2, T3, TS = B(7, 0), B(7, 1.5), B(7, 3.0), B(8, 0)
NODE_Y = CY - 60
NODE_R = 118
NX = (CX - 540, CX, CX + 540)


def _hexagon(r):
    pts = [(math.cos(math.radians(60 * i - 90)) * r, math.sin(math.radians(60 * i - 90)) * r) for i in range(6)]
    return S.union(S.poly(pts), S.stroke_to_fill(S.poly(pts), 70))


BLOBS = [S.Shape(S.circle(0, 0, 205)),
         S.Shape(S.rrect_c(0, 0, 370, 370, 96)),
         S.Shape(_hexagon(180)),
         S.Shape(S.circle(0, 0, NODE_R))]
_logo_scale = 0.42
ICONS = [S.Shape(S.ic_glasses(0, 0, 1.25)),
         S.Shape(S.ic_gear(0, 0, 2.7)),
         S.Shape(S.text_path('{ }', 210, 'Menlo', 700)),
         S.Shape(S.union(S.xform(O_PATH, -S.LOGO_CENTER_DX * _logo_scale, 0, _logo_scale),
                         S.xform(R_PATH, -S.LOGO_CENTER_DX * _logo_scale, 0, _logo_scale)))]
BLOB_COLS = [C.MINT, C.AMBER, C.BLUE, C.INK]
STEPS = [('01', '接入', '眼镜已有的官方能力'),
         ('02', '处理', '录音 · 转写 · 说话人 · 总结'),
         ('03', '开放', '本机 API，交给你的 Agent')]


def _stage(t):
    """Continuous morph index 0..3 with snappy transitions."""
    v = 0.0
    for i, ts in enumerate((T2, T3, TS)):
        v += out_quart(prog(t, ts - 0.04, 0.4)) if i < 2 else in_out_cubic(prog(t, ts, 0.5))
    return v


def _bump(t):
    b = 0.0
    for ts in (T1 - 0.4, T2, T3):
        if t > ts:
            d = t - ts
            b += 0.13 * math.exp(-6 * d) * math.sin(13 * d)
    return b


def _hero_pos(t):
    p = in_out_cubic(prog(t, TS, 0.5))
    return lerp(HX, NX[1], p), lerp(HY, NODE_Y, p)


def draw(c, t):
    K.soft_bg(c, C.PAPER, 0.02)
    K.grid_dots(c, t, C.INK, 0.06)
    st = _stage(t)
    i = min(int(math.floor(st)), 2)
    f = clamp(st - i, 0, 1.15)
    hx, hy = _hero_pos(t)

    # title
    K.headline(c, 'OpenRayneo 只做三件事', None, 120, 150, t, B(6, 3.2), B(8, 3.0), color=C.INK,
               size=44, accent=C.MINT)

    # step-1 bluetooth waves / step-2 orbit dots / step-3 output chevrons
    with Save(c):
        c.translate(hx, hy)
        if st < 1.0:
            for k in range(3):
                p = ((t - T1) * 1.6 - k * 0.33) % 1.0
                a = (1 - p) * 0.55 * (1 - clamp(st * 3))
                for sgn in (-1, 1):
                    ang0 = 0 if sgn > 0 else 180
                    path = skia.Path()
                    r = 250 + 120 * p
                    path.addArc(skia.Rect.MakeLTRB(-r, -r, r, r), ang0 - 28, 56)
                    c.drawPath(path, paint(C.INK, a, stroke=9))
        # morphing blob
        col_idx = min(int(round(st)), 3)
        bcol = mixc(BLOB_COLS[i], BLOB_COLS[i + 1], clamp(f))
        s0 = out_cubic(prog(t, T1 - 0.4, 0.3)) * (1 + _bump(t))
        with Save(c):
            c.scale(s0, s0)
            c.rotate(-8 * math.sin(st * math.pi))
            c.drawPath(S.morph_chain(BLOBS, min(st, 3.0)), paint(bcol))
            # hero icon
            icol = mixc(C.INK, C.WHITE, clamp(st - 2.0))
            with Save(c):
                if 0.6 < st < 2.2:
                    c.rotate((t - T2) * 120 * clamp(st - 0.6) * clamp(2.2 - st))
                c.drawPath(S.morph_chain(ICONS, min(st, 3.0)), paint(icol))
        # LED pill once the logo has formed
        lp = out_back(prog(t, TS + 0.45, 0.35), 2.5)
        if lp > 0:
            x0, y0, w, h = S._LOGO['pill']
            with Save(c):
                c.translate(-S.LOGO_CENTER_DX * _logo_scale, 0)
                c.scale(_logo_scale, _logo_scale)
                c.translate(x0 + w / 2, y0 + h / 2)
                c.scale(lp, lp)
                rrect_c(c, 0, 0, w, h, h / 2, paint(C.MINT))

    # step labels
    for k, (num, verb, desc) in enumerate(STEPS):
        t_in = (T1 - 0.1, T2, T3)[k]
        t_out = (T2 - 0.05, T3 - 0.05, TS - 0.05)[k]
        T.ktext(c, num, CX - 150, CY + 250, 64, t, t_in, t_out, color=BLOB_COLS[k] if k != 0 else C.MINTD,
                family=T.NUM, weight=700, align='right', stagger=0.03, dur=0.4, out_dur=0.25)
        T.ktext(c, verb, CX - 120, CY + 250, 96, t, t_in + 0.03, t_out, color=C.INK, weight=600,
                stagger=0.05, dur=0.45, out_dur=0.25)
        T.ktext(c, desc, CX - 120, CY + 320, 34, t, t_in + 0.1, t_out, color=C.GRAY2, weight=500,
                stagger=0.012, dur=0.4, out_dur=0.25)

    # summary chain
    if t >= TS:
        nodes = [(NX[0], C.MINT, S.ic_glasses, C.INK, '眼镜', '官方能力'),
                 None,
                 (NX[2], C.BLUE, S.ic_spark, C.WHITE, '你的 Agent', '理解与决策')]
        for k, nd in enumerate(nodes):
            if nd is None:
                continue
            x, col, icon, icol, title, desc = nd
            s = out_back(prog(t, TS + 0.15 + 0.1 * (k == 2), 0.5), 2.0)
            with Save(c):
                c.translate(x, NODE_Y)
                c.scale(s, s)
                c.drawCircle(0, 0, NODE_R, paint(col))
                c.drawPath(icon(0, 0, 0.62 if icon is S.ic_glasses else 1.15), paint(icol))
        # arrows with flowing dots
        for k in range(2):
            x0 = NX[k] + NODE_R + 26
            x1 = NX[k + 1] - NODE_R - 26
            d = out_cubic(prog(t, TS + 0.3 + 0.12 * k, 0.4))
            if d > 0:
                path = skia.Path()
                path.moveTo(x0, NODE_Y)
                path.lineTo(x1, NODE_Y)
                K.draw_trim(c, path, 0, d, C.INK, 6, 0.25)
                K.flow_dots(c, path, t, C.INK, speed=1.1, n=3, r=7, a=d, t0=TS + 0.5)
                tip = lerp(x0, x1, d)
                c.drawPath(S.poly([(tip + 4, NODE_Y), (tip - 16, NODE_Y - 13), (tip - 16, NODE_Y + 13)]),
                           paint(C.INK, 0.45 * d))
        labels = [('眼镜', '官方能力'), ('OpenRayneo', '伴侣端处理'), ('你的 Agent', '理解与决策')]
        for k, (title, desc) in enumerate(labels):
            t_in = TS + 0.3 + 0.1 * k
            T.ktext(c, title, NX[k], NODE_Y + NODE_R + 78, 44, t, t_in, B(8, 3.0), color=C.INK,
                    align='center', stagger=0.03, out_dur=0.3)
            T.ktext(c, desc, NX[k], NODE_Y + NODE_R + 130, 32, t, t_in + 0.1, B(8, 3.0), color=C.GRAY2,
                    weight=500, align='center', stagger=0.02, out_dur=0.3)
        T.ktext(c, '只接入眼镜已有的官方能力 · 处理在伴侣端 · 决策交给 Agent', CX, CY + 400, 34, t,
                TS + 0.8, B(8, 3.0), color=C.INK, a=0.65, weight=500, align='center', stagger=0.012,
                out_dur=0.3)
