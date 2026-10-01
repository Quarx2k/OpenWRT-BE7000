#!/usr/bin/env bash
set -euo pipefail
source_dir=$(realpath "${1:?Dev source tree}")
base=$(realpath "${2:?prepared OpenWrt tree}")
cold=$(realpath "${3:?working cold-boot kernel directory}")
work=${4:?new independent Linux build directory}
out=${5:?output directory}
jobs=${6:-24}
build_mode=${7:-build}
[[ $build_mode == build || $build_mode == pack ]]
[[ $work == /home/* && $work != "$base" && $work != "$cold" ]]
mkdir -p "$out"
out=$(realpath "$out")
pkg=$source_dir/package/boot/be7000-nand
version=$(cat "$cold/linux-6.18.52/include/config/kernel.release")
linux=$work/linux-$version
root=$work/root
if [[ ! -d $linux ]]; then
  [[ ! -e $work ]] || { echo 'Use a new build directory' >&2; exit 1; }
  mkdir -p "$work"
  cp -a --reflink=auto "$cold/linux-$version" "$linux"
fi
toolchain=($base/staging_dir/toolchain-aarch64_cortex-a53_gcc-*_musl)
export PATH=${toolchain[0]}/bin:$base/staging_dir/host/bin:/usr/sbin:/usr/bin:/sbin:/bin
export STAGING_DIR=$base/staging_dir/target-aarch64_cortex-a53_musl GCC_HONOUR_COPTS=s
cross=aarch64-openwrt-linux-musl-
cmdline='console=ttyMSM0,115200n8 earlycon ubi.block=0,rootfs root=/dev/ubiblock0_1 rootfstype=squashfs rootwait ro maxcpus=4 be7000_printk=1 loglevel=7 pcie_pme=nomsi pcie_port_pm=off panic=10'
! grep -q be7000_pll_restart "$linux/drivers/clk/qcom/apss-ipq6018.c"
test ! -e "$linux/drivers/rpmsg/qcom_glink_be7000.h"
grep -q BE7000_CRASH_HEADER_SIZE "$linux/kernel/printk/be7000_persist.h"
if ! grep -q CLK_SET_RATE_NO_REPARENT "$linux/drivers/clk/qcom/nsscc-qca8k.c"; then
  patch --batch -d "$linux" -p1 <"$source_dir/target/linux/qualcommbe/patches-6.18/9518-clk-qcom-qca8k-preserve-phy-clock-parent.patch"
fi
if ! grep -q 'IS_REACHABLE(CONFIG_MTD_BLKDEVS)' "$linux/drivers/mtd/mtdcore.c"; then
  patch --batch -d "$linux" -p1 <"$pkg/patches/001-mtd-optional-blktrans.patch"
fi
if ! grep -q be7000_boot_animation "$linux/drivers/leds/leds-gpio.c"; then
  patch --batch -d "$linux" -p1 <"$pkg/patches/002-be7000-boot-leds.patch"
fi
if grep -q 'msleep(120)' "$linux/drivers/leds/leds-gpio.c"; then
  patch --batch -d "$linux" -p1 <"$pkg/patches/004-be7000-boot-leds-slower.patch"
fi
if ! grep -q 'subsys_initcall(gpio_led_init)' "$linux/drivers/leds/leds-gpio.c"; then
  patch --batch -d "$linux" -p1 <"$pkg/patches/003-gpio-leds-early-init.patch"
fi
"$linux/scripts/config" --file "$linux/.config" --set-str INITRAMFS_SOURCE '' \
  --set-str CMDLINE "$cmdline" --disable CMDLINE_FORCE --enable CMDLINE_FROM_BOOTLOADER \
  --disable MTD_BLOCK --disable MTD_UBI_GLUEBI --disable MTD_ROOTFS_ROOT_DEV --disable MTD_SPLIT_SQUASHFS_ROOT \
  --enable MTD_UBI_BLOCK --enable UBIFS_FS --enable SQUASHFS --enable PM_OPP --enable LEDS_GPIO
make_args=(-C "$linux" ARCH=arm64 CROSS_COMPILE="$cross" KERNELRELEASE="$version" KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=buildhost KBUILD_BUILD_VERSION=0)
make "${make_args[@]}" olddefconfig
make "${make_args[@]}" -j"$jobs" Image
cp "$linux/.config" "$out/kernel.config"
gzip -n -9 -c "$linux/arch/arm64/boot/Image" >"$out/Image.gz"
test "$(stat -c %s "$linux/arch/arm64/boot/Image")" -lt $((0x49b00000-0x41000000))
mkdir -p "$work/dts"
cp -a "$source_dir/target/linux/qualcommbe/dts/." "$work/dts/"
cp "$pkg/nand-buttons.dtsi" "$work/dts/"
sed -i 's/"stock-/"/g' "$work/dts/ipq9574-be7000-nand.dtsi"
cat >"$work/dts/nand.dts" <<EOF
#include "ipq9574-be7000-native-nand.dts"
#include "nand-buttons.dtsi"
/ {
 model = "Xiaomi BE7000 (NAND)";
 compatible = "xiaomi,be7000-nand", "xiaomi,be7000", "qcom,ipq9574";
 reserved-memory {
  qcn9224_pcie2_mlo: mlo@57300000 { reg = <0 0x57300000 0 0x700000>; no-map; };
 };
 leds { be7000,boot-animation; };
 chosen {
  bootargs = "";
  bootargs-append = " $cmdline";
 };
};
&wifi5 {
 xiaomi,selectable-radio-mode;
 /delete-property/ qcom,board_id;
 /delete-property/ qcom,num-radios;
 memory-region = <&qcn9224_pcie2>, <&qcn9224_pcie2_m3>,
                 <&qcn9224_pcie2_caldb>, <&qcn9224_pcie2_pageable>,
                 <&qcn9224_pcie2_mlo>;
 memory-region-names = "qmi", "m3-dump", "caldb", "pageable", "mlo-global";
 rf-low-gpios = <&tlmm 6 GPIO_ACTIVE_HIGH>;
 rf-high-gpios = <&tlmm 7 GPIO_ACTIVE_HIGH>;
};
&tlmm {
 /delete-node/ rf-low-hog;
 /delete-node/ rf-high-hog;
};
&qpic_nand {
 flash@0 {
  partitions {
   partition@d00000 { /delete-property/ read-only; };
   partition@1140000 { /delete-property/ read-only; };
   partition@3940000 { /delete-property/ read-only; };
   partition@62c0000 { label = "be7000-data"; /delete-property/ read-only; };
  };
 };
};
EOF
"${cross}gcc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
  -I "$work/dts" -I "$linux/arch/arm64/boot/dts/qcom" -I "$linux/arch/arm64/boot/dts" -I "$linux/include" \
  "$work/dts/nand.dts" -o "$work/nand.dts"
dtc -I dts -O dtb -o "$out/nand.dtb" "$work/nand.dts" 2>"$out/dtc.log"
cat >"$out/kernel.its" <<EOF
/dts-v1/;
/ {
 description = "Xiaomi BE7000 NAND";
 #address-cells = <1>;
 images {
  kernel { description = "Linux $version"; data = /incbin/("Image.gz"); type = "kernel"; arch = "arm64"; os = "linux"; compression = "gzip"; load = <0x41000000>; entry = <0x41000000>; hash@1 { algo = "crc32"; }; };
  fdt { data = /incbin/("nand.dtb"); type = "flat_dt"; arch = "arm64"; compression = "none"; hash@1 { algo = "crc32"; }; };
 };
 configurations {
  default = "config@al02-c6";
  config@al02-c6 { kernel = "kernel"; fdt = "fdt"; };
 };
};
EOF
mkimage -f "$out/kernel.its" "$out/kernel.itb" >"$out/fit.txt"
if [[ $build_mode == build ]]; then
  bash "$pkg/prepare-root.sh" "$source_dir" "$base" "$root"
fi
grep -qx be7000-nand-v1 "$root/etc/be7000-nand-layout"
bash "$pkg/build-wifi.sh" "$base" "$linux" "$work" "$root" "$jobs"
cp "$linux/modules.builtin" "$linux/modules.builtin.modinfo" "$root/lib/modules/$version/"
mksquashfs4 "$root" "$out/root.squashfs" -noappend -all-root -comp xz -b 262144 -no-xattrs >"$out/squashfs.log"
cat >"$out/factory.ini" <<EOF
[kernel]
mode=ubi
image=$out/kernel.itb
vol_id=0
vol_type=dynamic
vol_name=kernel
[rootfs]
mode=ubi
image=$out/root.squashfs
vol_id=1
vol_type=dynamic
vol_name=rootfs
EOF
ubinize -o "$out/factory.ubi" -p 131072 -m 2048 -s 2048 "$out/factory.ini"
test "$(stat -c %s "$out/factory.ubi")" -le $((300*131072))
stage=$work/sysupgrade-be7000-nand
mkdir -p "$stage"
printf 'BOARD=xiaomi,be7000-nand\nLAYOUT=be7000-nand-v1\n' >"$stage/CONTROL"
cp "$out/root.squashfs" "$stage/root"
cp "$out/kernel.itb" "$stage/kernel"
tar --sort=name --owner=0 --group=0 --numeric-owner --no-recursion -C "$work" \
  -cf "$out/be7000-nand-sysupgrade.bin" sysupgrade-be7000-nand \
  sysupgrade-be7000-nand/CONTROL sysupgrade-be7000-nand/kernel sysupgrade-be7000-nand/root
revision=$( . "$root/etc/openwrt_release"; printf '%s' "$DISTRIB_REVISION")
cat >"$out/metadata.json" <<EOF
{"metadata_version":"1.1","supported_devices":["xiaomi,be7000-nand"],"compat_version":"1.0","version":{"dist":"OpenWrt","version":"SNAPSHOT","revision":"$revision","target":"qualcommbe/ipq95xx","board":"xiaomi_be7000-nand"}}
EOF
fwtool -I "$out/metadata.json" "$out/be7000-nand-sysupgrade.bin"
mkdir -p "$out/install/installer"
install -m 755 "$pkg/installer/install.sh" "$out/install/install.sh"
sed 's/\r$//;s/$/\r/' "$pkg/installer/install.cmd" >"$out/install/install.cmd"
install -m 755 "$pkg/installer/router-install.sh" "$out/install/installer/router-install.sh"
cp "$out/factory.ubi" "$out/install/"
tar --owner=0 --group=0 --mode='u=rwX,go=rX' -C "$out" -czf "$out/be7000-nand-install.tar.gz" \
  install/install.cmd install/install.sh install/installer/router-install.sh install/factory.ubi
cp "$linux/System.map" "$out/System.map"
printf '%s\n' "$work" >"$out/build-directory.txt"
echo "Built NAND image and installation bundle in $out"
