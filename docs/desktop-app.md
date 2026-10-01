# Mac desktop controls

Build with `sh scripts/build-app.sh`, then double-click `OpenRayneoBridge.app`. The native window opens on **设备与 API**, without requiring a paired device or a running HTTP server. Bluetooth use begins when you open the pairing assistant, connect, or send content.

## Connect

1. For a new device, put the glasses into pairing mode and choose **添加并配对眼镜**. OpenRayneo discovers RayNeo iO over BLE and reads the classic address from its manufacturer advertisement (company `0x5716`, model `0x06`). If more than one candidate is found, choose the intended glasses in the app. Ordinary **连接眼镜** preserves the existing bond.
2. Every pairing action first shuts down the app's owned Bridge, stops discovery, runs a separate `--unpair ADDRESS` helper, and then uses a new `--pairing-status ADDRESS` process to require both `isPaired: false` and `isConnected: false`. Only then does it launch `--pair ADDRESS`. The pairing helper uses `IOBluetoothDevicePair(device:)`, pumps the run loop for up to 25 seconds, calls `stop()` on completion, and exits. Another independent status check must confirm the new bond before the headless Bridge starts. The status command does not create a pairing agent. See [the connection protocol](protocol.md). Complete any numeric comparison or PIN/passkey sheet yourself; the app relays the answer to the helper over its private stdin pipe. **取消配对流程** stops discovery or the owned helper and waits for it to exit; a bond already removed by this action is not restored. Do not simultaneously forget the device in system settings or re-enter glasses pairing mode while the app is pairing.
3. For an already paired device, select it and press **连接并启用 API** or the sidebar's **连接眼镜**. The app starts an owned `--headless` subprocess, authenticates with its generated API token, waits for system Bluetooth readiness/permission, and requests BLE authentication plus RFCOMM connection. An undecided initial permission can wait up to 90 seconds before the ordinary connection timeout begins.
4. The API step becomes ready after `/health` and an authenticated `/v1/device` query pass, BLE is authenticated, and RFCOMM is connected. Copy the address, token, or **复制带令牌的调用示例** for an immediately runnable, read-only device query. The token is masked in the on-screen example. **检查 API** repeats these checks; connection loss clears the verified state.
5. If connection fails, inspect the error and **连接帮助与诊断**. If the phone occupies the connection, turn off its Bluetooth. For re-pairing, enter glasses pairing mode and use **添加并配对眼镜** to discover the device again. There is no automatic retry after failure. **蓝牙设置** remains available when native removal is unsupported or does not finish; the app will not proceed with pairing in that case.

If re-pairing continues to fail within the same app session, quit OpenRayneo completely, reopen it, and use **添加并配对眼镜** again. This recovered a failure on 2026-09-29. A restart also releases process-owned Bluetooth and helper state, so which of those clears the problem is unclear. Repeated pairing within one app session is still not reliable.

### Restart the connection service

**重启连接服务** on **设备与 API** restarts the independent `--headless` worker while keeping the GUI window open. It cancels and waits for pending controller operations and monitoring, requests that active display/audio sessions stop, terminates the owned worker, and confirms its exit before starting a new worker. A worker that does not exit within two seconds is killed; if its exit still cannot be confirmed, restart stops without launching a second worker. Successful shutdown finalizes recordings through the existing stop endpoint; forced termination of an unresponsive worker can leave a recording unfinalized.

The new worker reconnects to the selected glasses using the existing Mac bond and checks the API. Restart never invokes `--unpair` or `--pair`, does not reset macOS Bluetooth, and does not erase the glasses' state. The new API token and possibly the port differ; copy the current connection details again. **连接帮助与诊断** shows the worker PID so its replacement can be checked. A stalled connection request can be interrupted with this button; restart is unavailable during pairing.

BLE authentication, RFCOMM, display/audio handling, and HTTP serving live in the worker. Discovery for the pairing UI remains in the GUI; pairing and removal use short-lived helper processes. This is a GUI-owned child, not a login daemon: quitting the GUI also stops its worker. Whether restarting this worker matches the full-app restart recovery above is still untested.

Native removal uses the runtime-checked, undocumented `IOBluetoothDevice.remove` operation, also used by blueutil's experimental unpair command. It targets only the selected device and does not edit Bluetooth preference/keychain files, reset the Bluetooth controller, or reset the glasses. Apple may change this undocumented selector in a future macOS. The fresh-state check covers the Mac's exposed pairing/connection state, not every internal cache or the glasses' state.

The app remembers the selected paired device. It prefers `OPENRAYNEO_PORT` or port 8765 and chooses an available loopback port if that port is occupied. The GUI-generated token is held in memory and is not printed or stored by the desktop controller. Copy actions intentionally place credentials on the local clipboard. A new service launch generates a new token, and a fallback port can change; use the current setup page for integration values. Environment variables for optional Opus/recording paths are inherited by the child.

The paired-device list comes from macOS `system_profiler SPBluetoothDataType -json`, read in the background with its 10-second timeout option. Direct `IOBluetoothDevice.pairedDevices()` enumeration blocked inside the system framework during GUI testing, so the panel does not use that path. Bluetooth transport remains in the existing bridge.

### Manual first-pair acceptance

1. Quit other standalone Bridge instances and turn off phone Bluetooth. Enter glasses pairing mode. An existing Mac bond can remain in place to exercise automatic removal. Do not reconnect through system settings.
2. Open the rebuilt app. On **设备与 API**, press **添加并配对眼镜** once. This is the single pairing workflow and always discovers the target from current BLE advertisements. The app stops its own Bridge if needed.
3. Wait for pairing, independent verification, connection, and API readiness. Confirm the glasses leave their connecting page. A selected device or a successful system pairing alone is not the acceptance criterion.
4. Press **检查 API**, then send a notification from the notifications panel and verify its title/body on the glasses.
5. If it fails, record the displayed error and diagnostics before disconnecting. A missing advertisement and a BLE-authenticated RFCOMM failure have different guidance. Automatic bond removal occurs only as part of an explicit pairing action, never as a background retry; do not repeatedly reset both sides.

On 2026-09-29, the first manual run of this revised GUI completed system pairing and BLE application authentication but failed to open RFCOMM; macOS logged `BT_ERROR_INVALID_LINK_KEY`. After disconnecting in the app, forgetting only the Mac bond, leaving the glasses' state unchanged, and using the app to pair again, the wearer reported success and macOS confirmed RFCOMM 26 opened with MTU 1011. This validates recovery through the revised GUI; first-attempt pairing from every device state is still unreliable. The original standalone helper's successful hardware test is documented separately.

## Persistent macOS permissions

Quit the running app before rebuilding. The build script uses `OPENRAYNEO_SIGNING_IDENTITY` when set. Otherwise it selects the single available **Apple Development** or **Developer ID Application** identity in the local keychain. If more than one is available, choose explicitly:

```sh
security find-identity -v -p codesigning
OPENRAYNEO_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' sh scripts/build-app.sh
```

Keep using the same signing identity and bundle identifier (`com.openrayneo.bridge`). The certificate-backed designated requirement remains stable across ordinary rebuilds, allowing macOS to retain Bluetooth and Speech Recognition consent. Migrating from ad-hoc signing may require consent once more. Changing identity, resetting privacy settings, or OS policy changes can require renewed permission. Signing does not grant permissions by itself, and the app never edits the privacy database.

Without a suitable identity, the script falls back to ad-hoc signing and prints a warning. `OPENRAYNEO_SIGNING_IDENTITY=-` explicitly selects that mode; its code requirement can change on rebuild and trigger repeated prompts. These local builds are not notarized. This concerns macOS privacy consent, not the glasses' Bluetooth bond or the GUI's per-session API token.

## Controls

| Page | Available actions |
| --- | --- |
| 设备与 API | Pair a new device, connect an existing one, restart its independent connection service, check API readiness, and copy integration details |
| 导航演示 | Choose left/right/straight/U-turn and distance; send or update the 20×5 frame |
| 字符视频 | Import a local movie, preview brightness-matched full-width characters, block, or half-block frames, and play silently at 5–10 updates/s; see [the player guide](text-video.md) |
| 文字显示 | Send complete captions or a prompt title/body |
| 通知 | Send a notification title and body |
| 提词器 | Send a script, pause, resume, or end playback |
| 语音与录音 | Start local ASR, optionally save audio, or record only; show/play the resulting WAV |

The navigation renderer uses `final: true`. First-row alignment is automatic: the first navigation frame in a newly opened display session has no prefix; after a successful send, subsequent updates add one `U+3000` before the entire frame. The wearer reported that first display and later refreshes need different alignment. **重新打开显示**, ending or switching the display session, and starting a new connection worker reset this behavior. A failed first send does not advance to the update rule. The manual alignment toggle has been replaced by an explanation of this automatic behavior. The preview shows the logical 20×5 grid, not the compensating prefix. Navigation values are manually entered examples; no GPS or route provider is connected. If the wearer exits the page on the glasses, use **重新打开显示** to start a fresh session.

Switching display features stops the previous app-tracked session first. **结束当前功能** exits the tracked session. If you manually exit on the glasses, **重新打开显示** explicitly restarts the caption/prompt page because the current protocol does not reliably synchronize that manual exit back to the client. Successful sends indicate transmission; confirm visible rendering on the glasses.

Real-time prompts activate glasses audio uplink. The ordinary text panel does not save or recognize that audio. ASR/recording starts only through the audio controls; the existing [Opus and local speech requirements](asr.md) still apply. Finalized recordings can be revealed in Finder or opened in the default audio player.

Weather, todos, and LifeLog diagnostics remain available through the HTTP API; they are not included in this first desktop panel. Avoid concurrent external display/audio control while using the GUI: its selected session reflects actions taken in this window.

## Service ownership and command-line use

Disconnecting stops the tracked session and audio processing before terminating the app-owned subprocess. Closing the last window or quitting follows the same cleanup path. Forced termination, Bluetooth failures, or a nonresponsive service can prevent confirmation of the glasses' exit; see [recording limitations](recording.md) for abrupt shutdown.

The GUI does not terminate an unrelated process occupying a port. Ordinary connection, disconnection, and service restart do not change macOS pairing credentials; the explicit add-and-pair workflow described above replaces the target bond. To run the API without the desktop window:

```sh
./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge --headless
```

The executable built directly by SwiftPM defaults to headless mode; `--gui` explicitly opens the desktop window. The app bundle defaults to the GUI. The underlying Bluetooth/display/audio APIs and their authentication requirements are unchanged.

## Validation

On the development Mac, the native UI loaded the paired glasses, chose a different port while 8765 was occupied, connected and retried successfully, and sent the 20×5 navigation frame. With first-row correction off, the wearer confirmed that the frame appeared together and was aligned. Ending the display, disconnecting, and quitting with an active navigation session were exercised; the owned service processes exited. Text/prompt, notification, teleprompter editing, and audio-panel controls were inspected in the native window. GUI-triggered microphone recording and ASR were not repeated in this UI validation; their existing backend device tests are documented separately.

Already-paired GUI connection and authenticated API checks passed, with unauthenticated `/v1/device` returning HTTP 401. The revised separate-helper GUI also recovered a failed pairing after a Mac-only bond replacement, as described above; first-attempt pairing remains unreliable. System inquiry alone did not list the glasses. The historical successful flow used a separate direct-address `IOBluetoothDevicePair` helper, independently confirmed `isPaired()`, exited the helper, and then launched a standalone Bridge. New SDP preflight, BLE pre-binding, and reconnect-flag experiments were removed from the baseline; none proved necessary to reproduce that success.

The revised process coordinator was checked with disposable simulated helper processes for success, pairing failure, cancellation, and status-query timeout. These checks exercise the actual coordinator, verify that status confirmation happens after pairing-process exit, and check that no pairing helper remains running; they do not replace Bluetooth hardware or numeric/PIN prompt acceptance testing.

The subsequent mandatory-removal change passed simulated success, removal failure, residual-pairing, residual-connection, and cancellation checks. Pairing never started when cleanup failed or either status flag remained true. The wearer subsequently confirmed that **添加并配对眼镜**, including discovery and automatic removal, succeeded. The shortcut using a remembered address failed in the same testing round and was removed at the user's request; the app now uses discovery for every pairing action, and why the shortcut failed is unknown.

Connection-service restart was checked against disposable local HTTP workers using the actual desktop controller: normal restart, a worker ignoring termination, and a pending connection request all produced a new connected worker PID only after the old worker exited. The same GUI controller was reused, no pairing command was invoked, and final shutdown left no worker running. Hardware recovery through this restart button still needs wearer validation.


Certificate-backed signing was verified before and after a source change and release rebuild: the designated requirement stayed identical. After quitting, rebuilding, and reopening the app, the glasses connected and API checks passed without another Bluetooth consent action. Debug/release builds, bundle signature verification, plist validation, and diff whitespace checks passed. Speech consent persistence was not separately exercised in this pass.
