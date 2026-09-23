#!/usr/bin/env bash
set -euo pipefail
output=$1 platform=$2 epoch=$3
package=$(cd "$(dirname "$0")" && pwd)
topdir=$(cd "$package/../../.." && pwd)
case "$platform" in linux) launcher=install.sh;; windows) launcher=install.cmd;; *) exit 2;; esac
work=$(mktemp -d "${output}.installer.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
base=$work/BE7000-OpenWrt-Snapshot-Installer
mkdir -p "$base/installer"
# One standard firmware image is used by both stock and live OpenWrt.
cp "$output" "$base/firmware.bin"
cp "$package/installer/$launcher" "$base/"
cp "$package/installer/router-install.sh" "$package/installer/stock-install.sh" \
    "$package/installer/autostart.sh" "$package/installer/hook.sh" \
    "$package/files/be7000-usb-upgrade" "$base/installer/"
cp "$topdir/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh" "$base/installer/"
chmod 755 "$base"/*.sh "$base/installer"/*.sh 2>/dev/null || true
if [[ $platform == windows ]]; then
    sed 's/\r$//;s/$/\r/' "$package/installer/install.cmd" > "$base/install.cmd"
fi
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -C "$work" -czf "$output" "${base##*/}"
