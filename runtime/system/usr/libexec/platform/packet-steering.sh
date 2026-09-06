#!/bin/sh

mode=${1:-1}
flows=$(uci -q get 'network.@globals[0].steering_flows')
if [ "${flows:-0}" -gt 0 ]; then
    /usr/libexec/network/packet-steering.uc -l "$flows" "$mode"
else
    /usr/libexec/network/packet-steering.uc "$mode"
fi

[ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || exit 0
[ -w /proc/sys/net/edma/rps_num_cores ] || exit 0

set_value() {
    [ -w "$1" ] || return 0
    [ "$(cat "$1")" = "$2" ] || printf '%s\n' "$2" > "$1"
}

# QSDK distributes EDMA rings across CPUs after all four cores are online.
for kind in edma_rxdesc edma_txcmpl; do
    mask=1
    for irq in $(awk -v name="$kind" '$NF ~ ("^" name "_[0-9]+$") {gsub(":", "", $1); print $1}' /proc/interrupts); do
        set_value "/proc/irq/$irq/smp_affinity" "$mask"
        mask=$((mask * 2))
        [ "$mask" -le 8 ] || mask=1
    done
done

# The Wi-Fi 7 board profile uses three Ethernet RX cores. Mode 2 permits all.
cores=3
[ "$mode" != 2 ] || cores=4
set_value /proc/sys/net/edma/rps_num_cores "$cores"
for dev in eth0 eth1 eth2 eth3; do
    for queue in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        set_value "$queue" 0
    done
done

# PCI2 is the 5 GHz radio; match interrupt names, since IRQ numbers can change.
awk '$NF ~ /^pci2_wlan_grp_dp_[0-7]$/ {gsub(":", "", $1); print $1, $NF}' /proc/interrupts |
while read -r irq name; do
    case "${name##*_}" in
        0|5) mask=2 ;;
        1|6) mask=4 ;;
        2|3|7) mask=8 ;;
        4) mask=1 ;;
    esac
    set_value "/proc/irq/$irq/smp_affinity" "$mask"
done

# QSDK AP interfaces lack a device parent, so identify the 5 GHz radio by PHY.
for dev in /sys/class/net/*; do
    [ -r "$dev/phy80211/index" ] || continue
    [ "$(cat "$dev/phy80211/index")" = 1 ] || continue
    [ "$(cat "$dev/type")" = 1 ] || continue
    case "$mode" in
        0) mask=0 ;;
        2) mask=f ;;
        *) mask=b ;;
    esac
    for queue in "$dev"/queues/rx-*; do
        set_value "$queue/rps_cpus" "$mask"
        set_value "$queue/rps_flow_cnt" "${flows:-0}"
    done
done
