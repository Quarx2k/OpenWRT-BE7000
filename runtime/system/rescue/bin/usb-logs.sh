#!/rescue/bin/busybox sh
BB=/rescue/bin/busybox
for mod in xhci-hcd xhci-plat-hcd dwc3 dwc3-qcom usb-storage; do
    $BB insmod /lib/modules/5.4.164/$mod.ko || exit 1
done
expected=$($BB cat /rescue/bin/usb-identity)
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    for part in /sys/class/block/sd*[0-9]; do
        [ -e "$part" ] || continue
        case "$($BB readlink -f "$part")" in */usb*/*) ;; *) continue;; esac
        dev=/dev/${part##*/}
        id=$($BB blkid "$dev")
        case "$id" in *"$expected"*)
            $BB mkdir -p /mnt/usb
            $BB mount -t ext4 -o rw,sync,noatime,nosuid,nodev,noexec "$dev" /mnt/usb || exit 1
            boot=$($BB cat /proc/sys/kernel/random/boot_id)
            dir=/mnt/usb/Openwrt-logs/kexec-v63-owrt-v7-$boot
            $BB mkdir -p "$dir" || exit 1
            echo "$dir" >/tmp/owrt7-logdir
            $BB cat /proc/cmdline >"$dir/cmdline.txt"
            $BB cat /proc/mounts >"$dir/mounts-start.txt"
            /rescue/bin/kmsg-log "$dir/kernel.log" </dev/null >"$dir/kmsg-reader.log" 2>&1 &
            /rescue/bin/busybox sh /rescue/bin/snapshot-logs.sh "$dir" </dev/null >"$dir/collector.log" 2>&1 &
            echo "OWRT7: USB logging ready $dir" >/dev/kmsg
            exit 0;;
        esac
    done
    $BB sleep 2
done
echo 'OWRT7: expected USB not found' >/dev/kmsg
exit 1
