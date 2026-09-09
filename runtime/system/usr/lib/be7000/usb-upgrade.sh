#!/bin/sh
# USB-only platform upgrade. Never write a block device or firmware partition.
set -eu
set -o pipefail
base=/mnt/usb/BE7000-OpenWrt
prefix=sysupgrade-be7000
files='system.img.gz userdata.img.gz manifest.json provenance.json
payload/01-load-only.sh payload/02-execute.sh payload/02-quiesce-stage2.sh
payload/03-cancel.sh payload/06-check-layout.sh payload/Image payload/System.map
payload/kexec payload/kexec_mod.ko payload/kexec_mod_arm64.ko payload/target-layout.json'
fail() { echo "BE7000 sysupgrade: $*" >&2; exit 1; }

usb_identity() {
    dev=$(awk '$2=="/mnt/usb" && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {print $1; exit}' /proc/mounts)
    case "$dev" in /dev/sd*) ;; *) fail 'Writable USB filesystem not mounted';; esac
    case "$(readlink -f /sys/class/block/${dev##*/})" in */usb*) ;; *) fail 'Not a USB device';; esac
    uuid=$(blkid -s UUID -o value "$dev")
    case "$uuid" in ''|*[!0-9a-f-]*) fail 'Invalid USB UUID';; esac
    [ "${#uuid}" = 36 ] || fail 'Invalid USB UUID'
    [ "$(readlink -f "$base")" = "$base" ] || fail 'Redirected installation directory'
}

layout() {
    [ -f "$base/USB_SLOTS_V1" ] || fail 'Recreate this installation with the updated installer first (USB slots required)'
    [ ! -L "$base/slots" ] || fail 'Redirected slots directory'
    active=$(readlink "$base/current")
    case "$active" in slots/a) next=b;; slots/b) next=a;; *) fail 'Invalid active slot';; esac
    for name in system.img userdata.img payload; do
        [ "$(readlink "$base/$name")" = "current/$name" ] || fail "Invalid $name alias"
    done
    [ ! -L "$base/$active" ] && [ -d "$base/$active" ] || fail 'Invalid active directory'
    [ ! -L "$base/slots/$next" ] || fail 'Redirected inactive directory'
    # A second update without reboot must not overwrite the still-running slot.
    for loop in /sys/block/loop*/loop/backing_file; do
        [ -r "$loop" ] || continue
        case "$(cat "$loop")" in */BE7000-OpenWrt/slots/"$next"/*) fail 'Inactive slot is still in use; reboot first';; esac
    done
    awk -v p="$base/slots/$next" '$2==p || index($2,p"/")==1 {busy=1} END {exit busy}' /proc/mounts || fail 'Inactive slot has mounted filesystems'
    awk -v p="$base/slots/$next" '$1==p || index($1,p"/")==1 {busy=1} END {exit busy}' /proc/swaps || fail 'Inactive slot has active swap'
}

check_image() {
    image=$1
    command -v losetup >/dev/null || fail 'The losetup package is required'
    command -v mke2fs >/dev/null || fail 'The e2fsprogs package is required'
    [ "$(cat /tmp/sysinfo/board_name)" = 'xiaomi,be7000' ] || fail 'Wrong board'
    grep -q 'boot_source=kexec' /proc/cmdline || fail 'Not running the USB OpenWrt system'
    usb_identity
    grep -q "be7000_usb_uuid=$uuid" /proc/cmdline || fail 'Boot USB UUID mismatch'
    layout
    data_bytes=$(ls -ln "$base/$active/userdata.img" | awk '{print $5}')
    userdata_mib=$((data_bytes / 1048576))
    case "$userdata_mib" in 256|512|1024|2048) ;; *) fail 'Unsupported storage size';; esac
    [ "$data_bytes" -eq "$((userdata_mib * 1048576))" ] || fail 'Invalid userdata image size'
    meta=$(mktemp /tmp/be7000-image.XXXXXX)
    fwtool -q -i "$meta" "$image" || { rm -f "$meta"; fail 'Invalid firmware metadata'; }
    format=$(jsonfilter -i "$meta" -e '@.be7000_format')
    board=$(jsonfilter -i "$meta" -e '@.supported_devices[0]')
    rm -f "$meta"
    [ "$format" = 'be7000-usb-sysupgrade-v1' ] && [ "$board" = 'xiaomi,be7000' ] || fail 'Incompatible firmware metadata'
    [ "$(tar -xOf "$image" "$prefix/FORMAT")" = 'be7000-usb-sysupgrade-v1' ] || fail 'Wrong image format'
    expected=$(printf '%s\n' "$prefix/FORMAT" "$prefix/FILES"; for name in $files; do echo "$prefix/$name"; done)
    [ "$(tar -tf "$image")" = "$expected" ] || fail 'Unexpected or duplicate archive members'
    manifest=$(tar -xOf "$image" "$prefix/FILES")
    [ "$(printf '%s\n' "$manifest" | awk '{print $2}')" = "$(printf '%s\n' $files)" ] || fail 'Invalid file manifest'
    for name in $files; do
        size=$(printf '%s\n' "$manifest" | awk -v n="$name" '$2==n {print $1}')
        case "$size" in ''|*[!0-9]*) fail "Invalid size for $name";; esac
        [ "$size" -gt 0 ] && [ "$size" -le 134217728 ] || fail "Oversized component $name"
        [ "$(tar -xOf "$image" "$prefix/$name" | wc -c)" -eq "$size" ] || fail "Incomplete component $name"
    done
    free=$(df -Pk /mnt/usb | awk 'END {print $4}')
    reclaim=0
    [ ! -d "$base/slots/$next" ] || reclaim=$(du -sk "$base/slots/$next" | awk '{print $1}')
    needed=$((536870912 / 1024 + userdata_mib * 1024 + 524288))
    [ "$((free + reclaim))" -ge "$needed" ] || fail 'Not enough free USB space for this update'
}

stage() {
    check_image "$1"
    mkdir -p "$base/boot"
    exec >> "$base/boot/sysupgrade.log" 2>&1
    echo 'Preparing USB sysupgrade'
    slot="$base/slots/$next"
    rm -rf "$slot"
    mkdir -p "$slot/payload"
    chmod 700 "$slot" "$slot/payload"
    for name in $files; do
        tar -xOf "$image" "$prefix/$name" > "$slot/$name"
    done
    gzip -dc "$slot/system.img.gz" > "$slot/system.img"
    # Keep userdata.img.gz in the archive for older USB upgrade implementations.
    # This updater creates a fresh overlay at the size of the current installation.
    rm "$slot/system.img.gz" "$slot/userdata.img.gz"
    [ "$(wc -c < "$slot/system.img")" -eq 536870912 ] || fail 'Invalid system image size'
    dd if=/dev/zero of="$slot/userdata.img" bs=1048576 count=0 seek="$userdata_mib"
    mke2fs -q -t ext4 -F -b 4096 -m 0 -O '^orphan_file,^metadata_csum_seed' \
        -E lazy_itable_init=0,lazy_journal_init=0 -L be7000-userdata "$slot/userdata.img"
    cp "$base/payload/launch.conf" "$slot/payload/launch.conf"
    cp "$base/payload/be7000-spin-table.dtb" "$slot/payload/be7000-spin-table.dtb"
    chmod 700 "$slot/payload/"*.sh "$slot/payload/kexec"
    sysloop=; dataloop=
    cleanup() {
        umount /tmp/be7000-upgrade-system 2>/dev/null || true
        umount /tmp/be7000-upgrade-data 2>/dev/null || true
        [ -z "$sysloop" ] || losetup -d "$sysloop"
        [ -z "$dataloop" ] || losetup -d "$dataloop"
    }
    trap cleanup EXIT
    mkdir -p /tmp/be7000-upgrade-system /tmp/be7000-upgrade-data
    sysloop=$(losetup -f); losetup -r "$sysloop" "$slot/system.img"
    mount -t ext4 -o ro "$sysloop" /tmp/be7000-upgrade-system
    dataloop=$(losetup -f); losetup "$dataloop" "$slot/userdata.img"
    mount -t ext4 -o rw "$dataloop" /tmp/be7000-upgrade-data
    mkdir /tmp/be7000-upgrade-data/upper /tmp/be7000-upgrade-data/work
    cp /tmp/be7000-upgrade-system/etc/be7000-system-id /tmp/be7000-upgrade-data/base-id
    [ -x /tmp/be7000-upgrade-system/usr/lib/be7000/usb-upgrade.sh ] || fail 'Image lacks USB upgrade support'
    if [ -n "${2:-}" ]; then
        tar -xzf "$2" -C /tmp/be7000-upgrade-data/upper
    fi
    sync
    cleanup
    trap - EXIT
    printf '%s\n' "$uuid" "$active" "$next" > /tmp/be7000-upgrade-state
    touch "$slot/READY"
    sync
    echo "BE7000 sysupgrade: slot $next prepared; $active remains active"
}

commit() {
    saved_uuid=$(sed -n '1p' /tmp/be7000-upgrade-state)
    saved_active=$(sed -n '2p' /tmp/be7000-upgrade-state)
    saved_next=$(sed -n '3p' /tmp/be7000-upgrade-state)
    case "$saved_uuid" in ''|*[!0-9a-f-]*) fail 'Invalid saved UUID';; esac
    [ "${#saved_uuid}" = 36 ] || fail 'Invalid saved UUID'
    if ! awk '$2=="/mnt/usb" {found=1} END {exit !found}' /proc/mounts; then
        dev=$(blkid -U "$saved_uuid")
        case "$dev" in /dev/sd*) ;; *) fail 'USB device unavailable';; esac
        mkdir -p /mnt/usb
        mount -t ext4 -o rw "$dev" /mnt/usb
    fi
    usb_identity
    [ "$uuid" = "$saved_uuid" ] || fail 'USB changed during upgrade'
    exec >> "$base/boot/sysupgrade.log" 2>&1
    layout
    [ "$active" = "$saved_active" ] && [ "$next" = "$saved_next" ] || fail 'Active slot changed during upgrade'
    [ -f "$base/slots/$next/READY" ] || fail 'Inactive slot not prepared'
    if [ -L "$base/current.new" ]; then
        case "$(readlink "$base/current.new")" in slots/a|slots/b) rm "$base/current.new";; *) fail 'Unexpected temporary pointer';; esac
    fi
    [ ! -e "$base/current.new" ] || fail 'Unexpected temporary pointer'
    ln -s "slots/$next" "$base/current.new"
    mv -Tf "$base/current.new" "$base/current"
    sync
    echo "BE7000 sysupgrade: activated slots/$next; previous $active retained"
}

case "${1:-}" in
    check) check_image "$2";;
    stage) stage "$2" "${3:-}";;
    commit) commit;;
    *) fail 'Usage: usb-upgrade.sh check IMAGE | stage IMAGE [BACKUP] | commit';;
esac
