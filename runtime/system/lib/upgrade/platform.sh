# SPDX-License-Identifier: GPL-2.0-or-later
REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='/usr/sbin/blkid /usr/bin/jsonfilter readlink ln'
RAMFS_COPY_DATA='/usr/lib/be7000/usb-upgrade.sh'

platform_check_image() {
    /usr/lib/be7000/usb-upgrade.sh check "$1" || return 74
}

platform_pre_upgrade() {
    /usr/lib/be7000/usb-upgrade.sh stage "$1" "${UPGRADE_BACKUP:-}" || {
        v 'USB update preparation failed; the active installation is unchanged.'
        reboot -f
        exit 1
    }
}

platform_do_upgrade() {
    /usr/lib/be7000/usb-upgrade.sh commit || {
        v 'USB update was not activated.'
        reboot -f
        exit 1
    }
}

# Configuration was restored into the inactive userdata image before ramfs.
platform_copy_config() { :; }
