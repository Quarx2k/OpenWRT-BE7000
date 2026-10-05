#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = xiaomi,be7000-nand ]; then
	command -v owut >/dev/null
	. /lib/be7000-nand.sh
	be7000_nand_guard
	case "${1:-}" in
		prepare)
			mkdir backup
			sysupgrade -b backup/settings.tar.gz >&2
			cp /lib/upgrade/nand.sh backup/nand.sh
			cat /sys/class/ubi/ubi0/mtd_num >backup/active-mtd
			chmod +x installer/fix-sysupgrade.sh
			echo 'OpenWrt NAND detected. Saving settings to your computer...' >&2
			tar -cf - backup
			;;
		flash)
			[ "$(cat backup/active-mtd)" = "$(cat /sys/class/ubi/ubi0/mtd_num)" ]
			[ -s backup/settings.tar.gz ]
			awk '
				/return this.rev_num\(\) < from.rev_num\(\);/ {
					print "\t\tif (this.is_snapshot() && from.is_snapshot() && (match(this.rev_code, /^r[0-9]+\\+[0-9]+-/) || match(from.rev_code, /^r[0-9]+\\+[0-9]+-/)))"
					print "\t\t\treturn version_older(this.kernel, from.kernel);"
				}
				{ print }
			' "$(command -v owut)" >backup/owut
			chmod +x backup/owut
			owut=$PWD/backup/owut
			echo 'Building an ASU image with your installed packages. Settings will be kept.'
			repo=/etc/apk/repositories.d/be7000.list
			if [ -f "$repo" ]; then
				cp "$repo" backup/be7000.list
				trap 'cp backup/be7000.list "$repo"' EXIT
				sed '/^https:\/\/openwrt\.quarx2k\.dev\/packages\/r[^/]*\/qualcommbe\/ipq95xx\/packages\.adb$/d' backup/be7000.list >"$repo"
			fi
			"$owut" dump -v -v >backup/asu-packages.json
			missing=$(ucode -e '
				import { readfile } from "fs";
				let data = json(readfile(ARGV[0]));
				for (let name, pkg in data.packageDB)
					if (pkg.top_level && !pkg.default && !pkg.new_version)
						print(name, "\n");
			' backup/asu-packages.json)
			set -- --image "$PWD/asu-sysupgrade.bin"
			if [ -n "$missing" ]; then
				echo 'These packages are unavailable in ASU and will be removed after the upgrade:'
				printf '%s\n' "$missing"
				echo 'Their saved settings will be kept. No packages have been removed yet.'
				printf 'Type YES to continue without these packages, or anything else to cancel: '
				read -r confirm
				[ "$confirm" = YES ] || { echo 'Cancelled. Firmware was not changed.'; exit 1; }
				for name in $missing; do
					set -- "$@" --remove "$name"
				done
			fi
			"$owut" download "$@"
			[ ! -f backup/be7000.list ] || cp backup/be7000.list "$repo"
			trap - EXIT
			[ -s asu-sysupgrade.bin ]
			"$owut" install --image "$PWD/asu-sysupgrade.bin" --pre-install "$PWD/installer/fix-sysupgrade.sh"
			;;
		*) echo 'Usage: router-install.sh prepare|flash' >&2; exit 1;;
	esac
	exit 0
fi
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
