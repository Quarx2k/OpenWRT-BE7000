#!/rescue/bin/busybox sh
BB=/rescue/bin/busybox
dir=$1
while :; do
    $BB cp /tmp/netguard.log "$dir/netguard.log" 2>/dev/null
    $BB cp /tmp/early-network.log "$dir/early-network.log"
    $BB timeout 3 $BB chroot /mnt/owrt-root /sbin/logread >"$dir/userspace.latest.log" 2>&1
    {
        $BB cat /proc/uptime
        $BB ip addr
        $BB ip route
        $BB ps w
        for p in /sys/class/net/eth*/carrier; do echo "$p"; $BB cat "$p"; done
    } >"$dir/state.latest.txt" 2>&1
    $BB sleep 5
done
