#!/bin/sh
set -eu
# Native first-boot DHCP defaults need the board's LAN protocol before S10boot.
[ -s /etc/board.json ] || /bin/board_detect
[ ! -e /etc/be7000-provisioned ] || exit 0
. /mnt/usb/BE7000-OpenWrt/device/provision.env
uci set system.@system[0].hostname='BE7000-OpenWrt'
uci set wireless.default_radio0.macaddr="$WIFI_MAC_2G"
uci set wireless.default_radio1.macaddr="$WIFI_MAC_5G"
uci set dhcp.lan.force='1'
uci set dhcp.lan.start='2'
uci set dhcp.lan.limit='248'
if grep -q 'be7000_diagnostic=1' /proc/cmdline; then
    uci del_list network.@device[0].ports=eth1
fi
uci commit system
uci commit wireless
uci commit network
uci commit dhcp
# Standard OpenWrt first login: set the root password in LuCI over wired LAN.
awk -F: -v OFS=: '$1=="root" {$2=""} {print}' /etc/shadow >/etc/shadow.new
chmod 600 /etc/shadow.new
mv /etc/shadow.new /etc/shadow
touch /etc/be7000-provisioned
sync
