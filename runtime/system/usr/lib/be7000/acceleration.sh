#!/bin/sh
set -eu
load() {
    name=$1; shift
    normalized=$(echo "$name" | tr - _)
    [ ! -d "/sys/module/$normalized" ] || return 0
    echo "Loading $name $*"
    insmod "/lib/modules/$(uname -r)/$name.ko" "$@"
}

for name in udp_tunnel ip6_udp_tunnel bonding vxlan l2tp_core l2tp_netlink l2tp_ppp nf_conncount \
    qca-nss-ppe-rule qca-nss-ppe-vlan qca-nss-ppe-pppoe-mgr qca-nss-ppe-bridge-mgr \
    qca-nss-ppe-lag qca-nss-ppe-vp qca-nss-sfe emesh-sp \
    qca-nss-ppe-ds qca-nss-ppe-tun qca-nss-ppe-gretap qca-nss-ppe-mapt \
    qca-nss-ppe-tunipip6 qca-nss-ppe-vxlanmgr; do
    load "$name"
done

# Respect a user's choice of the standard nftables flow-offload engine.
if [ "$(uci -q get firewall.@defaults[0].flow_offloading || true)" = 1 ]; then
    echo 'ECM skipped: nftables flow offloading is enabled'
else
    load ecm front_end_selection=3
    if [ -d /sys/module/umac ] && [ -d /sys/module/wifi_3_0 ]; then
        load ecm-wifi-plugin
    fi
    load qca-nss-nsm
fi

echo 'Network acceleration modules ready (PPE frontend; check flow counters under traffic)'
