# Two built-in virtual microphones

OpenRayneo ships its own Core Audio HAL driver and forwards both glasses channels simultaneously. It publishes two independent mono input devices:

| Input device | Glasses source |
| --- | --- |
| `OpenRayneo Microphone Channel 1` | Wearer / bone-conduction microphone |
| `OpenRayneo Microphone Channel 2` | Forward-facing microphone |

The channel mapping comes from the owner's tested RayNeo iO, not an official specification or a guarantee of acoustic isolation on other firmware/models. Two applications can select different devices, and multiple clients can read the same device independently. Codex normally selects Channel 1 for the wearer's voice.

## Install and use

1. Build the app with `sh scripts/build-app.sh`. The build machine needs `libopus` (`brew install opus`, or set `OPENRAYNEO_OPUS_LIBRARY`); the resulting app bundles the decoder and its license. Users of that app do not need Homebrew, Opus, BlackHole, or Background Music installed separately.
2. Open **设备与 API** and click **安装内置驱动…**. The bundled `OpenRayneoAudio.pkg` opens in the macOS Installer, which requests administrator authentication. It installs only `OpenRayneoAudio.driver` under `/Library/Audio/Plug-Ins/HAL/`. The app does not request, receive, or store the password.
3. Complete installation and refresh devices. If the two inputs do not appear, restart the Mac, or run `sudo killall coreaudiod` yourself in Terminal. Reloading Core Audio briefly interrupts audio; launchd restarts the daemon. The `launchctl kickstart` route can be rejected by SIP on current macOS, so do not disable SIP to reload the driver. The installer does not forcibly restart audio services or the computer.
4. Choose an automatic stop time in **设备与 API** and connect the paired glasses. The app opens a real-time prompt session and enables both microphones by default. **文字显示** defaults to that same page; sending/updating answers keeps the microphone session running. Keep the glasses' real-time prompt page open. If the driver is missing, the GUI opens a text-only prompt and explains how to install the driver; reopen the prompt after installation.
5. In Codex, select `OpenRayneo Microphone Channel 1` as the microphone if its selector is available. If the app uses the system default input, select Channel 1 in macOS **声音 → 输入**, then start/restart voice chat. Select Channel 2 in another receiving app to use forward-facing audio. Keep sound output on speakers/headphones.
6. Use the sidebar **进入麦克风模式** / **重新进入麦克风模式** after failed entry or after exiting the page on the glasses. Re-entry opens a fresh prompt session and restores the last question/answer sent from this window. For an output-only interruption, **设备与 API → 恢复音频输出** retries it within the existing SID. Click **结束当前功能** when finished. Restore your previous system input if you changed it.

Forwarding does not record WAV files, perform ASR, or change system default input/output. The receiving app controls its microphone permissions and any processing/upload of audio. Both channels continue to be available as system devices when the app stops, but yield silence without a producer. ASR, recording, and forwarding share one exclusive glasses session. Forwarding shares its prompt page with question/answer text updates. Starting captions, video, navigation, teleprompter, ASR, or recording in the GUI replaces that session and stops forwarding.

## Local API

All endpoints use the existing local address and Bearer token.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/virtual-mic/devices` | Installed virtual duplex devices, including the two built-in inputs when loaded |
| `POST` | `/v1/prompts/start` | Open the prompt page and enable both built-in microphones by default; `microphone_enabled:false` opens text only |
| `POST` | `/v1/prompts/text` | Update title/answer on the active microphone session without restarting audio |
| `POST` | `/v1/prompts/stop` | Close the shared prompt page and stop both microphones |
| `POST` | `/v1/virtual-mic/start` | Start simultaneous built-in Channel 1/2 forwarding; body can be `{}` |
| `GET` | `/v1/virtual-mic` | Shared audio status and both output engines |
| `POST` | `/v1/virtual-mic/recover` | Retry unavailable outputs and reset the decoder without closing/restarting the glasses page |
| `POST` | `/v1/virtual-mic/stop` | Stop the shared audio session; repeated stop is safe |

```sh
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /v1/virtual-mic/devices
uv run python .agents/skills/openrayneo-api/scripts/request.py POST /v1/prompts/start --body - <<'JSON'
{"duration":3600}
JSON
uv run python .agents/skills/openrayneo-api/scripts/request.py POST /v1/prompts/text --body - <<'JSON'
{"text":"问题","translation":"完整回答","final":true}
JSON
uv run python .agents/skills/openrayneo-api/scripts/request.py GET /v1/virtual-mic
uv run python .agents/skills/openrayneo-api/scripts/request.py POST /v1/prompts/stop
```

Configure the current `OPENRAYNEO_API_URL` and `OPENRAYNEO_API_TOKEN` first. `duration` defaults to 3600 seconds and accepts 10–21,600. Both built-in devices must be loaded before starting. Their stable UIDs are `com.openrayneo.microphone.channel1` and `com.openrayneo.microphone.channel2`.

`POST /v1/prompts/start` returns `accepted:true`, the shared SID, and audio status after startup succeeds. Text updates reuse that SID. The legacy `/v1/virtual-mic/start` remains available and also accepts `/v1/prompts/text` updates. ASR/recording continue to reject external prompt writes.

Status has `engine: "virtual-microphone"`, `recording: null`, and a `virtualMicrophones` array with two entries. Each entry contains `deviceUID`, `deviceName`, `channel`, source `sampleRate`, `outputSampleRate`, `running`, `recovering`, `recoveryCount`, `error`, `bufferedSeconds`, `droppedFrames`, and `underrunFrames`. A recovering output is temporarily unavailable while the shared glasses session remains running. Top-level `audioState` is `waiting`, `receiving`, `recovering`, or `stopped`; `running:true` describes the owned session, not a guarantee of incoming audio. Initial HAL startup failures likewise enter output recovery after the glasses accept the page, rather than rolling back the page. The singular `virtualMicrophone` field remains an alias for the first entry for compatibility. Device/statistics remain available after stop until the next successful audio start. `audioRMS` measures the first forwarded channel; it is not a two-channel level meter.

The older explicit `deviceUID` plus `channel` request still forwards one channel to another installed loopback device. It does not start the built-in pair. This compatibility path requires that device's own driver/routing configuration.

ASR, recording, and forwarding status endpoints report the same session; any corresponding stop ends it. Do not stop another caller's session. Session/engine `running: true` proves neither that Codex selected the correct input nor that it recognized speech. Verify the receiving application's meter and result.

## Driver and audio path

`Drivers/OpenRayneoAudio/OpenRayneoAudio.c` implements Apple's `AudioServerPlugInDriverInterface`. Each device has a 48 kHz, 32-bit float mono input and an output sink for the Bridge. These are separate loopback paths; they are not channels of a single stereo input. The output sinks cannot be system default outputs. No kernel extension, DriverKit entitlement, external driver code, or custom IPC is used.

Stereo Opus is decoded once at 48 kHz. Each channel enters its own bounded FIFO and an audio graph with a mixer and dedicated HAL output, explicitly bound to that device. The mixer handles sample-rate/channel conversion; these outputs do not follow changes to the system default microphone or speakers. The driver stores the host's mixed sink audio in a timestamped atomic ring. Reads do not consume data, so simultaneous readers cannot steal samples from each other. Unwritten/expired frames return silence. The driver uses the monotonic host clock and a fixed 1024-frame loopback delay (about 21.3 ms).

Bridge FIFOs hold at most 250 ms, initially wait for at least 40 ms and one render block, drop oldest samples on overflow, and supply silence on underrun. These limits plus driver delay are not a measurement of end-to-end latency. Adaptive clock correction and Bluetooth packet-loss reconstruction are not implemented.

Forwarding stops both outputs on the duration limit or explicit stop. Missing audio for ten seconds changes `audioState` to `waiting` while the page/session stays open. Decoder errors also retain the microphone page; successful stereo decoding clears the warning, or the user can reset decoding with the recover endpoint. ASR/WAV sessions retain their ten-second missing-audio stop policy. If an output stops or its device disappears, only that output is rebuilt; it resolves the original UID once per second until available again, without closing the prompt page or falling back to speakers. The FIFO is cleared when rebuilding to avoid replaying stale speech. Explicit stop cancels recovery. Mono glasses packets are not forwarded as two independent sources; they report a warning while retaining the page for manual re-entry or later stereo audio.

## Build and removal

`sh scripts/build-audio-driver.sh` builds/signs `.build/audio-driver/OpenRayneoAudio.driver`. `sh scripts/package-audio-driver.sh` produces its Installer package. `build-app.sh` runs both and embeds the package in `Contents/Resources/`, plus `libopus.dylib` in `Contents/Frameworks/`. Release ZIPs include those resources. Driver packages are not relocatable and can be reinstalled at the same version. Local app/driver signing does not imply Apple notarization.

To remove the driver, stop forwarding and use Finder's **Go to Folder** for `/Library/Audio/Plug-Ins/HAL/`, move only `OpenRayneoAudio.driver` to Trash with administrator authentication, then restart the Mac. No third-party audio drivers are removed or replaced.

## Validation

On 2026-10-11, direct driver-interface tests verified both device UIDs/formats, channel separation, multiple independent readers, silence for missing/overwritten samples, rejection of mismatched streams/rates, and timeline reset after the last client stops. The signed `.driver` loaded through the real CFPlugIn factory and exposed both mono inputs to a test host. A separate test using actual stereo Opus packets verified that the real speech controller forwards all decoded frames to both channel outputs, preserves tone separation, rejects concurrent recording, and rolls back the first output if the second fails to start. Temporary test sources were discarded after their checks.

The earlier external-device implementation passed synthetic audio tests through the main Background Music device, including channel isolation and 48 → 32 kHz conversion. Those results do not prove that the new driver has loaded into the system audio server. The package was installed on the development Mac with administrator authentication. After the owner ran `sudo killall coreaudiod`, both 48 kHz mono devices appeared in the actual system audio inventory. A live test sent generated stereo Opus through the bundled decoder, real speech controller, both output engines, and installed HAL driver into three Core Audio input clients: Channel 1, Channel 2, and a second independent Channel 1 reader. All received their expected tone with the other tone suppressed; stop returned silence and system defaults stayed unchanged. The owner subsequently reported live input level changes while wearing the glasses; Codex recognition accuracy was not measured.

See Apple's [Audio Server driver sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) for the HAL installation mechanism.

On 2026-10-12, a disposable integration check exercised the real display controller, speech controller, decoder, and both installed HAL output engines with a simulated Bluetooth transport. Forty generated stereo Opus packets continued through eight 120-line answer updates using one SID, without page restart, stop, or text truncation. Both engines stayed healthy. Shared stop, conflicting display ownership, explicit text-only prompts, and the legacy forwarding endpoint passed. This verifies host-side coexistence; simultaneous live Bluetooth audio and visible answer updates still need wearer confirmation. The test source and binary were moved to Trash after the check.

A subsequent local check switched real system default input devices between the original input and both virtual inputs, and switched the default output to another installed virtual device and back. Two real HAL input clients continued to receive their separate generated tones. Forcing one HAL output to stop recovered only that output, and explicit stop did not restart it. Original system defaults were restored.
