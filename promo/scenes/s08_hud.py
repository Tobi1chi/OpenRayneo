"""Bars 25–28: what the glasses can display — captions, teleprompter, notifications, 26×7 text video."""
import math
import numpy as np
import skia

from core import *
import shapes as S
import typo as T
import kit as K

T0 = B(25)
PX, PY, PW, PH = CX, 650, 1240, 520
TABS = ['字幕', '提词', '通知', '字符视频']
TAB_T = [B(25), B(26), B(27), B(28)]
T_END = B(28, 3.2)


def panel_rect():
    return PX, PY, PW, PH


# ---------------------------------------------------------------- 26×7 text video source
PALETTE = '　．：－＝＋＊＃％＠'
_SRC = None


def _source():
    """Grayscale strip: OR logo + 'OPENRAYNEO' at 28 sample rows."""
    global _SRC
    if _SRC is not None:
        return _SRC
    h = 28
    w = 520
    surf = skia.Surface(w, h)
    c = surf.getCanvas()
    c.clear(skia.ColorBLACK)
    O, R, pill = S.logo_parts(0, 0, 1.0)
    with Save(c):
        c.translate(26, 14)
        c.scale(12.5 / 144, 12.5 / 144)
        c.drawPath(O, skia.Paint(AntiAlias=True, Color=skia.ColorWHITE))
        c.drawPath(R, skia.Paint(AntiAlias=True, Color=skia.ColorWHITE))
        c.drawPath(pill, skia.Paint(AntiAlias=True, Color=skia.Color(150, 150, 150)))
    f = skia.Font(S.typeface('Avenir Next', 800), 30)
    c.drawString('OPENRAYNEO', 74, 25, f, skia.Paint(AntiAlias=True, Color=skia.ColorWHITE))
    arr = surf.makeImageSnapshot().toarray()[..., 0].astype(np.float32) / 255.0
    _SRC = arr
    return arr


def _grid(t):
    src = _source()
    w = src.shape[1]
    off = int((t * 64) % w)
    cols = [(off + i) % w for i in range(52)]
    win = src[:, cols]                         # 28 × 52
    g = win.reshape(7, 4, 26, 2).mean(axis=(1, 3))
    idx = np.clip((g * (len(PALETTE) - 1) + 0.5).astype(int), 0, len(PALETTE) - 1)
    return [''.join(PALETTE[k] for k in row) for row in idx]


def _tabs(c, t, a):
    widths = [T.width(s, 30) + 60 for s in TABS]
    gap = 18
    x0 = CX - (sum(widths) + gap * 3) / 2
    xs = []
    x = x0
    for wd in widths:
        xs.append(x + wd / 2)
        x += wd + gap
    # active index with smooth slide
    f = 0.0
    for k in range(1, 4):
        f += in_out_cubic(prog(t, TAB_T[k] - 0.15, 0.3))
    k0 = min(int(f), 3)
    k1 = min(k0 + 1, 3)
    u = f - k0
    hx = lerp(xs[k0], xs[k1], u)
    hw = lerp(widths[k0], widths[k1], u) * (1 + 0.25 * math.sin(u * math.pi))
    s = out_back(prog(t, T0 + 0.2, 0.5), 1.6)
    with Save(c):
        c.translate(CX, 318)
        c.scale(s, s)
        c.translate(-CX, -318)
        rrect_c(c, CX, 318, sum(widths) + gap * 3 + 24, 74, 37, paint(C.INK2, a))
        rrect_c(c, hx, 318, hw, 58, 29, paint(C.HUD, a))
        for i, (lab, x) in enumerate(zip(TABS, xs)):
            on = 1 - min(1, abs(f - i))
            T.text(c, lab, x, 329, 30, mixc(C.PAPER, C.INK, on), a, align='center')


def _captions(c, t, x0, y0, a):
    lines = [(B(25, 0.5), '大家好，这里是 OpenRayneo'), (B(25, 2.0), '它把眼镜的官方能力开放给本机 Agent'),
             (B(25, 3.3), '字幕按整行替换刷新')]
    for i, (ts, s) in enumerate(lines):
        te = lines[i + 1][0] if i + 1 < len(lines) else 1e9
        if t < ts or t >= te:
            continue
        wipe = out_cubic(prog(t, ts, 0.3))
        fl = pulse(t, ts, 0.35)
        w = T.width(s, 52, weight=600)
        with Save(c):
            c.clipRect(skia.Rect.MakeLTRB(CX - w / 2 - 20, y0 - 60, CX - w / 2 - 20 + (w + 40) * wipe, y0 + 80),
                       skia.ClipOp.kIntersect, True)
            K.glow_text(c, s, CX, y0 + 30, 52, C.HUD, a, align='center', weight=600)
        if 0 < wipe < 1:
            x = CX - w / 2 - 20 + (w + 40) * wipe
            rrect_c(c, x, y0 + 12, 8, 76, 4, paint(C.HUD, a * 0.9))
        if fl > 0:
            rrect_c(c, CX, y0 + 12, w + 80, 110, 20, paint(C.HUD, 0.08 * fl * a))
    K.wave_bars(c, CX - 220, CX + 220, y0 + 150, t, C.HUD, n=28, hmax=40, a=a * 0.5, seed=8)
    T.text(c, '实时字幕 · 整行替换', x0 + PW - 60, y0 + PH / 2 - 40, 22, C.HUD, a * 0.55, weight=500, align='right')


def _prompter(c, t, x0, y0, a):
    lines = ['今天演示三个能力', '原生助手接入本机 Agent', '全天智记自动转写总结', '本机 API 一行命令调用',
             '欢迎来 GitHub 点个 Star']
    sc = (t - TAB_T[1]) * 1.6
    with Save(c):
        c.clipRect(skia.Rect.MakeXYWH(x0 + 40, y0 - PH / 2 + 50, PW - 80, PH - 100), skia.ClipOp.kIntersect, True)
        for i, s in enumerate(lines):
            y = y0 + (i - sc) * 92
            d = abs(i - sc)
            al = clamp(1 - d * 0.55) * a
            if al <= 0:
                continue
            K.glow_text(c, s, CX, y + 20, 48 if d < 0.5 else 42, C.HUD, max(0.2 * a, al), align='center',
                        weight=600 if d < 0.5 else 500, glow=8)
    c.drawPath(S.poly([(x0 + 70, y0 - 16), (x0 + 96, y0), (x0 + 70, y0 + 16)]), paint(C.HUD, a))
    T.text(c, '提词器 · 暂停 / 继续 / 停止', x0 + PW - 60, y0 + PH / 2 - 40, 22, C.HUD, a * 0.55, weight=500,
           align='right')


def _notify(c, t, x0, y0, a):
    for k, (ts, title, body, icon) in enumerate(((B(27, 0.25), '日程提醒', '15:00 与导师讨论同步协议', S.ic_calendar),
                                                (B(27, 1.5), '新通知', 'Agent：今日总结已生成', S.ic_bell))):
        p = out_back(prog(t, ts, 0.5), 1.4)
        if p <= 0:
            continue
        push = out_cubic(prog(t, B(27, 1.5), 0.4)) if k == 0 else 0.0
        y = y0 - 70 + (1 - p) * -160 + push * 150
        al = a * clamp(p * 3) * (1 - 0.5 * push)
        w, h = 860, 140
        rrect_c(c, CX, y, w, h, 28, paint(C.HUD, 0.1 * al))
        rrect_c(c, CX, y, w, h, 28, paint(C.HUD, 0.6 * al, stroke=3))
        c.drawPath(icon(CX - w / 2 + 76, y, 0.75), paint(C.HUD, al))
        K.glow_text(c, title, CX - w / 2 + 140, y - 12, 34, C.HUD, al, weight=600, glow=6)
        K.glow_text(c, body, CX - w / 2 + 140, y + 38, 30, C.HUD, al * 0.85, weight=500, glow=6)
    T.text(c, '通知卡片 · 本机 API 推送', x0 + PW - 60, y0 + PH / 2 - 40, 22, C.HUD, a * 0.55, weight=500,
           align='right')


def _textvideo(c, t, x0, y0, a):
    rows = _grid(t - TAB_T[3])
    f = T.font(44, T.ZH, 500)
    cw = 44
    gx = CX - cw * 13
    gy = y0 - 3 * 60 + 16
    for j, row in enumerate(rows):
        y = gy + j * 60
        c.drawString(row, gx, y, f, paint(C.HUD, a * 0.5, blur=8))
        c.drawString(row, gx, y, f, paint(C.HUD, a))
    T.text(c, '26×7 全角灰度字符视频', x0 + PW - 92, y0 + PH / 2 - 26, 22, C.HUD, a * 0.55, weight=500,
           align='right')


def draw(c, t):
    rp = prog(t, B(24, 2.8), 0.6)
    if rp < 1:
        K.circle_reveal_clip(c, 860, 600, lerp(0, 2200, in_out_cubic(rp)))
    K.soft_bg(c, C.INK, 0.03)
    K.grid_dots(c, t, C.PAPER, 0.04)
    out = in_cubic(prog(t, T_END, 0.35))
    K.headline(c, '眼镜上的显示', '字幕 · 提词 · 通知 · 字符视频，全部走官方显示通道', 110, 160, t, T0 + 0.1, T_END,
               color=C.WHITE, sub_color=C.PAPER, size=58, sub_size=28, accent=C.HUD)
    _tabs(c, t, 1 - out)
    if t >= T_END + 0.05:
        return  # the terminal window of the next scene takes the panel over
    K.hud_panel(c, PX - PW / 2, PY - PH / 2, PW, PH, t, T0 + 0.3)
    x0, y0 = PX - PW / 2, PY
    with Save(c):
        c.clipRect(skia.Rect.MakeXYWH(PX - PW / 2, PY - PH / 2, PW, PH), skia.ClipOp.kIntersect, True)
        for k, fn in enumerate((_captions, _prompter, _notify, _textvideo)):
            ta = TAB_T[k]
            tb = TAB_T[k + 1] if k < 3 else T_END + 0.2
            a = clamp(prog(t, ta - 0.05, 0.2)) * (1 - clamp(prog(t, tb - 0.15, 0.15)))
            if a > 0:
                fn(c, t, x0, y0, a)
