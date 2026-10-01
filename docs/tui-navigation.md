# Navigation with a character grid

This is a design experiment based on the [measured caption grids](text-layout.md). The current navigation design targets **20 columns × 5 rows**, fitting the previously tested font-`2` layout. Glasses tests confirmed block glyph rendering, whole-frame replacement with `final: true`, and a one-space prefix workaround for first-row alignment. No navigation-provider integration was performed. All distances and maneuvers are synthetic.

## Useful graphic primitives

| Graphic | Character approach | Navigation use |
| --- | --- | --- |
| Large directional symbol | Multiple rows of full-width `#`, or `+`, `-`, `|`, `<`, `>`, `^`, `v` | Left, right, straight, U-turn |
| Junction / route outline | Horizontal and vertical lines, marked route cells and a current-position label | Schematic of the next maneuver |
| Lane indication | Repeated arrows with a bracketed selected lane | Guidance when actual lane data is available |
| Meter / progress | Fixed-width brackets filled with `#`, cleared with full-width spaces | Distance approaching the next maneuver |
| Border / divider | `+`, `-`, `|` | Separate regions, though borders consume scarce cells |
| Sparkline / stepped path | `_`, `/`, `\`, `-` | Small trends or simplified path shapes |
| Marker / compass | Letters or a character marker such as `@` | Heading or a selected point, with an explicit orientation convention |

These use the previously tested **full-width ASCII plus `U+3000` padding strategy**, not a claim that every new character or arrangement has already been device-tested. A full-width grid cell is not a solid pixel: font glyphs have margins and strokes, and `#` tiles do not form a continuous filled polygon.

Unicode box drawing (`┌─┐`), arrows (`←↑→↓`), half-block elements (`▀▄`), and shading could draw cleaner or finer shapes, but their glyph availability, advance width, and alignment remain unverified. The solid `█` used below has been device-tested. Later video testing reported Braille unusable; see [the video limitations](text-video.md). A theoretical 2×4 dot pattern per Braille cell does not establish a usable 52×28 display.

## Current minimal layout

The design shows only a maneuver arrow on the left, distance on the right, and a two-character action below the distance. At distance zero, `现在` replaces the distance. Left, right, straight, and U-turn states share the same layout.

The current medium-weight revision uses `█` block characters with one-cell-wide shafts in a 7×5 logical arrow area, between the original thin character strokes and the subsequent two-cell-wide block design. The overall logical frame stays 20×5. A device ruler confirmed that four `█` characters occupy the same advance as four `U+3000` spaces at font `2`. This establishes the tested run's width, not every Unicode glyph's metrics. Text uses weight `500` in the browser preview. The current caption API does not expose a font-weight parameter, so browser styling is not a demonstrated device capability.

Road name, travel time, remaining route, next instruction, progress bar, junction diagram, and lane information are omitted from this default view. The user preferred less information after reviewing the initial 26×7 concepts. This is a readability decision, not a revision of the measured 26×7 capacity.

The preview fixes each character to one browser cell. Its font, color, cell aspect ratio, and spacing are illustrative and do not reproduce the optical display. Controls change the simulated maneuver and distance; no live route or automatic animation is active.

## Whole-frame display test

At font `2`, width `100`, and 5 lines, an initial `100米 / 掉头` frame sent with the default `final: false` appeared progressively, although the bridge sent all five lines in one text request. Sending `80米 / 右转` with **`final: true`** made the whole display appear together, according to the wearer.

Two more `final: true` frames, `50米 / 直行` and `20米 / 左转`, were sent three seconds apart. The wearer confirmed whole-frame replacement and clearing of the previous contents, while reporting an alignment problem in the first row. Thus final marking addresses the observed progressive appearance. This does not establish hidden-history behavior or a high-rate rendering limit.

For these complete navigation frames, use `POST /v1/captions/text` with `{"text":"<complete padded frame>","final":true}`. There is no need to change the caption API's default for streaming speech clients. The underlying protocol maps this to message type `5`, mode `3`, and status `1`.

## First-row alignment workaround

A diagnostic frame placed the same full-width `｜` at column zero of all five rows. Every transmitted row contained 20 characters and no leading whitespace. The wearer reported that the first row's `｜` disappeared and that the row shifted left by one full-width cell; the other rows retained their markers. This is an observed rendering effect, not proof of which firmware parsing or layout step caused it.

Prepending **one `U+3000` ideographic space to the entire text** restored all five left markers and the arrow alignment. Do not prefix each row. Construct the logical 20×5 frame first, pad every row to 20 cells, then send:

```python
payload = {"text": "\u3000" + "\n".join(fullwidth_rows), "final": True}
```

The transmitted row lengths are therefore **21, 20, 20, 20, 20**, while the intended visible grid remains 20×5. After removing the diagnostic bars, a clean `100米 / 掉头` frame using both the prefix and `final: true` was confirmed to appear together with correct arrow/text alignment; the wearer accepted this result. The caption test was then stopped.

This workaround was tested with font `2`, width `100`, 5 lines, and final caption frames on the connected glasses. A later fresh session opened by the desktop GUI sent final frames directly; with the prefix enabled, the wearer reported a one-cell right shift. Repeating the GUI test with the prefix disabled restored correct alignment and whole-frame appearance, confirmed by the wearer. The wearer subsequently identified the distinction as initial display versus later refreshes: the first frame needs no correction, while later updates need the prefix.

The desktop navigation controller now applies this rule automatically per display session. The first successfully sent frame has row lengths **20, 20, 20, 20, 20**; subsequent updates use **21, 20, 20, 20, 20**, retaining `final: true`. Reopening, ending or switching the display, and restarting the connection worker reset the first-frame state. A failed send does not consume that first-frame state. Tests against a simulated caption endpoint checked the actual controller's outgoing frames for these transitions; visible rendering of the revised automatic behavior still needs wearer confirmation. The firmware cause of the differing alignment remains unproven, and the workaround is not applied globally to the caption API.

## A future navigation client

The existing caption API can carry these complete text frames. A minimal client needs the maneuver and distance to that maneuver from a route provider. It would convert those into a bounded cell grid, convert printable ASCII to full-width forms, and pad cleared cells with `U+3000` before replacing the whole text.

Use the agreed **5–10 updates/s** as a maximum UI cadence; position updates can arrive less often, and unchanged frames need not be resent. The current priority is the minimal maneuver card. No GPS, routing, turn-detection, lane inference, or automatic bridge connection was added by this experiment.
