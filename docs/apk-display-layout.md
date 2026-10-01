# Display layout evidence in the official APK

Inspected the local `RayNeo_AI_1.0.5+.apk` on 2026-09-29. This note combines APK assets and strings, the current bridge's transmitted fields, and the separate [device layout measurements](text-layout.md). APK strings establish that a setting or model exists; they do not by themselves establish its allowed values, wire encoding, or firmware behavior. No glasses settings were changed during this inspection.

## Caption settings

The Flutter application contains these source-path strings in `lib/arm64-v8a/libapp.so`:

- `features/caption_page/presentation/more_settings/caption_setting_subtitle.dart`
- `features/caption_page/presentation/more_settings/caption_setting_spatial.dart`
- `features/caption_page/presentation/more_settings/caption_setting_translate_display.dart`
- `features/caption_page/data/model/caption_settings_config.dart`
- `features/caption_page/data/model/caption_glasses_config.dart`

Model/class names include `CaptionConfigConstants`, `CaptionDisplayConfig`, `CaptionGlassesConfig`, `CaptionSyncConfigRequestModel`, and `CaptionSyncConfigResponseModel`. The application is Flutter AOT: JADX recovers the Java/native bridge, not these Dart implementations. The names are not recovered source code or a complete schema.

| Setting | APK evidence | OpenRayneo / device status |
| --- | --- | --- |
| Font size | `font_size`; small/large font slider assets | Exposed; font `1` and `2` tested; request `0` returned `1` |
| Content width | `content_width`; narrow/wide slider assets | Exposed; request `120` returned `100` |
| Number of lines | `max_lines`; line slider assets | Exposed; font `1` with 12 or 16 requested lines returned 7 |
| Position | `position` in the existing configuration; up/down slider assets and `_PositionSettingControl` | Bridge fixes this to `center`; other wire values and their effect on capacity remain unverified |
| Display visibility | `is_display` | Bridge fixes this to `true`; this is not evidence of a denser layout |
| Straight-ahead view / spatial presentation | `straight_view`, a spatial settings page, and original/translation view guidance | Bridge fixes this to `original`; other values and interactions remain unverified |

The packaged fixture `assets/flutter_assets/assets/config/setting_test.json` contains `lineCount: 3`, `fontSize: 2`, `position: 2`, `width: 100`, `spatial: 1`, and `calibration: true`, alongside language settings. This is a test/default asset, **not a range declaration**. In particular, its numeric `position` is not evidence that the glasses' JSON `position` accepts the same number. Likewise, filenames ending in `line_one` or `line_five` do not prove a firmware limit of five lines.

The APK's Chinese guidance describes reading translation while looking straight ahead, looking up to see the original, and switching original/translation positions with the crown. This supports the interpretation of spatial and translation display settings as presentation controls, but not an inference that they increase simultaneous text capacity.

No caption-specific independent line-spacing, custom font-family, or smaller-than-`1` setting was established by this inspection. Generic Flutter `lineHeight`/`fontFamily` strings and Android `lineSpacing` resource attributes are present, but were not linked to the glasses caption configuration. The native `DebugHandleCaptionMessage` branch in plugin `f` returns `false`; it is not evidence of an arbitrary-layout debug interface.

The seven-line clamp came from the glasses' `effective_config` reply in the device tests, not a maximum inserted by OpenRayneo. Changing the phone's slider range alone would therefore not bypass that observed clamp.

## Teleprompter: a separate, more detailed layout path

The official APK's Chinese teleprompter help explicitly describes adjusting display height and distance, text size, **line spacing**, and manuscript width. It also describes scene presets and remembering layout settings for each manuscript.

Related AOT strings include `TeleprompterSettings`, `TeleprompterTextSize`, `TeleprompterDepth`, `TeleprompterGear`, `TeleprompterAppliedDisplaySettingsNotifier`, and the source path `features/teleprompter_page/bluetooth/model/0x07_settings_update.dart`. This is evidence of a settings-update path in addition to initial script transfer; its complete message shape and limits were not recovered here.

OpenRayneo already sends these fixed settings on its teleprompter path in `startTeleprompter`:

| Field | Current value | Interpretation / remaining work |
| --- | --- | --- |
| `size` | `18` | Text-size setting; supported range and units unverified |
| `leading` | `4` | Candidate line-spacing control, consistent with the APK's help; changing it needs a device test |
| `width` | `492` | Manuscript-width setting; supported range and units unverified |
| `depth` | `1` | Depth/distance setting; enum-to-distance mapping unverified |
| `gear` | `1` | Setting whose precise mapping, including any relation to display height, still needs recovery |

The APK contains the corresponding settings/debug strings, including `TeleprompterSettings(gear:`, `, depth:`, `, size:`, `, width:`, and `, leading:`. Help text plus these existing transmitted fields makes teleprompter spacing a stronger next experiment than inventing a caption `line_spacing` field. It does **not** establish that teleprompter settings can be sent on the caption channel.

The next useful capacity test is a paused, numbered teleprompter script with smaller `size` and `leading`, changing one parameter at a time and keeping the other settings fixed. More visible rows are plausible but unverified. Even if that works, the existing file-transfer/scrolling teleprompter API does not establish the same inexpensive full-text replacement behavior as captions, so suitability for a live TUI needs separate validation.

## Reproducible local evidence

The following offsets are **file offsets in this APK's ARM64 `libapp.so`**, not runtime addresses or identifiers for another release:

| Evidence | Offset |
| --- | --- |
| `CaptionConfigConstants` | `0x83c0d4` |
| `CaptionGlassesConfig` | `0x8e90a6` |
| `font_size` | `0x89a5c2` |
| `content_width` | `0xa05d98` |
| `max_lines` | `0x125af8` |
| `straight_view` | `0x17de00` |
| Teleprompter Chinese “display mode” help, UTF-16LE | `0x899342` |
| `TeleprompterSettings(gear:` | `0x9aecb5` |
| `, leading:` | `0xc36593` |

The original APK and extracted/decompiled artifacts remain local and ignored by Git. No firmware or APK was patched, and no new layout control was added to the bridge in this audit.
