REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='fw_printenv fw_setenv'
RAMFS_COPY_DATA='/etc/be7000-nand/fw_env.config /lib/be7000-nand.sh'
CI_DATA_UBIPART=be7000-data
CI_KERNPART=kernel
CI_ROOTPART=rootfs
CI_SKIP_KERNEL_MTD=1
. /lib/be7000-nand.sh

be7000_nand_image() {
	local image="$1" listing control
	be7000_nand_guard || return 1
	case "$(be7000_nand_slot)" in
		0) CI_UBIPART=rootfs;;
		1) CI_UBIPART=rootfs_1;;
		*) return 1;;
	esac
	listing=$(tar tf "$image") || return 1
	[ "$listing" = "sysupgrade-be7000-nand/
sysupgrade-be7000-nand/CONTROL
sysupgrade-be7000-nand/kernel
sysupgrade-be7000-nand/root" ] || return 1
	control=$(tar xOf "$image" sysupgrade-be7000-nand/CONTROL) || return 1
	[ "$control" = "BOARD=xiaomi,be7000-nand
LAYOUT=be7000-nand-v1" ] || return 1
	[ "$(identify_tar "$image" cat sysupgrade-be7000-nand/root)" = squashfs ] || return 1
	[ "$(identify_tar "$image" cat sysupgrade-be7000-nand/kernel)" = fit ] || return 1
	BE7000_KERNEL_LENGTH=$(tar xOf "$image" sysupgrade-be7000-nand/kernel | wc -c)
	BE7000_ROOT_LENGTH=$(tar xOf "$image" sysupgrade-be7000-nand/root | wc -c)
	[ "$BE7000_KERNEL_LENGTH" -gt 1048576 ] && [ "$BE7000_ROOT_LENGTH" -gt 1048576 ] || return 1
	[ $(((BE7000_KERNEL_LENGTH+126975)/126976 + (BE7000_ROOT_LENGTH+126975)/126976)) -le 296 ]
}

platform_check_image() {
	be7000_nand_image "$1" || { echo 'Not a compatible BE7000 NAND image, or slot/layout mismatch.' >&2; return 1; }
}

platform_do_upgrade() {
	local ubidev kernvol rootvol
	be7000_nand_image "$1" || return 1
	nand_upgrade_prepare_ubi "$BE7000_ROOT_LENGTH" squashfs "$BE7000_KERNEL_LENGTH" 0 || return 1
	ubidev=$(nand_find_ubi "$CI_UBIPART")
	kernvol=$(nand_find_volume "$ubidev" kernel)
	rootvol=$(nand_find_volume "$ubidev" rootfs)
	[ "$kernvol" = ubi0_0 ] && [ "$rootvol" = ubi0_1 ] || return 1
	tar xOf "$1" sysupgrade-be7000-nand/root | ubiupdatevol "/dev/$rootvol" -s "$BE7000_ROOT_LENGTH" - || return 1
	tar xOf "$1" sysupgrade-be7000-nand/kernel | ubiupdatevol "/dev/$kernvol" -s "$BE7000_KERNEL_LENGTH" - || return 1
	nand_do_upgrade_success
}
