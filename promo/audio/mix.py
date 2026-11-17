"""Render music + SFX, mix with sidechain pumping, master to about -14 LUFS / -1 dBTP.

python -m audio.mix            → out/audio.wav and out/stems/*.wav
"""
import os
import sys
import time

import numpy as np
import pyloudnorm as pyln
from pedalboard import (Pedalboard, Reverb, Delay, Compressor, Limiter, HighpassFilter, LowpassFilter,
                        Chorus, Gain, LowShelfFilter, HighShelfFilter)
from pedalboard.io import AudioFile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from core import DURATION, BEAT
from audio.dsp import SR, secs, Track, db, limit
from audio import music, cues

OUT = os.path.join(HERE, 'out')


def sidechain(n, kicks, depth=0.7, release=0.16, attack=0.006):
    g = np.ones(n)
    L = secs(release * 4)
    t = np.arange(L) / SR
    curve = 1 - depth * np.exp(-t / release) * np.minimum(1, t / attack + 0.35)
    for k in kicks:
        i = secs(k)
        j = min(n, i + L)
        if i < n:
            g[i:j] = np.minimum(g[i:j], curve[:j - i])
    return g[:, None]


def fxchain(x, board):
    y = board(x.T.astype(np.float32), SR)
    return y.T.astype(np.float64)


def write(path, x):
    with AudioFile(path, 'w', SR, 2, bit_depth=24) as f:
        f.write(x.T.astype(np.float32))


def main():
    t0 = time.time()
    stems, kicks = music.render()
    n = secs(DURATION)
    for k in stems:
        stems[k] = stems[k][:n]
    print(f' music rendered in {time.time() - t0:.1f}s')

    sc_hard = sidechain(n, kicks, 0.72, 0.15)
    sc_soft = sidechain(n, kicks, 0.45, 0.18)

    drums = fxchain(stems['drums'], Pedalboard([HighpassFilter(28), Compressor(-14, 3.0, 4, 90), Gain(1.5)]))
    bass = fxchain(stems['bass'] * sc_hard, Pedalboard([HighpassFilter(32), LowpassFilter(4000), Compressor(-16, 3, 10, 120)]))
    chords = fxchain(stems['chords'] * sc_hard,
                     Pedalboard([HighpassFilter(160), Chorus(0.6, 0.15, 6, 0.15, 0.3),
                                 Reverb(0.6, 0.4, 0.22, 0.85, 1.0)]))
    pad = fxchain(stems['pad'] * sc_soft, Pedalboard([HighpassFilter(110), Reverb(0.85, 0.5, 0.35, 0.75, 1.0)]))
    arp = fxchain(stems['arp'] * sc_soft,
                  Pedalboard([HighpassFilter(220), Delay(0.75 * BEAT, 0.32, 0.24), Reverb(0.6, 0.5, 0.2, 0.85, 1.0)]))
    lead = fxchain(stems['lead'], Pedalboard([HighpassFilter(220), Delay(0.75 * BEAT, 0.28, 0.2),
                                              Reverb(0.7, 0.5, 0.24, 0.85, 1.0), Compressor(-18, 2.5, 5, 100)]))
    bell = fxchain(stems['bell'], Pedalboard([HighpassFilter(300), Reverb(0.85, 0.4, 0.4, 0.75, 1.0)]))
    mfx = fxchain(stems['fx'], Pedalboard([HighpassFilter(25), Reverb(0.7, 0.5, 0.2, 0.9, 1.0)]))

    # SFX
    t1 = time.time()
    sfx = Track(DURATION + 4)
    for (t, clip, gain) in cues.cues():
        sfx.add(t, clip, gain)
    sfx = sfx.buf[:n]
    # soft, roomy SFX bus so effects sit inside the music: no harsh top, generous reverb, gentle glue
    sfx = fxchain(sfx, Pedalboard([HighpassFilter(90), LowpassFilter(9000), Reverb(0.72, 0.55, 0.26, 0.85, 1.0),
                                   Compressor(-20, 2.0, 10, 150)]))
    print(f' sfx rendered in {time.time() - t1:.1f}s')

    levels = dict(drums=db(-3.0), bass=db(-4.0), chords=db(-5.5), pad=db(-8.0), arp=db(-8.5), lead=db(-5.0),
                  bell=db(-9.0), mfx=db(-6.0), sfx=db(-2.5))
    buses = dict(drums=drums, bass=bass, chords=chords, pad=pad, arp=arp, lead=lead, bell=bell, mfx=mfx, sfx=sfx)
    music_mix = sum(buses[k] * levels[k] for k in buses if k != 'sfx')
    mix = music_mix + buses['sfx'] * levels['sfx']

    master = Pedalboard([HighpassFilter(30), LowShelfFilter(70, -2.5, 0.7), HighShelfFilter(8000, 2.5, 0.7),
                         Compressor(-12, 2.0, 25, 180)])
    y = fxchain(mix, master)
    # fade tail
    fo = secs(2.0)
    y[-fo:] *= np.linspace(1, 0, fo)[:, None] ** 1.5

    meter = pyln.Meter(SR)
    target = -14.0
    for _ in range(4):
        L = meter.integrated_loudness(y)
        y = y * db(target - L)
        y = limit(y, -2.0)   # leaves room for AAC encoding overshoot (≈ +0.8 dB)
    L = meter.integrated_loudness(y)
    # true-peak check (4x oversampled)
    from scipy.signal import resample_poly
    tp = 20 * np.log10(np.max(np.abs(resample_poly(y, 4, 1, axis=0))) + 1e-12)
    print(f' integrated {L:.2f} LUFS, true peak {tp:.2f} dBTP')

    os.makedirs(os.path.join(OUT, 'stems'), exist_ok=True)
    write(os.path.join(OUT, 'audio.wav'), y)
    write(os.path.join(OUT, 'stems', 'music.wav'), music_mix * db(target - L) * 0.8)
    write(os.path.join(OUT, 'stems', 'sfx.wav'), buses['sfx'] * levels['sfx'] * db(target - L) * 0.8)
    print(f' wrote out/audio.wav ({len(y) / SR:.2f}s) in {time.time() - t0:.1f}s')


if __name__ == '__main__':
    main()
