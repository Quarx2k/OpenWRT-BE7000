#!/usr/bin/env bash
set -euo pipefail
image=${1:?squashfs image}
kernel=${2:?NAND FIT}
epoch=${3:?source date}
root_size=$(stat -c %s "$image")
kernel_size=$(stat -c %s "$kernel")
if (( (root_size+126975)/126976 + (kernel_size+126975)/126976 > 296 )); then
    echo 'Selected packages exceed the BE7000 NAND slot capacity' >&2
    exit 1
fi
stage=$(mktemp -d "${image}.nand.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/sysupgrade-be7000-nand"
printf 'BOARD=xiaomi,be7000-nand\nLAYOUT=be7000-nand-v1\n' >"$stage/sysupgrade-be7000-nand/CONTROL"
mv "$image" "$stage/sysupgrade-be7000-nand/root"
cp "$kernel" "$stage/sysupgrade-be7000-nand/kernel"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --no-recursion \
    -C "$stage" -cf "$image" sysupgrade-be7000-nand \
    sysupgrade-be7000-nand/CONTROL sysupgrade-be7000-nand/kernel sysupgrade-be7000-nand/root
