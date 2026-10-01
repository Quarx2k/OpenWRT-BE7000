be7000_nand_slot() {
	case "$(cat /sys/class/ubi/ubi0/mtd_num)" in
		23) echo 0;;
		24) echo 1;;
		*) return 1;;
	esac
}

be7000_nand_geometry() {
	local n="$1" name="$2" size="$3" offset="$4" dir="/sys/class/mtd/mtd$1"
	[ "$(cat "$dir/name")" = "$name" ] &&
	[ "$(cat "$dir/size")" = "$size" ] &&
	[ "$(cat "$dir/offset")" = "$offset" ] &&
	[ "$(cat "$dir/erasesize")" = 131072 ] &&
	[ "$(cat "$dir/writesize")" = 2048 ]
}

be7000_nand_guard() {
	local slot="$(be7000_nand_slot)"
	[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,be7000-nand ] || return 1
	case "$slot" in
		0) be7000_nand_geometry 23 rootfs 41943040 18087936 || return 1;;
		1) be7000_nand_geometry 24 rootfs_1 41943040 60030976 || return 1;;
		*) return 1;;
	esac
	be7000_nand_geometry 28 be7000-data 29360128 103546880 || return 1
	be7000_nand_geometry 17 0:APPSBLENV 524288 13631488 || return 1
	[ "$(fw_printenv -c /etc/be7000-nand/fw_env.config -n flag_boot_rootfs)" = "$slot" ] || return 1
}
