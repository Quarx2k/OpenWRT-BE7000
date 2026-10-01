#!/usr/bin/env bash
set -euo pipefail
source_dir=${1:?source}
base=${2:?prepared packages}
root=${3:?empty NAND root}
[[ $root == /home/*/root && $root != "$base"/* && ! -e $root ]]
pkg=$source_dir/package/boot/be7000-nand
apk=$base/staging_dir/host/bin/apk
repo=${root%/root}/packages
mkdir -p "$repo" "$root"
mkdir "$root/tmp"
ln -s tmp "$root/var"
while IFS= read -r -d '' file; do
  ln -sf "$file" "$repo/${file##*/}"
done < <(find "$base/bin/packages" "$base/bin/targets/qualcommbe/ipq95xx/packages" -name '*.apk' -print0)
"$apk" mkndx --allow-untrusted -o "$repo/packages.adb" "$repo"/*.apk
printf '%s\n' "$repo/packages.adb" >"$repo/repositories"
mapfile -t packages <"$pkg/packages.list"
"$base/staging_dir/host/bin/fakeroot" "$apk" --root "$root" --arch aarch64_cortex-a53 --initdb --no-scripts --no-network --no-logfile --allow-untrusted \
  --repositories-file "$repo/repositories" add "${packages[@]}"
mkdir -p "$root/etc/rc.d" "$root/var/lock"
(
  cd "$root"
  gzip -dc lib/apk/db/scripts.tar.gz >lib/apk/db/post-install.tar
  tar -C lib/apk/db -xf lib/apk/db/post-install.tar --wildcards '*.post-install'
  for script in lib/apk/db/*.post-install; do
    IPKG_INSTROOT="$root" bash "$script"
    tar --delete -f lib/apk/db/post-install.tar "${script##*/}"
  done
  gzip -n -9 -c lib/apk/db/post-install.tar >lib/apk/db/scripts.tar.gz
  rm lib/apk/db/post-install.tar lib/apk/db/*.post-install
)
while IFS= read -r -d '' file; do
  install -D -m 0644 "$file" "$root/${file#"$pkg/files/"}"
done < <(find "$pkg/files" -type f -print0)
cp "$source_dir/package/utils/luci-app-be7000-wifi/root/usr/libexec/be7000-wifi" "$root/usr/libexec/"
sed -i 's/xiaomi,be7000)/xiaomi,be7000-nand)/g' "$root/etc/board.d/01_leds" "$root/etc/board.d/02_network"
chmod 755 "$root/usr/libexec/be7000-wifi" "$root/usr/libexec/be7000-nand-env" "$root/usr/libexec/be7000-nand-radio" \
  "$root/etc/init.d/be7000-nand-confirm" "$root/etc/init.d/be7000-nand-radio"
ln -sf /tmp/be7000-ath12k.modules "$root/etc/modules.d/ath12k"
ln -s /tmp/be7000-caldata/ath11k.bin "$root/lib/firmware/ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin"
ln -s /tmp/be7000-caldata/ath12k.bin "$root/lib/firmware/ath12k/QCN9274/hw2.0/cal-pci-0002:01:00.0.bin"
(
  cd "$root"
  for script in etc/init.d/*; do
    grep -q '#!/bin/sh /etc/rc.common' "$script" || continue
    IPKG_INSTROOT="$root" bash etc/rc.common "$script" enable
  done
)
printf 'be7000-nand-v1\n' >"$root/etc/be7000-nand-layout"
cp "$pkg/files/lib/upgrade/be7000-nand.sh" "$root/lib/upgrade/platform.sh"
rm "$root/lib/upgrade/be7000-nand.sh"
"$apk" --root "$root" list --installed >"${root%/root}/packages.manifest"
