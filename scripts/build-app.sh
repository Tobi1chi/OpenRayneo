#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0

set -eu

workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$workspace_dir/OpenRayneoBridge.app"

swift build --package-path "$workspace_dir" --configuration release
mkdir -p "$app_dir/Contents/MacOS"
cp "$workspace_dir/.build/release/openrayneo-bridge" "$app_dir/Contents/MacOS/openrayneo-bridge"
cp "$workspace_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier com.openrayneo.bridge "$app_dir"
printf 'Built %s\n' "$app_dir"
