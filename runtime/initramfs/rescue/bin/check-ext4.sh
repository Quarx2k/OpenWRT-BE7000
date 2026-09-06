#!/rescue/bin/busybox sh
# Preen fixes only problems e2fsck considers safe to repair unattended.
BB=/rescue/bin/busybox
dev=$1
case "$dev" in /dev/*) ;; *) exit 1;; esac
[ -b "$dev" ] || exit 1
if $BB awk -v dev="$dev" '$1 == dev {found=1} END {exit !found}' /proc/mounts; then
    echo "BE7000: refusing fsck on mounted $dev" >/dev/kmsg
    exit 1
fi
log=/tmp/fsck-${dev##*/}.log
echo "BE7000: checking ext4 $dev" >/dev/kmsg
$BB chroot /rescue /usr/sbin/e2fsck -p "$dev" >"$log" 2>&1
status=$?
if [ -s /tmp/owrt12-logdir ]; then
    $BB cp "$log" "$($BB cat /tmp/owrt12-logdir)/" || true
fi
$BB cat "$log" >/dev/kmsg
echo "BE7000: ext4 check $dev exit=$status" >/dev/kmsg
case "$status" in 0|1) exit 0;; *) exit 1;; esac
