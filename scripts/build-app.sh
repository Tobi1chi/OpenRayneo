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
mkdir -p "$app_dir/Contents/MacOS"
cp "$workspace_dir/.build/release/openrayneo-bridge" "$app_dir/Contents/MacOS/openrayneo-bridge"
cp "$workspace_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "$signing_identity" --identifier com.openrayneo.bridge "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
