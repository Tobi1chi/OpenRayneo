"""Synthesised instruments. Every function returns a mono or (n, 2) float array."""
import math
import numpy as np

from audio.dsp import (SR, secs, mtof, saw, square, sine, tri, noise, lp, hp, bp, svf, adsr, expdec, fade,
                       pan, stereo, RNG, db)


# ---------------------------------------------------------------- drums
def kick(vel=1.0, tone=1.0, dur=0.55):
    n = secs(dur)
    t = np.arange(n) / SR
    f = 46 + 130 * np.exp(-t / 0.03) + 40 * np.exp(-t / 0.006)
    body = sine(f, n) * np.exp(-t / 0.32)
    body *= np.minimum(1, t / 0.0015)
    click = hp(noise(n), 2500) * np.exp(-t / 0.004) * 0.6
    sub = sine(46, n) * np.exp(-t / 0.2) * 0.22 * tone
    x = np.tanh((body + click + sub) * 1.6) * 0.95
    return fade(x * vel, 0.0005, 0.03)


def clap(vel=1.0, dur=0.45):
    n = secs(dur)
    t = np.arange(n) / SR
    env = np.zeros(n)
    for k, off in enumerate((0.0, 0.011, 0.022)):
        m = t >= off
        env[m] += np.exp(-(t[m] - off) / 0.007) * (0.8 if k < 2 else 1.0)
    m = t >= 0.022
    env[m] += 0.45 * np.exp(-(t[m] - 0.022) / 0.14)
    x = bp(noise(n), 1300, 1.2) * 1.6 + hp(noise(n), 3000) * 0.3
    l = x * env
    r = np.roll(x, 37) * env
    return np.stack([l, r], 1) * vel * 0.9


def snare(vel=1.0, dur=0.3):
    n = secs(dur)
    t = np.arange(n) / SR
    tone = sine(190 + 60 * np.exp(-t / 0.02), n) * np.exp(-t / 0.06) * 0.6
    nz = hp(noise(n), 1500) * np.exp(-t / 0.09)
    return fade((tone + nz) * vel * 0.9, 0.0005, 0.02)


def hat(vel=1.0, open_=False):
    dur = 0.32 if open_ else 0.07
    n = secs(dur)
    t = np.arange(n) / SR
    # metallic: sum of detuned squares + noise, high-passed
    m = sum(square(f, n) for f in (3150, 4370, 5210, 6110, 7420, 8640)) / 6
    x = hp(m * 0.5 + noise(n), 7000, 0.9)
    env = np.exp(-t / (0.11 if open_ else 0.018))
    return fade(x * env * vel * 0.45, 0.0003, 0.01)


def shaker(vel=1.0):
    n = secs(0.09)
    t = np.arange(n) / SR
    env = np.minimum(1, t / 0.012) * np.exp(-t / 0.03)
    return hp(noise(n), 6000) * env * vel * 0.4


def crash(vel=1.0, dur=2.6):
    n = secs(dur)
    t = np.arange(n) / SR
    m = sum(square(f * (1 + 0.003 * k), n) for k, f in enumerate((2950, 3720, 4710, 5430, 6630, 7890, 9120))) / 7
    x = hp(m * 0.4 + noise(n), 4200, 0.8)
    env = np.exp(-t / 0.75) * (1 - np.exp(-t / 0.002))
    l = x * env
    r = hp(np.roll(m, 101) * 0.4 + noise(n), 4200, 0.8) * env
    return np.stack([l, r], 1) * vel * 0.5


def rev_crash(dur=1.5, vel=1.0):
    c = crash(vel, dur + 0.3)[:secs(dur)]
    return c[::-1].copy() * np.linspace(0.2, 1.0, len(c))[:, None] ** 2


def tom(freq=110, vel=1.0):
    n = secs(0.35)
    t = np.arange(n) / SR
    f = freq * (1 + 0.6 * np.exp(-t / 0.03))
    return fade(sine(f, n) * np.exp(-t / 0.16) * vel, 0.0005, 0.02)


# ---------------------------------------------------------------- synths
def supersaw(midi, dur, voices=7, detune=0.18, cutoff=3200, q=0.8, a=0.01, d=0.3, s=0.8, r=0.25,
             fenv=0.0, fdec=0.25, spread=0.9, vel=1.0):
    n = secs(dur + r)
    f0 = mtof(midi)
    out = np.zeros((n, 2))
    for v in range(voices):
        off = (v - (voices - 1) / 2) / ((voices - 1) / 2)
        f = f0 * 2 ** (detune * off / 12)
        x = saw(f, n, RNG.random())
        p = spread * off
        out += pan(x, p) * (1.0 if v == voices // 2 else 0.75)
    out /= voices * 0.6
    t = np.arange(n) / SR
    fc = cutoff * (1 + fenv * np.exp(-t / fdec))
    env = adsr(n, a, d, s, r, gate=dur)
    out[:, 0] = lp(out[:, 0], fc, q) * env
    out[:, 1] = lp(out[:, 1], fc, q) * env
    return out * vel


def pluck(midi, dur=0.25, cutoff=900, fenv=7.0, fdec=0.09, vel=1.0, bright=1.0):
    n = secs(dur + 0.25)
    f = mtof(midi)
    t = np.arange(n) / SR
    x = saw(f, n, RNG.random()) * 0.6 + square(f * 1.005, n, RNG.random(), 0.3) * 0.4
    fc = cutoff * (1 + fenv * bright * np.exp(-t / fdec))
    y = lp(x, fc, 1.1)
    env = np.exp(-t / (0.12 + dur * 0.4)) * np.minimum(1, t / 0.002)
    return fade(y * env * vel, 0.0005, 0.03)


def bass(midi, dur, vel=1.0, cutoff=420, fenv=2.5, fdec=0.08, sub=0.6):
    n = secs(dur + 0.04)
    f = mtof(midi)
    t = np.arange(n) / SR
    x = saw(f, n, 0.0) * 0.55 + square(f, n, 0.25, 0.5) * 0.25
    fc = cutoff * (1 + fenv * np.exp(-t / fdec))
    y = lp(x, fc, 0.9)
    y += sine(f, n) * sub
    env = adsr(n, 0.003, 0.05, 0.85, 0.035, gate=dur)
    return np.tanh(y * env * 1.4) * vel * 0.8


def lead(midi, dur, vel=1.0, cutoff=4200, vib=0.12):
    n = secs(dur + 0.2)
    f0 = mtof(midi)
    t = np.arange(n) / SR
    vibr = 1 + (vib / 12 * math.log(2)) * np.sin(2 * np.pi * 5.5 * t) * np.minimum(1, t / 0.25)
    x = (saw(f0 * vibr * 2 ** (0.07 / 12), n, RNG.random()) + saw(f0 * vibr * 2 ** (-0.07 / 12), n, RNG.random())
         + square(f0 * vibr / 2, n, RNG.random(), 0.4) * 0.5) / 2.3
    fc = cutoff * (1 + 1.5 * np.exp(-t / 0.12))
    y = lp(x, fc, 1.0)
    env = adsr(n, 0.006, 0.12, 0.75, 0.16, gate=dur)
    yl = y * env
    return np.stack([yl, np.roll(yl, 90)], 1) * vel


def chip(midi, dur, vel=1.0):
    n = secs(dur + 0.02)
    x = square(mtof(midi), n, 0.0, 0.25)
    env = adsr(n, 0.001, 0.04, 0.6, 0.02, gate=dur)
    return lp(x * env, 9000) * vel * 0.5


def bell(midi, dur=1.2, vel=1.0, ratio=3.5, index=2.2):
    n = secs(dur)
    f = mtof(midi)
    t = np.arange(n) / SR
    mod = np.sin(2 * np.pi * f * ratio * t) * index * np.exp(-t / 0.35)
    x = np.sin(2 * np.pi * f * t + mod) * np.exp(-t / 0.7) * np.minimum(1, t / 0.002)
    return fade(x * vel * 0.6, 0.0005, 0.05)


def pad(midis, dur, vel=1.0, cutoff=1500, a=0.6, r=1.2):
    n = secs(dur + r)
    out = np.zeros((n, 2))
    for m in midis:
        out[:len(out)] += supersaw(m, dur, voices=5, detune=0.22, cutoff=cutoff, a=a, d=0.5, s=0.9, r=r,
                                   spread=1.0)[:n]
    return out * vel / max(1, len(midis)) * 1.4


def sub_boom(freq=44, dur=2.0, vel=1.0):
    n = secs(dur)
    t = np.arange(n) / SR
    f = freq * (1 + 1.2 * np.exp(-t / 0.05))
    return fade(sine(f, n) * np.exp(-t / 0.7) * vel, 0.001, 0.2)
