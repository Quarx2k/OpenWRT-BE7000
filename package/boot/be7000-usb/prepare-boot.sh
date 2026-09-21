#!/usr/bin/env bash
# Assemble the proven kexec handoff; derive layout from this build's Image.
set -euo pipefail
base=$1 rootfs=$2 entry=$3 memsz=$4 pen=$5
package=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$base/boot/bash-runtime/bin" "$base/boot/bash-runtime/lib"
bytes=$(stat -c %s "$base/payload/Image")
dtb_bytes=$(stat -c %s "$base/payload/be7000-spin-table.dtb")
for file in "$package"/installer/boot/*.sh; do
    sed -e 's/@RUN@/installer/g' -e "s/@IMAGE_BYTES@/$bytes/g" \
        -e "s/@DTB_BYTES@/$dtb_bytes/g" -e "s/@HOLDING_PEN@/$pen/g" \
        -e 's/@USB_DIR@/BE7000-OpenWrt-Snapshot/g' \
        -e 's/linux612/linux618/g' -e 's/LINUX612/LINUX618/g' -e 's/6\.12/6.18/g' \
        "$file" > "$base/boot/${file##*/}"
    chmod 755 "$base/boot/${file##*/}"
done
cp "$package/installer/boot/kexec" "$base/boot/kexec"
cp "$package/installer/boot/COPYING" "$base/boot/"
chmod 755 "$base/boot/kexec"
cp -L "$rootfs/bin/bash" "$base/boot/bash-runtime/bin/"
for lib in ld-musl-aarch64.so.1 libc.so libgcc_s.so.1 libncursesw.so.6; do
    source=$rootfs/lib/$lib
    [[ -e $source ]] || source=$rootfs/usr/lib/$lib
    cp -L "$source" "$base/boot/bash-runtime/lib/$lib"
done
chmod 755 "$base/boot/bash-runtime/bin/bash" "$base/boot/bash-runtime/lib/ld-musl-aarch64.so.1"
for file in Image be7000-spin-table.dtb; do
    ln -s "../payload/$file" "$base/boot/$file"
done
for file in kexec_mod.ko kexec_mod_arm64.ko; do
    ln -s "../payload/stock-sender/$file" "$base/boot/$file"
done
printf 'KERNEL_ENTRY=0x%x\nKERNEL_MEMORY_BYTES=%s\nHOLDING_PEN=%s\n' "$entry" "$memsz" "$pen" > "$base/boot/target.env"
