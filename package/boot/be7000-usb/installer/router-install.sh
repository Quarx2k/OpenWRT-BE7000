#!/bin/sh
# Runs on Xiaomi stock, not on the PC. Never formats storage or replaces userdata.
set -eu
fail() { echo "ERROR: $*" >&2; exit 1; }
case "${1:-}" in yes|no) auto=$1;; *) fail 'Expected autostart yes/no';; esac
[ "$(uname -r)" = 5.4.164 ] || fail 'Boot Xiaomi stock firmware before installing.'
case "$(uname -v)" in
    '#0 SMP PREEMPT Mon Jan 22 02:33:42 2024'|'#0 SMP PREEMPT Tue Jan 27 03:33:27 2026') ;;
    *) fail 'Supported stock versions: Xiaomi 1.1.16 and 1.1.38.';;
esac
grep -q 'xiaomi,be7000\|BE7000\|RA72' /proc/device-tree/model /proc/device-tree/compatible 2>/dev/null ||
    [ -e /tmp/IPQ9574/caldata.bin ] || fail 'BE7000 calibration is not available.'
case "$(cat /tmp/be7000-kexec-quiesce.phase 2>/dev/null || :)" in
    quiescing|transition|failed:*) fail 'Restart stock before another installation.';;
esac
pid=$(cat /tmp/be7000-kexec-quiesce.pid 2>/dev/null || :)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail 'A boot transition is already running.'
fi
mounts=$(awk '$1 ~ /^\/dev\/sd/ && $2 ~ /^\/mnt\/usb-/ && $3 == "ext4" && $4 ~ /(^|,)rw(,|$)/ { print $1, $2 }' /proc/mounts)
[ "$(printf '%s\n' "$mounts" | grep -c '^/dev/' || :)" = 1 ] ||
    fail 'Connect exactly one mounted ext4 USB partition. No disks will be formatted.'
set -- $mounts
dev=$1 usb=$2
case "$usb" in *[!a-zA-Z0-9_/-]*) fail 'Unsupported USB mount path';; esac
base=$usb/BE7000-OpenWrt-Snapshot
[ ! -L "$base" ] || fail 'Installation directory must not be a symlink.'
here=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
stage=$usb/.be7000-snapshot-install
mkdir "$stage" || fail 'Previous staging directory exists; remove it before retrying.'
data_mount=
cleanup() {
    if [ -n "$data_mount" ]; then umount "$data_mount" || return; fi
    # Only this invocation's staging directory, always below the chosen USB mount.
    rm -rf "$stage"
}
trap cleanup EXIT
tar -xzf "$here/firmware.tar.gz" -C "$stage"
set -- "$stage"/BE7000-OpenWrt-Snapshot*
[ "$#" = 1 ] && [ -d "$1" ] || fail 'Expected one BE7000 snapshot bundle.'
new=$1
for f in system.img userdata.img boot/start.sh boot/kexec payload/Image payload/be7000-spin-table.dtb; do
    [ -s "$new/$f" ] || fail "Bundle is missing $f (use an installer-capable build)."
done
[ ! -L "$base/userdata.img" ] && [ ! -L "$base/device" ] && [ ! -L "$base/boot" ] &&
    [ ! -L "$base/payload" ] || fail 'Installation files must not be redirected.'
mkdir -p "$base/device/calibration/IPQ9574" "$base/device/calibration/qcn9224" "$base/boot" "$base/payload"
chmod 755 "$base" "$base/device" "$base/boot" "$base/payload"
rm -f "$base/READY"
if [ -f "$new/native-wlan" ]; then
    for item in IPQ9574/caldata.bin qcn9224/caldata_3.bin; do
        source=/tmp/$item
        [ -s "$source" ] || source=/lib/firmware/$item
        [ -s "$source" ] || fail "Stock calibration missing: $item"
        cp "$source" "$base/device/calibration/$item"
    done
    [ "$(wc -c < "$base/device/calibration/IPQ9574/caldata.bin")" = 131072 ] || fail 'Invalid 2.4 GHz calibration size.'
    [ "$(wc -c < "$base/device/calibration/qcn9224/caldata_3.bin")" = 184320 ] || fail 'Invalid 5 GHz calibration size.'
fi
# UUID is read from the ext4 superblock; stock does not always ship blkid.
hex=$(dd if="$dev" bs=1 skip=1128 count=16 2>/dev/null | hexdump -v -e '16/1 "%02x"')
[ "${#hex}" = 32 ] || fail 'Unable to read USB UUID.'
uuid=$(printf '%s' "$hex" | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
if [ ! -e "$base/userdata.img" ]; then mv "$new/userdata.img" "$base/userdata.img"; fi
# Fresh calibration overrides any per-device data left by older builds.
if [ -f "$new/native-wlan" ]; then
    mkdir "$stage/userdata"
    mount -t ext4 -o loop,rw "$base/userdata.img" "$stage/userdata"
    data_mount=$stage/userdata
    upper=$data_mount/upper
    mkdir -p "$upper/lib/firmware/ath11k/IPQ9574/hw1.0" "$upper/lib/firmware/ath12k/QCN9274/hw2.0"
    cp "$base/device/calibration/IPQ9574/caldata.bin" "$upper/lib/firmware/ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin"
    cp "$base/device/calibration/qcn9224/caldata_3.bin" "$upper/lib/firmware/ath12k/QCN9274/hw2.0/cal-pci-0002:01:00.0.bin"
    sync
    umount "$data_mount"
    data_mount=
fi
cp -R "$new/payload/." "$base/payload/"
cp -R "$new/boot/." "$base/boot/"
printf 'USB_UUID=%s\nDIAGNOSTIC=0\n' "$uuid" > "$base/boot/launch.conf"
mv "$new/system.img" "$base/system.img"
touch "$base/READY"
state=/data/BE7000-OpenWrt-Snapshot
mkdir -p "$state"
cp "$here/installer/autostart.sh" "$state/autostart.sh"
cp "$here/installer/hook.sh" "$state/hook.sh"
printf '%s\n' "$uuid" > "$state/usb.uuid"
chmod 700 "$state" "$state/autostart.sh" "$state/hook.sh"
uci set firewall.be7000_snapshot=include
uci set firewall.be7000_snapshot.type=script
uci set firewall.be7000_snapshot.path="$state/hook.sh"
uci set firewall.be7000_snapshot.reload=0
if [ "$auto" = yes ]; then
    uci set firewall.be7000_snapshot.enabled=1
else
    uci set firewall.be7000_snapshot.enabled=0
fi
# Only one BE7000 USB launcher may run at boot. Keep old installations on USB.
if uci -q get firewall.be7000_openwrt >/dev/null; then
    uci set firewall.be7000_openwrt.enabled=0
fi
uci commit firewall
rm -f "$base/boot/boot-pending" "$base/boot/autostart-disabled"
sync
echo 'Installed. Saved OpenWrt settings were preserved. Starting OpenWrt...'
sh "$base/boot/start.sh"
