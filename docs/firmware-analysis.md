# Firmware acquisition: current evidence

The acquisition target is an OTA download package. Obtaining an OTA package is distinct from dumping the glasses' entire installed flash: an update can contain only selected files or incremental changes. Following the initial official-app investigation, a third-party repack of stock 1.0.4.12 members and a modified TAP1 package were downloaded from Turbo-IO's public releases for offline comparison. See [Turbo-IO firmware findings](turbo-io-firmware.md) for provenance, local artifacts, and verified differences. No update/install command was sent.

## Evidence from the existing official-app capture

The APK's `P3/EnumC0848h.java` maps business `0x09` to `MARS_FOTA`.

A captured phone request on this business used Protobuf version `1`, type `1`, and empty message/data fields. The glasses replied on the same business and type with:

```json
{
  "OsVersion": "Strix OS 1.0.4.12",
  "OtaValidationStateCode": 4294967295,
  "OtaValidationState": "idle",
  "OtaValidationConfirmed": true,
  "PackageInfoVersions": [1, 2],
  "PackageTypes": ["files", "zip"]
}
```

This identifies the version reported at capture time, not a fresh query of the current device. The response lists package types and package-info versions; archive layout, compression, encryption, signatures, partition contents, and full-versus-incremental status are still unknown. The numeric validation-state sentinel is not decoded here.

## Official APK leads

Flutter AOT strings identify these components:

- `common_services/ota_service/fota/api/ota_api.dart`
- `common_services/ota_service/fota/api/models/ota_api_response.dart`
- `common_services/ota_service/fota/fota_service.dart`
- `common_services/ota_service/fota/ota_package_storage.dart`
- `features/ota_page/utils/ota_firmware_download.dart`
- `features/ota_page/utils/ota_firmware_reuse_validation.dart`

Candidate upgrade-check paths are `/xrlauncherhwapi/v1/signApi/gray/upgrade` and `/xrlauncherapi/v1/signApi/gray/upgrade`. These strings alone do not reveal the division between hardware/app updates, request fields, server selection, authentication, and response contract.

Strings such as `downloadFotaPackage`, `downloadOtaFile: URL:`, `_startDownloadOTAPackage downloadUrl=`, and `startDownloadOTAPackageAndPushToGlasses` identify download and transfer stages. The latter also indicates that a UI action may combine downloading and pushing, so a download flow need not be a download-only button.

No obvious firmware image was found among the APK's `.bin`, `.img`, `.fw`, `.dfu`, `.ota`, and `.zip` entries. The listed binary candidates instead included app assets and speech models. Existing app logcat and bugreport text did not contain the identified OTA download-log markers or a usable package URL. Android's empty `/metadata/ota/state` bugreport entry concerns the phone, not the glasses.

## Alternative acquisition directly from the official app

1. Connect the existing Android phone over USB with USB debugging authorized. Keep phone Bluetooth off for the initial cache inspection; changing glasses pairing is unnecessary for that step.
2. Inspect the official app's accessible external files/cache directories for a previously downloaded OTA package. Private internal app storage may not be readable on a production, non-rooted phone; do not assume `adb pull` can access it.
3. If no package is available, inspect official upgrade metadata/logging to locate a valid download URL. Establish whether the UI action also starts a transfer before invoking it; obtaining a package should not require installing it on the glasses.
4. Save any acquired package in the ignored analysis directory. Inspect its file signatures, archive manifest and contents, then determine whether resources and executable code can be extracted. Keep account-bearing URLs and raw firmware out of the public source repository.

Potential analysis targets include built-in weather icon IDs/resources, display templates, microphone-channel routing, and pairing-record management. The downloaded third-party baseline contains readable AP strings and separate image/audio/Bluetooth payloads, providing a starting point for static analysis. It is not a complete flash dump, and direct official-app acquisition would provide a separate provenance check.
