"""Low-level DSP: band-limited oscillators, TPT state-variable filter, envelopes, utilities."""
import math
import numpy as np
from numba import njit

SR = 48000
RNG = np.random.default_rng(7)


def secs(n):
    return int(round(n * SR))


def tvec(dur):
    return np.arange(secs(dur)) / SR


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def db(x):
    return 10 ** (x / 20.0)


# ---------------------------------------------------------------- oscillators
def _phase(freq, n, ph0):
    if np.isscalar(freq):
        inc = np.full(n, freq / SR)
    else:
        inc = np.asarray(freq, dtype=np.float64) / SR
    ph = (ph0 + np.cumsum(inc) - inc[0]) % 1.0
    return ph, inc


def _blep(t, dt):
    y = np.zeros_like(t)
    m = t < dt
    x = t[m] / dt[m]
    y[m] = x + x - x * x - 1.0
    m2 = t > 1.0 - dt
    x2 = (t[m2] - 1.0) / dt[m2]
    y[m2] = x2 * x2 + x2 + x2 + 1.0
    return y


def saw(freq, n, ph0=0.0):
    ph, dt = _phase(freq, n, ph0)
    return 2.0 * ph - 1.0 - _blep(ph, dt)


def square(freq, n, ph0=0.0, pw=0.5):
    ph, dt = _phase(freq, n, ph0)
    y = np.where(ph < pw, 1.0, -1.0)
    y = y + _blep(ph, dt) - _blep((ph + 1 - pw) % 1.0, dt)
    return y


def sine(freq, n, ph0=0.0):
    ph, _ = _phase(freq, n, ph0)
    return np.sin(2 * np.pi * ph)


def tri(freq, n, ph0=0.0):
    ph, _ = _phase(freq, n, ph0)
    return 2 * np.abs(2 * ph - 1) - 1


def noise(n):
    return RNG.standard_normal(n) * 0.5


# ---------------------------------------------------------------- filters
@njit(cache=True)
def _svf(x, fc, q, mode):
    n = x.shape[0]
    y = np.empty(n)
    ic1 = 0.0
    ic2 = 0.0
    k = 1.0 / q
    for i in range(n):
        f = fc[i]
        if f < 10.0:
            f = 10.0
        if f > 0.45 * 48000.0:
            f = 0.45 * 48000.0
        g = math.tan(math.pi * f / 48000.0)
        a1 = 1.0 / (1.0 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
        v3 = x[i] - ic2
        v1 = a1 * ic1 + a2 * v3
        v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        if mode == 0:
            y[i] = v2
        elif mode == 1:
            y[i] = v1
        else:
            y[i] = x[i] - k * v1 - v2
    return y


def svf(x, fc, q=0.707, mode='lp'):
    fc = np.full(len(x), float(fc)) if np.isscalar(fc) else np.asarray(fc, dtype=np.float64)
    m = {'lp': 0, 'bp': 1, 'hp': 2}[mode]
    return _svf(np.ascontiguousarray(x, dtype=np.float64), fc, float(q), m)


def lp(x, fc, q=0.707):
    return svf(x, fc, q, 'lp')


def hp(x, fc, q=0.707):
    return svf(x, fc, q, 'hp')


def bp(x, fc, q=1.0):
    return svf(x, fc, q, 'bp')


@njit(cache=True)
def _onepole(x, a):
    y = np.empty_like(x)
    s = 0.0
    for i in range(x.shape[0]):
        s += a * (x[i] - s)
        y[i] = s
    return y


# ---------------------------------------------------------------- envelopes
def adsr(n, a=0.005, d=0.1, s=0.7, r=0.1, gate=None):
    """ADSR with gate length (seconds); total length n samples."""
    gate = gate if gate is not None else n / SR - r
    t = np.arange(n) / SR
    env = np.empty(n)
    a = max(a, 1e-4)
    m1 = t < a
    env[m1] = t[m1] / a
    m2 = (t >= a) & (t < a + d)
    env[m2] = 1 - (1 - s) * (t[m2] - a) / max(d, 1e-4)
    m3 = (t >= a + d) & (t < gate)
    env[m3] = s
    lvl = s if gate >= a + d else (gate / a if gate < a else 1 - (1 - s) * (gate - a) / max(d, 1e-4))
    m4 = t >= gate
    env[m4] = lvl * np.maximum(0.0, 1 - (t[m4] - gate) / max(r, 1e-4))
    return env


def expdec(n, tau):
    return np.exp(-np.arange(n) / SR / tau)


def fade(x, fin=0.002, fout=0.01):
    n = len(x)
    a, b = min(secs(fin), n), min(secs(fout), n)
    if a > 0:
        x[:a] *= np.linspace(0, 1, a)
    if b > 0:
        x[-b:] *= np.linspace(1, 0, b)
    return x


# ---------------------------------------------------------------- stereo / mixing
def pan(x, p):
    """Equal-power pan, p in [-1, 1]. Returns (n, 2)."""
    a = (p + 1) * math.pi / 4
    return np.stack([x * math.cos(a), x * math.sin(a)], axis=1)


def stereo(x):
    return np.stack([x, x], axis=1)


class Track:
    """Stereo buffer you can add clips into by time."""
    def __init__(self, dur):
        self.buf = np.zeros((secs(dur), 2))

    def add(self, t, clip, gain=1.0):
        if clip.ndim == 1:
            clip = stereo(clip)
        i = secs(t)
        if i >= len(self.buf):
            return
        if i < 0:
            clip = clip[-i:]
            i = 0
        j = min(len(self.buf), i + len(clip))
        self.buf[i:j] += clip[:j - i] * gain


def soft_clip(x, drive=1.0):
    return np.tanh(x * drive) / np.tanh(drive)


# ---------------------------------------------------------------- true-peak lookahead limiter
@njit(cache=True)
def _lim_gain(req, look, rel):
    n = req.shape[0]
    # sliding minimum over the next `look` samples
    g = np.empty(n)
    for i in range(n):
        m = 1.0
        for j in range(i, min(n, i + look)):
            if req[j] < m:
                m = req[j]
        g[i] = m
    # moving average (attack ramp) then release
    out = np.empty(n)
    acc = 0.0
    buf = np.ones(look)
    for i in range(look):
        acc += 1.0
    s = 1.0
    for i in range(n):
        k = i % look
        acc += g[i] - buf[k]
        buf[k] = g[i]
        a = acc / look
        if a < g[i]:
            v = a
        else:
            v = a
        if v < s:
            s = v
        else:
            s = s + (v - s) * rel
        out[i] = s
    return out


def limit(x, ceiling_db=-1.2, look_ms=1.5, release_ms=80.0):
    """x: (n, 2). Brickwall on 4× oversampled peaks."""
    from scipy.signal import resample_poly
    ceil = 10 ** (ceiling_db / 20)
    os_ = np.abs(resample_poly(x, 4, 1, axis=0)).max(axis=1)
    pk = os_[:len(x) * 4].reshape(len(x), 4).max(axis=1)
    pk = np.maximum(pk, np.abs(x).max(axis=1))
    req = np.minimum(1.0, ceil / np.maximum(pk, 1e-9))
    look = max(2, int(look_ms * SR / 1000))
    # delay the signal by `look` so the gain ramp lands before the peak
    g = _lim_gain(np.concatenate([req, np.ones(look)]), look, 1 - math.exp(-1 / (release_ms * SR / 1000)))
    xd = np.concatenate([np.zeros((look, 2)), x])
    y = xd * g[:, None]
    return y[look:]
