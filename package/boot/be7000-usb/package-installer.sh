#!/usr/bin/env bash
set -euo pipefail
output=$1 platform=$2 epoch=$3
package=$(cd "$(dirname "$0")" && pwd)
case "$platform" in linux) launcher=install.sh;; windows) launcher=install.cmd;; *) exit 2;; esac
work=$(mktemp -d "${output}.installer.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
base=$work/BE7000-OpenWrt-Snapshot-Installer
mkdir -p "$base/installer"
# Keep build/debug metadata in the USB build artifact, not in the user installer.
mkdir "$work/firmware"
tar -xzf "$output" -C "$work/firmware"
for firmware in "$work"/firmware/BE7000-OpenWrt-Snapshot*; do
    rm -f "$firmware/README.txt" "$firmware/boot/README.kexec" \
        "$firmware"/boot/*.patch "$firmware/payload/System.map" \
        "$firmware/payload/target-layout.json" "$firmware/payload/stock-sender/module-options"
done
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" \
    -C "$work/firmware" -czf "$base/firmware.tar.gz" .
cp "$package/installer/$launcher" "$base/"
cp "$package/installer/router-install.sh" "$package/installer/autostart.sh" "$package/installer/hook.sh" "$base/installer/"
chmod 755 "$base"/*.sh "$base/installer"/*.sh 2>/dev/null || true
if [[ $platform == windows ]]; then
    sed 's/$/\r/' "$package/installer/install.cmd" > "$base/install.cmd"
fi
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -C "$work" -czf "$output" "${base##*/}"
