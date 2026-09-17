#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

modules=(
    wcss/qcom_q6v5_wcss_sec.ko
    qca-wifi/mem_manager.ko
    qca-wifi/platform/cnss/ipq_cnss2.ko
    qca-wifi/qdf.ko
    qca-wifi/wifi_3_0.ko
    qca-wifi/umac.ko
    qca-wifi/qca_ol.ko
)

fail() { printf 'qcom-wlan: %s\n' "$*" >&2; exit 1; }
usage() {
    echo 'Usage: prebuilt.sh check PACKAGE_BUILD_DIR LINUX_DIR TARGET_CROSS'
    echo '       prebuilt.sh pack  PACKAGE_BUILD_DIR LINUX_DIR TARGET_CROSS OUTPUT_ARCHIVE'
    exit 1
}
(( $# >= 4 )) || usage
action=$1
package_name=$(basename "$2")
package_dir=$(realpath "$2")
linux_dir=$(realpath "$3")
cross=$4

module_vermagic() {
    LC_ALL=C "${cross}readelf" -p .modinfo "$1" | sed -n 's/.* vermagic=//p'
}

check_modules() {
    local dir=$1 module expected actual
    [[ -s $dir/kernel.release && -s $dir/kernel.abi ]] ||
        fail 'Missing binary kernel metadata; use a matching prebuilt archive.'
    [[ $(cat "$dir/kernel.release") == "$(cat "$linux_dir/include/config/kernel.release")" ]] ||
        fail 'Binary kernel release mismatch; rebuild WLAN from source for this kernel.'
    [[ $(cat "$dir/kernel.abi") == "$(cat "$linux_dir/.vermagic")" ]] ||
        fail 'Binary OpenWrt kernel ABI mismatch; rebuild WLAN from source for this configuration.'
    expected=$(module_vermagic "$linux_dir/drivers/soc/qcom/qmi_helpers.ko")
    [[ -n $expected ]] || fail 'Cannot read vermagic from native qmi_helpers.ko.'
    for module in "${modules[@]}"; do
        [[ -s $dir/build/$module ]] || fail "Missing binary module: $module"
        actual=$(module_vermagic "$dir/build/$module")
        [[ $actual == "$expected" ]] || fail "Incompatible module vermagic: $module"
    done
}

case "$action" in
    check)
        (( $# == 4 )) || usage
        check_modules "$package_dir"
        printf 'qcom-wlan: prebuilt modules match kernel %s and its OpenWrt ABI\n' \
            "$(cat "$package_dir/kernel.release")"
        ;;
    pack)
        (( $# == 5 )) || usage
        archive=$(realpath -m "$5")
        [[ ! -e $package_dir/kernel.abi ]] || fail 'Export modules from a source build, not a prebuilt package.'
        stage=$(mktemp -d)
        trap 'rm -rf -- "$stage"' EXIT
        payload=$stage/$package_name
        mkdir -p "$payload"
        cp "$linux_dir/include/config/kernel.release" "$payload/kernel.release"
        cp "$linux_dir/.vermagic" "$payload/kernel.abi"
        for module in "${modules[@]}"; do
            install -D -m 0644 "$package_dir/build/$module" "$payload/build/$module"
            "${cross}strip" --strip-debug "$payload/build/$module"
        done
        check_modules "$payload"
        mkdir -p "$(dirname "$archive")"
        tar -C "$stage" --owner=0 --group=0 --numeric-owner -cJf "$archive.tmp" "$(basename "$payload")"
        mv -- "$archive.tmp" "$archive"
        printf 'qcom-wlan: wrote %s\n' "$archive"
        ;;
    *) usage ;;
esac
