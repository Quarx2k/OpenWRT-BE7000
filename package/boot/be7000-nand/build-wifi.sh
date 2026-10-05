#!/usr/bin/env bash
set -euo pipefail
base=${1:?prepared OpenWrt tree}
linux=${2:?NAND kernel}
work=${3:?NAND work directory}
root=${4:?NAND root}
jobs=${5:-24}
pkg=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
wifi=$work/mac80211-nand
prepared=$base/build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq95xx/mac80211-regular/backports-7.2
[[ $work == /* && $wifi != "$prepared" ]]
[[ -d $wifi ]] || cp -a --reflink=auto "$prepared" "$wifi"
if [[ ! -f $wifi/drivers/net/wireless/ath/ath12k/be7000.c ]]; then
  patch --batch -p1 -d "$wifi" <"$pkg/ath12k-patches/001-be7000-radio-mode.patch"
fi
if ! grep -q 'if (ab->pdevs\[i\].ar)' "$wifi/drivers/net/wireless/ath/ath12k/dp.c"; then
  patch --batch -p1 -d "$wifi" <"$pkg/ath12k-patches/002-skip-absent-pdev-on-cleanup.patch"
fi
if ! grep -q ath12k_qmi_assign_pci_mlo_mem_chunk "$wifi/drivers/net/wireless/ath/ath12k/qmi.c"; then
  patch --batch -p1 -d "$wifi" <"$pkg/ath12k-patches/003-pci-fixed-mlo-memory.patch"
fi
if ! grep -A3 'if (!irq_grp->napi_enabled)' "$wifi/drivers/net/wireless/ath/ath12k/pci.c" | grep -q ath12k_pci_ext_grp_enable; then
  patch --batch -p1 -d "$wifi" <"$pkg/../../kernel/mac80211/patches/ath12k/110-wifi-ath12k-guard-external-irq-transitions.patch"
fi
if ! grep -q ath12k_dp_rx_alloc_skb "$wifi/drivers/net/wireless/ath/ath12k/dp_rx.c"; then
  patch --batch -p1 -d "$wifi" <"$pkg/../../kernel/mac80211/patches/ath12k/111-wifi-ath12k-isolate-rxdma-page-frag-caches.patch"
fi
toolchain=($base/staging_dir/toolchain-aarch64_cortex-a53_gcc-*_musl)
export PATH=${toolchain[0]}/bin:$base/staging_dir/host/bin:/usr/sbin:/usr/bin:/sbin:/bin
export STAGING_DIR=$base/staging_dir/target-aarch64_cortex-a53_musl GCC_HONOUR_COPTS=s
version=$(cat "$linux/include/config/kernel.release")
make -C "$wifi" -j"$jobs" ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- \
  KLIB_BUILD="$linux" KERNELRELEASE="$version" MODPROBE=true modules
for file in ath12k.ko wifi7/ath12k_wifi7.ko; do
  install -m 0644 "$wifi/drivers/net/wireless/ath/ath12k/$file" "$root/lib/modules/$version/${file##*/}"
  aarch64-openwrt-linux-musl-strip --strip-debug "$root/lib/modules/$version/${file##*/}"
done
