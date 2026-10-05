#!/bin/sh
set -eu
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,be7000-nand ]
file=/lib/upgrade/nand.sh
if grep -q -- '-N provisioning -s 131072' "$file"; then
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' EXIT
	sed 's/-N provisioning -s 131072/-N provisioning -n $(( $(cat \/sys\/class\/ubi\/$root_ubidev\/max_vol_count) - 1 )) -s 131072/' "$file" >"$tmp"
	sh -n "$tmp"
	cp "$tmp" "$file"
	sync
	echo 'Fixed NAND sysupgrade provisioning volume ID.'
fi
