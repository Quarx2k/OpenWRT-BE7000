#!/bin/sh
# Read-only compatibility gate. Run before any upload or module load.
set -eu
fail() { echo "Unsupported router state: $*" >&2; exit 1; }
# @BE7000_KERNEL_PROFILE@
[ "$(id -u)" = 0 ] || fail 'root SSH is required'
be7000_kernel_profile || fail 'kernel compatibility'
case " $(cat /proc/cmdline) " in *' boot_source=kexec '*) fail 'already in kexec';; esac
[ "$(cat /sys/devices/system/cpu/online)" = 0-3 ] || fail 'all four CPUs must be online'
[ -r /sys/firmware/fdt ] || fail 'live device tree unavailable'
grep -aq 'qcom,ipq9574-ap-al02-c6' /sys/firmware/fdt || fail 'board device tree'
for f in /tmp/IPQ9574/caldata.bin /tmp/qcn9224/caldata_3.bin; do
    [ -s "$f" ] || fail "factory Wi-Fi calibration missing: $f"
done
echo "BE7000_KERNEL_PROFILE=$KERNEL_PROFILE"
echo "Compatibility check passed: Xiaomi $KERNEL_FIRMWARE kernel"
