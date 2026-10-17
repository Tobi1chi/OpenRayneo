# Release packaging

**v1.0** is the current coordinated macOS and Android stable release. Both apps
report **1.0.0**. It supersedes v0.1 with the same functionality and light OR
branding. Mac build number 5 and Android versionCode 19 support upgrades.
The v0.1 release and historical Mac prereleases `v0.1.0` / `v0.2.0` remain
available under their original tags.

Both platforms use the light OR monogram from `assets/icons/openrayneo.png`.
Run `sh scripts/build-icons.sh` on macOS to regenerate ICNS and Android resources.
The artwork stays transparent; Android supplies an independent dark adaptive
background. The README preview is `docs/assets/openrayneo-logo.png`.

## macOS ZIP

Build on macOS with Xcode Command Line Tools and `libopus` (`brew install opus`):

```sh
sh scripts/package-release.sh
```

The script reads `Info.plist`, builds the native architecture, creates a fresh
bundle in `.build/distributions/<version>-<architecture>/`, validates metadata
and signing, and produces `OpenRayneo-<version>-macos-<architecture>.zip`.
Move a previous staging directory aside before rebuilding. Update both the
public version and internal build number for subsequent releases.

The distributed Apple Silicon build requires macOS 15+ because of its bundled
Opus library, although the Swift code and driver target macOS 13. Testing used
macOS 15.6.1. Intel is not validated or included. The app is **ad-hoc signed and
not Apple-notarized**; first launch may require per-app approval. A signature
check does not establish notarization or compatibility with other Macs.

The bundle contains its icon, executable, Opus decoder/license and
`OpenRayneoAudio.pkg`. Installing the two-channel microphone driver requires
administrator authentication and may require a restart. No API tokens, pairing
records, videos, recordings or development logs are packaged. See [ASR](asr.md)
and [recording](recording.md).

## Android APK

```sh
./android/gradlew -p android :app:assembleRelease :app:lintRelease
```

The output is `android/app/build/outputs/apk/release/app-release.apk`; distribute
it as `OpenRayneo-1.0.0-android.apk`. Android 13+ is required. The release build
is **not debuggable**. By the maintainer's explicit choice, v1.0 uses the existing
development certificate (`signingConfigs.debug`) so the installed development
app can upgrade without uninstalling or losing its private configuration.
This is a direct-distribution compatibility choice, not a dedicated production
signing key or Play Store signing setup.

Future updates must use the same certificate. Keep a secure backup of the
original build machine's `~/.android/debug.keystore`; never commit or upload it.
A clean build machine generates a different debug certificate and its APK will
not update existing installations. Compare signing certificates before upload.
A future change to an unrelated release key requires a separate migration plan.

## v1.0 scope and evidence

- macOS: direct Bluetooth connection, display controls, local API, audio/ASR,
  native microphone driver and existing diagnostics.
- Android: direct Bluetooth connection, Gaode notification navigation, mobile
  model configuration, desktop Codex access, display coordinator, compact UI,
  onboarding and notification-listener recovery.
- Shared transparent light OR icon, included in both packages and both READMEs.
- Xiaomi 13 verified navigation and 0.5.2 manual listener recovery; the newer
  automatic timeout recovery still needs a matching real-device failure test.
- Android glasses ASR remains paused. Long-running background, outdoor-route and
  cross-network scenarios have not all been validated. Stable release status
  does not expand the documented hardware or feature coverage.

## Publish

Commit and push the intended source, create the new `v1.0` tag at that commit,
and upload the macOS ZIP and signed Android APK to a **non-prerelease** GitHub
Release. Keep older tags and downloads intact and mark v1.0 as latest.

Before upload, extract the ZIP and check the bundled icon, metadata, architecture,
dynamic library paths and code signature. Check the APK's version, non-debuggable
manifest, launcher resources and signature. Build artifacts and signing keys
stay outside tracked source files.
