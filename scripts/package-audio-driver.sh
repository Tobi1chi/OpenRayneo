#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
set -eu
workspace_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
driver_dir=${OPENRAYNEO_DRIVER_DIR:-"$workspace_dir/.build/audio-driver/OpenRayneoAudio.driver"}
package_path=${OPENRAYNEO_DRIVER_PACKAGE:-"$workspace_dir/.build/audio-driver/OpenRayneoAudio.pkg"}
package_work=$(mktemp -d /tmp/openrayneo-driver-package.XXXXXX)
trap 'rm -rf "$package_work"' EXIT
package_stage="$package_work/payload"
package_scripts="$package_work/scripts"
package_metadata="$package_work/components.plist"
mkdir -p "$package_stage/Library/Audio/Plug-Ins/HAL" "$package_scripts" "$(dirname -- "$package_path")"
ditto "$driver_dir" "$package_stage/Library/Audio/Plug-Ins/HAL/OpenRayneoAudio.driver"
cat > "$package_scripts/postinstall" <<'EOF'
#!/bin/sh
set -eu
launchctl kickstart -kp system/com.apple.audio.coreaudiod >/dev/null 2>&1 || killall coreaudiod >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$package_scripts/postinstall"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$driver_dir/Contents/Info.plist")
pkgbuild --analyze --root "$package_stage" "$package_metadata"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$package_metadata"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$package_metadata"
pkgbuild --root "$package_stage" --scripts "$package_scripts" --identifier com.openrayneo.audio.driver \
    --component-plist "$package_metadata" --version "$version" --install-location / --ownership recommended "$package_path"
printf 'Built %s\n' "$package_path"
