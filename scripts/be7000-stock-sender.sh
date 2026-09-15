#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Rebuild the reusable stock-side handoff modules; not needed for image builds.
set -euo pipefail
if (( $# != 4 )); then
	echo "Usage: $0 OUTPUT_DIRECTORY STOCK_KERNEL_BUILD SENDER_SOURCE CROSS_COMPILE_PREFIX" >&2
	exit 2
fi
topdir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$1"
output=$(realpath "$1")
stock=$(realpath "$2")
sender=$(realpath "$3")
cross=$4
[[ -s $stock/.config && -s $stock/include/generated/autoconf.h && -s $sender/arch/arm64/machine_kexec.c ]]
if [[ ! -s $stock/Module.symvers ]] && grep -q '^CONFIG_MODVERSIONS=y' "$stock/.config"; then
	echo 'The stock kernel enables symbol versions; its Module.symvers is required.' >&2
	exit 1
fi
[[ -x ${cross}gcc && -x ${cross}strip ]]
work=$(mktemp -d "${TMPDIR:-/tmp}/be7000-stock-sender.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/source"
# Apply the runtime-address change to a temporary copy of the sender sources.
rsync -a --include='*/' --include='*.c' --include='*.h' --include='*.S' \
	--include=Makefile --include=Kbuild --exclude='*' "$sender/" "$work/source/"
patch --batch --fuzz=0 -d "$work/source" -p1 \
	<"$topdir/target/linux/qualcommbe/image/be7000/stock-sender-runtime-pen.patch"
make -C "$stock" ARCH=arm64 CROSS_COMPILE="$cross" M="$work/source" -j8 modules \
	>"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }
for module in kexec_mod arch/arm64/kexec_mod_arm64; do
	file=$output/${module##*/}.ko
	install -m644 "$work/source/$module.ko" "$file"
	"${cross}strip" --strip-debug "$file"
done
printf 'Built reusable stock-side sender in %s\n' "$output"
