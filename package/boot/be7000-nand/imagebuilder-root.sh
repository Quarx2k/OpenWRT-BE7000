#!/usr/bin/env bash
set -euo pipefail
root=${1:?ImageBuilder root}
pkg=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cp -a "$pkg/files/." "$root/"
cp -a "$pkg/modules/." "$root/lib/modules/"
sed -i 's/xiaomi,be7000)/xiaomi,be7000-nand)/g' "$root/etc/board.d/01_leds" "$root/etc/board.d/02_network"
chmod 755 "$root/usr/libexec/be7000-nand-env" "$root/usr/libexec/be7000-nand-radio" \
    "$root/etc/init.d/be7000-nand-confirm" "$root/etc/init.d/be7000-nand-radio"
ln -sf /tmp/be7000-ath12k.modules "$root/etc/modules.d/ath12k"
ln -sf /tmp/be7000-caldata/ath11k.bin "$root/lib/firmware/ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin"
ln -sf /tmp/be7000-caldata/ath12k.bin "$root/lib/firmware/ath12k/QCN9274/hw2.0/cal-pci-0002:01:00.0.bin"
(
    cd "$root"
    for service in be7000-nand-confirm be7000-nand-radio; do
        IPKG_INSTROOT="$root" bash etc/rc.common "etc/init.d/$service" enable
    done
)
printf 'be7000-nand-v1\n' >"$root/etc/be7000-nand-layout"
mv "$root/lib/upgrade/be7000-nand.sh" "$root/lib/upgrade/platform.sh"
