# Turbo-IO firmware research

Reviewed on 2026-09-29 against [Turbo1123/Turbo-IO commit cb3bcf59](https://github.com/Turbo1123/Turbo-IO/tree/cb3bcf59abaa903e89b3db120e8a8d8317e72a06), the repository's current `main` at the time. This review reads public source and compares release artifacts offline. It does not execute the project's build/flash scripts, install a phone addon, flash glasses, or incorporate its implementation into OpenRayneo.

## Finding: actual modified firmware is published

Turbo-IO publishes version-specific additions to Strix OS 1.0.4.12, including custom display pages and native application runtimes. This matches the OS version reported in our earlier official-app Bluetooth capture, though a matching version string does not imply installation compatibility.

The current release inspected is [Android GUARD07 + TAP1-TEST-01](https://github.com/Turbo1123/Turbo-IO/releases/tag/android-105-guard07-tap1-test01), published 2026-09-27. Its firmware asset is `TurboIO-TAP1-TEST-01.zip` (9,320,672 bytes). The release also offers a modified Android APK; that APK was not downloaded or installed for this review.

Earlier published stages include:

| Stage | Documented capability |
| --- | --- |
| R3 | Additional launcher entry and embedded PNG display |
| TDP1 / TNV1 | A 512×128 grayscale display test surface and a separate 540×180 native navigation page |
| TMU1 | Music page and lyrics |
| TWR1 | Book shelf and native text reader |
| TFP1 / FOCUS-04 | Four-item menu layout and native focus timer |
| TAP1 | Bounded application runtime and dashboard capabilities |

These feature descriptions and device acceptance reports come from the project's documentation. Our independent checks cover archive contents and source structure, not a fresh installation or on-glasses test of these features.

## Downloaded artifacts and provenance

Two packages are saved under the Git-ignored `analysis/firmware/turbo-io/` directory:

- `StrixOS-1.0.4.12-ORIGINAL-rollback.zip`, from the [R3 release](https://github.com/Turbo1123/Turbo-IO/releases/tag/firmware-strix-1.0.4.12-turbophoto-r3).
- `TurboIO-TAP1-TEST-01.zip`, from the current Android/TAP1 release above.

The author's [firmware README](https://github.com/Turbo1123/Turbo-IO/blob/cb3bcf59abaa903e89b3db120e8a8d8317e72a06/firmware-research/strix-1.0.4.12/README.md) explicitly describes the first package as stock members obtained from the official app cache and **repacked locally**. It is not the original server ZIP, a full flash backup, or an independently authenticated vendor release, and the filename's “rollback” label does not guarantee recovery.

Both ZIPs could be read with the standard archive reader; their ZIP encryption flags are unset. Their contents comprise `OtaFileInfo.json` and 14 payloads. That observation concerns the container, not every embedded component's internal format or the device's complete signing chain.

## Independently verified differences

Comparison used the extracted bytes directly, not filenames or the author's checksums alone:

| Item | Baseline | TAP1-TEST-01 | Result |
| --- | --- | --- | --- |
| `nuttx_ap.bin` | 9,466,560 bytes | 9,590,856 bytes | Changed; grows by 124,296 bytes |
| Other 13 payloads | — | — | Byte-for-byte identical |
| `OtaFileInfo.json` | 14 entries | 14 entries | Parsed differences only in AP `Size` and `Md5` |

Within the original AP file extent, 117 byte positions differ; the rest of the growth is beyond that extent. This count is not a count of instructions or independent patches and includes metadata/footer changes; it does not prove the meaning or runtime safety of the modifications.

The package has separately named AP, Bluetooth, audio and other components, including `nuttx_bth.bin`, `nuttx_audio.bin`, `nuttx_apc1.bin`, `images.bin`, `lotties.bin`, `rives.bin`, `smf.json`, and audio algorithm DLL payloads. These provide distinct analysis targets. The baseline AP contains readable NuttX/LVGL source-path strings, supporting static inspection.

Local `member-comparison.json` records the comparison. Extracted `original-nuttx_ap.bin` and `tap1-nuttx_ap.bin` are available alongside the packages. These artifacts remain outside the public source set.

## How the extension works

The inspected [TAP1 build input](https://github.com/Turbo1123/Turbo-IO/blob/cb3bcf59abaa903e89b3db120e8a8d8317e72a06/firmware-research/strix-1.0.4.12/tap1/source/official-addon/research/build-image-rx-candidate.py) and native module code show:

1. Start from a pinned original AP binary and version-specific symbol/address mappings.
2. Compile additional C/assembly modules for ARM Cortex-M33 / Thumb, using LLVM's `arm-none-eabi` toolchain.
3. Append the compiled module within the AP partition budget and replace selected entry instructions with branches into the added code.
4. Attach to launcher construction, menu/input handling, file reception, message dispatch, and page lifecycle.
5. Call existing firmware services and LVGL functions for widgets, fonts, drawing, timers, power and input.
6. Update AP metadata and the OTA manifest, then package a complete OTA ZIP. Unchanged members remain in that complete package; unchanged contents do not imply the installer skips writing those members.

This is a binary extension of the stock system. The project does not provide the vendor's full firmware source. Its [TAP1 README](https://github.com/Turbo1123/Turbo-IO/blob/cb3bcf59abaa903e89b3db120e8a8d8317e72a06/firmware-research/strix-1.0.4.12/tap1/README.md) also states that the current source snapshot is not a self-contained SDK that rebuilds everything from scratch without additional baseline/symbol inputs. Older stages have their own documented reproduction procedures; those claims should not be generalized to every release.

The native navigation module receives a bounded semantic snapshot via the existing file-transfer mechanism (`turbo-navigation.tnv`), updates an eye-side LVGL page, and replies through Launcher messages. It does not need to stream a full map image on every navigation update. The larger application SDK uses constrained page/component descriptions and small packages; the glasses do not execute arbitrary browser JavaScript or MCP services.

## Phone-side versus firmware-side changes

The repository maintains several routes:

- V1: an independent iOS client/SDK for connection and existing protocols.
- V2 / Android addon: extensions integrated into a compatible official phone app, reusing its pairing, services and OTA transport.
- Firmware runtimes: additional eye-side display/application capabilities that require the matching modified firmware.

Model integration or existing text surfaces can work with stock firmware, while new native menus, custom graphical runtimes and bounded app loading depend on the modified AP. After a compatible runtime is installed, changing supported card/app content does not necessarily require another firmware modification.

## Implications for OpenRayneo

OpenRayneo currently drives stock firmware surfaces directly from the Mac. Turbo-IO demonstrates a separate route to new eye-side pages by adding native handlers and renderers. A future Mac client could investigate sending that runtime's supported commands without making a phone the permanent relay, but that combination has not been tested here.

Useful next investigations are stock `images.bin` and AP weather mappings, stock display entry points, and audio/channel configuration. The verified AP-only change set does not solve our multiple-host pairing issue: the Bluetooth and audio payloads are unchanged, and no such behavior was tested in this review.

Turbo-IO's original code uses [PolyForm Noncommercial 1.0.0](https://github.com/Turbo1123/Turbo-IO/blob/cb3bcf59abaa903e89b3db120e8a8d8317e72a06/LICENSE); OpenRayneo uses Apache-2.0. Architecture/protocol research should be distinguished from importing implementation code. Any incorporation would need to respect the applicable license and cannot simply be relabeled Apache-2.0. Vendor firmware/resources retain their separate ownership. This review only adds descriptive research notes to OpenRayneo.
