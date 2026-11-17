"""Sound effects for the motion graphics (all synthesised)."""
import math
import numpy as np

from audio.dsp import (SR, secs, mtof, saw, square, sine, tri, noise, lp, hp, bp, svf, adsr, expdec, fade,
                       pan, stereo, RNG)


def whoosh(dur=0.5, f0=400, f1=4000, q=1.4, vel=1.0, pan0=-0.6, pan1=0.6, shape=0.45):
    """Band-passed noise sweep with a bell-shaped amplitude and a pan move."""
    n = secs(dur)
    t = np.linspace(0, 1, n)
    fc = f0 * (f1 / f0) ** t
    x = bp(noise(n), fc, q) * 2.2 + lp(noise(n), fc * 0.6) * 0.4
    env = np.exp(-((t - shape) / 0.22) ** 2)
    env *= np.minimum(1, t / 0.05)
    x = x * env * vel
    p = pan0 + (pan1 - pan0) * t
    a = (p + 1) * math.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)], 1)


def swish(vel=1.0, up=True, dur=0.22):
    return whoosh(dur, 900 if up else 6000, 6000 if up else 900, 2.0, vel, -0.3, 0.3, 0.5)


def riser(dur=4.0, vel=1.0, f0=200, f1=9000):
    n = secs(dur)
    t = np.linspace(0, 1, n)
    fc = f0 * (f1 / f0) ** (t ** 1.6)
    nz = bp(noise(n), fc, 2.0) * 2.0 + hp(noise(n), fc * 1.5) * 0.25
    tone = saw(110 * 2 ** (t * 3), n) * 0.12
    tone = lp(tone, fc)
    env = t ** 2.2
    x = (nz + tone) * env * vel
    return np.stack([x, np.roll(x, 211)], 1)


def downlifter(dur=1.5, vel=1.0):
    n = secs(dur)
    t = np.linspace(0, 1, n)
    fc = 7000 * (150 / 7000) ** t
    x = bp(noise(n), fc, 1.6) * 2 * (1 - t) ** 1.5
    return stereo(x * vel)


def impact(vel=1.0, dur=3.0):
    n = secs(dur)
    t = np.arange(n) / SR
    boom = sine(42 + 90 * np.exp(-t / 0.04), n) * np.exp(-t / 0.6)
    crack = hp(noise(n), 1200) * np.exp(-t / 0.05) * 0.7
    body = lp(noise(n), 600) * np.exp(-t / 0.25) * 0.8
    x = np.tanh((boom * 1.2 + crack + body) * 1.3)
    return np.stack([x, np.roll(x, 53)], 1) * vel


def pop(midi=72, vel=1.0, dur=0.18):
    n = secs(dur)
    t = np.arange(n) / SR
    f = mtof(midi) * (1 + 0.9 * np.exp(-t / 0.012))
    x = sine(f, n) * np.exp(-t / 0.05)
    x += tri(mtof(midi) * 2, n) * np.exp(-t / 0.02) * 0.25
    return fade(x * vel, 0.0005, 0.02)


def bloop(midi=60, vel=1.0, dur=0.3, up=True):
    n = secs(dur)
    t = np.arange(n) / SR
    k = (t / dur)
    f = mtof(midi) * (2 ** ((k if up else -k) * 0.9))
    x = sine(f, n) * np.sin(np.pi * np.minimum(1, k * 1.3)) ** 0.6
    return fade(x * vel, 0.002, 0.03)


def blip(midi=84, vel=1.0, dur=0.06):
    n = secs(dur)
    t = np.arange(n) / SR
    x = square(mtof(midi), n, 0, 0.5) * np.exp(-t / 0.02)
    return fade(lp(x, 7000) * vel * 0.4, 0.0005, 0.005)


def tick(vel=1.0, freq=3500):
    n = secs(0.025)
    t = np.arange(n) / SR
    x = bp(noise(n), freq, 3.0) * np.exp(-t / 0.004) * 3
    return x * vel


def key(vel=1.0):
    n = secs(0.05)
    t = np.arange(n) / SR
    f = 1800 + RNG.random() * 1600
    x = bp(noise(n), f, 2.5) * np.exp(-t / 0.006) * 2.5 + sine(160, n) * np.exp(-t / 0.01) * 0.3
    return x * vel


def click_lock(vel=1.0):
    a = tick(vel, 5200)
    b = tick(vel * 0.8, 2600)
    out = np.zeros(secs(0.06))
    out[:len(a)] += a
    o = secs(0.018)
    out[o:o + len(b)] += b
    return out


def chime(midis=(84, 91), vel=1.0, gap=0.08, dur=0.9):
    n = secs(dur + gap * len(midis))
    out = np.zeros(n)
    for k, m in enumerate(midis):
        f = mtof(m)
        nn = secs(dur)
        t = np.arange(nn) / SR
        mod = np.sin(2 * np.pi * f * 2.0 * t) * 1.2 * np.exp(-t / 0.2)
        x = np.sin(2 * np.pi * f * t + mod) * np.exp(-t / 0.35) * np.minimum(1, t / 0.002)
        o = secs(gap * k)
        out[o:o + nn] += x
    return fade(out * vel * 0.5, 0.0005, 0.05)


def shimmer(vel=1.0, dur=1.2, base=84):
    n = secs(dur)
    out = np.zeros(n)
    for k, m in enumerate((base, base + 4, base + 7, base + 12, base + 16)):
        o = secs(k * 0.035)
        nn = n - o
        t = np.arange(nn) / SR
        out[o:] += sine(mtof(m), nn) * np.exp(-t / 0.3) * np.minimum(1, t / 0.003)
    return stereo(fade(out * vel * 0.25, 0.001, 0.1))


def zip_(vel=1.0, dur=0.18, up=True):
    n = secs(dur)
    t = np.linspace(0, 1, n)
    f = (500 + 3500 * t) if up else (4000 - 3500 * t)
    x = square(f, n, 0, 0.5) * 0.3
    x = bp(x + noise(n) * 0.3, f * 1.2, 1.5)
    env = np.sin(np.pi * t) ** 0.7
    return fade(x * env * vel, 0.001, 0.01)


def goo(vel=1.0, dur=0.35, midi=55):
    n = secs(dur)
    t = np.arange(n) / SR
    f = mtof(midi) * (1 + 0.5 * np.sin(2 * np.pi * 9 * t) * np.exp(-t / 0.15))
    x = sine(f, n) * np.exp(-t / 0.12) * np.minimum(1, t / 0.01)
    x += bp(noise(n), 700, 3) * np.exp(-t / 0.05) * 0.5
    return fade(x * vel, 0.002, 0.03)


def scan(dur=1.0, vel=1.0):
    n = secs(dur)
    t = np.linspace(0, 1, n)
    f = 800 + 2400 * t
    x = bp(noise(n), f, 6) * 2.5 + sine(f * 1.5, n) * 0.08 * (0.5 + 0.5 * np.sin(2 * np.pi * 24 * t * dur))
    env = np.minimum(1, t / 0.05) * np.minimum(1, (1 - t) / 0.1)
    p = -0.8 + 1.6 * t
    a = (p + 1) * math.pi / 4
    x = x * env * vel
    return np.stack([x * np.cos(a), x * np.sin(a)], 1)


def glitch(vel=1.0, dur=0.25):
    n = secs(dur)
    out = np.zeros(n)
    k = 0
    while k < n:
        seg = secs(0.008 + RNG.random() * 0.02)
        f = 200 + RNG.random() * 3000
        x = square(f, min(seg, n - k), 0, 0.5) * (0.3 + 0.7 * RNG.random())
        out[k:k + len(x)] = x
        k += seg + secs(RNG.random() * 0.012)
    return lp(out, 6000) * vel * 0.25


def hum_on(vel=1.0, dur=0.6):
    n = secs(dur)
    t = np.arange(n) / SR
    f = 60 + 240 * (1 - np.exp(-t / 0.08))
    x = (saw(f, n) * 0.3 + sine(f * 2, n) * 0.3)
    x = lp(x, 1800) * np.exp(-t / 0.25) * np.minimum(1, t / 0.01)
    return fade(x * vel, 0.001, 0.05)


def toggle(vel=1.0):
    a = tick(vel, 4200)
    out = np.zeros(secs(0.12))
    out[:len(a)] += a
    p = pop(84, vel * 0.5, 0.08)
    o = secs(0.02)
    out[o:o + len(p)] += p
    return out


# ---------------------------------------------------------------- soft palette (v2)
# Quieter, rounder sounds that sit inside the music instead of on top of it: no hard clicks, no pitch
# zaps, tonal parts in A minor / C major.
def _fade2(x, fin, fout):
    a, b = min(secs(fin), len(x)), min(secs(fout), len(x))
    if a > 0:
        x[:a] *= np.linspace(0, 1, a)[:, None]
    if b > 0:
        x[-b:] *= np.linspace(1, 0, b)[:, None]
    return x


def air(dur=0.8, vel=1.0, f0=350, f1=1800, peak=0.6, pan0=-0.35, pan1=0.35, width=0.6):
    """Breath-like transition: low-Q filtered noise with a raised-cosine swell, decorrelated L/R."""
    n = secs(dur)
    t = np.linspace(0, 1, n)
    fc = f0 * (f1 / f0) ** np.minimum(1, t / peak) * (1 - 0.35 * np.maximum(0, t - peak) / max(1e-3, 1 - peak))
    env = np.where(t < peak, np.sin(0.5 * np.pi * t / peak) ** 2,
                   np.cos(0.5 * np.pi * (t - peak) / max(1e-3, 1 - peak)) ** 2)
    ch = []
    for _ in range(2):
        nz = noise(n)
        ch.append((lp(nz, fc, 0.55) * 1.3 + bp(nz, fc * 1.6, 0.6) * 0.35) * env)
    m = (ch[0] + ch[1]) / 2
    l = m * (1 - width) + ch[0] * width
    r = m * (1 - width) + ch[1] * width
    p = pan0 + (pan1 - pan0) * t
    a = (p + 1) * math.pi / 4
    return np.stack([l * np.cos(a) * 1.41, r * np.sin(a) * 1.41], 1) * vel


def bell_soft(midis=(81, 88), vel=1.0, gap=0.12, dur=1.6):
    """Rounded sine chime (UI / device tone): soft attack, gentle 2nd partial, slight L/R detune."""
    n = secs(dur + gap * len(midis))
    out = np.zeros((n, 2))
    for k, m in enumerate(midis):
        f = mtof(m)
        nn = secs(dur)
        t = np.arange(nn) / SR
        env = np.exp(-t / 0.55) * np.minimum(1, t / 0.006)
        o = secs(gap * k)
        for c, det in ((0, 1.0), (1, 1.0018)):
            x = (np.sin(2 * np.pi * f * det * t)
                 + 0.10 * np.sin(2 * np.pi * 2 * f * det * t) * np.exp(-t / 0.18)
                 + 0.03 * np.sin(2 * np.pi * 3 * f * det * t) * np.exp(-t / 0.08))
            out[o:o + nn, c] += x * env * (0.85 ** k)
    return _fade2(out * vel * 0.35, 0.001, 0.08)


def soft_click(vel=1.0, freq=1250):
    """Muted 'tock' for a switch or lock: short damped sine plus a low-passed transient."""
    n = secs(0.07)
    t = np.arange(n) / SR
    x = sine(freq * (1 + 0.25 * np.exp(-t / 0.003)), n) * np.exp(-t / 0.014) * 0.55
    x += lp(noise(n), 2800) * np.exp(-t / 0.0035) * 0.7
    return fade(x * vel, 0.0003, 0.012)


def soft_key(vel=1.0):
    """Quiet laptop key: band-limited thock, no bright click."""
    n = secs(0.05)
    t = np.arange(n) / SR
    f = 900 + RNG.random() * 800
    x = bp(noise(n), f, 1.1) * np.exp(-t / 0.0045) * 1.8
    x += sine(130 + RNG.random() * 40, n) * np.exp(-t / 0.011) * 0.3
    return fade(lp(x, 4200) * vel, 0.0003, 0.01)
