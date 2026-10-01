#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0

set -eu

workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$workspace_dir/Info.plist")
architecture=$(uname -m)
release_dir="$workspace_dir/.build/distributions/$version-$architecture"
app_dir="$release_dir/OpenRayneoBridge.app"
archive="$release_dir/OpenRayneo-$version-macos-$architecture.zip"

# Start with an empty staging directory; never include a developer's existing app.
if [ -e "$release_dir" ]; then
    printf 'Output already exists: %s\nMove it aside before packaging again.\n' "$release_dir" >&2
    exit 1
fi
mkdir -p "$release_dir"
OPENRAYNEO_APP_DIR="$app_dir" OPENRAYNEO_SIGNING_IDENTITY=- sh "$workspace_dir/scripts/build-app.sh"
plutil -lint "$app_dir/Contents/Info.plist"
lipo "$app_dir/Contents/MacOS/openrayneo-bridge" -verify_arch "$architecture"
codesign --verify --strict "$app_dir"
ditto -c -k --keepParent --norsrc --noextattr "$app_dir" "$archive"
printf 'Release archive: %s\n' "$archive"
