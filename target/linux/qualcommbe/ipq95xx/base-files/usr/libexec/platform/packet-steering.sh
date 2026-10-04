#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

mode=${1:-1}
flows=$(uci -q get 'network.@globals[0].steering_flows')
set --
[ "${flows:-0}" -gt 0 ] && set -- -l "$flows"
/usr/libexec/network/packet-steering.uc "$@" "$mode" || exit $?

[ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || exit 0

set_value() {
	[ -w "$1" ] || return 0
	[ "$(cat "$1")" = "$2" ] || echo "$2" > "$1"
}

irqs=$(awk '
$NF ~ /^(edma_)?(rxdesc|txcmpl)_[0-9]+$/ {
	name = $NF; sub(/^.*_/, "", name)
	cpu = name % 2
}
/DP_EXT_IRQ/ {
	cpu = 2 + (dp++ % 2)
}
$NF ~ /^ce[0-9]+$/ ||
$NF ~ /^(wbm2host-|reo2host-|reo2ost-|rxdma2host-|host2rxdma-|ppdu-end-)/ {
	cpu = 2
	if ($NF ~ /^reo2host-destination-ring[0-9]+$/) {
		name = $NF; sub(/^.*ring/, "", name)
		cpu += (name - 1) % 2
	}
}
cpu != "" {
	sub(/:$/, "", $1); print $1, cpu
	cpu = ""
}' /proc/interrupts)
while read -r irq cpu; do
	[ -n "$irq" ] || continue
	mask=f
	if [ "$mode" != 0 ]; then
		mask=$(printf '%x' "$((1 << cpu))")
	fi
	set_value "/proc/irq/$irq/smp_affinity" "$mask" || exit $?
done <<EOF
$irqs
EOF
