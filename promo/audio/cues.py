"""SFX cue sheet, timed against the same bar/beat grid the scenes use.

Kept deliberately sparse: the music carries the rhythm, so sound effects only mark
  * scene transitions (one soft breath of air, peaking where the motion peaks), and
  * moments where the product itself would make a sound (wake tone, HUD reply, notification,
    typing, request accepted, sync done, the logo locking in).
Individual elements appearing on screen get no sound of their own.
"""
import numpy as np

from core import B
from audio import sfx as X
from audio.dsp import RNG, SR


def cues():
    q = []

    def add(t, clip, gain=1.0):
        q.append((t, clip, gain))

    def breath(t_peak, gain=0.3, dur=0.8, peak=0.6, f0=350, f1=1800, pan=0.35):
        """Air swell whose loudest point (measured, ~10 ms smoothing) lands on the visual transition."""
        clip = X.air(dur, 1.0, f0, f1, peak, -pan, pan)
        level = np.convolve(np.abs(clip).max(1), np.ones(480) / 480, 'same')
        add(t_peak - np.argmax(level) / SR, clip, gain)

    # ---- S1 intro: the indicator LED lights up; chips are pulled back in before the drop
    add(B(1, 1), X.bell_soft((81,), 0.8, dur=2.2), 0.22)
    breath(B(4, 1) + 0.35, 0.18, dur=1.0, peak=0.7, f0=900, f1=300)

    # ---- S2 logo: the pill locks into the O; zoom through the hole
    add(B(5) + 0.72, X.soft_click(0.9, 1100), 0.32)
    breath(B(6, 3.62), 0.36, dur=0.9, peak=0.55, f0=300, f1=2600, pan=0.0)

    # ---- S3 → S4
    breath(B(8, 3.55), 0.24)
    # S4: the scene switch flips from Mac to phone
    add(B(11, 3), X.soft_click(0.8, 1400), 0.24)
    breath(B(12, 3.16), 0.26)

    # ---- S5 native assistant: wake word recognised, reply appears on the HUD; second wake reuses the session
    add(B(13, 2), X.bell_soft((81, 88), 0.9), 0.3)
    add(B(14, 2) + 0.42, X.bell_soft((88, 93), 0.7, gap=0.09), 0.22)
    add(B(15, 1.5), X.bell_soft((81, 88), 0.8), 0.24)
    breath(B(16, 3.18), 0.24)

    # ---- S6 lifelog: the day summary is generated
    add(B(19, 3), X.bell_soft((84, 88, 91), 0.7, gap=0.1), 0.22)
    breath(B(20, 3.15), 0.24)

    # ---- S7 speakers: a faint scan texture under channel 2
    add(B(21, 2.5), X.scan(2.2, 0.6), 0.06)
    breath(B(22, 3) + 0.5, 0.16, dur=1.0, f0=500, f1=1200)
    breath(B(24, 3.25), 0.2)

    # ---- S8 HUD: display wakes; one notification
    add(B(25) + 0.3, X.hum_on(0.6, 0.8), 0.18)
    add(B(27, 0.25), X.bell_soft((88, 84), 0.7, gap=0.1), 0.22)
    breath(B(28, 3.2) + 0.25, 0.18, dur=0.7, f0=600, f1=1500)

    # ---- S9 API: typing, Enter, request accepted
    from scenes.s09_api import T_TYPE, T_RESP, CMD, CPS
    n = sum(len(l) for l in CMD)
    k = 0
    tt = T_TYPE
    while k < n:
        add(tt, X.soft_key(0.6 + 0.4 * RNG.random()), 0.1)
        step = 2 + int(RNG.random() * 3)
        k += step
        tt += step / CPS
    add(T_RESP - 0.2, X.soft_key(1.0), 0.18)
    add(T_RESP + 0.05, X.bell_soft((88, 93), 0.6, gap=0.07), 0.18)
    breath(B(30, 3.47), 0.28, dur=0.7, peak=0.5, f0=400, f1=2400)

    # ---- S10 sync: devices meet; results flow both ways
    from scenes.s10_sync import T_MEET
    add(T_MEET, X.bell_soft((79, 84, 88), 0.7, gap=0.1), 0.22)
    breath(B(33) - 0.02, 0.18, dur=0.7, f0=1600, f1=400)

    # ---- S11 → S12: everything pulls into the pill right before the final drop
    breath(B(35) - 0.04, 0.24, dur=1.2, peak=0.92, f0=300, f1=2200, pan=0.0)

    # ---- S12 outro: logo locks again; the final chord gets a light shimmer
    add(B(35) + 0.72, X.soft_click(0.9, 1100), 0.3)
    add(B(37), X.shimmer(0.8, 2.5, 84), 0.2)
    return q
