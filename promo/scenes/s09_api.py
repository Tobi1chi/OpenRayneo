"""Bars 29–30: one HTTP request from a local agent puts text on the glasses."""
import math
import skia

from core import *
import shapes as S
import typo as T
import kit as K
from scenes.s08_hud import panel_rect, T_END

T0 = B(29)
TERM = (620, 610, 1020, 470)          # cx, cy, w, h
TERM_BG = hexrgb('#0B0E16')
CMD = ['$ curl -X POST 127.0.0.1:8765/v1/captions/text \\',
       '    -H "Authorization: Bearer $TOKEN" \\',
       '    -d \'{"text":"你好，Agent"}\'']
CPS = 60.0
T_TYPE = T0 + 0.25
ENDPOINTS = ['POST /v1/notifications', 'POST /v1/teleprompter', 'POST /v1/prompts/start', 'GET  /v1/asr',
             'POST /v1/recording/start', 'GET  /v1/lifelog', 'POST /v1/todos', 'POST /v1/virtual-mic/start',
             'GET  /v1/device', 'POST /v1/captions/text']


def _type_end():
    n = sum(len(l) for l in CMD)
    return T_TYPE + n / CPS


T_RESP = _type_end() + 0.15
T_OUT = B(30, 3.0)


def _window(t):
    p = in_out_cubic(prog(t, T_END, 0.5))
    a = panel_rect()
    return tuple(lerp(u, v, p) for u, v in zip(a, TERM)), p


def draw(c, t):
    (cx, cy, w, h), mp = _window(t)
    if t >= T0:
        K.soft_bg(c, C.INK, 0.03)
        K.grid_dots(c, t, C.PAPER, 0.04)
        K.headline(c, '一个 HTTP 请求，Agent 就能用上眼镜', '本机回环端口 · Bearer 鉴权 · 附带 Agent Skill', 110, 160,
                   t, T0 + 0.05, T_OUT, color=C.WHITE, sub_color=C.PAPER, size=54, sub_size=28, accent=C.BLUE)
    out = in_back(prog(t, T_OUT, 0.45), 1.4)
    # terminal window (morphs from the HUD panel)
    with Save(c):
        c.translate(cx, cy)
        sc = 1 - out
        c.scale(sc, sc)
        r = lerp(36, 22, mp)
        rrect_c(c, 0, 0, w, h, r, paint(mixc(C.INK2, TERM_BG, mp)))
        rrect_c(c, 0, 0, w, h, r, paint(mixc(C.HUD, C.BLUE, mp), lerp(0.18, 0.5, mp), stroke=2))
        if mp > 0.5:
            ta = clamp((mp - 0.5) * 2)
            for k, col in enumerate((C.CORAL, C.AMBER, C.MINT)):
                c.drawCircle(-w / 2 + 36 + k * 30, -h / 2 + 34, 9, paint(col, ta))
            T.text(c, 'zsh — agent', 0, -h / 2 + 42, 22, C.GRAY, ta, family=T.MONO, weight=400, align='center')
            c.drawLine(-w / 2, -h / 2 + 66, w / 2, -h / 2 + 66, paint(C.WHITE, 0.06 * ta, stroke=2))
        if t >= T0:
            x0, y0 = -w / 2 + 40, -h / 2 + 130
            t_line = T_TYPE
            for i, line in enumerate(CMD):
                k, done = T.typewriter(c, line, x0, y0 + i * 52, 27, t, t_line, cps=CPS, color=C.PAPER,
                                       cursor=(t < t_line + len(line) / CPS + 0.02) and t >= t_line,
                                       cursor_color=C.BLUE)
                t_line += len(line) / CPS
            rp = prog(t, T_RESP, 0.25)
            if rp > 0:
                T.text(c, 'HTTP/1.1 202 Accepted', x0, y0 + 3 * 52 + 30, 27, C.MINT, out_cubic(rp), family=T.MONO,
                       weight=700)
                T.text(c, '# 帧已写入，眼镜显示更新', x0, y0 + 4 * 52 + 30, 25, C.GRAY, out_cubic(prog(t, T_RESP + 0.2, 0.3)),
                       family=T.ZH, weight=500)
    if t < T0:
        return
    # glasses with HUD on the right
    gx, gy = 1490, 470
    gs = out_back(prog(t, T0 + 0.2, 0.5), 2.0) * (1 - out)
    if gs > 0:
        with Save(c):
            c.translate(gx, gy - 150)
            c.scale(gs, gs)
            c.drawPath(S.ic_glasses(0, 0, 1.15), paint(C.PAPER))
        with Save(c):
            c.translate(gx, gy + 40)
            c.scale(gs, gs)
            hw, hh = 560, 170
            rrect_c(c, 0, 0, hw, hh, 30, paint(C.INK2))
            rrect_c(c, 0, 0, hw, hh, 30, paint(C.HUD, 0.3, stroke=2))
            hp = prog(t, T_RESP + 0.05, 0.3)
            if hp > 0:
                fl = pulse(t, T_RESP + 0.05, 0.5)
                rrect_c(c, 0, 0, hw, hh, 30, paint(C.HUD, 0.18 * fl))
                with Save(c):
                    c.clipRect(skia.Rect.MakeLTRB(-hw / 2, -hh / 2, -hw / 2 + hw * out_cubic(hp), hh / 2),
                               skia.ClipOp.kIntersect, True)
                    K.glow_text(c, '你好，Agent', 0, 20, 56, C.HUD, 1.0, align='center', weight=600)
            else:
                for k in range(3):
                    c.drawCircle(-24 + 24 * k, 0, 6, paint(C.HUD, 0.3 + 0.3 * math.sin(t * 8 + k)))
    # request packet flying terminal → glasses
    fp = prog(t, T_RESP - 0.25, 0.3)
    if 0 < fp < 1:
        path = K.arc_path(TERM[0] + TERM[2] / 2 - 40, TERM[1] - 60, gx - 280, gy + 40, 160)
        pm = skia.PathMeasure(path, False, 1)
        pos, _ = pm.getPosTan(pm.getLength() * in_out_cubic(fp))
        rrect_c(c, pos.x(), pos.y(), 60, 26, 13, paint(C.BLUE))
    # endpoint ticker
    ta = clamp(prog(t, T0 + 0.6, 0.4)) * (1 - out)
    if ta > 0:
        x0, y0, hh = 1250, 700, 300
        with Save(c):
            c.clipRect(skia.Rect.MakeXYWH(x0 - 10, y0, 600, hh), skia.ClipOp.kIntersect, True)
            off = (t - T0) * 60
            for i in range(len(ENDPOINTS) * 2):
                y = y0 + 30 + i * 46 - off
                if y < y0 - 40 or y > y0 + hh + 40:
                    continue
                e = ENDPOINTS[i % len(ENDPOINTS)]
                fade = clamp(min(y - y0, y0 + hh - y) / 70)
                meth, path = e[:4], e[5:]
                T.text(c, meth, x0, y, 24, C.BLUE if meth.startswith('POST') else C.MINT, ta * fade, family=T.MONO,
                       weight=700)
                T.text(c, path, x0 + 90, y, 24, C.PAPER, ta * fade * 0.85, family=T.MONO, weight=400)
