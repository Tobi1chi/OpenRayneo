"""Scene compositor. Each scene draws its own background; z decides overlap order."""
import skia

from core import C, c4, B, DURATION
from . import (s01_intro, s02_logo, s03_three, s04_arch, s05_assistant, s06_lifelog, s07_speaker,
               s08_hud, s09_api, s10_sync, s11_montage, s12_outro)

# (start, end, z, module)
SCENES = [
    (B(1), B(5), 0, s01_intro),
    (B(5), B(7), 1, s02_logo),
    (B(6, 2.8), B(9), 0, s03_three),
    (B(8, 3.2), B(13), 1, s04_arch),
    (B(12, 2.8), B(17), 2, s05_assistant),
    (B(16, 2.8), B(21), 3, s06_lifelog),
    (B(20, 2.8), B(25), 4, s07_speaker),
    (B(24, 2.8), B(29), 5, s08_hud),
    (B(28, 3.2), B(31), 6, s09_api),
    (B(30, 3.0), B(33), 7, s10_sync),
    (B(32, 3.2), B(35), 8, s11_montage),
    (B(34, 3.9), DURATION, 9, s12_outro),
]

# windows (start, end, samples) where fast motion gets sub-frame motion blur
BLUR_WINDOWS = [
    (B(5) - 0.05, B(5) + 0.65, 12),      # logo assemble + ring wave
    (B(6, 3.0), B(7, 0.2), 16),          # zoom through the O hole
    (B(8, 3.2), B(9, 0.2), 12),          # three → arch
    (B(12, 3.0), B(13), 12),             # coral reveal
    (B(16, 3.0), B(17), 12),             # assistant → lifelog
    (B(20, 3.0), B(21), 12),             # lifelog → speaker
    (B(30, 3.1), B(31, 0.3), 24),        # stripe wipe into sync
] + [(B(33, k) - 0.03, B(33, k) + 0.12, 8) for k in range(8)] + [
    (B(34, 3.4), B(35, 0.4), 12),        # implosion into the outro
]


def motion_blur_samples(t):
    for a, b, n in BLUR_WINDOWS:
        if a <= t < b:
            return n
    return 1


def draw_frame(c, t):
    c.clear(c4(C.INK))
    active = [(z, m) for (a, b, z, m) in SCENES if a <= t < b]
    active.sort(key=lambda x: x[0])
    for z, m in active:
        c.save()
        m.draw(c, t)
        c.restore()
