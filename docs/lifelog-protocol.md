# LifeLog / AlwaysOn entry points

Findings from the official RayNeo AI 1.0.5 APK and direct Mac experiments. The Mac has enabled LifeLog, answered wake events, and received real-time audio. Controlled observations support speech-triggered wake on the tested device; the complete firmware trigger rules and physical menu entry remain unverified.

## Phone application

Flutter symbols identify the AI-page LifeLog module and route `/ai/lifelog`, plus `/ai/lifelog/conversation` and onboarding route `/ai/alwaysOnFillin`. Native Flutter method channel `rayneo_venus_sdk_plugin/always_on` exposes `always_on_initialize`, `always_on_init_workflow`, `always_on_start_workflow`, `always_on_stop_workflow`, and `always_on_set_realtime_page_state`. These are internal method-channel calls, not HTTP endpoints for OpenRayneo.

Evidence: `com/rayneo/rayneo_venus_sdk_plugin/f.java` dispatches these calls to `D7.C0547n` / `F7.i`. APK strings include `AiPageLifelogEnableTapAction`, `lifeLogEnabled`, and the LifeLog AI-page widgets. This establishes a phone-side module and workflow entry, not the exact current on-screen menu position or a complete glasses activation sequence.

## Audio message family

`com/rayneo/rayneo_venus_sdk_plugin/e.java` handles these `AssistantMsg` types:

| Decimal / hex type | Meaning in the official native helper |
| --- | --- |
| `161` / `0xA1` | Glasses AlwaysOn wake |
| `162` / `0xA2` | Phone starts recording |
| `163` / `0xA3` | Glasses real-time audio |
| `164` / `0xA4` | Glasses cached audio |
| `165` / `0xA5` | Glasses exit |
| `166` / `0xA6` | Phone abnormal exit |
| `167` / `0xA7` | Phone queries cached audio |
| `168` / `0xA8` | Phone reports real-time page state |

`F7.i.B` constructs `AlwaysOnStartRecordPayload` with `taskId` and `idleTimeoutSec`, serializes it to JSON, and sends type `162` through the helper. Re-decompiling `e.k` with JADX's bad-code/debug output confirms that it constructs an `AssistantMsg` and sends it on `EnumC0848h.f10135f`, `VOICE_ASSISTANT` business `0x0D`. This routing also worked in the direct Mac test. The real-time audio receive path parses both JSON metadata and the Protobuf binary data field; the cached audio path handles task ID and finish state.

The tested Proactive AI recording path uses business `0x17`, type `1` startup and type `4` audio. It is a separate path; its success alone does not verify AlwaysOn activation or permit assuming the same audio packet format. The two-channel microphone mapping established in Proactive AI must also be checked separately in LifeLog.

## Direct Mac enablement test

The existing official-app capture contains Launcher business `0x0F`, type `20`, command `life_log_switch`, with `payload: {value: 0, mode: 0, data: ""}` and a type `21` `life_log_switch_result` reply. For the Mac experiment, sending the same command with `value: 1` produced a reply with `value: 0`, followed by a glasses `A1` wake event. The reply value is therefore not interpreted as a direct echo of the requested switch state.

The Mac answered `A1` using `A2` with a fresh task ID and `idleTimeoutSec: 30`, then `A8` with `inRealtimePage: false`. It received 25 `A3` batches containing 761 declared frames / 182,640 audio bytes. Metadata included `mode: 1`, `frameCount`, `vpuMask`, and `vadMask`. An `A5` with `rc: 0` arrived about 46 seconds after the first wake. Audio bytes are counted and discarded by this diagnostic path, not recorded or recognized.

The owner initially reported that the LifeLog indication appeared while quiet after enablement. The indication remained visible after `A5` and after audio stopped, so that visual report does not establish when recording woke. A later quiet baseline had no `A1` or audio despite the feature being enabled. Use protocol events to distinguish the enabled state from an individual active recording round.

### Wake stimulus comparison

The owner performed the following actions while the Mac observed the native events, without a connected phone app:

| Condition | Observation |
| --- | --- |
| Before the Mac's enable request: quiet, then natural wearer speech | No `A1` or audio observed |
| Feature enabled, wearer silent, external human speech from another person or playback | A new `A1`; automatic Mac `A2`; new `A3` audio; later `A5` with `rc: 0` |
| After that round ended: external source stopped, wearer naturally spoke without a wake word or button | Another `A1` and new `A3` audio; the observation timer subsequently stopped this round |
| Re-enabled, quiet for 35 seconds | No `A1` or audio |
| From the quiet baseline: one head-up screen-wake action without speaking or touching the temples | No `A1` or audio |

This supports the feature remaining armed between recording rounds and waking for both wearer and external speech in these trials. It does not establish acoustic thresholds, distinguish live human speech from recorded playback, or prove that all gestures are irrelevant. VPU/VAD flags were present in the audio but have not been calibrated as reliable speaker-identity labels. Repeated trials and frame-level timing are needed for stronger conclusions.

The first observation accumulated three wake events and 1,694 declared audio frames (406,560 bytes); the final round was cut off by the diagnostic observation deadline. The separate quiet/head-up observation produced no audio. Stop returned `observing: false`, `enabledByProbe: false`, and no error after a switch-off reply; the owner then confirmed the persistent LifeLog indicator disappeared. Cached `A4` retrieval was not exercised in this experiment.

Experimental endpoints are `POST /v1/lifelog/observe` (10–600 seconds, default 300), `GET /v1/lifelog`, `POST /v1/lifelog/switch` with `enabled`, `POST /v1/lifelog/record`, and `POST /v1/lifelog/stop`. Observation reserves the audio/display controls, automatically answers `A1`, counts audio and VPU/VAD flags, and retains bounded control events. Its timeout sends an `A6` exit (`rc: 1`) for a task started by the probe and requests switch-off if this probe enabled LifeLog. A switch-off reply is not a separate readback of the persisted setting; inspect actual device behavior and errors during cleanup.

## Real-time versus cached audio

- Real-time `A3`: the native receive helper supports a legacy single-frame body and a batched format. In the latter it splits binary data into 240-byte frames, clamps `frameCount` to available data and at most 31, and extracts per-frame `vpuMask`/`vadMask` bits plus `mode`. It passes the frames to the AlwaysOn audio processing path, enabling live processing rather than waiting for a complete file. The payload and flags must be preserved when implementing this path; do not decode an entire batch as one Opus packet.
- Cached `A4`: `F7/a.java` appends received bytes to `always_on_cached_audio/<taskId>.opus`. On `isFinish: true`, it closes the file and reports task ID, file path, and size to Flutter. The filename extension alone does not establish standard Ogg encapsulation or direct player compatibility.
- Reconnect query `A7`: `D7/S1.java` sends type `167` with an empty message after a qualifying Bluetooth reconnection, provided the device is marked for a query and the app is in the foreground. This establishes an intended recovery/synchronization path. Cache duration, capacity, contents, and guarantees during disconnection are not established; this is not evidence of unlimited all-day raw-audio storage.
- A separate phone-side AIRuntime network-buffering mechanism exists. `F7/i.java` handles buffering-window exhaustion by sending `A6`, `rc: 3`, and stopping the workflow. Do not conflate a phone/cloud network interruption with Bluetooth disconnection or glasses-side cached audio.

## Wake sequence and remaining uncertainty

The glasses send `A1`. The native helper dispatches it to the AlwaysOn listener, or briefly retains it until a listener is registered. `F7/i.java` can build a default AlwaysOn configuration if no template is available; the fallback includes Opus input and `idleTimeoutSec: 300`. The runtime's `onAudioRecordStart` callback sends `A2` with a task ID and idle timeout, followed by `A8` page-state reporting when the send succeeds.

This establishes the host-side wake/record handshake. The direct tests above provide evidence for speech-triggered activation but do not reveal the firmware algorithm or individual microphone trigger thresholds. The existence of VPU/VAD audio flags alone is not proof of a particular `A1` trigger. The idle timeout default is also not proof of an exact five-minute shutdown rule; the Mac experiment explicitly used a shorter 30-second idle parameter and observed normal `A5` endings in two rounds.
