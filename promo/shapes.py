"""Morphable vector shapes: path builders, icon library and contour-matching morphs."""
import json
import math
import os
import numpy as np
import skia

from core import lerp, clamp

HERE = os.path.dirname(os.path.abspath(__file__))
N_PTS = 320


# ---------------------------------------------------------------- path builders
def P():
    return skia.Path()


def circle(cx, cy, r):
    p = skia.Path()
    p.addCircle(cx, cy, r)
    return p


def oval(cx, cy, rx, ry):
    p = skia.Path()
    p.addOval(skia.Rect.MakeLTRB(cx - rx, cy - ry, cx + rx, cy + ry))
    return p


def rrect(x, y, w, h, r):
    p = skia.Path()
    p.addRRect(skia.RRect.MakeRectXY(skia.Rect.MakeXYWH(x, y, w, h), r, r))
    return p


def rrect_c(cx, cy, w, h, r):
    return rrect(cx - w / 2, cy - h / 2, w, h, r)


def poly(pts, close=True):
    p = skia.Path()
    p.moveTo(*pts[0])
    for q in pts[1:]:
        p.lineTo(*q)
    if close:
        p.close()
    return p


def op(a, b, kind):
    r = skia.Op(a, b, kind)
    return r if r is not None else skia.Path()


def union(*ps):
    out = ps[0]
    for q in ps[1:]:
        out = op(out, q, skia.PathOp.kUnion_PathOp)
    return out


def diff(a, *bs):
    for b in bs:
        a = op(a, b, skia.PathOp.kDifference_PathOp)
    return a


def inter(a, b):
    return op(a, b, skia.PathOp.kIntersect_PathOp)


def ring(cx, cy, R, thick):
    return diff(circle(cx, cy, R), circle(cx, cy, R - thick))


def rring(cx, cy, w, h, r, thick):
    """Rounded-rect outline as a filled shape."""
    return diff(rrect_c(cx, cy, w, h, r), rrect_c(cx, cy, w - 2 * thick, h - 2 * thick, max(0, r - thick)))


def stroke_to_fill(path, width, cap='round', join='round'):
    p = skia.Paint()
    p.setStyle(skia.Paint.kStroke_Style)
    p.setStrokeWidth(width)
    p.setStrokeCap({'round': skia.Paint.kRound_Cap, 'butt': skia.Paint.kButt_Cap,
                    'square': skia.Paint.kSquare_Cap}[cap])
    p.setStrokeJoin({'round': skia.Paint.kRound_Join, 'miter': skia.Paint.kMiter_Join}[join])
    dst = skia.Path()
    skia.FillPathWithPaint(path, p, dst) if hasattr(skia, 'FillPathWithPaint') else p.getFillPath(path, dst)
    return skia.Simplify(dst) or dst


def seg(x0, y0, x1, y1, w, cap='round'):
    return stroke_to_fill(poly([(x0, y0), (x1, y1)], close=False), w, cap)


def arc(cx, cy, r, a0, sweep, w, cap='round'):
    p = skia.Path()
    p.addArc(skia.Rect.MakeLTRB(cx - r, cy - r, cx + r, cy + r), a0, sweep)
    return stroke_to_fill(p, w, cap)


def xform(path, dx=0, dy=0, s=1.0, rot=0.0, sx=None, sy=None):
    m = skia.Matrix()
    m.setTranslate(dx, dy)
    if rot:
        m.preRotate(rot)
    m.preScale(s * (sx or 1.0), s * (sy or 1.0))
    out = skia.Path(path)
    out.transform(m)
    return out


def bounds(path):
    return path.computeTightBounds()


# ---------------------------------------------------------------- glyph outlines
_TF = {}


def typeface(family, weight=600):
    key = (family, weight)
    if key not in _TF:
        _TF[key] = skia.FontMgr().matchFamilyStyle(
            family, skia.FontStyle(weight, 5, skia.FontStyle.kUpright_Slant))
    return _TF[key]


def text_path(s, size, family='Avenir Next', weight=700, cx=0, cy=0, tracking=0.0):
    """Outline of a string, centered on (cx, cy) by its cap box."""
    f = skia.Font(typeface(family, weight), size)
    glyphs = f.textToGlyphs(s)
    widths = f.getWidths(glyphs)
    total = sum(widths) + tracking * size * (len(glyphs) - 1)
    out = skia.Path()
    x = -total / 2
    cap = f.getMetrics().fCapHeight
    for g, w in zip(glyphs, widths):
        gp = f.getPath(g)
        if gp is not None:
            gp.offset(x, cap / 2)
            out.addPath(gp)
        x += w + tracking * size
    out.offset(cx, cy)
    return out


# ---------------------------------------------------------------- logo (traced from docs/assets)
with open(os.path.join(HERE, 'assets', 'logo.json')) as fh:
    _LOGO = json.load(fh)


def logo_parts(cx=0.0, cy=0.0, s=1.0):
    """O (with slot), R and the pill. Origin is the O's centre; O outer radius = 144*s."""
    def mk(pts):
        return poly([(cx + x * s, cy + y * s) for x, y in pts])
    O = mk(_LOGO['O'])
    R = mk(_LOGO['R'])
    x, y, w, h = _LOGO['pill']
    pill = rrect(cx + x * s, cy + y * s, w * s, h * s, h * s / 2)
    return O, R, pill


LOGO_CENTER_DX = 89.5   # logo bbox centre relative to O centre (source px)


# ---------------------------------------------------------------- icon library (≈100px box, centred)
def ic_glasses(cx=0, cy=0, s=1.0, th=9):
    """Front view of flat glasses: two rounded lenses (rings), bridge, temple stubs."""
    lw, lh, gap = 92, 70, 30
    L = rring(-gap / 2 - lw / 2, 0, lw, lh, 26, th)
    Rr = rring(gap / 2 + lw / 2, 0, lw, lh, 26, th)
    bridge = arc(0, 8, gap / 2 + 2, 200, 140, th, 'butt')
    tl = seg(-gap / 2 - lw - 0, -lh / 2 + 14, -gap / 2 - lw - 22, -lh / 2 + 6, th)
    tr = seg(gap / 2 + lw + 0, -lh / 2 + 14, gap / 2 + lw + 22, -lh / 2 + 6, th)
    return xform(union(L, Rr, bridge, tl, tr), cx, cy, s)


def ic_lens_pair(cx=0, cy=0, s=1.0, th=9):
    lw, lh, gap = 92, 70, 30
    L = rring(-gap / 2 - lw / 2, 0, lw, lh, 26, th)
    Rr = rring(gap / 2 + lw / 2, 0, lw, lh, 26, th)
    return xform(union(L, Rr), cx, cy, s)


def ic_mic(cx=0, cy=0, s=1.0):
    body = rring(0, -14, 34, 58, 17, 8)
    cup = arc(0, -6, 28, 0, 180, 8, 'round')
    stem = seg(0, 22, 0, 36, 8)
    base = seg(-14, 38, 14, 38, 8)
    return xform(union(body, cup, stem, base), cx, cy, s)


def ic_clock(cx=0, cy=0, s=1.0):
    r = ring(0, 0, 36, 8)
    hands = union(seg(0, 0, 0, -20, 8), seg(0, 0, 15, 8, 8))
    return xform(union(r, hands), cx, cy, s)


def ic_caption(cx=0, cy=0, s=1.0):
    box = rring(0, -4, 78, 56, 14, 8)
    tail = poly([(-16, 22), (-2, 22), (-18, 38)])
    l1 = seg(-22, -12, 22, -12, 7)
    l2 = seg(-22, 4, 8, 4, 7)
    return xform(union(box, tail, l1, l2), cx, cy, s)


def ic_record(cx=0, cy=0, s=1.0):
    return xform(union(ring(0, 0, 36, 8), circle(0, 0, 17)), cx, cy, s)


def ic_bell(cx=0, cy=0, s=1.0):
    b = skia.Path()
    b.moveTo(-28, 20)
    b.lineTo(-24, -6)
    b.cubicTo(-22, -26, -12, -34, 0, -34)
    b.cubicTo(12, -34, 22, -26, 24, -6)
    b.lineTo(28, 20)
    b.close()
    clap = circle(0, 28, 7)
    knob = circle(0, -36, 5)
    return xform(union(b, clap, knob), cx, cy, s)


def ic_laptop(cx=0, cy=0, s=1.0, th=8):
    scr = rring(0, -8, 112, 74, 10, th)
    base = rrect_c(0, 36, 140, 10, 5)
    return xform(union(scr, base), cx, cy, s)


def ic_phone(cx=0, cy=0, s=1.0, th=8):
    body = rring(0, 0, 56, 100, 14, th)
    dot = rrect_c(0, -38, 14, 5, 2.5)
    return xform(union(body, dot), cx, cy, s)


def ic_gear(cx=0, cy=0, s=1.0, teeth=8):
    base = circle(0, 0, 32)
    for i in range(teeth):
        t = xform(rrect_c(0, -36, 16, 18, 4), 0, 0, 1.0, rot=i * 360 / teeth)
        base = union(base, t)
    return xform(diff(base, circle(0, 0, 14)), cx, cy, s)


def ic_braces(cx=0, cy=0, s=1.0):
    return text_path('{ }', 110, 'Menlo', 700, cx, cy)


def ic_person(cx=0, cy=0, s=1.0):
    head = circle(0, -16, 17)
    body = skia.Path()
    body.addArc(skia.Rect.MakeLTRB(-32, 6, 32, 70), 180, 180)
    body.close()
    body = inter(body, rrect_c(0, 22, 80, 32, 0))
    return xform(union(head, body), cx, cy, s)


def ic_chat(cx=0, cy=0, s=1.0):
    b = rrect_c(0, -4, 84, 60, 22)
    tail = poly([(-24, 18), (-6, 22), (-30, 40)])
    hole = union(circle(-18, -4, 6), circle(0, -4, 6), circle(18, -4, 6))
    return xform(diff(union(b, tail), hole), cx, cy, s)


def ic_spark(cx=0, cy=0, s=1.0):
    p = skia.Path()
    p.moveTo(0, -40)
    p.quadTo(4, -4, 40, 0)
    p.quadTo(4, 4, 0, 40)
    p.quadTo(-4, 4, -40, 0)
    p.quadTo(-4, -4, 0, -40)
    p.close()
    return xform(p, cx, cy, s)


def ic_doc(cx=0, cy=0, s=1.0):
    b = rring(0, 0, 64, 82, 10, 7)
    l = union(seg(-16, -16, 16, -16, 6), seg(-16, 0, 16, 0, 6), seg(-16, 16, 6, 16, 6))
    return xform(union(b, l), cx, cy, s)


def ic_calendar(cx=0, cy=0, s=1.0):
    b = rring(0, 4, 80, 70, 12, 7)
    top = rrect_c(0, -20, 80, 22, 10)
    pins = union(seg(-20, -40, -20, -26, 7), seg(20, -40, 20, -26, 7))
    dots = union(*[circle(-20 + 20 * i, 12 + 16 * j, 4.5) for i in range(3) for j in range(2)])
    return xform(union(b, top, pins, dots), cx, cy, s)


def ic_wifi(cx=0, cy=0, s=1.0):
    a = union(arc(0, 22, 46, 225, 90, 8), arc(0, 22, 30, 225, 90, 8), circle(0, 20, 6))
    return xform(a, cx, cy, s)


def ic_bt(cx=0, cy=0, s=1.0):
    pts = [(-16, -14), (16, 14), (0, 30), (0, -30), (16, -14), (-16, 14)]
    return xform(stroke_to_fill(poly(pts, close=False), 7, 'round', 'round'), cx, cy, s)


def ic_wave(cx=0, cy=0, s=1.0, n=7, hs=None):
    hs = hs or [0.3, 0.6, 1.0, 0.75, 0.95, 0.55, 0.3]
    out = skia.Path()
    for i in range(n):
        h = 64 * hs[i % len(hs)]
        out = union(out, rrect_c((i - (n - 1) / 2) * 13, 0, 8, h, 4))
    return xform(out, cx, cy, s)


def ic_star(cx=0, cy=0, s=1.0, r1=40, r2=17):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = r1 if i % 2 == 0 else r2
        pts.append((math.cos(a) * r, math.sin(a) * r))
    return xform(union(poly(pts), stroke_to_fill(poly(pts), 8)), cx, cy, s)


def ic_check(cx=0, cy=0, s=1.0):
    return xform(stroke_to_fill(poly([(-22, 0), (-6, 16), (24, -16)], close=False), 10), cx, cy, s)


def ic_sync(cx=0, cy=0, s=1.0):
    a = union(arc(0, 0, 30, 200, 130, 8, 'butt'), arc(0, 0, 30, 20, 130, 8, 'butt'))
    h1 = poly([(22, -30), (40, -16), (18, -10)])
    h2 = poly([(-22, 30), (-40, 16), (-18, 10)])
    return xform(union(a, h1, h2), cx, cy, s)


def ic_terminal(cx=0, cy=0, s=1.0):
    b = rring(0, 0, 100, 76, 12, 7)
    chev = stroke_to_fill(poly([(-30, -12), (-16, 0), (-30, 12)], close=False), 7)
    us = seg(-6, 14, 18, 14, 7)
    return xform(union(b, chev, us), cx, cy, s)


def ic_plug(cx=0, cy=0, s=1.0):
    body = rrect_c(0, 6, 56, 40, 12)
    prongs = union(rrect_c(-12, -26, 9, 24, 3), rrect_c(12, -26, 9, 24, 3))
    cord = seg(0, 26, 0, 46, 9)
    return xform(union(body, prongs, cord), cx, cy, s)


# ---------------------------------------------------------------- morph machinery
def contours_of(path, n=N_PTS):
    out = []
    pm = skia.PathMeasure(path, True, 1)
    while True:
        L = pm.getLength()
        if L > 0.5:
            ds = np.linspace(0, L, n, endpoint=False)
            pts = np.array([tuple(pm.getPosTan(float(d))[0]) for d in ds], dtype=np.float64)
            out.append(pts)
        if not pm.nextContour():
            break
    return out


def signed_area(c):
    x, y = c[:, 0], c[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def centroid(c):
    return c.mean(axis=0)


class Shape:
    """A path plus its resampled contours (sorted by |area|, largest first)."""
    def __init__(self, path, n=N_PTS):
        self.path = path
        cs = contours_of(path, n)
        cs.sort(key=lambda q: -abs(signed_area(q)))
        self.cs = cs
        self.n = n


_PAIR_CACHE = {}


def _align(a, b):
    """Re-index contour b so it corresponds point-to-point with a."""
    if signed_area(a) * signed_area(b) < 0:
        b = b[::-1].copy()
    ac = a - a.mean(0)
    bc = b - b.mean(0)
    fa = np.fft.fft(ac[:, 0] + 1j * ac[:, 1])
    fb = np.fft.fft(bc[:, 0] + 1j * bc[:, 1])
    corr = np.fft.ifft(np.conj(fa) * fb).real
    k = int(np.argmax(corr))
    return np.roll(b, -k, axis=0)


def _pairs(A, B):
    key = (id(A), id(B))
    if key in _PAIR_CACHE:
        return _PAIR_CACHE[key]
    acs, bcs = list(A.cs), list(B.cs)
    pairs = []
    used = set()
    # greedy: largest contours of A take the nearest unused contour of B
    for a in acs:
        best, bi = None, None
        for j, b in enumerate(bcs):
            if j in used:
                continue
            d = np.linalg.norm(centroid(a) - centroid(b)) + 0.15 * abs(math.sqrt(abs(signed_area(a))) - math.sqrt(abs(signed_area(b))))
            if best is None or d < best:
                best, bi = d, j
        if bi is None:
            ca = centroid(a)
            pairs.append((a, np.repeat(ca[None], len(a), 0)))
        else:
            used.add(bi)
            pairs.append((a, _align(a, bcs[bi])))
    for j, b in enumerate(bcs):
        if j not in used:
            cb = centroid(b)
            pairs.append((np.repeat(cb[None], len(b), 0), b))
    _PAIR_CACHE[key] = pairs
    return pairs


def morph_path(A, B, p, swirl=0.0):
    """Interpolated path between Shapes A and B at progress p (0..1)."""
    if p <= 0.0:
        return A.path
    if p >= 1.0:
        return B.path
    out = skia.Path()
    out.setFillType(skia.PathFillType.kEvenOdd)
    for a, b in _pairs(A, B):
        pts = a + (b - a) * p
        if swirl:
            c = pts.mean(0)
            ang = swirl * math.sin(math.pi * p)
            ca, sa = math.cos(ang), math.sin(ang)
            d = pts - c
            pts = c + np.stack([d[:, 0] * ca - d[:, 1] * sa, d[:, 0] * sa + d[:, 1] * ca], 1)
        out.moveTo(float(pts[0, 0]), float(pts[0, 1]))
        # polyline through all points
        for q in pts[1:]:
            out.lineTo(float(q[0]), float(q[1]))
        out.close()
    return out


def morph_chain(shapes, p, swirl=0.0):
    """Morph across a list of Shapes with p in [0, len-1]."""
    p = clamp(p, 0, len(shapes) - 1)
    i = min(int(math.floor(p)), len(shapes) - 2)
    return morph_path(shapes[i], shapes[i + 1], p - i, swirl)
