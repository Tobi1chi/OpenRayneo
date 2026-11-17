"""Timeline grid, easing, colors and small drawing primitives shared by every scene."""
import math
import numpy as np
import skia

# ---------------------------------------------------------------- timeline
BPM = 105.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT
FPS = 60
W, H = 1920, 1080          # design space; the renderer scales the canvas
CX, CY = W / 2, H / 2


def B(bar, beat=0.0):
    """Seconds at 1-indexed bar + beat offset (4/4)."""
    return ((bar - 1) * 4 + beat) * BEAT


DURATION = B(40)           # 39 bars


# ---------------------------------------------------------------- easing
def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def lerp(a, b, t):
    return a + (b - a) * t


def prog(t, t0, dur):
    if dur <= 0:
        return 1.0 if t >= t0 else 0.0
    return clamp((t - t0) / dur)


def linear(x): return x
def in_quad(x): return x * x
def out_quad(x): return 1 - (1 - x) ** 2
def in_cubic(x): return x ** 3
def out_cubic(x): return 1 - (1 - x) ** 3
def in_quart(x): return x ** 4
def out_quart(x): return 1 - (1 - x) ** 4
def in_quint(x): return x ** 5
def out_quint(x): return 1 - (1 - x) ** 5
def in_out_sine(x): return -(math.cos(math.pi * x) - 1) / 2


def in_out_cubic(x):
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def in_out_quart(x):
    return 8 * x ** 4 if x < 0.5 else 1 - (-2 * x + 2) ** 4 / 2


def in_out_quint(x):
    return 16 * x ** 5 if x < 0.5 else 1 - (-2 * x + 2) ** 5 / 2


def out_expo(x):
    return 1.0 if x >= 1 else 1 - 2 ** (-10 * x)


def in_expo(x):
    return 0.0 if x <= 0 else 2 ** (10 * x - 10)


def in_out_expo(x):
    if x <= 0: return 0.0
    if x >= 1: return 1.0
    return 2 ** (20 * x - 10) / 2 if x < 0.5 else (2 - 2 ** (-20 * x + 10)) / 2


def out_back(x, s=1.70158):
    c3 = s + 1
    return 1 + c3 * (x - 1) ** 3 + s * (x - 1) ** 2


def in_back(x, s=1.70158):
    return (s + 1) * x ** 3 - s * x ** 2


def out_elastic(x):
    if x <= 0: return 0.0
    if x >= 1: return 1.0
    return 2 ** (-10 * x) * math.sin((x * 10 - 0.75) * (2 * math.pi / 3)) + 1


def spring(x, damp=5.5, freq=2.2):
    """Damped spring 0->1 over normalized time x (overshoots once or twice)."""
    if x <= 0: return 0.0
    if x >= 1: return 1.0
    v = 1 - math.exp(-damp * x) * math.cos(freq * 2 * math.pi * x)
    # blend the tiny residual away near the end
    return lerp(v, 1.0, out_quint(clamp((x - 0.75) / 0.25)))


def E(t, t0, dur, ease=out_cubic):
    return ease(prog(t, t0, dur))


def inout(t, t_in, d_in, t_out, d_out, ein=out_cubic, eout=in_cubic):
    """1 while visible: eases in at t_in, out at t_out. Returns 0..1."""
    a = ein(prog(t, t_in, d_in))
    b = eout(prog(t, t_out, d_out)) if t_out is not None else 0.0
    return a * (1 - b)


def kf(t, keys):
    """Keyframes [(time, value[, ease]), ...]; ease on a key shapes the segment arriving at it."""
    if t <= keys[0][0]:
        return keys[0][1]
    for i in range(1, len(keys)):
        k1 = keys[i]
        if t <= k1[0]:
            k0 = keys[i - 1]
            ease = k1[2] if len(k1) > 2 else in_out_cubic
            p = ease(prog(t, k0[0], k1[0] - k0[0]))
            v0, v1 = k0[1], k1[1]
            if isinstance(v0, (tuple, list, np.ndarray)):
                return tuple(lerp(a, b, p) for a, b in zip(v0, v1))
            return lerp(v0, v1, p)
    return keys[-1][1]


def pulse(t, t0, dur=0.25, ease=out_cubic):
    """1 at t0 decaying to 0 over dur (beat accents)."""
    if t < t0 or t > t0 + dur:
        return 0.0
    return 1 - ease(prog(t, t0, dur))


def beat_pulse(t, start, end, every=BEAT, dur=0.22):
    if t < start or t >= end:
        return 0.0
    k = math.floor((t - start) / every)
    return pulse(t, start + k * every, dur)


def hash01(*xs):
    s = math.sin(sum((i + 1) * 12.9898 * x for i, x in enumerate(xs)) + 78.233) * 43758.5453
    return s - math.floor(s)


# ---------------------------------------------------------------- color
def hexrgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


class C:
    INK = hexrgb('#121318')
    INK2 = hexrgb('#1B1D24')
    INK3 = hexrgb('#272A33')
    PAPER = hexrgb('#F4F1EA')
    PAPER2 = hexrgb('#E8E4DA')
    WHITE = hexrgb('#FBFAF7')
    MINT = hexrgb('#3DDC97')
    MINTD = hexrgb('#1BAE73')
    BLUE = hexrgb('#4170FF')
    CORAL = hexrgb('#FF5B45')
    AMBER = hexrgb('#FFB21E')
    VIOLET = hexrgb('#8E7CFF')
    GRAY = hexrgb('#8B909B')
    GRAY2 = hexrgb('#5B606B')
    HUD = hexrgb('#5CFFB0')


def mixc(a, b, t):
    return tuple(lerp(x, y, t) for x, y in zip(a, b))


def c4(rgb, a=1.0):
    return skia.Color4f(rgb[0], rgb[1], rgb[2], a)


def paint(rgb, a=1.0, stroke=None, cap='round', join='round', blur=0.0):
    p = skia.Paint()
    p.setAntiAlias(True)
    p.setColor4f(c4(rgb, clamp(a)))
    if stroke is not None:
        p.setStyle(skia.Paint.kStroke_Style)
        p.setStrokeWidth(stroke)
        p.setStrokeCap({'round': skia.Paint.kRound_Cap, 'butt': skia.Paint.kButt_Cap,
                        'square': skia.Paint.kSquare_Cap}[cap])
        p.setStrokeJoin({'round': skia.Paint.kRound_Join, 'miter': skia.Paint.kMiter_Join}[join])
    if blur > 0:
        p.setMaskFilter(skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, blur))
    return p


# ---------------------------------------------------------------- canvas helpers
class Save:
    """with Save(c): ... restores the canvas state."""
    def __init__(self, c):
        self.c = c

    def __enter__(self):
        self.c.save()
        return self.c

    def __exit__(self, *a):
        self.c.restore()


class Layer:
    """with Layer(c, alpha=..., blur=..., filt=...): offscreen group."""
    def __init__(self, c, alpha=1.0, blur=0.0, filt=None, bounds=None):
        self.c, self.alpha, self.blur, self.filt, self.bounds = c, alpha, blur, filt, bounds

    def __enter__(self):
        p = skia.Paint()
        p.setAlphaf(clamp(self.alpha))
        f = self.filt
        if self.blur > 0.05:
            b = skia.ImageFilters.Blur(self.blur, self.blur)
            f = skia.ImageFilters.Compose(f, b) if f is not None else b
        if f is not None:
            p.setImageFilter(f)
        self.c.saveLayer(self.bounds, p)
        return self.c

    def __exit__(self, *a):
        self.c.restore()


def goo_filter(radius, sharp=22.0):
    """Gooey metaball filter: blur then threshold alpha."""
    m = [1, 0, 0, 0, 0,
         0, 1, 0, 0, 0,
         0, 0, 1, 0, 0,
         0, 0, 0, sharp, -sharp * 0.48]
    return skia.ImageFilters.ColorFilter(skia.ColorFilters.Matrix(m),
                                         skia.ImageFilters.Blur(radius, radius))


def transform(c, x=0, y=0, s=1.0, rot=0.0, sx=None, sy=None, ox=0, oy=0):
    """Translate to (x,y), rotate (deg) and scale about local origin (ox,oy)."""
    c.translate(x, y)
    if rot:
        c.rotate(rot)
    c.scale(s * (sx if sx is not None else 1.0), s * (sy if sy is not None else 1.0))
    c.translate(-ox, -oy)


def rrect(c, x, y, w, h, r, p):
    c.drawRRect(skia.RRect.MakeRectXY(skia.Rect.MakeXYWH(x, y, w, h), r, r), p)


def rrect_c(c, cx, cy, w, h, r, p):
    rrect(c, cx - w / 2, cy - h / 2, w, h, r, p)


def line(c, x0, y0, x1, y1, p):
    c.drawLine(x0, y0, x1, y1, p)


def trim_path(path, a, b):
    """Return a sub-path from fraction a..b of total length (first contour)."""
    pm = skia.PathMeasure(path, False, 1)
    L = pm.getLength()
    dst = skia.Path()
    if L <= 0 or b <= a:
        return dst
    pm.getSegment(L * clamp(a), L * clamp(b), dst, True)
    return dst


def bg(c, rgb):
    c.drawColor(c4(rgb))
