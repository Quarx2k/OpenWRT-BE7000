#!/bin/bash
set -euo pipefail
tree=${1:?OpenWrt build tree required}
patches=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/luci-patches" && pwd)
for patch in "$patches"/*.patch; do
    if git -C "$tree/feeds/luci" apply --reverse --check "$patch" 2>/dev/null; then
        continue
    fi
    git -C "$tree/feeds/luci" apply --check "$patch"
    git -C "$tree/feeds/luci" apply "$patch"
done
