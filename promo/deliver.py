"""Bilibili deliverables from the 4K60 master + mastered audio, all hardware encoded (VideoToolbox).

python deliver.py        → out/openrayneo_promo_2160p60.mp4  (H.264 High@5.2, avg ≤ 20 Mb/s, AAC 320k)
                           out/openrayneo_promo_1080p60.mp4  (H.264 High@4.2, avg ≤ 6 Mb/s,  AAC 320k)
python deliver.py --probe  → only re-check the two files

VideoToolbox's average-bitrate mode badly undershoots on flat animation (≈4 Mb/s at 4K for a 16M target),
and it ignores -maxrate once -q:v is set, so the files use constant quality with a level chosen so the
overall bitrate (what Bilibili's upload limits refer to) stays under the cap; probe() checks that and also
reports the busiest 1-second window for reference.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
MASTER = os.path.join(OUT, 'master_4k60.mov')
AUDIO = os.path.join(OUT, 'audio.wav')

COLOR = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']
AUDIO_ENC = ['-c:a', 'aac_at', '-aac_at_mode', 'cbr', '-b:a', '320k', '-ar', '48000', '-ac', '2']

TARGETS = [
    # name, scale filter, VideoToolbox quality (1–100), H.264 level, overall video bitrate cap Mb/s
    ('openrayneo_promo_2160p60.mp4', None, 80, '5.2', 20.0),
    ('openrayneo_promo_1080p60.mp4', 'scale=1920:1080:flags=lanczos+accurate_rnd+full_chroma_int', 76, '4.2', 6.0),
]


def encode(name, vf, q, level, cap):
    path = os.path.join(OUT, name)
    filt = (vf + ',' if vf else '') + 'format=yuv420p'
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-stats', '-y',
           '-hwaccel', 'videotoolbox', '-i', MASTER, '-i', AUDIO,
           '-map', '0:v:0', '-map', '1:a:0', '-vf', filt,
           '-c:v', 'h264_videotoolbox', '-profile:v', 'high', '-level', level, '-coder', 'cabac',
           '-q:v', str(q), '-prio_speed', '0',
           '-g', '120', '-keyint_min', '120', '-r', '60', *COLOR, *AUDIO_ENC,
           '-shortest', '-movflags', '+faststart', '-metadata', 'title=OpenRayneo', path]
    print(' encoding', name)
    subprocess.run(cmd, check=True)
    return path


def probe(path, cap):
    info = json.loads(subprocess.check_output(
        ['ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', path]))
    v = next(s for s in info['streams'] if s['codec_type'] == 'video')
    a = next(s for s in info['streams'] if s['codec_type'] == 'audio')
    fmt = info['format']
    keys = subprocess.check_output(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-skip_frame', 'nokey', '-show_entries',
         'frame=pts_time', '-of', 'csv=p=0', path]).decode().split()
    kt = [float(x.strip(',')) for x in keys if x.strip(',').strip()]
    gaps = [b - a for a, b in zip(kt, kt[1:])]
    per_s = {}
    for line in subprocess.check_output(
            ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,size', '-of',
             'csv=p=0', path]).decode().split():
        f = [x for x in line.split(',') if x]
        per_s[int(float(f[0]))] = per_s.get(int(float(f[0])), 0) + int(f[1])
    peak = max(per_s.values()) * 8 / 1e6
    print(f"  {os.path.basename(path)}: {v['width']}x{v['height']} {v['codec_name']} {v.get('profile')} "
          f"L{v.get('level')} {v['pix_fmt']} {v.get('color_space')} | {eval(v['r_frame_rate']):.2f} fps | "
          f"video {int(v.get('bit_rate', 0)) / 1e6:.2f} Mb/s | total {int(fmt['bit_rate']) / 1e6:.2f} Mb/s | "
          f"{a['codec_name']} {int(a.get('bit_rate', 0)) // 1000}k {a['sample_rate']} Hz | "
          f"{float(fmt['duration']):.2f}s | {os.path.getsize(path) / 2**20:.1f} MiB | "
          f"keyframes {len(kt)}, max gap {max(gaps) if gaps else 0:.2f}s | "
          f"busiest 1 s {peak:.2f} Mb/s")
    vbr = int(v.get('bit_rate', 0)) / 1e6
    print(f"  overall video bitrate {vbr:.2f} Mb/s: {'OK' if vbr <= cap else 'OVER'} (cap {cap:g} Mb/s)")


def main():
    for p in (MASTER, AUDIO):
        if not os.path.exists(p):
            sys.exit(f'missing {p}: run render.py --master and python -m audio.mix first')
    for t in TARGETS:
        path = os.path.join(OUT, t[0]) if '--probe' in sys.argv else encode(*t)
        probe(path, t[4])


if __name__ == '__main__':
    main()
