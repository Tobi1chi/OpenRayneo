# Local video as a character animation

The **字符视频** desktop page imports a local movie and plays its image through the existing caption API. It is intended for experiments such as a low-resolution Bad Apple silhouette animation. No movie is bundled; choose a local file in the app.

## Use

1. Select **字符视频 → 选择视频…** and choose a movie supported by macOS AVFoundation, such as H.264 MP4. The prototype accepts up to ten minutes and decodes the video before playback. Import can be cancelled.
2. Choose **全角灰度 26×7** (default), **方块**, or **半格方块（实验）**, 5 or 10 updates per second, and optionally invert black/white or enhance per-frame contrast.
3. Select the paired glasses and press **从头播放到眼镜**. Playback starts a fresh caption session at font `1`, width `100`, and 7 lines, and requires a matching effective configuration from the glasses.
4. Press **结束显示** to exit. Switching to another display feature, disconnecting, or restarting the connection service also stops the player. Natural completion leaves the last sent frame visible. The preview and progress indicator show the transmitted frames.

Before playback, **检查字符对齐** sends a fresh seven-row ruler without requiring a video import. Compare the left and right `｜` markers across blocks, blank cells, full-width letters, digits, and punctuation. The second row is intentionally blank between its markers. The wearer has confirmed that the full-width grayscale mode displays and aligns correctly on the tested glasses; the ruler remains useful for checking other devices or firmware.

Playback is silent. The image fills the character canvas and may change the original aspect ratio. The complete video is decoded locally into small grayscale frames in memory, with no external decoder required.

## Rendering and scheduling

The source image is low-pass filtered with Lanczos before being reduced to 52×28 grayscale samples at up to 10 frames per second. Edge clamping prevents the filter from introducing dark borders outside the image. For full-width grayscale, a normalized 2×4 box convolution with stride 2×4 averages each character's region into a 26×7 grid. Brightness is preserved through this stage rather than thresholded to black/white.

`FullWidthBrightnessPalette` measures ink coverage with Core Text using PingFang SC Regular. Candidates are full-width forms `U+FF01`–`U+FF5E` and the ideographic space `U+3000`; missing glyphs and glyphs whose advance differs from that space are excluded. Coverage is normalized from blank to the densest glyph, and a cached 256-entry lookup chooses the nearest brightness. Inversion follows region averaging; optional contrast normalization precedes it. No ordinary ASCII spaces are emitted.

On 2026-10-01 the wearer reported that both half-width ASCII modes had misaligned right edges while block mode aligned correctly, so those options were replaced with the full-width palette. The former Menlo calibration only measured Mac glyph density; it neither selected a glasses font nor proved equal glyph advances there. The wearer subsequently confirmed on the same date that **full-width grayscale displays and aligns correctly on the tested glasses**. PingFang remains a reference font: exact optical brightness calibration and metrics on other firmware are still open, and the firmware font/spacing behavior has not been isolated. The current tested caption configuration has seven rows, so more gray levels do not increase vertical resolution.

Blocks average 2×4 samples into one `█` or `U+3000`, yielding 26×7 binary cells. Half blocks use separate upper/lower averages and `▀`, `▄`, `█`, or a blank for 26×14 pixels. Half-block glyphs remain experimental. The wearer reported braille mode unusable on 2026-10-01; it has been removed from the player rather than offered as a supported high-resolution mode, and the precise cause was not isolated.

The first frame has no leading compensation. **后续刷新时首行补一格** optionally prefixes later frames with one `U+3000` before the complete frame, not before each row. This remains an optional, separately testable workaround for font-`1` video layout.

Every request uses `final: true` for whole-frame replacement. Playback selects the latest decoded frame according to monotonic elapsed time, sends requests sequentially, and skips missed time slots rather than queuing a backlog. A slow transport therefore lowers the number of displayed frames instead of extending playback with catch-up. The configured rate limits requests; it is not a measurement of physical screen refresh. Playback errors stop transmission; reconnect and start again explicitly.

## Validation

Disposable generated video checks covered native decoding, 10 Hz sampling, top/bottom orientation, all three 26×7 character outputs, inversion, half-block geometry, Unicode braille dot mapping, and contrast normalization including uniform frames. A simulated caption endpoint exercised the actual desktop player with 180 ms responses: layout confirmation, whole-frame requests, dropping frames under backpressure, cancellation during playback, and absence of late frames after stopping passed. These checks used synthetic content. Braille was subsequently reported unusable, and half-width ASCII misaligned. The wearer later confirmed normal display and alignment of the replacement full-width grayscale mode; half-block rendering and the separate first-row compensation were not part of that confirmation.

The previous half-width ASCII implementation was checked for all 256 brightness inputs against measured glyph coverage, monotonic nearest-character selection, normalized box filtering on alternating black/white samples, pure-ASCII row widths at 26 and 52 columns, and preservation of a constant white source through low-pass filtering including its borders. The supplied Bad Apple MP4 was decoded into 2,191 frames for a local comparison; this is software rendering evidence, not glasses validation.

The full-width replacement passed disposable checks for 95 supported equal-advance reference glyphs, blank-space coverage, all 256 nearest-brightness mappings, 2×4 box averaging, inversion, 26×7 output dimensions, and the seven-row ruler. These automated checks verify the Mac renderer; the separate wearer confirmation above covers normal full-width grayscale display on the tested glasses. Aspect-ratio correction is still pending: the decoder fills 52×28 samples and does not preserve the source ratio.

## README preview

The README embeds `assets/bad-apple-character-preview.gif`: an eight-second, silent excerpt from 00:08–00:16 of the user-supplied Bad Apple!! shadow-art PV. It contains 80 frames at 10 fps, rendered with the current `TextVideo.load` decoder and `TextVideoFrame.text(style: .fullWidth, inverted: true)` path. Core Text draws the 26×7 output using the same PingFang reference font. Labels and margins are presentation only; the GIF is a Mac software preview, not a glasses recording, and does not prove the glasses' glyph metrics. The original video is not distributed with the app. The PV artwork remains the work of its respective creators and is not covered by this repository's source-code license.

## Reference project

The user suggested [bad-apple-lab/Bad-Apple](https://github.com/bad-apple-lab/Bad-Apple), inspected at commit `80e39ed58d754e4de420b7a1c474e53e20a71ba3` (MIT). Its [font generator](https://github.com/bad-apple-lab/Bad-Apple/blob/80e39ed58d754e4de420b7a1c474e53e20a71ba3/font/font.py) measures the upper/lower brightness of actual glyphs and builds a 256×256 lookup table. Its encoder combines two vertically adjacent grayscale samples per character, optionally normalizes frame contrast, and its preloader saves character frames for replay.

This informed OpenRayneo's independently implemented half-block renderer and optional contrast normalization; no upstream source or font lookup table was copied. The upstream Consolas calibration does not describe the glasses' font metrics, and its ANSI terminal cursor operations are not the glasses' caption protocol. OpenRayneo uses native AVFoundation decoding, in-memory grayscale frames, elapsed-time frame skipping, and complete caption replacements; it does not read the upstream `.badapple` preload format.
