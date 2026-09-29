# Continuous WAV recording

The recording API saves glasses microphone audio directly into one growing WAV file. It does not need Apple Speech Recognition permission and does not use the Mac microphone. ASR can optionally save a WAV as well, using `"record": true` on `/v1/asr/start`.

## Start, inspect, and stop

Install `opus`, build and start the app as described in [ASR setup](asr.md), then:

```sh
curl -X POST http://127.0.0.1:8765/v1/recording/start \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"duration":300}'

curl http://127.0.0.1:8765/v1/recording \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"

curl -X POST http://127.0.0.1:8765/v1/recording/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

The output is **48 kHz, 16-bit PCM, two-channel WAV**. This is the decoder's output format, not evidence of the hardware microphone sampling rate or the original Opus bandwidth. The Opus compression that occurred on the glasses is not undone by saving WAV.

The response's `recording` object provides `path`, `sampleRate`, `channels`, `bitsPerSample`, `bytes`, `seconds`, and `finalized`. After stop, verify `running: false`, `recording.finalized: true`, and `error: null`. Repeated stop requests are safe. ASR and recording share a single audio session; either stop endpoint stops that session, and another start returns `409` while it is active.

By default files go to `~/Music/OpenRayneo/Recordings/`. Set `OPENRAYNEO_RECORDINGS_DIR` before launching the app to choose another directory. Filenames are generated per session and existing files are not overwritten. Recordings are not automatically deleted. The repository ignores `recordings/` if that directory is used for local output.

Recording-only `duration` defaults to 300 seconds and accepts 10–21,600 seconds (six hours). The recording stops on expiry, after ten seconds without incoming audio, on repeated decoding failures, or on a write error. There is no automatic reconnect/resume into the previous file. ASR sessions retain their shorter 600-second maximum even when recording is enabled.

## How one large file is written

```text
Glasses Opus packets -> stereo PCM -> append interleaved PCM to one WAV
                                              |
                           update RIFF/data lengths once per second
                                              |
                              finalize lengths and close on stop
```

The bridge writes a 44-byte WAV header, then appends each decoded packet's samples to that same file. It does not save one WAV per packet or concatenate multiple WAV headers. Every second it refreshes the length fields and synchronizes the file; stop writes the final lengths and closes it. The synthetic writer check verified append order, left/right sample separation, the live checkpoint header, and the final file using an independent WAV reader.

Buffer memory is bounded instead of accumulating the full recording. At this format, PCM uses 192,000 bytes per second, about **691 MB/hour** (659 MiB/hour). Classic RIFF WAV has a roughly 4 GiB size limit; the writer rejects growth beyond it. RF64, file rotation, and cross-session concatenation are not implemented.

Use the stop endpoint before closing the app. Abrupt termination can leave the header behind the trailing audio by approximately one checkpoint interval; periodic updates reduce the recovery work but are not a crash-proof transactional file format. Do not assume every media player will refresh the duration of an already-open growing file.

## Channels and missing audio

`encodedChannelCounts` reports the channel count indicated by the incoming Opus packets. The present Proactive AI audio path exposes one Opus stream containing **two decoded channels**, which can be saved separately from the stereo WAV.

A follow-up controlled recording and listening experiment on 2026-09-29 established the following mapping, as confirmed by the device owner:

| Exported channel | PCM / FFmpeg index | Microphone | Intended source |
| --- | --- | --- | --- |
| Channel 1 | `0` / `c0` | Bone-conduction microphone | The wearer's own voice |
| Channel 2 | `1` / `c1` | Forward-facing microphone | Other people's voices in front of the wearer |

This mapping was confirmed on the tested RayNeo iO through the owner's experiment, not through a hardware teardown or an official channel specification. It does not establish acoustic isolation, absence of signal processing, or the total number of physical microphones. Other models and firmware remain unverified.

In a live 57.94-second test, all 2,897 received packets reported stereo. Roughly 92.8% of channel sample pairs differed and their zero-lag correlation was about 0.16. The two channels therefore contain different signals rather than duplicated mono samples. This does not establish whether they are raw microphone feeds, beamformed outputs, or other processed signals. No API to select additional physical microphone channels has been identified in the examined protocol and APK paths.

`missingAudioPackets` counts forward gaps in audio `seq`; `droppedAudioPackets` counts the bounded processing queue's overflow; `decodeErrors` counts failed decoding attempts. The live test reported zero for all three, and the finalized file contained 2,781,120 stereo frames at 48 kHz. This is evidence for that short test, not a guarantee of lossless transport in all conditions.

Only successfully received and decoded packets are appended. Silence from valid packets is retained. Disconnections, missing packets, and failed decodes are not reconstructed or padded, so a recording with losses can be shorter than elapsed wall-clock time. Audio before the session starts cannot be recovered.

To split the two channels with an installed FFmpeg:

```sh
ffmpeg -i recording.wav -af 'pan=mono|c0=c0' channel-1.wav
ffmpeg -i recording.wav -af 'pan=mono|c0=c1' channel-2.wav
```

The names “left” and “right” in a stereo file describe sample positions, not physical positions on the glasses. Use the channel mapping above when selecting wearer or forward-facing audio.
