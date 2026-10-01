# Experimental display channels

This work uses the official RayNeo AI 1.0.5 Android APK, an official-app HCI capture, and direct tests of OpenRayneo. It does not incorporate third-party client code. These interfaces are experimental and use the existing firmware's pages.

See [schedule and weather transport](schedule-weather-protocol.md) for calendar research and the experimental dashboard/weather APIs. Schedule writes are not yet exposed by the bridge.

## Business channels

The APK's `P3.EnumC0848h` assigns these IDs:

| ID | Business |
| --- | --- |
| `0x13` / 19 | `AI_SUBTITLE` |
| `0x16` / 22 | `SCHEDULE_TODO` |
| `0x17` / 23 | `PROACTIVE_AI` |

Display messages use a Protobuf envelope with field 1 (varint version `1`), field 2 (varint message type), and field 3 (UTF-8 JSON). The APK contains `TransportMessage.CaptionMsg`, and native send paths in `E7.x` and `G7.g` use that envelope. OpenRayneo wraps it in the existing AA55 transport frame.

## Real-time captions

A temporary display configuration uses type `7`, with a new `sid`, `force: false`, `scope: "temporary"`, and a `config` object. The tested configuration is:

```json
{
  "font_size": 2,
  "content_width": 100,
  "max_lines": 5,
  "position": "center",
  "is_display": true,
  "straight_view": "original"
}
```

The glasses returned type `8`, the same SID, `code: 1`, and the matching `effective_config`. Font size is a firmware value, not a documented pixel size.

Type `5` updates text within that SID:

```json
{
  "sid": "<current-session>",
  "mode": 3,
  "status": 0,
  "content": {"source_transcript": "New caption text"}
}
```

A two-line Chinese caption was visibly confirmed, followed by a second two-line caption that replaced the first without noticeable loading. This was a text-only test; it did not implement ASR. Final/history accumulation semantics still need separate verification.

Further [text layout experiments](text-layout.md) confirmed full-width character grids using `U+3000` spaces: 20×6 at font setting `2`, and 26×7 at setting `1`. The same note records measured wrap positions, whole-frame update tests, and the limits of treating this text page as a TUI surface.

Later [navigation-grid tests](tui-navigation.md) found that `final: true` made complete frames appear together and replace the previous frame. A leading `U+3000` before the entire 20×5 frame corrected an observed first-row one-cell shift at font `2`; see the test conditions before applying this workaround.

Type `3` requests exit using `sid`, `reason_code: 10`, and an empty `text`. The user confirmed the glasses returned to the home page after the test.

## Real-time prompts

The official APK's `com.rayneo.rayneo_venus_sdk_plugin.e.a` constructs prompt text with `sid`, `mode: 4`, `status` (`0` for partial, `1` for final), and `content` containing `source_transcript`, optional `target_translation`, `keyword_info: null`, and `label: 0`. `G7.g` sends it as a `CaptionMsg` type `5` on business `23`.

An official-app capture established type `1` as the startup request:

```json
{
  "sid": "<new-session>", "trigger": 1, "force": false, "code": 0,
  "settings": {
    "mode": "conversation", "source_language": "zh-CN",
    "target_language": "zh-CN", "save_audio": false, "direction": "ahead"
  }
}
```

The glasses returned type `2`, the matching SID, `code: 1`, and `final_settings`. Direct Mac tests confirmed both the Chinese source text and answer displayed; a second final text update replaced the previous pair. Type `3` with `sid`, `reason_code: 2`, and empty `text` exited the page, after which the user opened the todo page. Caption type `7` is not a working startup on this channel.

Starting this page also activates the glasses' audio uplink (type `4`), even with `save_audio: false`. OpenRayneo normally discards those packets, retaining only a count. An explicit [ASR session](asr.md) instead decodes them and performs on-device recognition on the Mac; an explicit [recording session](recording.md) saves a WAV locally. The bridge does not forward audio to a speech cloud service. Always stop the audio session after use. The protocol's `save_audio` field does not prevent a receiver from explicitly saving incoming packets locally.

## Task query

The official capture contains type `15` queries and type `16` replies. A direct query with the following body succeeded:

```json
{"queryType":0,"eventType":1,"lastSyncTime":0,"eventIDList":[],"needFullData":true}
```

Replies contain `scheduleTotal`, `todoTotal`, `batchNo`, `isLastBatch`, `needFullData`, and `dataList`. Direct tests returned both an empty list and a populated list. OpenRayneo collects batches until `isLastBatch` and checks the todo count before a write.

## Todo synchronization

The official app sends type `6` with `total`, `isLastBatch: true`, and `eventList`. Items have this shape (illustrative values):

```json
{
  "eventType": 1, "eventID": 90000, "createTime": 1790640000000,
  "title": "Example todo", "isImportant": false,
  "status": 0, "lastModifiedTime": 1790640000
}
```

`createTime` is Unix milliseconds; `lastModifiedTime` is Unix seconds in the observed samples. Cloud IDs can exceed JavaScript's safe integer range: preserve them as integers when handling query results.

Type `6` replaces the todo list. OpenRayneo queries the full list, preserves existing records, adds one item, sends the merged list, and queries again. A direct Mac test confirmed the new Chinese item appeared alongside the pre-existing item. Removing only the bridge-created item through another full sync was confirmed by readback, with the original record unchanged. Visual confirmation of removal was not requested.

`POST /v1/todos` accepts `title` and optional boolean `important`. IDs are selected from unused integers in `90000..<100000`. `DELETE /v1/todos/{id}` only removes IDs created by the current bridge process; ownership is not recovered after restart. `readBack` reports whether the requested result was found in the subsequent query, not whether it rendered on screen. A readback timeout may occur after a write has already succeeded; query before retrying an add.

This is experimental full-list synchronization, without concurrent-writer protection or phone/cloud synchronization. Use it while the official phone app is disconnected. Schedule type `5`, completion updates, and automatic navigation into the todo page are not implemented. Open the todo menu on the glasses to view items.

## Local display API

Use `POST /v1/captions/start`, `/text`, `/stop`, or the equivalent `/v1/prompts/` paths. Start accepts an empty object. Captions optionally accept `font_size`, `content_width`, and `max_lines`; defaults are `2`, `100`, and `5`. The tested firmware also supports a 26×7 full-width grid at font `1`, width `100`, and 7 lines. Inspect `reply.effective_config`: requests for font `0`, width `120`, or excess lines were clamped in the [layout tests](text-layout.md). Text requires a nonempty `text`, with optional `translation` and boolean `final` (default `false`). Prompt tests used `final: true`; partial/final history semantics are not established.

Only one caption or prompt session is tracked at a time. Inspect `accepted: true` on start before sending text. A timeout returns `acknowledged: false`, and text remains blocked; call the matching stop endpoint before retrying. Stop the active session before starting a teleprompter or another display mode. Sessions are not recovered after a bridge restart or an external device operation.

## Diagnostics

`GET /v1/display/events` provides a bounded in-memory list of the latest 64 caption, prompt, and task replies, plus `discardedAudioPackets`. It requires the API bearer token. Reply bodies can contain displayed text or task content; they are not printed in normal transport logs. A successful write is not a visible-display acknowledgment.
