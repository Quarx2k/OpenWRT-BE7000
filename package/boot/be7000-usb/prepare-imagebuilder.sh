#!/usr/bin/env bash
set -euo pipefail
top=$1 ib=$2
# Keep this build's local packages available alongside the official feeds.
find "$top/bin/targets/qualcommbe/ipq95xx/packages" "$top/bin/packages/aarch64_cortex-a53" \
    -type f -name '*.apk' -exec cp -t "$ib/packages" {} +
# Native WLAN and PPE have local changes. Do not substitute a same-name
# upstream package when ASU refreshes the official repositories.
pins=$ib/package/boot/be7000-usb/imagebuilder-pins.mk
: > "$pins"
while read -r name separator version; do
    case "$name" in
        be7000-*|kmod-ath*|kmod-cfg80211|kmod-mac80211|kmod-qcom-qmi-helpers|kmod-qrtr-smd|kmod-qcom-wcss-sec-compat|kmod-qcom-ppe-offload|ath11k-firmware-ipq9574|ath12k-firmware-qcn9274)
            printf 'BE7000_PINNED_PACKAGES += %s=%s\n' "$name" "$version" >> "$pins";;
    esac
done < "$top/bin/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-xiaomi_be7000-native.manifest"
