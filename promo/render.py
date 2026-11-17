"""GPU renderer: Skia on an OpenGL (Metal-backed) context, piped into VideoToolbox.

Examples
  python render.py --stills 3.2,8.9 --scale 0.5          # PNG stills into out/stills
  python render.py --preview --start 0 --end 16           # 960x540@30 quick preview
  python render.py --master                               # 4K60 HEVC master (hardware)
"""
import argparse
import os
import queue
import subprocess
import sys
import threading
import time

import glfw
import numpy as np
import skia

import core
from core import W, H, FPS, DURATION

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')


class GPU:
    def __init__(self, scale):
        if not glfw.init():
            raise RuntimeError('glfw init failed')
        glfw.window_hint(glfw.VISIBLE, glfw.FALSE)
        glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 4)
        glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 1)
        glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        glfw.window_hint(glfw.OPENGL_FORWARD_COMPAT, True)
        self.win = glfw.create_window(16, 16, 'render', None, None)
        glfw.make_context_current(self.win)
        self.ctx = skia.GrDirectContext.MakeGL()
        self.scale = scale
        self.w, self.h = int(round(W * scale)), int(round(H * scale))
        self.info = skia.ImageInfo.Make(self.w, self.h, skia.kRGBA_8888_ColorType, skia.kPremul_AlphaType)
        self.surf = skia.Surface.MakeRenderTarget(self.ctx, skia.Budgeted.kNo, self.info, 4)
        acc_info = skia.ImageInfo.Make(self.w, self.h, skia.kRGBA_F16_ColorType, skia.kPremul_AlphaType)
        self.acc = skia.Surface.MakeRenderTarget(self.ctx, skia.Budgeted.kNo, acc_info, 0)
        if self.surf is None or self.acc is None:
            raise RuntimeError('could not create GPU surfaces')

    def draw(self, t, samples=1, shutter=0.5):
        import scenes
        if samples <= 1:
            c = self.surf.getCanvas()
            c.save()
            c.scale(self.scale, self.scale)
            scenes.draw_frame(c, t)
            c.restore()
            self.surf.flushAndSubmit()
            return self.surf
        acc = self.acc.getCanvas()
        for k in range(samples):
            ts = t + ((k + 0.5) / samples - 0.5) * shutter / FPS
            c = self.surf.getCanvas()
            c.save()
            c.scale(self.scale, self.scale)
            scenes.draw_frame(c, ts)
            c.restore()
            img = self.surf.makeImageSnapshot()
            p = skia.Paint()
            p.setAlphaf(1.0 / (k + 1))
            p.setBlendMode(skia.BlendMode.kSrcOver)
            acc.drawImage(img, 0, 0, skia.SamplingOptions(), p)
        self.acc.flushAndSubmit()
        return self.acc

    def read(self, surf, buf):
        surf.readPixels(self.info, buf, self.w * 4)
        return buf


def ffmpeg_cmd(w, h, fps, path, kind):
    base = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{w}x{h}', '-r', str(fps), '-i', '-',
            '-vf', 'scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p',
            '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']
    if kind == 'master':
        enc = ['-c:v', 'hevc_videotoolbox', '-tag:v', 'hvc1', '-profile:v', 'main', '-b:v', '90M',
               '-g', str(fps * 2)]
    else:
        enc = ['-c:v', 'h264_videotoolbox', '-profile:v', 'high', '-b:v', '12M', '-g', str(fps * 2)]
    return base + enc + [path]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stills', type=str, default='')
    ap.add_argument('--scale', type=float, default=None)
    ap.add_argument('--preview', action='store_true')
    ap.add_argument('--master', action='store_true')
    ap.add_argument('--start', type=float, default=0.0)
    ap.add_argument('--end', type=float, default=DURATION)
    ap.add_argument('--fps', type=int, default=None)
    ap.add_argument('--out', type=str, default=None)
    ap.add_argument('--mb', type=int, default=None, help='force motion-blur samples')
    ap.add_argument('--sheet', type=str, default='', help='contact sheet: start,end,count')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    import scenes

    if a.stills or a.sheet:
        scale = a.scale or 0.5
        gpu = GPU(scale)
        os.makedirs(os.path.join(OUT, 'stills'), exist_ok=True)
        ts = [float(x) for x in a.stills.split(',') if x.strip()]
        if a.sheet:
            s0, s1, n = a.sheet.split(',')
            ts = list(np.linspace(float(s0), float(s1), int(n)))
        imgs = []
        for t in ts:
            surf = gpu.draw(t, a.mb or 1)
            img = surf.makeImageSnapshot()
            if a.sheet:
                imgs.append(img)
            else:
                img.save(os.path.join(OUT, 'stills', f't{t:06.2f}.png'))
        if a.sheet:
            cols = 4
            rows = (len(imgs) + cols - 1) // cols
            tw, th = gpu.w // 2, gpu.h // 2
            sheet = skia.Surface(tw * cols, th * rows)
            sc = sheet.getCanvas()
            sc.clear(skia.ColorBLACK)
            f = skia.Font(skia.Typeface('Menlo'), 14)
            for i, (img, t) in enumerate(zip(imgs, ts)):
                x, y = (i % cols) * tw, (i // cols) * th
                sc.drawImageRect(img, skia.Rect.MakeXYWH(x, y, tw - 2, th - 2),
                                 skia.SamplingOptions(skia.FilterMode.kLinear))
                sc.drawString(f'{t:.2f}', x + 6, y + 18, f, skia.Paint(Color=skia.ColorYELLOW))
            path = a.out or os.path.join(OUT, 'stills', f'sheet_{s0}_{s1}.png')
            sheet.makeImageSnapshot().save(path)
            print(path)
        return

    if a.master:
        scale, fps, kind = a.scale or 2.0, a.fps or 60, 'master'
        path = a.out or os.path.join(OUT, 'master_4k60.mov')
    else:
        scale, fps, kind = a.scale or 0.5, a.fps or 30, 'preview'
        path = a.out or os.path.join(OUT, f'preview_{a.start:g}_{a.end:g}.mp4')
    gpu = GPU(scale)
    proc = subprocess.Popen(ffmpeg_cmd(gpu.w, gpu.h, fps, path, kind), stdin=subprocess.PIPE)
    q = queue.Queue(maxsize=3)
    pool = [np.empty((gpu.h, gpu.w, 4), np.uint8) for _ in range(5)]
    free = queue.Queue()
    for b in pool:
        free.put(b)

    def writer():
        while True:
            b = q.get()
            if b is None:
                break
            proc.stdin.write(memoryview(b))
            free.put(b)

    th = threading.Thread(target=writer, daemon=True)
    th.start()
    n0 = int(round(a.start * fps))
    n1 = int(round(a.end * fps))
    t_start = time.time()
    for n in range(n0, n1):
        t = n / fps
        samples = a.mb if a.mb is not None else scenes.motion_blur_samples(t)
        surf = gpu.draw(t, samples)
        buf = free.get()
        gpu.read(surf, buf)
        q.put(buf)
        if (n - n0) % (fps * 2) == 0:
            el = time.time() - t_start
            done = n - n0 + 1
            eta = el / done * (n1 - n0 - done)
            print(f'\r frame {done}/{n1 - n0}  t={t:6.2f}s  {el / done * 1000:5.1f} ms/f  eta {eta:5.0f}s',
                  end='', flush=True)
    q.put(None)
    th.join()
    proc.stdin.close()
    proc.wait()
    print(f'\n wrote {path} in {time.time() - t_start:.1f}s')


if __name__ == '__main__':
    main()
