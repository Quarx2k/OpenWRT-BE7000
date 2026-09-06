#!/bin/sh
set -eu
BB=/rescue/bin/busybox
base=/mnt/usb/BE7000-OpenWrt
test -f "$base/system.img"
test -f "$base/userdata.img"
$BB mkdir -p /mnt/owrt-system /mnt/owrt-data /mnt/owrt-root
sysloop=$($BB losetup -f)
$BB losetup "$sysloop" "$base/system.img"
$BB sh /rescue/bin/check-ext4.sh "$sysloop"
$BB losetup -d "$sysloop"
$BB losetup -r "$sysloop" "$base/system.img"
$BB mount -t ext4 -o ro "$sysloop" /mnt/owrt-system
dataloop=$($BB losetup -f)
$BB losetup "$dataloop" "$base/userdata.img"
$BB sh /rescue/bin/check-ext4.sh "$dataloop"
$BB mount -t ext4 -o rw,noatime "$dataloop" /mnt/owrt-data
test "$(cat /mnt/owrt-system/etc/be7000-system-id)" = "$(cat /mnt/owrt-data/base-id)"
$BB mount -t overlay overlay -o lowerdir=/mnt/owrt-system,upperdir=/mnt/owrt-data/upper,workdir=/mnt/owrt-data/work /mnt/owrt-root
test -x /mnt/owrt-root/sbin/procd
for name in proc sys dev tmp rescue; do
    $BB mount --bind /$name /mnt/owrt-root/$name
done
$BB mount --bind /mnt/usb /mnt/owrt-root/mnt/usb
$BB mount --bind /mnt/owrt-system /mnt/owrt-root/rom
$BB mount --bind /mnt/owrt-data /mnt/owrt-root/overlay
echo "$sysloop $dataloop" >/tmp/owrt12-root-loops
$BB mount --bind "$base/device/calibration" /mnt/owrt-root/opt/be7000/calibration
test -s "$base/device/wlan/manifest.json"
$BB cp /mnt/owrt-root/opt/be7000/wlan/regulatory.db "$base/device/wlan/firmware/regulatory.db"
$BB mount --bind "$base/device/wlan" /mnt/owrt-root/opt/be7000/vendor
$BB chroot /mnt/owrt-root /bin/sh /usr/lib/be7000/provision.sh
echo USB_OVERLAY_READY
