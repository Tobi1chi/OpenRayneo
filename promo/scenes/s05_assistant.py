"""Bars 13–16: native assistant → phone → local agent → reply on HUD; session reuse."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s04_arch import PX, CARD_Y

T0 = B(13)
TB = B(15)          # phase B: session reuse
ROW_Y = 640
BG = C.CORAL
DARK = hexrgb('#2A1512')


def _xs(t):
    p = in_out_cubic(prog(t, TB, 0.55))
    return (lerp(250, 200, p), lerp(650, 520, p), lerp(1050, 840, p), lerp(1460, 1390, p))


CARD = (1390, 600, 600, 560)
AG_SHAPE = S.Shape(S.circle(0, 0, 92))
CARD_SHAPE = S.Shape(S.rrect_c(0, 0, 600, 560, 44))


def _node(c, t, x, y, t0, icon, isc, title, sub, fill=C.WHITE, icol=DARK, ring=0.0):
    s = out_back(prog(t, t0, 0.5), 2.0)
    if s <= 0:
        return
    with Save(c):
        c.translate(x, y)
        c.scale(s, s)
        if ring > 0:
            c.drawCircle(0, 0, 92 + 70 * (1 - ring), paint(C.WHITE, ring * 0.6, stroke=6))
        c.drawCircle(0, 0, 92, paint(fill))
        c.drawPath(icon(0, 0, isc), paint(icol))
    T.ktext(c, title, x, y + 140, 32, t, t0 + 0.15, None, color=C.WHITE, align='center', stagger=0.02)
    T.ktext(c, sub, x, y + 180, 24, t, t0 + 0.25, None, color=C.WHITE, a=0.75, weight=500, align='center',
            stagger=0.012)


def _bubble(c, x, y, txt, t, t_in, t_out=None, size=34, fill=C.WHITE, fg=DARK, tail='down'):
    s = out_back(prog(t, t_in, 0.45), 2.2)
    if t_out is not None:
        s *= 1 - in_cubic(prog(t, t_out, 0.25))
    if s <= 0.001:
        return
    w = T.width(txt, size) + 56
    h = size + 44
    with Save(c):
        c.translate(x, y)
        c.scale(s, s)
        rrect_c(c, 0, 0, w, h, h / 2, paint(fill))
        if tail == 'down':
            c.drawPath(S.poly([(-14, h / 2 - 4), (14, h / 2 - 4), (-6, h / 2 + 22)]), paint(fill))
        T.text(c, txt, 0, size * 0.36, size, fg, align='center')


def _msg(c, txt, x, y, t, t_in, me, size=32, wmax=500, hl=None):
    p = out_back(prog(t, t_in, 0.45), 1.6)
    if p <= 0:
        return
    w = min(wmax, T.width(txt, size) + 44)
    h = size + 34
    with Save(c):
        bx = x + (CARD[2] / 2 - 36 - w if me else -CARD[2] / 2 + 36)
        c.translate(bx + (w if me else 0), y)
        c.scale(p, p)
        c.translate(-(w if me else 0), 0)
        rrect(c, 0, -h / 2, w, h, 20, paint(C.CORAL if me else C.PAPER2))
        cols = None
        if hl:
            cols = [C.WHITE if me else DARK] * len(txt)
            a, b = hl
            for i in range(a, b):
                cols[i] = C.MINTD
        T.ktext(c, txt, 22, size * 0.36, size, t, t_in + 0.05, None, color=C.WHITE if me else DARK,
                mode='fade', stagger=0.012, dur=0.25, colors=cols)


def draw(c, t):
    rp = prog(t, B(12, 2.8), 0.6)
    if rp < 1:
        K.circle_reveal_clip(c, PX, CARD_Y, lerp(0, 2300, in_out_cubic(rp)))
    K.soft_bg(c, BG, 0.04)
    K.grid_dots(c, t, C.WHITE, 0.07)
    K.headline(c, '原生助手 × 你的 Agent', '唤醒、音频、轮次走官方通道 · 回复由本机 Agent 生成', 110, 160, t, T0 + 0.1,
               None, color=C.WHITE, size=58, sub_size=28, accent=C.WHITE)
    ux, gx, px, ax = _xs(t)

    # links
    for i, (x0, x1) in enumerate(((ux + 100, gx - 110), (gx + 110, px - 110), (px + 110, ax - 110))):
        d = out_cubic(prog(t, T0 + 0.45 + 0.1 * i, 0.4))
        if d > 0:
            path = S.poly([(x0, ROW_Y), (x1, ROW_Y)], close=False)
            K.draw_trim(c, path, 0, d, DARK, 5, 0.25)
    # audio packets: user → glasses → phone ; text tokens phone → agent
    for (t0, t1, x0, x1, kind) in ((B(13, 2.5), B(14, 0.3), ux + 100, gx - 110, 'wave'),
                                   (B(13, 3.0), B(14, 0.6), gx + 110, px - 110, 'wave'),
                                   (B(14, 0.5), B(14, 1.4), px + 110, ax - 110, 'tok'),
                                   (B(15, 1.6), B(15, 2.4), ux + 100, gx - 110, 'wave'),
                                   (B(15, 1.9), B(15, 2.7), gx + 110, px - 110, 'wave'),
                                   (B(15, 2.4), B(15, 3.2), px + 110, ax - 230, 'tok')):
        if t0 <= t <= t1:
            for k in range(3):
                f = (t - t0) / (t1 - t0) * 1.6 - k * 0.25
                if 0 <= f <= 1:
                    x = lerp(x0, x1, out_quad(f))
                    a = clamp(min(f, 1 - f) * 6)
                    if kind == 'wave':
                        for j in range(3):
                            hh = 18 + 16 * abs(math.sin(t * 20 + j * 1.3 + k))
                            rrect_c(c, x + (j - 1) * 11, ROW_Y, 7, hh, 3.5, paint(C.WHITE, a))
                    else:
                        rrect_c(c, x, ROW_Y, 46, 20, 10, paint(C.WHITE, a))

    # nodes
    ring_g = pulse(t, B(13, 2), 0.6) + pulse(t, B(15, 1.5), 0.6)
    _node(c, t, ux, ROW_Y, T0 + 0.25, S.ic_person, 1.1, '你', '说话 / 唤醒', fill=C.WHITE, icol=C.CORAL)
    _node(c, t, gx, ROW_Y, T0 + 0.35, S.ic_glasses, 0.55, '雷鸟 iO', '唤醒 · 音频 · 回写', ring=ring_g)
    _node(c, t, px, ROW_Y, T0 + 0.45, S.ic_phone, 0.9, 'OpenRayneo', '音频 · 基础转写')

    # agent node → conversation card
    mp = in_out_cubic(prog(t, TB, 0.5))
    s = out_back(prog(t, T0 + 0.55, 0.5), 2.0)
    if s > 0:
        cx = lerp(ax, CARD[0], mp)
        cy = lerp(ROW_Y, CARD[1], mp)
        with Save(c):
            c.translate(cx, cy)
            c.scale(s, s)
            c.drawPath(S.morph_path(AG_SHAPE, CARD_SHAPE, mp), paint(mixc(DARK, C.WHITE, mp)))
            if mp < 0.5:
                sp = 1 - mp * 2
                c.scale(sp, sp)
                c.rotate(30 * math.sin(t * 2))
                c.drawPath(S.ic_spark(0, 0, 1.2), paint(C.MINT))
        if mp < 0.05:
            T.ktext(c, '本机 Agent', ax, ROW_Y + 140, 32, t, T0 + 0.7, None, color=C.WHITE, align='center')
            T.ktext(c, '如 DSH Go', ax, ROW_Y + 180, 24, t, T0 + 0.8, None, color=C.WHITE, a=0.75,
                    weight=500, align='center')
        # thinking dots
        if B(14, 1.3) <= t < B(14, 2.1):
            for k in range(3):
                yy = ROW_Y - 150 - 12 * abs(math.sin(t * 9 + k * 0.8))
                c.drawCircle(ax - 30 + 30 * k, yy, 9, paint(C.WHITE))

    # speech bubbles
    _bubble(c, ux, ROW_Y - 170, '小雷小雷', t, B(13, 1), B(13, 3.4))
    _bubble(c, ux + 60, ROW_Y - 170, '明天几点组会？', t, B(13, 3.5), B(14, 3.0))
    _bubble(c, ux + 120, ROW_Y - 170, '小雷小雷，提前半小时提醒我', t, B(15, 1), B(16, 1.0), size=30)
    if B(13, 1) <= t < B(14, 0.5) or B(15, 1) <= t < B(15, 3):
        K.wave_bars(c, ux - 80, ux + 80, ROW_Y + 236, t, C.WHITE, n=12, hmax=36, a=0.8, seed=3)

    # reply flies back: agent → glasses (arc), then HUD
    rp = prog(t, B(14, 2), 0.45)
    if 0 < rp < 1:
        path = K.arc_path(ax, ROW_Y - 100, gx, ROW_Y - 110, 260)
        pm = skia.PathMeasure(path, False, 1)
        pos, _ = pm.getPosTan(pm.getLength() * in_out_cubic(rp))
        rrect_c(c, pos.x(), pos.y(), 70, 28, 14, paint(C.WHITE))
        K.draw_trim(c, path, max(0, in_out_cubic(rp) - 0.25), in_out_cubic(rp), C.WHITE, 4, 0.6)
    hud_in = B(14, 2) + 0.42
    hud_out = TB
    hs = out_back(prog(t, hud_in, 0.45), 1.6) * (1 - in_cubic(prog(t, hud_out, 0.3)))
    if hs > 0:
        hw, hh = 520, 150
        hx, hy = gx, ROW_Y - 250
        with Save(c):
            c.translate(hx, hy)
            c.scale(hs, hs)
            rrect_c(c, 0, 0, hw, hh, 30, paint(C.INK))
            rrect_c(c, 0, 0, hw, hh, 30, paint(C.HUD, 0.25, stroke=2))
            K.glow_text(c, '明早 10:00 组会', -hw / 2 + 36, -10, 40, C.HUD, weight=600)
            K.glow_text(c, '原生回复 · 显示在眼镜上', -hw / 2 + 36, 40, 24, C.HUD, a=0.7, glow=6)
            c.drawPath(S.poly([(-14, hh / 2 - 2), (14, hh / 2 - 2), (0, hh / 2 + 22)]), paint(C.INK))

    # phase B: conversation card content
    if mp > 0.6:
        x, y, w, h = CARD
        top = y - h / 2
        T.ktext(c, '同一会话', x - w / 2 + 36, top + 66, 34, t, TB + 0.35, None, color=DARK)
        chip_s = out_back(prog(t, B(16, 0.0), 0.45), 2.0)
        if chip_s > 0:
            with Save(c):
                c.translate(x + w / 2 - 150, top + 54)
                c.scale(chip_s, chip_s)
                rrect_c(c, 0, 0, 230, 52, 26, paint(C.MINT))
                c.drawPath(S.ic_check(-82, 0, 0.6), paint(DARK))
                T.text(c, '上下文保留', 12, 10, 26, DARK, align='center')
        c.drawLine(x - w / 2 + 36, top + 100, x + w / 2 - 36, top + 100, paint(DARK, 0.1, stroke=2))
        _msg(c, '明天几点组会？', x, top + 160, t, TB + 0.45, True)
        _msg(c, '明早 10:00。', x, top + 240, t, TB + 0.6, False)
        tag = out_cubic(prog(t, TB + 0.8, 0.3))
        if tag > 0:
            T.text(c, '唤醒 #1', x - w / 2 + 36, top + 300, 22, DARK, 0.45 * tag, weight=500)
            T.text(c, '唤醒 #2', x - w / 2 + 36, top + 332, 22, DARK, 0.45 * clamp(prog(t, B(15, 3.2), 0.3)),
                   weight=500)
            c.drawLine(x - w / 2 + 120, top + 293, x + w / 2 - 36, top + 293, paint(DARK, 0.08 * tag, stroke=2))
        _msg(c, '提前半小时提醒我', x, top + 390, t, B(15, 3.3), True)
        _msg(c, '好的，9:30 提醒你。', x, top + 470, t, B(16, 0.6), False, hl=(4, 8))
        T.ktext(c, '跨唤醒复用 Agent 对话，不再每次新建', CX - 200, 960, 34, t, B(16, 1.0), None,
                color=C.WHITE, weight=600, align='center', stagger=0.02)
