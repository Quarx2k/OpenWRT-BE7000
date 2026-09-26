#!/bin/sh
# Interactive controller shared by the Windows and Linux installers.
set -eu
umask 022
fail() { echo "ERROR: $*" >&2; exit 1; }
read_choice() {
    choice=
    read -r choice || [ -n "$choice" ] ||
        fail 'Input closed before an answer was received. Run the installer in an interactive terminal.'
}
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
image=$here/../firmware.bin
helper=$here/be7000-usb-upgrade
[ -s "$image" ] || fail 'Place our BE7000 sysupgrade image here as firmware.bin.'
mkdir /tmp/be7000-install.lock || fail 'Another installation is running.'
scheduled=no
bootstrapped=no
cleanup() {
    if [ "$bootstrapped" = yes ] && [ "$scheduled" = no ]; then
        cp "$here/platform.saved" /lib/upgrade/platform.sh
        if [ "$had_helper" = yes ]; then
            cp "$here/helper.saved" /usr/libexec/be7000-usb-upgrade
        else
            rm -f /usr/libexec/be7000-usb-upgrade
        fi
    fi
    [ "$scheduled" = yes ] || rmdir /tmp/be7000-install.lock
    rm -f /tmp/be7000-installing
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

case "$(uname -r)" in
    6.18.*)
        [ "$(cat /tmp/sysinfo/board_name)" = xiaomi,be7000 ] || fail 'Not a Xiaomi BE7000.'
        grep -q 'boot_source=kexec' /proc/cmdline || fail 'Expected the BE7000 USB build.'
        system=openwrt
        base=/mnt/usb/BE7000-OpenWrt-Snapshot
        echo 'Detected: running OpenWrt on USB.'
        ;;
    5.4.164)
        case "$(uname -v)" in
            '#0 SMP PREEMPT Mon Jan 22 02:33:42 2024'|'#0 SMP PREEMPT Tue Jan 27 03:33:27 2026') ;;
            *) fail 'Supported stock versions: Xiaomi 1.1.16 and 1.1.38.';;
        esac
        grep -q 'xiaomi,be7000\|BE7000\|RA72' /proc/device-tree/model /proc/device-tree/compatible 2>/dev/null ||
            [ -e /tmp/IPQ9574/caldata.bin ] || fail 'Not a supported Xiaomi BE7000.'
        system=stock
        mounts=$(awk '$1 ~ /^\/dev\/sd/ && $2 ~ /^\/mnt\/usb-/ && $3 == "ext4" && $4 ~ /(^|,)rw(,|$)/ {print $1, $2}' /proc/mounts)
        [ "$(printf '%s\n' "$mounts" | grep -c '^/dev/' || :)" = 1 ] ||
            fail 'Connect exactly one mounted ext4 USB partition. No disks will be formatted.'
        set -- $mounts
        dev=$1 usb=$2
        case "$usb" in *[!a-zA-Z0-9_/-]*) fail 'Unsupported USB mount path';; esac
        base=$usb/BE7000-OpenWrt-Snapshot
        touch /tmp/be7000-installing
        echo 'Detected: Xiaomi stock firmware.'
        ;;
    *) fail 'Supported systems: Xiaomi stock 1.1.16/1.1.38 or our USB OpenWrt 6.18.';;
esac
[ ! -L "$base" ] || fail 'Installation directory must not be a symlink.'
for name in system.img userdata.img boot payload; do
    [ ! -L "$base/$name" ] || fail "Redirected installation path: $name"
done

echo 'Offline installation uses the packages included in firmware.bin.'
echo 'Additional installed packages are not carried over; use ASU to rebuild with them.'
if [ -s "$base/system.img" ] && [ -s "$base/userdata.img" ]; then
    echo 'An existing OpenWrt installation was found.'
    echo '  1 - Update and keep settings (default)'
    echo '  2 - Install from scratch: erase OpenWrt settings and installed packages'
    echo '  0 - Cancel'
    printf 'Choose [1/2/0]: '
    read_choice
    case "${choice:-1}" in 1) mode=update;; 2) mode=fresh;; 0) exit 0;; *) fail 'Invalid choice';; esac
else
    [ "$system" = stock ] || fail 'The running USB installation is incomplete.'
    [ ! -e "$base/system.img" ] && [ ! -e "$base/userdata.img" ] || fail 'Incomplete existing installation; no files changed.'
    printf 'No installation found. Install OpenWrt on USB? [Y/n]: '
    read_choice
    case "$choice" in ''|y|Y|yes|YES) mode=fresh;; *) exit 0;; esac
fi

if [ "$system" = stock ]; then
    printf 'Start OpenWrt automatically after reboot? [Y/n]: '
    read_choice
    case "$choice" in ''|y|Y|yes|YES) auto=yes;; n|N|no|NO) auto=no;; *) fail 'Invalid choice';; esac
    sh "$here/stock-install.sh" "$mode" "$auto" "$dev" "$usb"
    scheduled=yes
    exit 0
fi

# Bootstrap old 6.18 builds. Only sysupgrade may replace the active USB images.
echo 'Preparing USB sysupgrade. Existing stock autostart settings are kept.'
sh "$helper" check "$image"
cp /lib/upgrade/platform.sh "$here/platform.saved"
had_helper=no
if [ -e /usr/libexec/be7000-usb-upgrade ]; then
    cp /usr/libexec/be7000-usb-upgrade "$here/helper.saved"
    had_helper=yes
fi
bootstrapped=yes
cp "$helper" /usr/libexec/be7000-usb-upgrade
chmod 755 /usr/libexec/be7000-usb-upgrade
cp "$here/platform.sh" /lib/upgrade/platform.sh
if ! sysupgrade -T "$image"; then
    fail 'Firmware was not accepted. Restoring the previous upgrade handler.'
fi
set -- "$image"
[ "$mode" = update ] || set -- -n "$image"
echo 'Firmware accepted. Updating and rebooting; the SSH connection can close.'
echo "Progress log: $base/boot/offline-upgrade.log"
(trap '' HUP; sleep 3; exec /sbin/sysupgrade "$@") </dev/null >"$base/boot/offline-upgrade.log" 2>&1 &
scheduled=yes
