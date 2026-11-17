"""Bars 35–38: logo re-forms, repo link, call to action, disclaimer, fade out."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s02_logo import draw_logo

T0 = B(35)
T_HIT = B(37)
LS = 1.12


def draw(c, t):
    K.soft_bg(c, C.INK, 0.035)
    K.grid_dots(c, t, C.PAPER, 0.045)
    # pre-drop: the mint pill squashes at centre
    if t < T0:
        ant = out_cubic(prog(t, T0 - 0.2, 0.2))
        with Save(c):
            c.translate(CX, CY)
            c.scale(1 + 0.4 * ant, 1 - 0.45 * ant)
            rrect_c(c, 0, 0, 110, 48, 24, paint(C.MINT))
        return
    lx, ly = CX - S.LOGO_CENTER_DX * LS, CY - 215
    shake = 14 * math.exp(-7 * (t - T0))
    c.translate(shake * math.sin(t * 83), shake * math.cos(t * 71))
    K.shockwave(c, CX, ly + 20, t, T0, C.MINT, rmax=1300, dur=1.0, width=30, n=3)
    hit = pulse(t, T_HIT, 0.8)
    if hit > 0:
        K.shockwave(c, lx, ly, t, T_HIT, C.WHITE, rmax=900, dur=1.0, width=10, n=2)
    with Save(c):
        c.translate(lx, ly)
        sp = spring(prog(t, T0, 0.9))
        s = LS * lerp(0.7, 1.0, sp) * (1 + 0.04 * hit)
        c.scale(s, s)
        blink = 0.0
        if t > T_HIT + 0.6:
            ph = (t - T_HIT - 0.6) % BAR
            blink = 1.0 if 1.75 < ph < 1.9 else 0.0
        draw_logo(c, t, T0, led_blink=blink)
    K.burst(c, lx - 100 * LS, ly, t, T0 + 0.72, C.MINT, n=10, r0=60, r1=170, dur=0.45, width=7)
    wy = CY + 90
    size = 120
    w_open = T.width('Open', size, T.EN, 500)
    w_ray = T.width('Rayneo', size, T.EN, 700)
    x0 = CX - (w_open + w_ray) / 2
    T.ktext(c, 'Open', x0, wy, size, t, T0 + 1.0, None, color=C.WHITE, family=T.EN, weight=500, a=0.82, stagger=0.035)
    T.ktext(c, 'Rayneo', x0 + w_open, wy, size, t, T0 + 1.1, None, color=C.WHITE, family=T.EN, weight=700,
            stagger=0.035)
    T.ktext(c, '把眼镜的官方能力，交给你的 Agent', CX, wy + 84, 42, t, B(35, 3), None, color=C.PAPER, a=0.9,
            align='center', stagger=0.03)
    # repo pill
    rp = out_back(prog(t, B(36, 0.5), 0.55), 1.6)
    if rp > 0:
        url = 'github.com/Tobi1chi/OpenRayneo'
        tw = T.width(url, 34, T.MONO, 700)
        pw, ph = tw + 140, 84
        with Save(c):
            c.translate(CX, wy + 196)
            c.scale(lerp(0.4, 1, rp), rp)
            rrect_c(c, 0, 0, pw, ph, ph / 2, paint(C.INK2))
            rrect_c(c, 0, 0, pw, ph, ph / 2, paint(C.MINT, 0.6 + 0.4 * hit, stroke=3))
            c.drawPath(S.ic_star(-pw / 2 + 52, 0, 0.55), paint(C.AMBER))
        T.ktext(c, url, CX + 30, wy + 208, 34, t, B(36, 0.7), None, color=C.WHITE, family=T.MONO, weight=700,
                align='center', mode='scramble', stagger=0.018, dur=0.25)
    T.ktext(c, '点个 Star，一起把眼镜接进你的 Agent', CX, wy + 300, 34, t, B(36, 2.5), None, color=C.MINT,
            align='center', stagger=0.025)
    # disclaimer
    da = clamp(prog(t, T_HIT + 0.3, 0.6))
    if da > 0:
        T.text(c, 'OpenRayneo 为独立开源项目，与雷鸟官方无关；名称与商标归各自权利人 · Apache-2.0', CX, H - 44, 22,
               C.GRAY, 0.75 * da, weight=500, align='center')
    # fade to black
    fo = in_out_sine(prog(t, B(39), DURATION - B(39)))
    if fo > 0:
        c.drawColor(skia.Color4f(0, 0, 0, fo))
