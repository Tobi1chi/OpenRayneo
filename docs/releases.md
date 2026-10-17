# Release packaging

The current downloadable version is **v0.2.0**, an experimental prerelease for Apple Silicon (arm64), requiring macOS 15+. The bundled Opus binary has a macOS 15.0 minimum; the app metadata reflects that requirement even though the Swift code and native driver target macOS 13. Live device testing used macOS 15.6.1. Intel hardware has not been validated and is not included in this release. The original **v0.1.0** prerelease remains available.

## Build a ZIP

Source packaging is now **0.2.1** and includes the selected transparent glasses
icon in `assets/icons/OpenRayneo.icns`. This does not change the existing v0.2.0
GitHub download until a new release is published. Both platforms derive their
icons from `assets/icons/openrayneo.png`; regenerate exports on macOS with
`sh scripts/build-icons.sh`.

From a macOS source checkout with Xcode Command Line Tools and `libopus` installed on the build machine (`brew install opus`):

```sh
sh scripts/package-release.sh
```

The script reads the version from `Info.plist`, builds the native architecture, creates a fresh staging bundle under `.build/distributions/<version>-<architecture>/`, validates its metadata and signature, and produces `OpenRayneo-<version>-macos-<architecture>.zip`. To repeat a build, move the previous output directory aside first. Update both `CFBundleShortVersionString` and `CFBundleVersion` for subsequent versions.

Release packaging deliberately uses **ad-hoc signing**. It does not embed a developer's personal signing certificate, does not modify the existing app in the repository root, and does not perform Apple notarization. Gatekeeper acceptance on a fresh downloaded copy has not been validated. Signing validation is not notarization and does not guarantee compatibility with other Macs. Replacing an ad-hoc build can prompt again for Bluetooth/Speech permissions.

Current source packaging includes the app executable/metadata, signed Opus decoder and its license, and the bundled `OpenRayneoAudio.pkg` installer for both native microphones. It excludes local API tokens, pairing records, videos, recordings, APKs, captures, and development logs. No video or audio content is bundled. The decoder is bundled for runtime use. Users install the included audio driver once through macOS Installer with administrator authentication, and may need to restart for Core Audio to load it. The driver is built from this repository; no external loopback application is required. See [ASR](asr.md) and [recording](recording.md).

## Publish

Commit the intended source and documentation, push the branch and a version tag at that commit, then attach the ZIP to a GitHub Release for that tag. Use prerelease status while the documented hardware limitations remain. Release notes should state architecture, minimum/tested macOS, signing/notarization status, bundled audio components and installation requirements, and unresolved pairing/display behavior. Do not claim a universal macOS binary or device compatibility based solely on compilation.

Before uploading, extract the ZIP into a separate local directory and check the executable architecture, bundle version, file inventory, dynamic library paths, and code signature. Keep temporary verification artifacts outside the repository's tracked files.
