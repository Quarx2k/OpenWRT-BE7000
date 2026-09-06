#!/bin/sh
set -eu
base=/opt/be7000/vendor
for name in cfg80211 mem_manager qdf umac telemetry_agent qca_spectral ipq_cnss2 qca_ol smart_antenna rawmode_sim wifi_3_0 monitor ath_pktlog; do
    echo "$name" >/tmp/owrt7-wlan-phase
    echo "<6>OWRT7: WLAN loading $name" >/dev/kmsg
    echo "$(cat /proc/uptime) insmod $name"
    if [ "$name" = cfg80211 ]; then
        insmod /opt/be7000/wlan/modules/cfg80211.ko be7000_he_compat=1
    elif [ "$name" = umac ]; then
        # The vendor default 21 conflicts with Linux NETLINK_CRYPTO.
        insmod "$base/modules/$name.ko" netlink_band_steering_event=28
    elif [ "$name" = ipq_cnss2 ]; then
        insmod "$base/modules/$name.ko" bdf_pci2=0x02 enable_mlo_support=0
    else
        insmod "$base/modules/$name.ko"
    fi
    echo "<6>OWRT7: WLAN loaded $name" >/dev/kmsg
done
echo complete >/tmp/owrt7-wlan-phase
echo WLAN_LOAD_COMPLETE
