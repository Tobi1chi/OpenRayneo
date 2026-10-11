#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
set -eu
workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
driver_dir=${OPENRAYNEO_DRIVER_DIR:-"$workspace_dir/.build/audio-driver/OpenRayneoAudio.driver"}
package_path=${OPENRAYNEO_DRIVER_PACKAGE:-"$workspace_dir/.build/audio-driver/OpenRayneoAudio.pkg"}
package_work=$(mktemp -d /tmp/openrayneo-driver-package.XXXXXX)
trap 'trash "$package_work"' EXIT
package_stage="$package_work/payload"
package_metadata="$package_work/components.plist"
mkdir -p "$package_stage/Library/Audio/Plug-Ins/HAL" "$(dirname -- "$package_path")"
ditto "$driver_dir" "$package_stage/Library/Audio/Plug-Ins/HAL/OpenRayneoAudio.driver"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$driver_dir/Contents/Info.plist")
pkgbuild --analyze --root "$package_stage" "$package_metadata"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$package_metadata"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$package_metadata"
pkgbuild --root "$package_stage" --identifier com.openrayneo.audio.driver \
    --component-plist "$package_metadata" --version "$version" --install-location / --ownership recommended "$package_path"
printf 'Built %s\n' "$package_path"
