#!/bin/sh
case "${1:-}" in
    start) (trap '' HUP; exec sh "$0" run) </dev/null >/tmp/be7000-snapshot-autostart.log 2>&1 & exit 0;;
    run) ;;
    *) exit 2;;
esac
set -eu
mkdir /tmp/be7000-autostart.lock 2>/dev/null || exit 0
[ ! -e /tmp/be7000-installing ] || exit 0
uuid=$(cat /data/BE7000-OpenWrt-Snapshot/usb.uuid)
expected=$(printf '%s' "$uuid" | tr -d '-')
[ "${#expected}" = 32 ] || exit 1
for attempt in $(seq 1 90); do
    [ ! -e /tmp/be7000-installing ] || exit 0
    if [ -f /tmp/boot_check_done ] && [ "$(cat /proc/xiaoqiang/boot_status 2>/dev/null)" = 3 ]; then
        while read -r dev mount fs options rest; do
            case "$dev:$mount:$fs" in /dev/sd*:/mnt/usb-*:ext4) ;; *) continue;; esac
            actual=$(dd if="$dev" bs=1 skip=1128 count=16 2>/dev/null | hexdump -v -e '16/1 "%02x"')
            [ "$actual" = "$expected" ] || continue
            base=$mount/BE7000-OpenWrt-Snapshot
            [ -f "$base/READY" ] && [ ! -e "$base/boot/autostart-disabled" ] || exit 0
            count=$(cat "$base/boot/boot-pending" 2>/dev/null || echo 0)
            case "$count" in 0|1|2) ;; *) echo 'Three unconfirmed boots; staying in stock.'; exit 0;; esac
            printf '%s\n' "$((count + 1))" > "$base/boot/boot-pending"
            sync
            exec sh "$base/boot/start.sh"
        done < /proc/mounts
    fi
    sleep 2
done
echo 'USB or stock startup not ready; staying in stock.'
