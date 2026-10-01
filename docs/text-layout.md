# Text layout experiments

Direct visual tests on the same RayNeo iO using `/v1/captions/start` and `/v1/captions/text`. These measurements describe the tested firmware, configuration, and strings; they are not a general terminal specification.

## Baseline configuration

The glasses acknowledged this temporary configuration:

```json
{"font_size":2,"content_width":100,"max_lines":5,"position":"center","is_display":true,"straight_view":"original"}
```

Text updates used `final: false` (the default) and embedded newline characters where explicitly shown. The protocol does not expose a font-family selector in the implemented API.

| Test string | User-observed result |
| --- | --- |
| `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz` | Two rows; first row ends at lowercase `e`, i.e. 41 characters from this specific string |
| `一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥` | Two rows; first row ends at `子`, i.e. 21 Chinese characters |

These are automatic-wrap measurements without explicit newlines. Do not treat 41 as a guaranteed capacity for every ASCII string. Subsequent video testing on 2026-10-01 found misaligned right edges in both half-width ASCII modes while block mode aligned correctly. A separate `0`/`i`/`W` comparison established a common left edge, but the right-edge observation was not resolved, so this test does not establish a monospaced half-width Latin font.

## Blank characters

Five explicit rows compared the position of `B` after `A` plus a reference or blank run:

| Row | Run between `A` and `B` | Result |
| --- | --- | --- |
| `0` | Four ASCII zeroes | Width reference |
| `1` | Four ordinary spaces, `U+0020` | Not identified as matching the reference |
| `2` | Four no-break spaces, `U+00A0` | Not identified as matching the reference |
| `3` | Four figure spaces, `U+2007` | Not identified as matching the reference |
| `4` | Two ideographic/full-width spaces, `U+3000` | User identified this row as aligned with the reference |

Thus two `U+3000` spaces can replace the tested four-digit run while preserving the next field's position. The following full-panel test confirmed that full-width spaces work as blank cells. The result does not establish other space-to-digit ratios, whether unsupported glyphs appeared in the other rows, or a complete Unicode width table.

Zero-width spaces, word joiners, and blank Braille glyphs were not device-validated in this sequence. A zero-width character is not a general way to reserve a column. A supported blank glyph provides unpainted space within the label; it does not add a pixel-level alpha or overlay API.

## Fixed grids that worked

A **20-column × 5-row** panel was visibly confirmed: all five rows appeared, its borders aligned, and there was no wrapping or missing-glyph box. Each row had exactly 20 full-width cells. The panel stays one CJK character below the measured 21-character wrap limit.

That panel was a conservative starting point, not the maximum. Subsequent tests expanded the grid:

| Requested configuration | Firmware effective configuration | Visual observation |
| --- | --- | --- |
| Font `2`, width `100`, 8 rows | Font `2`, width `100`, 6 rows | All six numbered rows of 20 full-width cells visible |
| Font `1`, width `120`, 12 rows | Font `1`, width `100`, 7 rows | Initial blank screen was caused by manually exiting the caption page; it was not a font failure |
| Font `1`, width `100`, 12 rows | Font `1`, width `100`, 7 rows | Full-width ruler wraps after `Ｐ`, then `ｐ`: 26 cells per row; **26×7** numbered grid fully visible, aligned, without wrapping |
| Font `0`, width `100`, 16 rows | Font `1`, width `100`, 7 rows | Configuration clamp confirmed by reply; no larger grid obtained |

For this tested caption configuration, **26 full-width columns × 7 rows** is the largest visually verified grid. The API returns the firmware's `effective_config`; callers must use it rather than assume requested dimensions were accepted. These probes establish observed clamps, not the physical display resolution or limits of other display modes. `font_size` and `content_width` are protocol values with no established pixel units.

A subsequent [official APK layout audit](apk-display-layout.md) found subtitle position/spatial controls and a separate teleprompter layout path with text-size and line-spacing settings. It did not establish a way to bypass the caption seven-line clamp. Teleprompter capacity and suitability for frequent TUI updates remain untested.

If the wearer exits the caption page, text writes can still succeed while nothing is shown. Stop and restart the display session before interpreting a blank screen as a layout failure.

Generate the panel as fixed-width ASCII first, then map printable ASCII `!`–`~` to their full-width Unicode forms by adding `0xFEE0` to each code point. Map ordinary spaces to `U+3000`, and join rows with `\n`. This is a useful rendering subset, not a rule for calculating arbitrary Unicode/emoji widths.

The tested logical rows, before that conversion, were:

```text
+------------------+
|M1 [####----] 67% |
|M2 [##------] 25% |
|REC 00:12 CPU 08% |
+------------------+
```

The percentages, time, and recording label in this first panel were synthetic layout data, not live microphone or CPU readings. Its actual on-wire text uses full-width letters, numbers, punctuation, and spaces.

An application can construct rows this way (pad the inside to 18 characters, then add the two borders):

```python
def fullwidth_row(content):
    if len(content) > 18:
        raise ValueError("Content exceeds the tested row width")
    row = "|" + content.ljust(18) + "|"
    return "".join(
        "\u3000" if c == " " else chr(ord(c) + 0xFEE0)
        for c in row
    )
```

This example accepts printable ASCII content only. Send the resulting five-row string to `/v1/captions/text` after starting the baseline caption configuration. The existing API is sufficient; no new terminal endpoint is required.

## Refresh mechanism and limits

A refresh test sent 40 complete panel frames over 20 seconds (target 2 updates/second), changing simulated bars, a counter, and a moving marker. All requests returned `202`. The user confirmed stable borders, correct clearing of the marker's previous position, and no noticeable flicker. This is a visual functional check, not a measured latency or maximum-refresh benchmark.

### Larger-grid rate tests

The next sweep used the visually verified **26×7** grid at font setting `1`. Every update replaced the entire panel, including a frame counter and a moving marker. Requests were sequential; missed schedule slots were skipped rather than queued for a burst. Each initial rate ran for 8 seconds, followed by a static `END` frame and a 2-second hold.

| Target updates/s | Completed writes/s | Frames written | Missed schedule slots | Longest request, ms |
| --- | --- | --- | --- | --- |
| 5 | 5.00 | 40 | 0 | 6.1 |
| 10 | 9.99 | 80 | 0 | 5.4 |
| 20 | 20.00 | 160 | 0 | 2.4 |
| 30 | 29.99 | 240 | 0 | 5.9 |
| 60 | 59.49 | 476 | 4 | 84.8 |
| 120 | 117.23 | 938 | 22 | 192.1 |

The wearer reported stable borders and prompt stopping throughout the initial 5/10/20 Hz sweep. The 30/60/120 Hz sweep produced stuttering or catch-up; the wearer confirmed it eventually stopped. Testing higher rates was therefore stopped, and lower rates were tested individually:

| Target updates/s | Duration | Completed writes/s | Frames / missed slots | Wearer observation |
| --- | --- | --- | --- | --- |
| 30 | 10 s | 29.99 | 300 / 0 | Stuttering or catch-up |
| 25 | 10 s | 24.99 | 250 / 0 | Slightly odd, difficult to judge; inconclusive |
| 20 | 20 s | 19.99 | 400 / 0 | Animation was not consistently smooth; the earlier short pass does not establish a stable 20 Hz limit |
| 10 | 20 s | 10.00 | 200 / 0 | Tentatively normal; wearer requested a richer animation for easier comparison |

The marker moved in whole character cells at about 12 cells/s and wrapped back to the start of the row. This introduces visible discrete motion and a periodic jump independently of transmission lag. The test did not measure which individual frames the firmware displayed or where any delay occurred.

At the wearer's request, a richer pattern replaced the counter/marker: two bouncing characters with trails, a moving wave, and two expanding/contracting bars. It used the same 26×7 grid, movement speeds driven by elapsed time, and a final frozen `STOP` panel. This made comparison easier without requiring the wearer to time or count updates.

| Target updates/s | Duration | Frames / missed slots | Wearer observation |
| --- | --- | --- | --- |
| 10 | 15 s | 150 / 0 | Motion normal; all movement stopped with `STOP` |
| 20 | 15 s | 300 / 0 | Normal; all movement stopped with `STOP` |
| 30 | 15 s | 450 / 0 | Wearer described inconsistent animation speed; the sinusoidal bar animation itself deliberately changes speed, so this is inconclusive |

The richer pattern's 20 Hz result means that the earlier single-marker report alone does not establish a queueing or display-throughput boundary at 20 Hz. Preserve both observations rather than treating subjective animation smoothness as an exact refresh measurement. The sinusoidal bars are also unsuitable for judging constant playback speed; a subsequent pattern replaced them with linear ramps and opposing character conveyors.

The final constant-speed pattern ran at **30 updates/s for 20 seconds**, completing all **600** scheduled writes (29.99 writes/s, no missed slots, longest request 6.7 ms). The wearer reported that motion was basically uniform and stopped with `STOP`. The conveyors advanced at 8 cells/s and the bars at 4 cells/s, so many transmitted frames contained identical visible content. This confirms usable motion and stopping in this test, not 30 distinct rendered frames/s.

**Daily-use decision: target 5–10 whole-panel updates/s.** The wearer ended further stress testing after the constant-speed 30 Hz pass. That pass supersedes interpreting the earlier subjective 30 Hz complaint as a demonstrated hard throughput boundary, while the mixed high-rate sweep remains insufficient to identify the exact failing rate. No runtime refresh limiter or TUI renderer was added by these experiments; this is the agreed target for future clients.

These numbers measure completed HTTP/bridge writes, **not displayed frames per second**. There is no per-frame rendering acknowledgment. Visual reports establish usability for these short runs; precisely measuring display cadence or end-to-end latency requires an independently timed recording of the glasses display. The transport's maximum throughput was not established, because visible problems occurred before writes failed.

The client must maintain its own grid, replace cleared cells with full-width spaces, and resend the entire string. This experiment does not establish ANSI escape handling, cursor-position commands, partial-screen updates, color support, arbitrary font selection, or a shell/PTY connection. Other firmware and content require separate tests.
