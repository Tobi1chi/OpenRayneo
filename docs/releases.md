# Release packaging

The first downloadable version is **v0.1.0**, an experimental prerelease for Apple Silicon (arm64). It targets macOS 13+; live device testing used macOS 15.6.1. Intel hardware has not been validated and is not included in this release.

## Build a ZIP

From a macOS source checkout with Xcode Command Line Tools installed:

```sh
sh scripts/package-release.sh
```

The script reads the version from `Info.plist`, builds the native architecture, creates a fresh staging bundle under `.build/distributions/<version>-<architecture>/`, validates its metadata and signature, and produces `OpenRayneo-<version>-macos-<architecture>.zip`. To repeat a build, move the previous output directory aside first. Update both `CFBundleShortVersionString` and `CFBundleVersion` for subsequent versions.

Release packaging deliberately uses **ad-hoc signing**. It does not embed a developer's personal signing certificate, does not modify the existing app in the repository root, and does not perform Apple notarization. Gatekeeper acceptance on a fresh downloaded copy has not been validated. Signing validation is not notarization and does not guarantee compatibility with other Macs. Replacing an ad-hoc build can prompt again for Bluetooth/Speech permissions.

The ZIP includes only the app's executable, Info.plist, and signature resources. It excludes local API tokens, pairing records, videos, recordings, APKs, captures, and development logs. No video or audio content is bundled. The app loads system frameworks; optional microphone decoding still requires a separately installed `libopus`. See [ASR](asr.md) and [recording](recording.md).

## Publish

Commit the intended source and documentation, push the branch and a version tag at that commit, then attach the ZIP to a GitHub Release for that tag. Use prerelease status while the documented hardware limitations remain. Release notes should state architecture, minimum/tested macOS, signing/notarization status, optional audio dependencies, and unresolved pairing/display behavior. Do not claim a universal macOS binary or device compatibility based solely on compilation.

Before uploading, extract the ZIP into a separate local directory and check the executable architecture, bundle version, file inventory, dynamic library paths, and code signature. Keep temporary verification artifacts outside the repository's tracked files.
