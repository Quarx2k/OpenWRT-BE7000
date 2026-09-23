#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
mode=$1
shift

finish_ext4() {
	local rc=0
	# Finalize make_ext4fs bitmap padding before distributing the new image.
	E2FSPROGS_FAKE_TIME="$epoch" "$host/bin/e2fsck" -fy "$output" || rc=$?
	(( rc <= 1 ))
}

case "$mode" in
	sysupgrade)
		output=$1
		work=$(mktemp -d "${output}.work.XXXXXX")
		trap 'rm -rf -- "$work"' EXIT
		tar -xzf "$output" -C "$work"
		base=$(find "$work" -mindepth 1 -maxdepth 1 -type d)
		mkdir "$work/sysupgrade-be7000"
		upgrade=$work/sysupgrade-be7000
		printf 'be7000-snapshot-usb-v1\n' > "$upgrade/FORMAT"
		gzip -1 -c "$base/system.img" > "$upgrade/system.img.gz"
		tar -C "$base" -czf "$upgrade/boot.tar.gz" boot
		tar -C "$base" -czf "$upgrade/payload.tar.gz" payload
		(cd "$upgrade"; wc -c system.img.gz boot.tar.gz payload.tar.gz | head -n 3) > "$upgrade/FILES"
		tar -C "$work" -cf "$output" sysupgrade-be7000/FORMAT sysupgrade-be7000/FILES \
			sysupgrade-be7000/system.img.gz sysupgrade-be7000/boot.tar.gz sysupgrade-be7000/payload.tar.gz
		;;
	system)
		output=$1 host=$2 epoch=$3
		"$host/bin/tune2fs" -L be7000-system "$output"
		finish_ext4
		;;
	userdata)
		rootfs=$1 output=$2 host=$3 epoch=$4
		work=$(mktemp -d "${output}.work.XXXXXX")
		trap 'rm -rf -- "$work"' EXIT
		mkdir "$work/upper" "$work/work"
		"$host/bin/debugfs" -R 'cat /etc/be7000-system-id' "$rootfs" >"$work/base-id" 2>/dev/null
		[[ -s $work/base-id ]]
		"$host/bin/make_ext4fs" -L be7000-userdata -l 268435456 -b 4096 -m 0 -T "$epoch" "$output" "$work/"
		finish_ext4
		;;
	bundle)
		output=$1 image=$2 elf=$3 dtb=$4 system=$5 userdata=$6 nm=$7 epoch=$8
		directory=BE7000-OpenWrt-Snapshot
		ethernet='native OpenWrt PPE/QCA8084'
		wlan='external Qualcomm P74'
		wlan_files='WLAN firmware and INI are included in system.img.'
		case "${9:-xiaomi_be7000}" in
		xiaomi_be7000) ;;
		xiaomi_be7000-native)
			directory+=-Native
			wlan='native ath11k (2.4 GHz) and ath12k (5 GHz)'
			wlan_files='The installer copies calibration from the installing router into userdata.'
			;;
		xiaomi_be7000-wired)
			directory+=-Wired
			wlan='disabled (wired kernel compatibility bring-up)'
			wlan_files='No WLAN drivers or device calibration are included.'
			;;
		*) echo "Unsupported BE7000 device: $9" >&2; exit 2 ;;
		esac
		package=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
		rootfs=${10} topdir=${11}
		sender=$topdir/target/linux/qualcommbe/image/be7000
		template=$topdir/staging_dir/image/be7000-${9}-boot.tar
		[[ -s $system ]]
		[[ $userdata == - || -s $userdata ]]
		if [[ ! -s $template || -s $elf ]]; then
			[[ -s $image && -s $elf && -s $dtb ]]
		fi
		[[ -s $sender/kexec_mod.ko && -s $sender/kexec_mod_arm64.ko ]]
		work=$(mktemp -d "${output}.work.XXXXXX")
		trap 'rm -rf -- "$work"' EXIT
		base=$work/$directory
		mkdir -p "$base/payload" "$base/device" "$base/logs"
		mkdir "$base/payload/stock-sender"
		cp "$sender/kexec_mod.ko" "$sender/kexec_mod_arm64.ko" "$base/payload/stock-sender/"
		cp --sparse=always "$system" "$base/system.img"
		if [[ $userdata == - ]]; then
			bash "$package/image.sh" system "$base/system.img" "$topdir/staging_dir/host" "$epoch"
			bash "$package/image.sh" userdata "$base/system.img" "$base/userdata.img" "$topdir/staging_dir/host" "$epoch"
		else
			cp --sparse=always "$userdata" "$base/userdata.img"
		fi
		if [[ ! -s $elf && -s $template ]]; then
			tar -xf "$template" -C "$base"
		else
		cp "$image" "$base/payload/Image"
		cp "$dtb" "$base/payload/be7000-spin-table.dtb"
		"$nm" -n "$elf" >"$base/payload/System.map"
		[[ $(od -An -tx1 -j56 -N4 "$image" | tr -d ' \n') == 41524d64 ]]
		text_offset=$(od -An -tu8 --endian=little -j8 -N8 "$image" | tr -d ' ')
		image_size=$(od -An -tu8 --endian=little -j16 -N8 "$image" | tr -d ' ')
		image_bytes=$(stat -c %s "$image")
		text_addr=$(awk '$3 == "_text" { print "0x" $1; exit }' "$base/payload/System.map")
		pen_addr=$(awk '$3 == "secondary_holding_pen" { print "0x" $1; exit }' "$base/payload/System.map")
		[[ -n $text_addr && -n $pen_addr ]]
		kernel_base=$((0x42000000))
		entry=$((kernel_base + text_offset))
		pen=$((entry + (pen_addr - text_addr)))
		memsz=$(((image_size + 4095) & ~4095))
		(( image_size >= image_bytes && pen >= entry && pen < entry + image_size && entry + memsz <= 0x49b00000 ))
		printf -v pen_hex '0x%x' "$pen"
		printf 'holding_pen=%s\n' "$pen_hex" >"$base/payload/stock-sender/module-options"
		printf '{\n  "kernel_base": "0x%x",\n  "kernel_entry": "0x%x",\n  "text_offset": %d,\n  "image_size": %d,\n  "image_bytes": %d,\n  "kernel_memsz": %d,\n  "secondary_holding_pen": "0x%x",\n  "cpu_release_addr": "0x4fb3eff8"\n}\n' \
			"$kernel_base" "$entry" "$text_offset" "$image_size" "$image_bytes" "$memsz" "$pen" >"$base/payload/target-layout.json"
		bash "$package/prepare-boot.sh" "$base" "$rootfs" "$entry" "$memsz" "$pen_hex"
		mkdir -p "$(dirname "$template")"
		template_tmp=$(mktemp "$template.XXXXXX")
		tar -C "$base" -cf "$template_tmp" boot payload
		mv "$template_tmp" "$template"
		fi
		[[ ${9:-} != xiaomi_be7000-native ]] || touch "$base/native-wlan"
		cat >"$base/README.txt" <<EOF
Xiaomi BE7000 / OpenWrt snapshot / native Linux 6.18
Ethernet: $ethernet. WLAN: $wlan.

system.img: read-only 512 MiB ext4 system, label be7000-system.
userdata.img: writable 256 MiB ext4 overlay, label be7000-userdata.
The installer uses BE7000-OpenWrt-Snapshot and preserves existing userdata.
$wlan_files
Per-device WLAN calibration is not included in this build.
Passwords and 5.4 WLAN modules are not included.

Boot diagnostics are saved in logs/openwrt-<boot-id>/; logs/latest points
to the latest boot. kernel.log and state.latest.txt are periodic snapshots.
system.log records OpenWrt messages and rotates at 1 MiB with one .old copy.
usb-init.log captures USB startup and procd output. Each boot keeps its own logs.

payload/Image contains the native initramfs. The DTB uses spin-table release
0x4fb3eff8. payload/stock-sender includes prebuilt kexec modules for the audited
Xiaomi stock kernels 5.4.164 (20240122, 20260127). Normal image builds reuse them.
When loading kexec_mod_arm64.ko, pass the holding_pen argument saved in
payload/stock-sender/module-options. It is generated for THIS Image.
target-layout.json records the required load range and CPU entry address.
boot/start.sh includes the audited stock loader and quiesce sequence.
Boot arguments must retain rdinit=/usr/libexec/be7000-usb-init maxcpus=4
be7000_printk=1 be7000_handoff=1 from the DTB. Add:
be7000_usb_dir=$directory be7000_usb_uuid=<USB UUID>
The DTB appends pcie_port_pm=off to keep PCIe ports awake during WLAN bring-up.
System images stay on USB; autostart uses a stock firewall include in /data.
Use the Windows or Linux installer archive for initial setup and updates.
EOF
		tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -C "$work" -czf "$output" "$directory"
		;;
	*) echo "Unsupported image action: $mode" >&2; exit 2 ;;
esac
