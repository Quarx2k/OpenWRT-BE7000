#!/bin/sh
set -eu
load() {
    name=$1; shift
    normalized=$(echo "$name" | tr - _)
    [ ! -d "/sys/module/$normalized" ] || return 0
    echo "Loading $name $*"
    insmod "/lib/modules/$(uname -r)/$name.ko" "$@"
}

exec > /tmp/be7000-crypto.log 2>&1
firmware=/lib/firmware
if [ -s "$firmware/ifpp.bin" ] && [ -s "$firmware/ipue.bin" ] && \
   [ -s "$firmware/ofpp.bin" ] && [ -s "$firmware/opue.bin" ]; then
    for name in authenc qca-nss-eip qca-nss-eip-crypto xfrm_algo esp4 esp6; do
        load "$name"
    done
    [ ! -d /sys/module/ecm ] || load qca-nss-eip-ipsec
else
    echo 'EIP197 skipped: firmware was not collected by the installer'
    exit 0
fi
echo 'EIP197 crypto and IPsec ready'
