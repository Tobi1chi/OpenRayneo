#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
# Export platform icon formats from the shared transparent artwork on macOS.
set -eu
workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$workspace_dir/assets/icons/openrayneo.png"
iconset="$workspace_dir/.build/icons/OpenRayneo.iconset"
mkdir -p "$iconset" "$workspace_dir/android/app/src/main/res/drawable-nodpi"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$workspace_dir/assets/icons/OpenRayneo.icns"
sips -z 432 432 "$source" --out "$workspace_dir/android/app/src/main/res/drawable-nodpi/ic_brand_mark.png" >/dev/null
printf '%s\n' 'Exported macOS ICNS and Android transparent foreground.'
