# OpenRayneo

[English](README.md) · [简体中文](README.zh-CN.md)

**Send notifications, scripts, live text, and todos to RayNeo iO glasses from your Mac.**

OpenRayneo is an unofficial, experimental Bluetooth bridge with a local HTTP API. Use it from shell scripts, desktop apps, or local automation. The bridge connects directly to the glasses; it does not require a phone relay, cloud service, or a modified official app.

It uses the glasses' existing notification, teleprompter, caption, prompt, and todo interfaces. Arbitrary graphics, screen mirroring, and custom display layouts are outside the current scope.

## What works

Verified on one RayNeo iO with an Apple Silicon Mac running macOS 15.6.1:

| Capability | Result |
| --- | --- |
| Direct Bluetooth connection | BLE authentication and RFCOMM channel 26 connected |
| Custom notifications | Chinese title and body visibly confirmed |
| Chinese teleprompter text | Short script and 120-line, 16,319-byte script displayed |
| Playback controls | Pause, resume, and stop visibly confirmed |
| Real-time captions | Two-line Chinese text displayed and replaced without noticeable loading |
| Real-time prompts | Chinese question and answer displayed; updates replaced the previous pair |
| Todos | New item visibly confirmed alongside an existing item; test removal confirmed by readback |
| Larger writes | Segmented to the negotiated RFCOMM MTU |
| Connection diagnostics | Inspect connection state and retry through HTTP |

The glasses' firmware version was not recorded. Compatibility with other firmware versions, RayNeo models, Intel Macs, and older macOS releases has not been verified.

## Requirements

- RayNeo **iO** glasses, powered on and paired with your Mac.
- macOS 13 or later (the package deployment target; tested on macOS 15.6.1).
- Xcode Command Line Tools or Xcode with Swift 5.10 or later. Development was tested with Swift 6.1.2.
- Bluetooth permission for the bridge or the application launching it, as requested by macOS.

The Swift package uses Apple's system frameworks and has no external package dependencies. The official Android APK and Bluetooth captures are not needed to build or run it.

## Quick start

### 1. Build

Install Apple's development tools if needed:

```sh
xcode-select --install
```

Then clone and build:

```sh
git clone https://github.com/Tobi1chi/OpenRayneo.git
cd OpenRayneo
sh scripts/build-app.sh
```

This creates `OpenRayneoBridge.app` with the Bluetooth usage description required by macOS. It is a locally built command-line app bundle, not a notarized GUI installer.

### 2. Pair and start

Pair the glasses in **System Settings → Bluetooth** and complete any pairing confirmation yourself. For the first connection, keep the glasses near the Mac and temporarily turn off the phone's system Bluetooth if it normally connects to them.

In the first terminal, run:

```sh
export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge
```

Allow Bluetooth access if macOS asks. Keep this terminal running; press `Ctrl+C` to stop the bridge.

By default, the API listens on `http://127.0.0.1:8765`. Startup output includes the API token. In a second terminal, set that same token for the examples below:

```sh
export OPENRAYNEO_API_TOKEN='paste-the-token-from-the-first-terminal'
```

If several iO devices are paired, set `RAYNEO_ADDRESS` before starting the bridge to select the intended device.

### 3. Connect and send a notification

```sh
curl -X POST http://127.0.0.1:8765/v1/device/connect \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"

curl -X POST http://127.0.0.1:8765/v1/notifications \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Hello from Mac","body":"Your local app can send text here."}'
```

Notification and teleprompter requests also connect on demand, so the explicit connect request is optional.

## API

All endpoints except `GET /health` require `Authorization: Bearer <token>`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Process health and BLE/RFCOMM connection flags |
| `GET` | `/v1/device` | BLE phase, scan count, last BLE error, and connection state |
| `POST` | `/v1/device/connect` | Connect without sending display content |
| `POST` | `/v1/notifications` | Send a notification; requires `title` and `body` strings |
| `POST` | `/v1/teleprompter` | Transfer and start a script; requires a nonempty `text` string |
| `POST` | `/v1/teleprompter/pause` | Pause the active script |
| `POST` | `/v1/teleprompter/resume` | Resume the active script |
| `POST` | `/v1/teleprompter/stop` | Stop the active script |
| `POST` | `/v1/captions/start`, `/text`, `/stop` | Start, update, or exit live captions |
| `POST` | `/v1/prompts/start`, `/text`, `/stop` | Start, update, or exit real-time prompts |
| `GET` | `/v1/todos` | Read the complete task snapshot |
| `POST` | `/v1/todos` | Add a todo while preserving existing records; requires `title` |
| `DELETE` | `/v1/todos/{id}` | Remove a todo created by this bridge process |
| `GET` | `/v1/display/events` | Recent display replies and discarded audio packet count |

### Teleprompter

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Demo","text":"Hello from OpenRayneo.\n你好，雷鸟眼镜。","speed":60}'
```

`title` defaults to `OpenRayneo`; `speed` defaults to `120`. Speed values `60` and `120` were used during testing; the firmware's complete range and units have not been established. The current layout uses a three-second countdown.

A successful response has the form:

```json
{"ok":true,"sent":"teleprompter","did":"<script-id>"}
```

Control the script created by the current bridge process:

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter/pause \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/resume \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

### Captions, prompts, and todos

```sh
curl -X POST http://127.0.0.1:8765/v1/captions/start \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/captions/text \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Live captions\nUpdated by your local app."}'
curl -X POST http://127.0.0.1:8765/v1/captions/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

Check `accepted: true` in the start response before sending text. Replace `captions` with `prompts` to use the prompt page; its text body can include `translation` for an answer and `final: true`. Stop each session when finished. Prompt startup activates the glasses' audio uplink; the bridge discards it and does not implement ASR.

Todo creation accepts `{"title":"Prepare notes","important":false}` and returns `eventID` and `readBack`. It uses a full-list read/merge/sync, so keep the official phone app disconnected during writes. Open the glasses' todo menu manually. Deletion is limited to IDs created by the running bridge; a restart loses this ownership state. See [display protocol and API details](docs/display-protocol.md) for tested behavior and limitations.

### Response semantics

- `200`: a read succeeded, RFCOMM opened for `/v1/device/connect`, or a display startup reply arrived (inspect `accepted`). In `/health`, `ok: true` means the server is running; inspect `bleReady` and `rfcommConnected` separately.
- `202`: the display/control frames were written. Script startup also waits for a file-transfer acknowledgment. This does **not** confirm visible rendering or playback state.
- Errors use `{"error":"..."}`. Common statuses include `400` for invalid input, `401` for a missing/wrong token, `409` when no script is active, `413` for oversized data, and `503`/`504` for connection or transfer failures.

## Configuration

Set these environment variables before launching the bridge:

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENRAYNEO_API_TOKEN` | Generated at startup | Bearer token; printed in startup output |
| `OPENRAYNEO_PORT` | `8765` | Local HTTP port |
| `RAYNEO_ADDRESS` | Auto-select one paired iO | Classic Bluetooth address when selection is ambiguous |
| `OPENRAYNEO_BLE_TRACE` | Off | Set to `1` to log nearby advertisement names, services, connectability, and RSSI |

The server binds to `127.0.0.1` only and is intended for local integrations. Treat the startup token as a credential, and redact it before sharing logs. BLE tracing can include names of nearby devices.

## Troubleshooting

**The bridge cannot select the glasses:** pair them in macOS first. If multiple iO devices are paired, set `RAYNEO_ADDRESS` to the desired device's address.

**BLE discovery times out:** keep the glasses awake and nearby, check their pairing/discovery mode, and temporarily disable the phone's system Bluetooth. Disconnecting only the phone app was not sufficient during testing. Check macOS Bluetooth permissions as well.

**A connection attempt fails:** inspect `GET /v1/device`, then retry `POST /v1/device/connect`. A BLE attempt has a 15-second timeout and cleans up its scan/pending connection. RFCOMM opening has a further 12-second wait.

**RFCOMM times out after switching from the phone:** if macOS logs report `BT_ERROR_INVALID_LINK_KEY`, stop the bridge, forget the glasses in Mac Bluetooth settings, put them in pairing mode, and pair again. This recovered the data channel during testing; unbinding the official phone account was not required.

**A control request returns `409`:** start a new script through this bridge process. Active script state is not recovered after a restart or after `stop`. Caption/prompt text requires an accepted session; stop that session before retrying a failed start.

## Current limits

- This is an early prototype with a narrow hardware test base, not an official RayNeo SDK.
- The API manages one selected pair of glasses and one active script per process. It does not synchronize the phone app's script library.
- The tested long script fits in one application-level file chunk. Repeated file-chunk requests and larger scripts still need device testing.
- A protocol payload cannot exceed 65,531 bytes; framing overhead reduces the space available for text. Oversized frames return `413`. This is separate from RFCOMM MTU segmentation.
- Account-bound ECDH authentication is not implemented. Firmware requesting it will receive an explicit unsupported-authentication error.

## Development

```sh
swift build
sh scripts/build-app.sh
```

The GitHub Actions workflow builds the app on macOS. It cannot validate Bluetooth behavior without real hardware. See [protocol notes](docs/protocol.md) for the transport format, authentication flow, and device-validation boundaries.

Issues and pull requests are welcome. For connection reports, include the glasses model/firmware, macOS version, and a redacted `/v1/device` response. Keep tokens, device addresses, personal notification text, official APKs, and raw captures out of public reports.

## License and affiliation

Licensed under the [Apache License 2.0](LICENSE). OpenRayneo is an independent project, not affiliated with or endorsed by RayNeo. RayNeo names and trademarks belong to their respective owners. No official APK, firmware image, or captured user data is distributed in this repository.
