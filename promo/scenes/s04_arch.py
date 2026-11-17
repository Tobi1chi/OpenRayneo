"""Bars 9–12: glasses → Mac / phone (each direct, switch by scene) → local agents; sync."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s03_three import NODE_Y

T0 = B(9)
GLX, GLY = CX, 178
CARD_W, CARD_H = 640, 260
MX, PX, CARD_Y = CX - 470, CX + 470, 590
AG_Y = 880
SWITCH = B(11, 3)


def _card(c, t, x, y, t0, accent, icon, title, sub, bullet, active):
    pw = out_back(prog(t, t0, 0.5), 1.6)
    ph = out_back(prog(t, t0 + 0.08, 0.5), 1.6)
    if pw <= 0:
        return
    w, h = CARD_W * pw, CARD_H * max(ph, 0.12)
    rrect_c(c, x, y, w, h, min(36, h / 2), paint(C.INK2))
    rrect_c(c, x, y, w, h, min(36, h / 2), paint(accent, 0.35 + 0.65 * active, stroke=3 + 2 * active))
    if active > 0:
        rrect_c(c, x, y, w + 30, h + 30, 50, paint(accent, 0.18 * active, blur=30))
    ix = x - CARD_W / 2 + 105
    s = out_back(prog(t, t0 + 0.25, 0.45), 2.2)
    if s > 0:
        with Save(c):
            c.translate(ix, y)
            c.scale(s, s)
            c.drawCircle(0, 0, 70, paint(accent, 0.16))
            c.drawPath(icon(0, 0, 0.9 if icon is S.ic_laptop else 0.95), paint(accent))
    tx = x - CARD_W / 2 + 200
    T.ktext(c, title, tx, y - 36, 54, t, t0 + 0.3, None, color=C.WHITE, family=T.EN, weight=700)
    T.ktext(c, sub, tx, y + 20, 34, t, t0 + 0.4, None, color=C.PAPER, weight=600, stagger=0.02)
    T.ktext(c, bullet, tx, y + 76, 26, t, t0 + 0.5, None, color=C.GRAY, weight=500, stagger=0.012)


def _agent(c, t, x, t0, accent, port):
    s = out_back(prog(t, t0, 0.5), 2.0)
    if s <= 0:
        return
    with Save(c):
        c.translate(x, AG_Y)
        c.scale(s, s)
        w, h = 400, 92
        rrect_c(c, 0, 0, w, h, h / 2, paint(C.PAPER))
        c.drawCircle(-w / 2 + 46, 0, 30, paint(accent))
        c.drawPath(S.ic_spark(-w / 2 + 46, 0, 0.5), paint(C.WHITE))
        T.text(c, '本机 Agent', -w / 2 + 92, 12, 34, C.INK, weight=600)
        T.text(c, port, w / 2 - 30, 13, 36, accent, family=T.NUM, weight=700, align='right')


def _link(x0, y0, x1, y1):
    p = skia.Path()
    p.moveTo(x0, y0)
    p.cubicTo(x0, y0 + 70, x1, y0 + 10, x1, y1)
    return p


LINK_M = _link(GLX - 150, 350, MX, CARD_Y - CARD_H / 2 - 12)
LINK_P = _link(GLX + 150, 350, PX, CARD_Y - CARD_H / 2 - 12)


def draw(c, t):
    # circle reveal from the OpenRayneo node of the previous scene
    rp = prog(t, B(8, 3.2), 0.4)
    if rp < 1:
        K.circle_reveal_clip(c, CX, NODE_Y, lerp(118, 1250, in_out_cubic(rp)))
    K.soft_bg(c, C.INK, 0.03)
    K.grid_dots(c, t, C.PAPER, 0.04)

    # glasses node
    gs = spring(prog(t, T0 + 0.05, 0.7))
    with Save(c):
        c.translate(GLX, GLY)
        c.scale(gs, gs)
        c.drawPath(S.ic_glasses(0, 0, 1.05), paint(C.PAPER))
        rrect_c(c, 92 * 1.05 - 6, -36, 34, 12, 6, paint(C.MINT))
    T.ktext(c, '雷鸟 iO · 官方能力', GLX, GLY + 108, 32, t, T0 + 0.3, None, color=C.PAPER,
            align='center', stagger=0.025)
    T.ktext(c, '助手 · 全天智记 · 字幕提示 · 录音 · 设置', GLX, GLY + 148, 24, t, T0 + 0.45, None,
            color=C.GRAY, weight=500, align='center', stagger=0.01)

    # links: draw on, then show which side is connected
    sw = out_cubic(prog(t, SWITCH, 0.35))
    act_m = clamp(prog(t, B(10, 2), 0.3)) * (1 - sw)
    act_p = sw
    for path, d0, act, col in ((LINK_M, T0 + 0.55, act_m, C.BLUE), (LINK_P, T0 + 0.65, act_p, C.MINT)):
        d = out_cubic(prog(t, d0, 0.5))
        if d <= 0:
            continue
        inactive = 1 - act
        if inactive > 0.01:
            p = paint(C.GRAY, 0.45 * inactive, stroke=4)
            p.setPathEffect(skia.DashPathEffect.Make([14, 12], -t * 40))
            c.drawPath(K._trim(path, 0, d), p)
        if act > 0.01:
            K.draw_trim(c, path, 0, d, col, 6, act)
            K.flow_dots(c, path, t, col, speed=0.9, n=4, r=8, a=act)
        # bluetooth badge at the midpoint
        pm = skia.PathMeasure(path, False, 1)
        pos, _ = pm.getPosTan(pm.getLength() * 0.5)
        bs = out_back(prog(t, d0 + 0.3, 0.4), 2.4)
        if bs > 0:
            with Save(c):
                c.translate(pos.x(), pos.y())
                c.scale(bs, bs)
                c.drawCircle(0, 0, 30, paint(mixc(C.INK3, col, act)))
                c.drawPath(S.ic_bt(0, 0, 0.62), paint(C.WHITE if act > 0.5 else C.PAPER))
    # switch flash
    fl = pulse(t, SWITCH, 0.5)
    if fl > 0:
        c.drawCircle(GLX, GLY, 160 + 180 * (1 - fl), paint(C.MINT, 0.5 * fl, stroke=6))
    K.headline(c, '双端各自直连', 'Mac 扩展测试 · 手机日常记录 · 按场景切换', 110, 150, t, T0 + 0.9, None,
               color=C.WHITE, sub_color=C.PAPER, size=52, sub_size=26, accent=C.MINT)

    # device cards
    _card(c, t, MX, CARD_Y, T0 + 0.8, C.BLUE, S.ic_laptop, 'Mac', '扩展与测试工作台',
          'Agent · 脚本 · 工作流 · 测试', act_m)
    _card(c, t, PX, CARD_Y, T0 + 0.95, C.MINT, S.ic_phone, 'Android', '日常记录主端',
          '全天记录 · 转写 · 人物 · 总结', act_p)

    # local API connectors + agents
    for x, t0, col, port, act in ((MX, B(10, 0), C.BLUE, ':8765', act_m), (PX, B(10, 0.5), C.MINT, ':8766', act_p)):
        d = out_cubic(prog(t, t0, 0.3))
        if d > 0:
            y0, y1 = CARD_Y + CARD_H / 2 + 8, AG_Y - 54
            path = S.poly([(x, y0), (x, y1)], close=False)
            K.draw_trim(c, path, 0, d, col, 5, 0.5 + 0.5 * act)
            if act > 0.05:
                K.flow_dots(c, path, t, col, speed=1.4, n=2, r=6, a=act)
            T.ktext(c, '本机 API', x + 22, (y0 + y1) / 2 + 9, 22, t, t0 + 0.1, None, color=C.GRAY, weight=500)
        _agent(c, t, x, t0 + 0.2, col, port)

    # meet-up sync between the two devices
    d = out_cubic(prog(t, B(10, 2), 0.45))
    if d > 0:
        y = CARD_Y - 10
        xa, xb = MX + CARD_W / 2 + 20, PX - CARD_W / 2 - 20
        path = S.poly([(xa, y), (xb, y)], close=False)
        K.draw_trim(c, path, 0.5 - d / 2, 0.5 + d / 2, C.AMBER, 5, 0.9)
        for sgn, xx in ((-1, xa), (1, xb)):
            c.drawPath(S.poly([(xx + sgn * 2, y), (xx - sgn * 16, y - 12), (xx - sgn * 16, y + 12)]),
                       paint(C.AMBER, d))
        sync_on = clamp(prog(t, B(12, 0), 0.3))
        if sync_on > 0:
            K.flow_dots(c, path, t, C.AMBER, speed=0.8, n=3, r=6, a=sync_on)
            K.flow_dots(c, S.poly([(xb, y), (xa, y)], close=False), t, C.AMBER, speed=0.8, n=3, r=6,
                        a=sync_on, phase=0.5)
        with Save(c):
            c.translate(CX, y - 46)
            sc = out_back(prog(t, B(10, 2.4), 0.4), 2.0)
            c.scale(sc, sc)
            c.drawPath(S.ic_sync(0, 0, 0.55), paint(C.AMBER))
        T.ktext(c, '相遇同步', CX, y + 52, 28, t, B(10, 2.6), None, color=C.AMBER, align='center',
                stagger=0.03)
        T.ktext(c, ':8767', CX, y + 90, 26, t, B(10, 2.8), None, color=C.GRAY, family=T.NUM,
                weight=700, align='center')
