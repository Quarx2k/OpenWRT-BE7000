#!/usr/bin/env bash
set -euo pipefail
source_dir=$(realpath "$1")
ib=$(realpath "$2")
tag=${3:-$(TOPDIR="$source_dir" "$source_dir/scripts/getver.sh")}
install -m 0644 "$source_dir/package/system/be7000-package-feed/files/be7000-packages.pem" "$ib/keys/"
printf 'https://openwrt.quarx2k.dev/packages/%s/qualcommbe/ipq95xx/packages.adb\n' "$tag" >>"$ib/repositories"
awk '
    /^Target-Profile:/ { profile=$2 }
    /^Target-Profile-Packages:/ && (profile=="DEVICE_xiaomi_be7000-native" || profile=="DEVICE_xiaomi_be7000-nand") {
        $0=$0 " be7000-package-feed"
    }
    { print }
' "$ib/.targetinfo" >"$ib/.targetinfo.feed"
mv "$ib/.targetinfo.feed" "$ib/.targetinfo"
"$ib/scripts/target-metadata.pl" profile_mk "$ib/.targetinfo" qualcommbe/ipq95xx >"$ib/.profiles.mk"
if [[ -x $source_dir/staging_dir/host/bin/apk ]]; then
    for name in amneziawg-tools kmod-amneziawg luci-proto-amneziawg luci-i18n-amneziawg-ru luci-app-ssclash; do
        while IFS= read -r file; do
            "$source_dir/staging_dir/host/bin/apk" adbdump "$file" | awk '
                /^  name:/ { name=$2 }
                /^  version:/ { printf "BE7000_PINNED_PACKAGES += %s=%s\n", name, $2 }
            ' >>"$ib/package/boot/be7000-usb/imagebuilder-pins.mk"
        done < <(find "$source_dir/bin" -type f -name "$name-*.apk")
    done
fi
