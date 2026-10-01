#!/usr/bin/env bash
set -euo pipefail
top=$(realpath "${1:?OpenWrt tree}")
kdir=$(realpath "${2:?kernel build directory}")
output=${3:?kernel output}
jobs=${4:-$(nproc)}
rootfs=${5:?OpenWrt root}
work=$kdir/be7000-nand
out=$kdir/be7000-nand-artifacts
rm -rf -- "$work"
bash "$top/package/boot/be7000-nand/build.sh" "$top" "$top" "$kdir" "$work" "$out" "$jobs" image "$rootfs"
cp "$out/kernel.itb" "$output"
cp "$out/kernel.itb" "$kdir/xiaomi_be7000-nand-kernel.bin"
