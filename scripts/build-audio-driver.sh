#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
set -eu
workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
driver_dir=${OPENRAYNEO_DRIVER_DIR:-"$workspace_dir/.build/audio-driver/OpenRayneoAudio.driver"}
mkdir -p "$driver_dir/Contents/MacOS"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=13.0 -bundle -fvisibility=hidden \
    -framework CoreFoundation -framework CoreAudio \
    "$workspace_dir/Drivers/OpenRayneoAudio/OpenRayneoAudio.c" \
    -o "$driver_dir/Contents/MacOS/OpenRayneoAudio"
cp "$workspace_dir/Drivers/OpenRayneoAudio/Info.plist" "$driver_dir/Contents/Info.plist"
codesign --force --sign "${OPENRAYNEO_SIGNING_IDENTITY:--}" --identifier com.openrayneo.audio.driver "$driver_dir"
codesign --verify --strict "$driver_dir"
printf 'Built %s\n' "$driver_dir"
