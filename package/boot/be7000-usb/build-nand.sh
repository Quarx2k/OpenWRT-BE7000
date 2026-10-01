#!/usr/bin/env bash
set -euo pipefail
source_dir=${1:?source tree}
base=${2:?prepared USB build tree}
out=${3:?output directory}
jobs=${4:-24}
work=${5:-${base}-nand}
mode=${6:-build}
[[ $mode == build || $mode == pack ]] || exit 1
source_dir=$(realpath "$source_dir")
base=$(realpath "$base")
mkdir -p "$out"
out=$(realpath "$out")
[[ $work != "$base" && $work != /mnt/* ]] || exit 1
kernel_base=$base/build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq95xx
version=$(cat "$kernel_base"/linux-6.18.*/include/config/kernel.release)
linux=$work/linux-$version
root=$work/root
patch_file=$source_dir/target/linux/qualcommbe/patches-6.18/9502-be7000-rpm-handoff.patch
[[ -s $kernel_base/linux-$version/vmlinux && -s $base/build_dir/target-aarch64_cortex-a53_musl/root-qualcommbe/etc/be7000-system-id ]]
if [[ $mode == build ]]; then
[[ ! -e $work ]] || { echo "Use a new, empty NAND build directory: $work" >&2; exit 1; }
mkdir -p "$work"
printf 'Prepared USB build: %s\nKernel: %s\n' "$base" "$version" >"$out/source.txt"
git -C "$base" rev-parse HEAD >>"$out/source.txt"
git -C "$base" diff --binary >"$out/prepared-build.diff"
git -C "$base" status --short >"$out/prepared-build-status.txt"
echo 'Copying kernel and initramfs into the independent NAND build directory'
cp -a --reflink=auto "$kernel_base/linux-$version" "$linux"
cp -a --reflink=auto "$base/build_dir/target-aarch64_cortex-a53_musl/root-qualcommbe" "$root"
cp "$linux/.config" "$out/kernel.config.before"
patch --batch -d "$linux" -p1 -R <"$patch_file"
! grep -q be7000_pll_restart "$linux/drivers/clk/qcom/apss-ipq6018.c"
test ! -e "$linux/drivers/rpmsg/qcom_glink_be7000.h"
printk_patch=$source_dir/target/linux/qualcommbe/patches-6.18/9501-be7000-persistent-printk.patch
awk '/^diff --git a\/kernel\/printk\/be7000_persist.h / { section=1; next } section && /^diff --git / { exit } section && /^@@ / { body=1; next } section && body && /^\+/ { print substr($0,2) }' "$printk_patch" >"$work/be7000_persist.h"
grep -q BE7000_CRASH_HEADER_SIZE "$work/be7000_persist.h"
cp "$work/be7000_persist.h" "$linux/kernel/printk/be7000_persist.h"
patch --dry-run --batch --forward -R -d "$linux" -p1 <"$printk_patch"
opp_patch=$source_dir/target/linux/qualcommbe/patches-6.18/9517-tty-serial-msm-select-pm-opp.patch
if ! sed -n '/^config SERIAL_MSM$/,/^config SERIAL_MSM_CONSOLE$/p' "$linux/drivers/tty/serial/Kconfig" | grep -q 'select PM_OPP'; then
patch --batch -d "$linux" -p1 <"$opp_patch"
fi
cp "$source_dir/package/boot/be7000-usb/files/be7000-usb-init" "$root/usr/libexec/"
chmod 755 "$root/usr/libexec/be7000-usb-init"
cp "$source_dir/target/linux/generic/other-files/init" "$work/init"
printf 'file /init %s/init 0755 0 0\n' "$work" >"$work/init-cpio-list"
cp "$source_dir/target/linux/generic/image/initramfs-base-files.txt" "$work/initramfs-base-files.txt"
fi
[[ -s $linux/.config && -s $root/etc/be7000-system-id ]]
mkdir -p "$work/dts"
cp -a "$source_dir/target/linux/qualcommbe/dts/." "$work/dts/"
toolchain=($base/staging_dir/toolchain-aarch64_cortex-a53_gcc-*_musl)
export PATH=${toolchain[0]}/bin:$base/staging_dir/host/bin:/usr/sbin:/usr/bin:/sbin:/bin
export STAGING_DIR=$base/staging_dir/target-aarch64_cortex-a53_musl
export GCC_HONOUR_COPTS=s
cross=aarch64-openwrt-linux-musl-
if [[ $mode == build ]]; then
cmdline=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"/\1/p' "$source_dir/target/linux/qualcommbe/config-nand")
"$linux/scripts/config" --file "$linux/.config" --set-str CMDLINE "$cmdline" --enable CMDLINE_FORCE --disable CMDLINE_FROM_BOOTLOADER \
	--set-str INITRAMFS_SOURCE "$root $work/init-cpio-list $work/initramfs-base-files.txt"
make_args=(-C "$linux" ARCH=arm64 CROSS_COMPILE="$cross" KERNELRELEASE="$version" KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=buildhost KBUILD_BUILD_VERSION=0)
make "${make_args[@]}" olddefconfig
grep -qx CONFIG_PM_OPP=y "$linux/.config"
cp "$linux/.config" "$out/kernel.config"
diff -u "$out/kernel.config.before" "$out/kernel.config" >"$out/kernel-config.diff" || [[ $? == 1 ]]
echo 'Building the cold-boot kernel with embedded USB initramfs'
	make "${make_args[@]}" -j"$jobs" Image
fi
test $(stat -c %s "$linux/arch/arm64/boot/Image") -lt $((0x49b00000 - 0x41000000))
gzip -n -9 -c "$linux/arch/arm64/boot/Image" >"$out/Image-initramfs.gz"
for flavor in native-nand native-mlo-nand; do
"${cross}gcc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I "$work/dts" -I "$linux/arch/arm64/boot/dts/qcom" -I "$linux/arch/arm64/boot/dts" -I "$linux/include" \
	"$work/dts/ipq9574-be7000-$flavor.dts" -o "$work/$flavor.dts"
dtc -I dts -O dtb -o "$out/be7000-$flavor.dtb" "$work/$flavor.dts" 2>"$out/dtc-$flavor.log"
bash "$source_dir/scripts/mkits.sh" -A arm64 -C gzip -a 0x41000000 -e 0x41000000 \
	-v "$version" -k "$out/Image-initramfs.gz" -D 'Xiaomi BE7000 NAND flavor / USB root' \
	-d "$out/be7000-$flavor.dtb" -c config@be7000 -o "$out/be7000-$flavor.its"
mkimage -f "$out/be7000-$flavor.its" "$out/openwrt-qualcommbe-ipq95xx-xiaomi_be7000-$flavor-initramfs-uImage.itb"
mkimage -l "$out/openwrt-qualcommbe-ipq95xx-xiaomi_be7000-$flavor-initramfs-uImage.itb" >"$out/fit-info-$flavor.txt"
done
"${cross}nm" "$linux/vmlinux" | grep -E 'be7000_printk_init|be7000_glink_adopt|cpu_psci_cpu_boot' >"$out/kernel-symbols.txt"
cp "$linux/System.map" "$out/System.map"
cp "$root/etc/be7000-system-id" "$out/be7000-system-id"
printf '%s\n' "$work" >"$out/build-directory.txt"
echo "NAND flavor built: $out/openwrt-qualcommbe-ipq95xx-xiaomi_be7000-native-nand-initramfs-uImage.itb"
