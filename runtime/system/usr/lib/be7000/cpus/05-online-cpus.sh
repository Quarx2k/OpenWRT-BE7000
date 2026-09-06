#!/bin/sh
# Bring up the retained CPUs after RPM recovery and before loading WLAN.
set -eu
die() { echo "ERROR: $*" >&2; exit 1; }
[ "${1:-}" = ONLINE-SOURCE-CPUS ] || die "usage: $0 ONLINE-SOURCE-CPUS"
SELF_DIR=${0%/*}
[ "$SELF_DIR" = "$0" ] && SELF_DIR=.
BASE_DIR=$(CDPATH= cd "$SELF_DIR" && pwd)
case " $(cat /proc/cmdline) " in
    *" be7000_source=owrt12 "*) ;;
    *) die "not the expected source-kernel boot" ;;
esac
[ "$(cat /sys/devices/system/cpu/online)" = 0 ] || die "expected CPU0-only baseline"
dmesg | grep -q 'RGLH ADOPTED:' || die "retained RPM channel has not been adopted"
sh "$BASE_DIR/04-verify-rpm.sh"
STATES=/sys/devices/system/cpu/hotplug/states
[ -r "$STATES" ] || die "CPU hotplug states unavailable"
ONLINE=$(awk '$2 == "online" {gsub(/:/,"",$1); print $1}' "$STATES")
case "$ONLINE" in ''|*[!0-9]*) die "ambiguous CPUHP_ONLINE state" ;; esac
for cpu in 1 2 3; do
    node=/sys/devices/system/cpu/cpu$cpu/hotplug
    [ -w "$node/target" ] || die "CPU$cpu hotplug target unavailable"
    echo "$ONLINE" > "$node/target"
    [ "$(cat "$node/state")" = "$ONLINE" ] || die "CPU$cpu did not reach online"
    [ "$(cat /sys/devices/system/cpu/online)" = "0-$cpu" ] || die "unexpected CPU online mask"
    sh "$BASE_DIR/04-verify-rpm.sh"
    echo "CPU$cpu online; RPM/regulator/cpufreq nodes remain present"
done
echo "All four CPUs online. Check Ethernet/Wi-Fi traffic and IRQ progress separately."
