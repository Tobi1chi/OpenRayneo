"""Arrangement: 105 BPM, A minor, F–G–Em–Am; ends on a C chord. Returns stereo stems."""
import numpy as np

from core import B, BEAT, BAR, DURATION
from audio.dsp import SR, secs, Track, db, lp, hp, stereo, RNG
from audio import instruments as I
from audio import sfx as X

CHORDS = {'F': [53, 57, 60, 64], 'G': [55, 59, 62, 67], 'Em': [52, 55, 59, 62], 'Am': [57, 60, 64, 67],
          'C': [48, 55, 60, 64, 67, 74]}
ROOT = {'F': 41, 'G': 43, 'Em': 40, 'Am': 45, 'C': 36}
PROG = ['F', 'G', 'Em', 'Am']
LAST_BAR = 38

# hook: per chord, (beat, length, midi)
HOOK = {
    'F': [(0, .75, 76), (.75, .25, 74), (1, .5, 72), (1.5, .5, 69), (2.5, .5, 72), (3, 1, 74)],
    'G': [(0, .75, 74), (.75, .25, 72), (1, .5, 71), (1.5, .5, 67), (2.5, .5, 71), (3, .5, 74), (3.5, .5, 76)],
    'Em': [(0, .75, 76), (.75, .25, 74), (1, .5, 71), (1.5, .5, 67), (2.5, .5, 71), (3, .5, 76), (3.5, .5, 79)],
    'Am': [(0, 1.5, 81), (1.5, .5, 79), (2, 1, 76), (3, .5, 72), (3.5, .5, 74)],
}
ARP16 = [0, 2, 1, 3, 2, 4, 3, 5, 4, 6, 5, 7, 6, 4, 3, 1]


def chord_of(bar):
    if bar in (35,):
        return 'F'
    if bar in (36,):
        return 'G'
    if bar >= 37:
        return 'C'
    return PROG[(bar - 1) % 4]


def section(bar):
    for hi, name in ((4, 'intro'), (8, 'dropA'), (12, 'verse'), (16, 'mainA'), (20, 'mainB'), (22, 'break'),
                     (24, 'build1'), (28, 'dropB'), (32, 'groove'), (34, 'build2'), (36, 'final')):
        if bar <= hi:
            return name
    return 'end'


FULL = ('dropA', 'mainA', 'mainB', 'dropB', 'groove', 'final')


def render():
    dur = DURATION + 1.0
    drums, bass, chords, pad, arp, lead, bell, fx = (Track(dur) for _ in range(8))
    kicks = []

    def K(t, v=1.0):
        drums.add(t, I.kick(v), 0.95)
        kicks.append(t)

    for bar in range(1, LAST_BAR + 1):
        sec = section(bar)
        ch = chord_of(bar)
        notes = CHORDS[ch]
        t0 = B(bar)
        # ------------------------------------------------ drums
        if sec in FULL:
            for b in range(4):
                K(t0 + b * BEAT)
                if b in (1, 3):
                    drums.add(t0 + b * BEAT, I.clap(0.9), 0.55)
                drums.add(t0 + (b + 0.5) * BEAT, I.hat(0.9, open_=True), 0.26)
            for s in range(16):
                v = 0.55 + 0.45 * (s % 2) * (0.6 + 0.4 * RNG.random())
                drums.add(t0 + s * BEAT / 4 + 0.004 * (s % 2), I.hat(v), 0.2)
            if sec in ('mainB', 'groove'):
                for s in (3, 6, 11, 14):
                    drums.add(t0 + s * BEAT / 4, I.tom(220 if s < 8 else 180, 0.35), 0.25)
        elif sec == 'verse':
            for b in range(4):
                K(t0 + b * BEAT, 0.9)
                if b in (1, 3):
                    drums.add(t0 + b * BEAT, I.clap(0.8), 0.45)
            for s in range(8):
                drums.add(t0 + s * BEAT / 2, I.hat(0.6 + 0.4 * (s % 2)), 0.22)
            if bar == 12:
                for s in range(4):
                    drums.add(t0 + 3 * BEAT + s * BEAT / 4, I.snare(0.5 + 0.15 * s), 0.24)
        elif sec == 'intro':
            if bar >= 3:
                for s in range(16):
                    drums.add(t0 + s * BEAT / 4, I.shaker(0.4 + 0.6 * (s % 2)), 0.35)
            if bar == 4:
                for k in range(12):
                    tt = t0 + 2 * BEAT + k * BEAT / 8
                    if tt < B(5) - 0.13:
                        drums.add(tt, I.snare(0.3 + 0.6 * k / 12), 0.13)
        elif sec == 'break':
            drums.add(t0 + 2 * BEAT, I.clap(0.6), 0.35)
            for s in range(8):
                drums.add(t0 + s * BEAT / 2, I.shaker(0.5 + 0.5 * (s % 2)), 0.3)
        elif sec == 'build1':
            for b in range(4):
                K(t0 + b * BEAT, 0.75 + 0.1 * (bar - 23))
            div = 2 if bar == 23 else 4
            n = 4 * div
            for k in range(n):
                tt = t0 + k * BEAT / div
                if bar == 24 and k >= 12:
                    for j in range(2):
                        drums.add(tt + j * BEAT / 8, I.snare(0.8), 0.13)
                elif not (bar == 24 and tt >= B(24, 3.5)):
                    drums.add(tt, I.snare(0.35 + 0.5 * (k / n) * (bar - 22) / 2), 0.14)
        elif sec == 'build2':
            for b in range(4):
                if not (bar == 34 and b == 3):
                    K(t0 + b * BEAT, 0.95)
                    chords.add(t0 + b * BEAT, I.supersaw(notes[0] + 12, 0.18, cutoff=5000, fenv=1.5, fdec=0.08, a=0.002,
                                                          d=0.1, s=0.6, r=0.12), 0.38)
            div = 2 if bar == 33 else 4
            for k in range(4 * div):
                tt = t0 + k * BEAT / div
                if tt < B(34, 3.0):
                    drums.add(tt, I.snare(0.4 + 0.5 * (tt - B(33)) / (2 * BAR)), 0.16)
        elif sec == 'final':
            pass  # same as FULL (handled above) — kept for clarity
        if bar == 37:
            K(t0, 1.0)
            drums.add(t0, I.crash(1.0, 4.0), 0.55)
        # crashes at section heads
        if bar in (5, 13, 17, 25, 29, 35):
            drums.add(t0, I.crash(0.9), 0.5)

        # ------------------------------------------------ bass
        r = ROOT[ch]
        if sec in FULL:
            for e in range(8):
                note = r + (12 if e in (3, 7) else 0)
                bass.add(t0 + e * BEAT / 2, I.bass(note, BEAT / 2 - 0.03, vel=0.9 if e % 2 else 1.0), 0.55)
        elif sec == 'verse':
            for (bt, ln) in ((0, 1.5), (1.5, 1.0), (2.5, 1.5)):
                bass.add(t0 + bt * BEAT, I.bass(r, ln * BEAT - 0.03, cutoff=300, fenv=1.5), 0.6)
        elif sec == 'intro' and bar >= 3:
            bass.add(t0, I.bass(r, BAR - 0.05, cutoff=200, fenv=0.5, sub=0.7, vel=0.7), 0.5)
        elif sec == 'build1':
            for e in range(8):
                bass.add(t0 + e * BEAT / 2, I.bass(r, BEAT / 2 - 0.05, cutoff=300 + 200 * (bar - 23)), 0.45)
        elif sec == 'build2':
            for e in range(16 if bar == 34 else 8):
                step = BEAT / (4 if bar == 34 else 2)
                tt = t0 + e * step
                if tt < B(34, 3.0):
                    bass.add(tt, I.bass(r, step - 0.03, cutoff=500), 0.45)
        elif sec == 'end' and bar == 37:
            bass.add(t0, I.bass(r, 3.0, cutoff=260, fenv=1.0, sub=1.0), 0.55)
            fx.add(t0, I.sub_boom(41, 3.0), 0.45)

        # ------------------------------------------------ chords & pads
        if sec in FULL:
            for m in notes:
                chords.add(t0, I.supersaw(m, BAR - 0.05, cutoff=5200 if sec in ('dropA', 'dropB', 'final') else 3800,
                                          a=0.01, d=0.4, s=0.75, r=0.2, fenv=0.6, fdec=0.3), 0.3)
            pad.add(t0, I.pad([m - 12 for m in notes[:3]], BAR, cutoff=900, a=0.2, r=0.6), 0.5)
        elif sec in ('intro', 'verse', 'break', 'build1'):
            cut = {'intro': 700 + 300 * bar, 'verse': 1500, 'break': 2200, 'build1': 1800 + 1500 * (bar - 23)}[sec]
            pad.add(t0, I.pad(notes, BAR, cutoff=cut, a=0.5 if sec == 'intro' else 0.25, r=1.0),
                    0.8 if sec != 'intro' else 0.7)
        elif sec == 'build2':
            pad.add(t0, I.pad(notes, BAR, cutoff=2500 + 2000 * (bar - 33), a=0.1, r=0.4), 0.55)
        elif bar == 37:
            for m in notes:
                chords.add(t0, I.supersaw(m, 3.5, cutoff=4200, a=0.005, d=1.2, s=0.6, r=2.5, fenv=0.8, fdec=0.5), 0.3)
            pad.add(t0, I.pad(notes, 4.0, cutoff=2000, a=0.05, r=2.5), 0.9)

        # ------------------------------------------------ arps
        tones = sorted(notes[:4]) + [n + 12 for n in sorted(notes[:4])]
        if sec in ('verse', 'mainB', 'break', 'build1', 'groove'):
            for s in range(16):
                m = tones[ARP16[s]] + 12
                v = 0.8 if s % 4 == 0 else 0.55
                cut = 1200 if sec != 'break' else 1600
                arp.add(t0 + s * BEAT / 4, I.pluck(m, 0.12, cutoff=cut, vel=v), 0.32)
        elif sec == 'intro':
            for s in range(8):
                m = tones[[0, 2, 4, 6, 7, 6, 4, 2][s]] + 12
                arp.add(t0 + s * BEAT / 2, I.pluck(m, 0.2, cutoff=500 + 250 * bar, vel=0.7 if s % 2 else 0.9), 0.36)
        if sec == 'dropB' and bar in (27, 28):
            for s in range(32):
                m = tones[[0, 1, 2, 3, 4, 5, 6, 7][s % 8]] + 12
                arp.add(t0 + s * BEAT / 8, I.chip(m, BEAT / 8 - 0.01, 0.6), 0.16)

        # ------------------------------------------------ lead hook / bells
        if sec in ('dropA', 'mainA', 'dropB', 'final'):
            oct_ = 0
            for (bt, ln, m) in HOOK.get(ch, []):
                lead.add(t0 + bt * BEAT, I.lead(m + oct_, ln * BEAT - 0.02, vel=0.9), 0.24)
        if sec in ('mainB', 'groove'):
            for bt, k in ((0, 3), (1.5, 2), (3, 1)):
                bell.add(t0 + bt * BEAT, I.bell(notes[k] + 24, 1.4, 0.8), 0.22)
        if bar == 37:
            for k, m in enumerate((72, 76, 79, 84)):
                bell.add(t0 + k * 0.06, I.bell(m, 3.0, 0.7), 0.25)

    # risers / transitions inside the music
    fx.add(B(3), X.riser(2 * BAR - 0.25, 0.8), 0.12)
    fx.add(B(5) - 1.5, I.rev_crash(1.5), 0.2)
    fx.add(B(23), X.riser(2 * BAR - 0.25, 0.8), 0.11)
    fx.add(B(25) - 1.2, I.rev_crash(1.2), 0.18)
    fx.add(B(33), X.riser(2 * BAR - 0.5, 0.9), 0.16)
    fx.add(B(13) - 1.0, I.rev_crash(1.0), 0.35)
    fx.add(B(29) - 1.0, I.rev_crash(1.0), 0.35)
    for tt in (B(5), B(25), B(35)):
        fx.add(tt, I.sub_boom(43, 2.0), 0.36)

    return dict(drums=drums.buf, bass=bass.buf, chords=chords.buf, pad=pad.buf, arp=arp.buf, lead=lead.buf,
                bell=bell.buf, fx=fx.buf), sorted(set(round(k, 4) for k in kicks))
