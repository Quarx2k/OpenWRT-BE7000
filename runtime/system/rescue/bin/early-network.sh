#!/rescue/bin/busybox sh
set -eu
BB=/rescue/bin/busybox
base=/mnt/usb/BE7000-OpenWrt
for mod in qca-ssdk nf_defrag_ipv6 nat46 qca-nss-ppe qca-nss-dp; do
    $BB insmod /lib/modules/5.4.164/$mod.ko
done
$BB ip link set lo up
# In normal mode netifd owns all Ethernet ports, with no rescue listener.
grep -q 'be7000_diagnostic=1' /proc/cmdline || exit 0
. "$base/device/provision.env"
$BB brctl addbr br-lan
$BB brctl stp br-lan off
$BB ip link set eth1 up
$BB brctl addif br-lan eth1
$BB ip addr add 192.168.32.1/24 dev br-lan
$BB ip link set br-lan up
for path in dev proc sys tmp; do $BB mount --bind /$path /rescue/$path; done
$BB mkdir -p /rescue/run "$base/device/rescue-ssh"
$BB mount --bind "$base/device/rescue-ssh" /rescue/etc/dropbear
$BB cp "$base/device/rescue_authorized_keys" /rescue/etc/dropbear/authorized_keys
$BB awk -F: -v OFS=: '$1=="root" {$2=""} {print}' /rescue/etc/shadow >/tmp/rescue-shadow
$BB mount --bind /tmp/rescue-shadow /rescue/etc/shadow
$BB chroot /rescue /usr/sbin/dropbear -R -s -E -j -k -p 192.168.32.1:2222 -P /run/dropbear-rescue.pid
if [ -n "${GUARD_PEER:-}" ]; then
    /rescue/bin/netguard "$GUARD_PEER" </dev/null >/tmp/netguard.log 2>&1 &
fi
