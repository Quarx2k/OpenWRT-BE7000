PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head blkid jsonfilter readlink ln'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock /usr/libexec/be7000-usb-upgrade'

platform_check_image() {
	case "$(board_name)" in
	xiaomi,be7000)
		/usr/libexec/be7000-usb-upgrade check "$1"
		return $?
		;;
	esac
	return 0;
}

platform_pre_upgrade() {
	[ "$(board_name)" = xiaomi,be7000 ] || return 0
	/usr/libexec/be7000-usb-upgrade stage "$1" "${UPGRADE_BACKUP:-}" || {
		echo 'BE7000 USB preparation failed; working image was not replaced.' >&2
		reboot -f
		exit 1
	}
}

platform_do_upgrade() {
	case "$(board_name)" in
	xiaomi,be7000)
		/usr/libexec/be7000-usb-upgrade commit || {
			echo 'BE7000 USB update was not activated.' >&2
			reboot -f
			exit 1
		}
		;;
	8devices,kiwi-dvk)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	askey,sbe1v1k)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		CI_DATAPART="rootfs_data"
		emmc_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	8devices,kiwi-dvk|\
	askey,sbe1v1k)
		emmc_copy_config
		;;
	esac
}
