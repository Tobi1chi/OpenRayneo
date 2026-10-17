#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0

set -eu

workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir=${OPENRAYNEO_APP_DIR:-"$workspace_dir/OpenRayneoBridge.app"}

# A certificate-backed identity keeps the designated requirement stable across builds.
# Explicit '-' remains available for machines without a development certificate.
signing_identity=${OPENRAYNEO_SIGNING_IDENTITY:-}
if [ -z "$signing_identity" ]; then
    identities=$(security find-identity -v -p codesigning | sed -nE '/"(Apple Development:|Developer ID Application:)/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]+) .*/\1/p')
    identity_count=$(printf '%s\n' "$identities" | awk 'NF { count++ } END { print count+0 }')
    case "$identity_count" in
        0) signing_identity=- ;;
        1) signing_identity=$identities ;;
        *) printf '%s\n' 'Multiple signing identities found. Set OPENRAYNEO_SIGNING_IDENTITY to the certificate you want to keep using.' >&2; exit 1 ;;
    esac
fi
if [ "$signing_identity" = - ]; then
    printf '%s\n' 'Warning: ad-hoc signing; rebuilding may require Bluetooth and Speech authorization again.' >&2
fi

swift build --package-path "$workspace_dir" --configuration release
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$workspace_dir/.build/release/openrayneo-bridge" "$app_dir/Contents/MacOS/openrayneo-bridge"
cp "$workspace_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$workspace_dir/assets/icons/OpenRayneo.icns" "$app_dir/Contents/Resources/OpenRayneo.icns"
OPENRAYNEO_SIGNING_IDENTITY="$signing_identity" sh "$workspace_dir/scripts/build-audio-driver.sh"
OPENRAYNEO_DRIVER_PACKAGE="$app_dir/Contents/Resources/OpenRayneoAudio.pkg" sh "$workspace_dir/scripts/package-audio-driver.sh"

opus_library=${OPENRAYNEO_OPUS_LIBRARY:-}
if [ -z "$opus_library" ]; then
    for candidate in /opt/homebrew/opt/opus/lib/libopus.dylib /usr/local/opt/opus/lib/libopus.dylib; do
        if [ -f "$candidate" ]; then opus_library=$candidate; break; fi
    done
fi
if [ -z "$opus_library" ] || [ ! -f "$opus_library" ]; then
    printf '%s\n' 'App packaging requires libopus: brew install opus, or set OPENRAYNEO_OPUS_LIBRARY. The built app bundles it for users.' >&2
    exit 1
fi
if [ -f "$app_dir/Contents/Frameworks/libopus.dylib" ]; then
    chmod u+w "$app_dir/Contents/Frameworks/libopus.dylib"
fi
cp "$opus_library" "$app_dir/Contents/Frameworks/libopus.dylib"
install_name_tool -id @rpath/libopus.dylib "$app_dir/Contents/Frameworks/libopus.dylib"
codesign --force --sign "$signing_identity" "$app_dir/Contents/Frameworks/libopus.dylib"
cp "$workspace_dir/ThirdParty/opus/COPYING" "$app_dir/Contents/Resources/opus-COPYING"
codesign --force --sign "$signing_identity" --identifier com.openrayneo.bridge "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
