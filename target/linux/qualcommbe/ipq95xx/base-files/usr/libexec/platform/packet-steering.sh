#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

mode=${1:-1}
flows=$(uci -q get 'network.@globals[0].steering_flows')
set --
[ "${flows:-0}" -gt 0 ] && set -- -l "$flows"
# Keep the standard policy for ath11k/ath12k and non-PPE devices.
/usr/libexec/network/packet-steering.uc "$@" "$mode" || exit $?

# IPQ9574 EDMA has four RSS receive rings, serviced by the four CPUs.
[ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || exit 0

set_value() {
	[ -w "$1" ] || return 0
	[ "$(cat "$1")" = "$2" ] || printf '%s\n' "$2" > "$1"
}

irqs=$(awk '$NF ~ /^edma_(rxdesc|txcmpl)_[0-9]+$/ {
	sub(/:$/, "", $1); print $1, $NF
}' /proc/interrupts)
rx_irqs=0
while read -r irq name; do
	[ -n "$irq" ] || continue
	ring=${name##*_}
	mask=f
	if [ "$mode" != 0 ]; then
		mask=$(printf '%x' "$((1 << (ring % 4)))")
	fi
	set_value "/proc/irq/$irq/smp_affinity" "$mask"
	case "$name" in edma_rxdesc_*) rx_irqs=$((rx_irqs + 1));; esac
done <<EOF
$irqs
EOF

[ "$rx_irqs" = 4 ] || exit 0
for dev in /sys/class/net/*; do
	case "$(readlink "$dev/device/driver")" in */qcom_ppe) ;; *) continue;; esac
	# Hardware RSS and IRQ affinity already distribute RX processing.
	for queue in "$dev"/queues/rx-*; do
		set_value "$queue/rps_cpus" 0
	done
done
