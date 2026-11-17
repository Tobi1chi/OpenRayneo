# OpenRayneo 宣传动画

约 89 秒、105 BPM 的平面形变（flat morph）宣传片，画面、音乐、音效全部由代码生成。分镜与节拍表见 [STORYBOARD.md](STORYBOARD.md)。

## 流水线

| 环节 | 实现 |
| --- | --- |
| 画面 | Skia（skia-python）在 OpenGL 上做 GPU 光栅化（Apple Silicon 上由 Metal 承载），4× MSAA；快速转场用 F16 累积缓冲做子帧运动模糊 |
| 形变 | 路径按弧长重采样，用 FFT 互相关对齐轮廓起点后逐点插值；液态融合用模糊 + alpha 阈值（gooey）滤镜 |
| 音乐 | numpy / numba 合成器（polyBLEP 振荡器、TPT 滤波器、超锯齿、拨弦、FM 钟、鼓组），A 小调 F–G–Em–Am |
| 音效 | 克制的合成音效：只在场景转场（一口柔和的气流声，最响处对准画面运动峰值）和产品本身会发声的时刻（唤醒提示音、HUD 回复、通知、敲键、请求成功、同步完成）出声，铃音都在 A 小调音阶内 |
| 混音 | kick 触发的侧链、pedalboard 效果链、4× 过采样真峰值限制器，响度 −14 LUFS，母带真峰值 −2.0 dBTP（AAC 编码后约 −1.5） |
| 编码 | 原始 RGBA 经管道送入 ffmpeg，VideoToolbox 硬件编码（母版 HEVC，投稿版 H.264） |

## 重新生成

需要 macOS、ffmpeg（带 VideoToolbox）和 Python 3.12。

```bash
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

```bash
.venv/bin/python -m audio.mix
```

```bash
.venv/bin/python render.py --master
```

```bash
.venv/bin/python deliver.py
```

三步分别生成 `out/audio.wav`、`out/master_4k60.mov`（4K60 HEVC，码率上限设 90 Mb/s，实际约 20 Mb/s，亮度 PSNR 约 70 dB，接近无损）和两个投稿文件：

- `out/openrayneo_promo_2160p60.mp4`：4K60 H.264 High@5.2，平均约 10 Mb/s（B 站上限 20），AAC 320 kb/s
- `out/openrayneo_promo_1080p60.mp4`：1080P60 H.264 High@4.2，平均约 4 Mb/s（上限 6），AAC 320 kb/s

投稿版用 VideoToolbox 的恒定质量模式（`-q:v`）。它的平均码率模式在扁平动画上严重欠码（4K 目标 16 Mb/s 实际只给 4 Mb/s），画质反而更差。`deliver.py --probe` 会重新检查分辨率、帧率、关键帧间隔和平均码率。

调试画面：

```bash
.venv/bin/python render.py --preview --start 0 --end 16
```

```bash
.venv/bin/python render.py --sheet 0,19.5,16
```

## 目录

- `core.py` 节拍网格、缓动、配色；`shapes.py` 路径、图标与形变；`typo.py` 动态文字；`kit.py` 通用动效组件
- `scenes/` 12 个场景，`scenes/__init__.py` 定义时间区间、叠放顺序和运动模糊窗口
- `audio/` 合成器、编曲、音效对位与混音
- `render.py` GPU 渲染与硬件编码；`deliver.py` B 站投稿版封装与校验

OpenRayneo 为独立开源项目，与雷鸟官方无关；名称与商标归各自权利人。
