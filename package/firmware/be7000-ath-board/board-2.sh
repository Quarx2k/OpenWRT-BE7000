#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Encode board and regulatory TLVs without changing their Xiaomi payloads.
set -euo pipefail
export LC_ALL=C
family=$1 name=$2 board=$3 regdb=$4 output=$5
case "$family" in
	ath11k|ath12k) ;;
	*) exit 1 ;;
esac

le32() {
	local value=$1 byte octal
	for byte in 0 8 16 24; do
		printf -v octal '%03o' "$(((value >> byte) & 255))"
		printf '%b' "\\$octal"
	done
}

padding() {
	local count=$(((4 - $1 % 4) % 4))
	while ((count-- > 0)); do printf '\0'; done
	return 0
}

entry() {
	local type=$1 file=$2 size name_size=${#name}
	size=$(stat -c %s "$file")
	le32 "$type"
	le32 "$((16 + (name_size + 3) / 4 * 4 + (size + 3) / 4 * 4))"
	le32 0
	le32 "$name_size"
	printf '%s' "$name"
	padding "$name_size"
	le32 1
	le32 "$size"
	cat "$file"
	padding "$size"
}

{
	magic="QCA-${family^^}-BOARD"
	printf '%s\0' "$magic"
	padding "$((${#magic} + 1))"
	entry 0 "$board"
	entry 1 "$regdb"
} > "$output"
