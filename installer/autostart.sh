#!/bin/sh
# Xiaomi firewall include: detach immediately; never block fw3 or boot_check.
case "${1:-}" in
start)
    (trap '' HUP; exec sh /data/BE7000-OpenWrt/autostart.sh run) > /tmp/be7000-autostart.log 2>&1 < /dev/null &
    exit 0
    ;;
run) ;;
*) exit 2 ;;
esac
umask 077
# Keep the lock even after a skip/failure: only a reboot allows another attempt.
mkdir /tmp/be7000-autostart.lock 2>/dev/null || exit 0
set -eu
say() { echo "BE7000 autostart: $*"; }
skip() { say "$*; staying in Xiaomi"; exit 0; }
# @BE7000_KERNEL_PROFILE@
be7000_kernel_profile || skip 'Unsupported kernel'
say "Selected Xiaomi $KERNEL_FIRMWARE kernel profile"
uuid=$(cat /data/BE7000-OpenWrt/usb.uuid)
case "$uuid" in ''|*[!0-9a-f-]*) skip 'Invalid USB UUID';; esac
[ "${#uuid}" = 36 ] || skip 'Invalid USB UUID'
expected=$(echo "$uuid" | tr -d '-')

# This marker is written after Xiaomi finishes its own successful-boot handling.
left=120
while [ ! -f /tmp/boot_check_done ] || [ "$(cat /proc/xiaoqiang/boot_status 2>/dev/null)" != 3 ]; do
    [ "$left" -gt 0 ] || skip 'Xiaomi boot did not complete'
    sleep 2
    left=$((left - 2))
done

find_usb() {
    while read -r dev mount fs options rest; do
        case "$dev" in /dev/sd*) ;; *) continue;; esac
        case "$mount" in /mnt/usb-*) ;; *) continue;; esac
        case "$mount" in *[!a-zA-Z0-9_/-]*) continue;; esac
        [ "$fs" = ext4 ] || continue
        case ",$options," in *,rw,*) ;; *) continue;; esac
        case ",$options," in *,noexec,*) continue;; esac
        case "$(readlink -f /sys/class/block/${dev##*/})" in */usb*) ;; *) continue;; esac
        actual=$(dd if="$dev" bs=1 skip=1128 count=16 2>/dev/null | hexdump -v -e '16/1 "%02x"')
        [ "$actual" = "$expected" ] || continue
        echo "$mount/BE7000-OpenWrt"
        return 0
    done < /proc/mounts
    return 1
}
left=120
while ! base=$(find_usb); do
    [ "$left" -gt 0 ] || skip 'USB not found'
    sleep 2
    left=$((left - 2))
done
[ "$(readlink -f "$base")" = "$base" ] || skip 'Redirected installation path'
state="$base/boot"
[ ! -L "$state" ] || skip 'Redirected boot directory'
mkdir -p "$state"
check_flags() {
    [ ! -f "$state/autostart-disabled" ] || skip 'Autostart disabled'
    if [ -f "$state/xiaomi-once" ]; then
        rm "$state/xiaomi-once"
        sync
        skip 'One-time Xiaomi boot requested'
    fi
}
check_flags
[ -f "$base/READY" ] && [ -s "$base/system.img" ] && [ -s "$base/userdata.img" ] &&
[ -s "$base/payload/launch.conf" ] || skip 'Installation incomplete'
# Older images lack success acknowledgement and must not be used automatically.
[ -f "$base/BOOT_CONTROL_V1" ] || skip 'Recreate with an autostart-capable image'
attempt=0
if [ -e "$state/boot-pending" ]; then
    attempt=$(cat "$state/boot-pending")
    case "$attempt" in 1|2) ;; 3) skip 'Three unconfirmed attempts';; *) skip 'Invalid attempt counter';; esac
fi
say 'Boot ready; transition in 10 seconds'
sleep 10
check_flags
[ "$(find_usb)" = "$base" ] || skip 'USB mount changed'
if [ -r /sys/kernel/kexec_loaded ]; then
    [ "$(cat /sys/kernel/kexec_loaded)" = 0 ] || skip 'Another kernel is already loaded'
fi
log="$state/logs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$log"
exec >> "$log/autostart.log" 2>&1
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$state/boot-pending.new"
mv "$state/boot-pending.new" "$state/boot-pending"
sync
say "Attempt $attempt of 3"
cd "$base/payload"
if ! sh ./01-load-only.sh LOAD-OWRT12-CANDIDATE; then
    say 'Kernel load failed; retry is allowed after reboot'
    exit 1
fi
cp loaded-state.txt "$log/loaded-state.txt"
if ! sh ./02-execute.sh EXECUTE-KEXEC-QUIESCED; then
    say 'Transition was not armed; cancelling loaded kernel'
    sh ./03-cancel.sh CANCEL-LOADED-KEXEC || true
    exit 1
fi
say 'Transition armed'
