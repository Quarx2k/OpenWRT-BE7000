#!/bin/sh

set -eu

fail=0

echo "cmdline: $(cat /proc/cmdline)"
echo "online CPUs: $(cat /sys/devices/system/cpu/online)"

if [ -e /sys/bus/rpmsg/devices/rpm-glink.rpm_requests.-1.-1 ]; then
	echo "rpm_requests: present"
else
	echo "rpm_requests: MISSING"
	fail=1
fi

for expected in s1 s2 s4 apc_corner npu_corner; do
	found=0
	for node in /sys/class/regulator/regulator.*; do
		[ -r "$node/name" ] || continue
		if [ "$(cat "$node/name")" = "$expected" ]; then
			echo "regulator $expected: present ($node)"
			found=1
			break
		fi
	done
	if [ "$found" -ne 1 ]; then
		echo "regulator $expected: MISSING"
		fail=1
	fi
done

if [ -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
	echo "cpufreq policy0: present"
	for item in scaling_driver scaling_governor scaling_cur_freq \
		cpuinfo_min_freq cpuinfo_max_freq; do
		[ -r "/sys/devices/system/cpu/cpufreq/policy0/$item" ] &&
			echo "  $item=$(cat "/sys/devices/system/cpu/cpufreq/policy0/$item")"
	done
else
	echo "cpufreq policy0: MISSING"
	fail=1
fi

echo "relevant dmesg:"
dmesg | grep -E 'rpm-glink|rpm_requests|Invalid open ack|s1:|s2:|s4:|msm_rpm_log_probe|cpr[34]|CPR' | tail -80 || true

exit "$fail"
