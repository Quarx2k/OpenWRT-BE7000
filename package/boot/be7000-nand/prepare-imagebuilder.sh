#!/usr/bin/env bash
set -euo pipefail
source_dir=$(realpath "${1:?source tree}")
ib=$(realpath "${2:?ImageBuilder}")
nand=$(realpath "${3:?built NAND artifacts}")
root=$(realpath "${4:?built NAND root}")
pkg=$ib/package/boot/be7000-nand
kernel=$(basename "$root"/lib/modules/*)
test -s "$root/lib/modules/$kernel/ath12k.ko"
test -s "$nand/kernel.itb"
test ! -e "$pkg"
mkdir -p "$pkg/modules/$kernel"
cp "$source_dir/package/boot/be7000-nand/"{imagebuilder.mk,imagebuilder-image.sh,imagebuilder-root.sh,packages.list} "$pkg/"
cp -a "$source_dir/package/boot/be7000-nand/files" "$pkg/"
for file in ath12k.ko ath12k_wifi7.ko modules.builtin modules.builtin.modinfo; do
    cp "$root/lib/modules/$kernel/$file" "$pkg/modules/$kernel/"
done
cp "$nand/kernel.itb" "$ib/build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq95xx/xiaomi_be7000-nand-kernel.bin"
if ! grep -q 'include $(TOPDIR)/package/boot/be7000-nand/imagebuilder.mk' "$ib/target/linux/qualcommbe/image/ipq95xx.mk"; then
    printf '\ninclude $(TOPDIR)/package/boot/be7000-nand/imagebuilder.mk\n' >>"$ib/target/linux/qualcommbe/image/ipq95xx.mk"
fi
sed -i '/^define Device\/xiaomi_be7000-common$/a\	FILESYSTEMS := ext4' "$ib/target/linux/qualcommbe/image/ipq95xx.mk"
sed -i '/$(call prepare_rootfs,$(TARGET_DIR),$(USER_FILES),$(DISABLED_SERVICES))/a\	$(if $(filter DEVICE_xiaomi_be7000-nand,$(USER_PROFILE)),bash $(TOPDIR)/package/boot/be7000-nand/imagebuilder-root.sh $(TARGET_DIR))' "$ib/Makefile"
sed -i 's/# CONFIG_TARGET_ROOTFS_SQUASHFS is not set/CONFIG_TARGET_ROOTFS_SQUASHFS=y/' "$ib/.config"
printf '\nCONFIG_TARGET_SQUASHFS_BLOCK_SIZE=256\nCONFIG_TARGET_SQUASHFS_BLOCK_READERS=4\nCONFIG_TARGET_SQUASHFS_SMALL_READERS=4\nCONFIG_SQUASHFS_XZ=y\n' >>"$ib/.config"
packages=$(tr '\n' ' ' <"$pkg/packages.list")
profile=$(mktemp)
trap 'rm -f "$profile"' EXIT
cat >"$profile" <<EOF

Target-Profile: DEVICE_xiaomi_be7000-nand
Target-Profile-Name: Xiaomi BE7000 (NAND)
Target-Profile-Packages: -kmod-qcom-ppe -kmod-leds-gpio -e2fsprogs -losetup $packages
Target-Profile-hasImageMetadata: 1
Target-Profile-SupportedDevices: xiaomi,be7000-nand
Target-Profile-Description:
Xiaomi BE7000 NAND
@@
EOF
awk -v profile="$profile" '
    /^Target-Profile: DEVICE_xiaomi_be7000-native$/ {
        while ((getline line < profile) > 0) print line
        close(profile)
    }
    { print }
' "$ib/.targetinfo" >"$ib/.targetinfo.nand"
mv "$ib/.targetinfo.nand" "$ib/.targetinfo"
"$ib/scripts/target-metadata.pl" profile_mk "$ib/.targetinfo" qualcommbe/ipq95xx >"$ib/.profiles.mk"
