#!/bin/sh
# Stock-side installation. Old OpenWrt is mounted read-only to export settings.
set -eu
set -o pipefail
umask 022
mode=$1 auto=$2 dev=$3 usb=$4
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
image=$here/../firmware.bin
base=$usb/BE7000-OpenWrt-Snapshot
next=$base/.upgrade-next
work=$usb/.be7000-snapshot-install
fail() { echo "ERROR: $*" >&2; exit 1; }
case "$mode:$auto" in update:yes|update:no|fresh:yes|fresh:no) ;; *) fail 'Invalid installation mode';; esac
case "$usb" in /mnt/usb-*) ;; *) fail 'Invalid stock USB mount';; esac
[ "$(readlink -f "$usb")" = "$usb" ] && [ ! -L "$base" ] || fail 'Redirected installation directory.'
[ ! -e "$base" ] || [ -d "$base" ] || fail 'Installation path is not a directory.'
case "$(cat /tmp/be7000-kexec-quiesce.phase 2>/dev/null || :)" in
    quiescing|transition|failed:*) fail 'Restart stock before another installation.';;
esac
pid=$(cat /tmp/be7000-kexec-quiesce.pid 2>/dev/null || :)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail 'A boot transition is already running.'
fi
[ ! -e "$base/.upgrade-pending" ] || fail 'A previous update must finish at boot first.'
[ ! -e "$next" ] && [ ! -L "$next" ] || fail 'Previous .upgrade-next remains; remove it before retrying.'
sh "$here/be7000-usb-upgrade" verify "$image"
userdata_mib=256
if [ "$mode" = update ]; then
    data_bytes=$(ls -ln "$base/userdata.img" | awk '{print $5}')
    userdata_mib=$((data_bytes / 1048576))
    case "$userdata_mib" in 256|512|1024|2048) ;; *) fail 'Unsupported userdata size';; esac
    [ "$data_bytes" -eq "$((userdata_mib * 1048576))" ] || fail 'Invalid userdata image size'
fi
[ "$(df -Pk "$usb" | awk 'END {print $4}')" -ge "$(((1024 + userdata_mib) * 1024))" ] ||
    fail 'Not enough free USB space for the new system and userdata.'
mkdir "$work" || fail 'Previous installation staging remains; remove it before retrying.'
mounts=
own_next=no
unmount_all() {
    while [ -n "$mounts" ]; do
        set -- $mounts
        umount "$1" || return
        shift
        mounts="$*"
    done
}
cleanup() {
    unmount_all || return
    if [ "$own_next" = yes ] && [ ! -e "$base/.upgrade-pending" ]; then
        rm -rf "$next"
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mount_at() {
    point=$1; shift
    mount "$@" "$point"
    mounts="$point $mounts"
}

backup=
if [ "$mode" = update ]; then
    echo 'Saving OpenWrt settings from USB...'
    mkdir "$work/old-system" "$work/old-data" "$work/old-root"
    mount_at "$work/old-system" -t ext4 -o loop,ro "$base/system.img"
    mount_at "$work/old-data" -t ext4 -o loop,ro "$base/userdata.img"
    mount_at "$work/old-root" -t overlay -o "ro,lowerdir=$work/old-data/upper:$work/old-system" overlay
    mount_at "$work/old-root/tmp" -t tmpfs -o mode=1777 tmpfs
    mount_at "$work/old-root/proc" -t proc proc
    mount_at "$work/old-root/dev" -o bind /dev
    chroot "$work/old-root" /sbin/sysupgrade -b /tmp/be7000-settings.tgz
    backup=$work/settings.tgz
    cp "$work/old-root/tmp/be7000-settings.tgz" "$backup"
fi

echo 'Preparing the new system and clean userdata...'
mkdir -p "$base"
mkdir "$next"
own_next=yes
tar -xOf "$image" sysupgrade-be7000/system.img.gz | gzip -dc > "$next/system.img"
for part in boot payload; do
    tar -xOf "$image" "sysupgrade-be7000/$part.tar.gz" > "$work/$part.tar.gz"
    tar -tzf "$work/$part.tar.gz" | awk -v p="$part/" '
        substr($0,1,length(p))!=p || /(^|\/)\.\.(\/|$)/ {bad=1}
        END {exit bad}' || fail 'Invalid firmware component paths.'
    tar -xzf "$work/$part.tar.gz" -C "$next"
done
mkdir "$work/new-system" "$work/new-data"
mount_at "$work/new-system" -t ext4 -o loop,ro "$next/system.img"
[ -x "$work/new-system/usr/libexec/be7000-usb-upgrade" ] || fail 'This image lacks USB sysupgrade support.'
# Use the image's own ext4 utility and libraries, independent of stock tools.
dd if=/dev/zero of="$next/userdata.img" bs=1048576 count=0 seek="$userdata_mib" 2>/dev/null
MKE2FS_CONFIG="$work/new-system/etc/mke2fs.conf" \
    "$work/new-system/lib/ld-musl-aarch64.so.1" \
    --library-path "$work/new-system/lib:$work/new-system/usr/lib" \
    "$work/new-system/usr/sbin/mke2fs" -q -t ext4 -F -b 4096 -m 0 \
    -O '^orphan_file,^metadata_csum_seed' -E lazy_itable_init=0,lazy_journal_init=0 \
    -L be7000-userdata "$next/userdata.img"
mount_at "$work/new-data" -t ext4 -o loop,rw "$next/userdata.img"
mkdir "$work/new-data/upper" "$work/new-data/work"
cp "$work/new-system/etc/be7000-system-id" "$work/new-data/base-id"
upper=$work/new-data/upper
sh "$here/be7000-usb-upgrade" restore "$upper" "$backup"
for item in IPQ9574/caldata.bin qcn9224/caldata_3.bin; do
    source=/tmp/$item
    [ -s "$source" ] || source=/lib/firmware/$item
    [ -s "$source" ] || fail "Stock calibration missing: $item"
    case "$item" in
        IPQ9574/*) size=131072; target=ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin;;
        qcn9224/*) size=184320; target=ath12k/QCN9274/hw2.0/cal-pci-0002:01:00.0.bin;;
    esac
    [ "$(wc -c < "$source")" = "$size" ] || fail "Invalid calibration size: $item"
    mkdir -p "$upper/lib/firmware/$(dirname "$target")"
    cp "$source" "$upper/lib/firmware/$target"
done
# UUID is read from the ext4 superblock; stock does not always ship blkid.
hex=$(dd if="$dev" bs=1 skip=1128 count=16 2>/dev/null | hexdump -v -e '16/1 "%02x"')
[ "${#hex}" = 32 ] || fail 'Unable to read USB UUID.'
uuid=$(printf '%s' "$hex" | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
printf 'USB_UUID=%s\nDIAGNOSTIC=0\n' "$uuid" > "$next/boot/launch.conf"
chmod 755 "$next/boot/"*.sh "$next/boot/kexec"
sync
unmount_all

# A stock reboot can resume a replacement interrupted after this point.
if [ -f "$base/boot/start.sh" ] && ! grep -q '^# Resume USB update$' "$base/boot/start.sh"; then
    {
        head -n 1 "$base/boot/start.sh"
        sed -n '/^# Resume USB update$/,/^# End USB update$/p' "$next/boot/start.sh"
        tail -n +2 "$base/boot/start.sh"
    } > "$base/boot/start.sh.new"
    chmod 755 "$base/boot/start.sh.new"
    mv -f "$base/boot/start.sh.new" "$base/boot/start.sh"
fi
cp "$next/boot/activate-upgrade.sh" "$base/.upgrade-activate.sh"
touch "$next/READY"
sync
touch "$base/.upgrade-pending"
sync
sh "$base/.upgrade-activate.sh" "$base"
touch "$base/READY"

state=/data/BE7000-OpenWrt-Snapshot
mkdir -p "$state"
cp "$here/autostart.sh" "$state/autostart.sh"
cp "$here/hook.sh" "$state/hook.sh"
printf '%s\n' "$uuid" > "$state/usb.uuid"
chmod 700 "$state" "$state/autostart.sh" "$state/hook.sh"
uci set firewall.be7000_snapshot=include
uci set firewall.be7000_snapshot.type=script
uci set firewall.be7000_snapshot.path="$state/hook.sh"
uci set firewall.be7000_snapshot.reload=0
if [ "$auto" = yes ]; then uci set firewall.be7000_snapshot.enabled=1
else uci set firewall.be7000_snapshot.enabled=0; fi
if uci -q get firewall.be7000_openwrt >/dev/null; then
    uci set firewall.be7000_openwrt.enabled=0
fi
uci commit firewall
rm -f "$base/boot/boot-pending" "$base/boot/autostart-disabled"
sync
echo 'Installation complete. Starting OpenWrt...'
sh "$base/boot/start.sh"
