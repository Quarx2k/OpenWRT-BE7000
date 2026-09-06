#!/bin/sh
# Read-only compatibility gate. Run before any upload or module load.
set -eu
fail() { echo "Unsupported router state: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root SSH is required'
[ "$(uname -m)" = aarch64 ] || fail architecture
[ "$(uname -r)" = 5.4.164 ] || fail 'kernel release'
[ "$(uname -v)" = '#0 SMP PREEMPT Tue Jan 27 03:33:27 2026' ] || fail 'only the audited January 2026 Xiaomi kernel is supported'
grep -q '^ffffffc0107f61a4 T secondary_holding_pen$' /proc/kallsyms || fail 'Xiaomi kernel layout'
case " $(cat /proc/cmdline) " in *' boot_source=kexec '*) fail 'already in kexec';; esac
[ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || fail 'all four CPUs must be online'
[ -r /sys/firmware/fdt ] || fail 'live device tree unavailable'
grep -aq 'qcom,ipq9574-ap-al02-c6' /sys/firmware/fdt || fail 'board device tree'
for f in /tmp/IPQ9574/caldata.bin /tmp/qcn9224/caldata_3.bin; do
    [ -s "$f" ] || fail "factory Wi-Fi calibration missing: $f"
done
echo 'Compatibility check passed: Xiaomi kernel, 27 January 2026'
