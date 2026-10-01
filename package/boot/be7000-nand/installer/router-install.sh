#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
active=$(nvram get flag_boot_rootfs)
case "$active" in 0|1) ;; *) echo 'Cannot determine the active stock slot' >&2; exit 1;; esac
slot=$((1-active))
mtd=$((23+slot))
name=rootfs
[ "$slot" = 0 ] || name=rootfs_1
[ "$(cat "/sys/class/mtd/mtd$mtd/name")" = "$name" ]
[ "$(cat "/sys/class/mtd/mtd$mtd/size")" = 41943040 ]
[ -s factory.ubi ] && [ "$(wc -c <factory.ubi)" -lt 41943040 ]
for dir in /sys/class/ubi/ubi*; do
	[ -f "$dir/mtd_num" ] || continue
	[ "$(cat "$dir/mtd_num")" != "$mtd" ] || { echo 'Target slot is attached; stopping' >&2; exit 1; }
done
case "${1:-}" in
	prepare)
		mkdir backup
		printf '%s\n' "$active" >backup/active-slot
		echo "Active slot: $active. Target: slot $slot (mtd$mtd). Saving backups to your computer..." >&2
		cat /dev/mtd17 >backup/APPSBLENV.bin
		cat "/dev/mtd$mtd" >"backup/mtd$mtd.ubi"
		cat /dev/mtd28 >backup/overlay.ubi
		tar -cf - backup
		;;
	flash)
		[ "$(cat backup/active-slot)" = "$active" ]
		mkdir /tmp/be7000-nand-flash.lock
		trap 'rmdir /tmp/be7000-nand-flash.lock' EXIT
		echo "Installing into slot $slot (mtd$mtd)..."
		ubiformat "/dev/mtd$mtd" -f factory.ubi -s 2048 -O 2048 -y
		nvram set "flag_boot_rootfs=$slot"
		nvram set "flag_last_success=$slot"
		nvram set flag_boot_success=0
		nvram set flag_ota_reboot=0
		nvram set "flag_try_sys$((slot+1))_failed=0"
		nvram set config_name=config@al02-c6
		nvram commit
		sync
		echo 'Installed. Rebooting into OpenWrt; LAN address: 192.168.1.1'
		(sleep 3; reboot) </dev/null >/dev/null 2>&1 &
		;;
	*) echo 'Usage: router-install.sh prepare|flash' >&2; exit 1;;
esac
