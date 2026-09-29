# Glasses microphone ASR on macOS

OpenRayneo can receive microphone audio from the glasses, decode it on the Mac, use Apple's on-device speech recognizer, and send recognized text back to the glasses' real-time prompt page. The Mac microphone is not used. Audio is saved only when explicitly requested through the [WAV recording API](recording.md). The bridge does not send it to a speech cloud service; cloud fallback is disabled.

## Requirements and launch

- The usual Bluetooth pairing and bridge build requirements.
- Apple's on-device speech recognition available for the requested locale. `zh-CN` is the default; recognition availability depends on the installed macOS language assets.
- A local `libopus` installation: `brew install opus`. The bridge checks the standard Apple Silicon and Intel Homebrew paths, or `OPENRAYNEO_OPUS_LIBRARY` for an explicit dylib path. Non-ASR display endpoints do not require this library.
- macOS Speech Recognition permission for OpenRayneo Bridge. Local microphone permission is not requested because the source is Bluetooth protocol audio.

Build the application and launch it through Launch Services so privacy requests are attributed to the app, rather than the terminal or coding application that launches the executable:

```sh
sh scripts/build-app.sh
export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
open -n -g ./OpenRayneoBridge.app \
  --env "OPENRAYNEO_API_TOKEN=$OPENRAYNEO_API_TOKEN"
```

Use an unused port with `--env OPENRAYNEO_PORT=8766` if necessary. Stop an existing bridge before launching another on the same port. The build script applies a local ad-hoc signature to bind the app's privacy descriptions; this is not notarization or a Developer ID distribution signature. macOS may request permission again after rebuilding.

Request permission once, then start recognition:

```sh
curl -X POST http://127.0.0.1:8765/v1/asr/authorize \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/asr/start \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"locale":"zh-CN","duration":120}'
```

The authorization endpoint waits up to 60 seconds for the system prompt. If it times out, finish the prompt and query status; a timeout does not imply denial. `speechAuthorization` uses Apple's enum: `0` undetermined, `1` denied, `2` restricted, `3` authorized.

## Control and diagnostics

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/asr/authorize` | Request macOS speech recognition permission; does not open glasses audio |
| `POST` | `/v1/asr/start` | Start glasses audio, local recognition, and text display |
| `GET` | `/v1/asr` | Query running state, audio/decoder statistics, latest transcript, displayed text, and error |
| `POST` | `/v1/asr/stop` | Stop recognition and send the prompt-page exit command |

All endpoints require the bearer token. `duration` is an integer number of seconds, defaults to `120`, and must be between `10` and `600`. Recognition stops at this limit, after 10 seconds without audio, on repeated decoding failures, or on a recognition/display error. Stop is idempotent. Add `"record": true` to the ASR start body to also save a stereo WAV; the default is no recording. Recording shares the same session lifetime and stops if ASR fails. Use the recording-only API when recognition should not affect recording duration.

`audioPackets`, `decodedSeconds`, `decodeErrors`, `droppedAudioPackets`, and `audioRMS` distinguish missing audio from decoding and recognition problems. `displayedText` means the text write succeeded, not that a frame was visibly rendered. `transcript` keeps at most the latest 400 characters in memory; the display uses its last 96 characters. These values remain available after stop until the next successful start or process exit, and are not printed in normal logs. Treat status responses as potentially private speech content.

Manual caption/prompt controls and teleprompter requests are rejected while ASR owns the display. Stop other display sessions before starting ASR. If a stop command cannot be sent, exit the prompt page on the glasses manually; the bridge reports the failure in `error`.

## Audio and recognition path

1. Start Proactive AI business `0x17` with type `1`, and require a matching type `2`, `code: 1` response. This existing page activates the glasses microphone and can display returned text.
2. Receive type `4`: Protobuf field `3` carries JSON metadata including `sid` and `seq`; field `4` carries raw Opus packet bytes. Only audio for the current SID is decoded.
3. Decode with `libopus` at 16 kHz into mono PCM, downmixing the captured stereo stream. Examination of 307 official captured packets found 240-byte packets with 320 decoded samples each (20 ms at 16 kHz). Packet byte length is not hardcoded.
4. Feed PCM to `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`, partial results and punctuation enabled.
5. Send changed text using the verified prompt type `5` message, at most four updates per second. This first implementation uses a fixed title and puts recognized text in the prompt page's answer field; it does not start the separate AI Subtitle audio session or generate AI answers.
6. Stop via prompt type `3`, reason `2`. Outside an active ASR session, caption/prompt audio packets are discarded as before.

The audio queue is bounded to 64 packets; overflow is counted instead of accumulating an unbounded recording. Recognition tasks are renewed after a final result or 45 seconds. Renewal does not preserve a full conversation transcript and may lose words at a task boundary; seamless long-session recognition, packet-loss concealment, translation, and speaker separation are not implemented.

The owner's subsequent microphone experiment identified channel 1 as bone-conduction/wearer audio and channel 2 as forward-facing/other-speaker audio; see the [recording channel mapping](recording.md#channels-and-missing-audio). The current ASR still downmixes both channels. Selecting a channel or running separate recognizers is a next implementation step; speaker roles should not be inferred from the mixed transcript alone.

## Troubleshooting

**The process exits when requesting speech permission:** launch the built `.app` with `open`, rather than executing its binary through a parent app that lacks a speech usage description. This was observed when launching through the coding application's terminal.

**On-device recognition unavailable:** make sure macOS has speech assets for the selected locale. The bridge intentionally does not fall back to cloud recognition.

**No audio packets:** check Bluetooth connection and whether the glasses entered the prompt page. Keep the phone Bluetooth disconnected during direct Mac use.

**Audio arrives but no transcript:** inspect `audioRMS` and `error`, speak a short clear sentence, and check the selected locale. The recognizer can revise partial text as speech continues.

## Device validation

Tested on the existing RayNeo iO and macOS 15.6.1 with Chinese on-device recognition. The first 90-second session decoded 4,487 packets without decoding errors or queue overflow, and automatically stopped at its duration limit. Recognition worked, but sending text only in `source_transcript` did not produce a readable body; the user observed title flicker.

The corrected path keeps `source_transcript` fixed as a title and sends recognition results in `target_translation`, the prompt page's body field. The user confirmed that body text appeared and updated while speaking. A restarted session also received and decoded audio without errors. Manual prompt/teleprompter controls and duplicate ASR starts were checked to return `409` during recognition, and repeated stop requests completed successfully. This is a live functional test, not a measured accuracy or latency benchmark.
