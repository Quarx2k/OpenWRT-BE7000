#!/bin/sh
# Require working local management for 30 consecutive seconds, not Internet/Wi-Fi.
good=0
left=180
while [ "$left" -gt 0 ]; do
    if ubus call system board >/dev/null 2>&1 &&
       [ "$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.up')" = true ] &&
       pidof rpcd >/dev/null && pidof uhttpd >/dev/null && pidof dropbear >/dev/null; then
        if [ "$good" -ge 30 ]; then
            /usr/sbin/be7000-boot success
            exit $?
        fi
        good=$((good + 2))
    else
        good=0
    fi
    sleep 2
    left=$((left - 2))
done
logger -t be7000-boot 'Boot not confirmed: LAN or management services unavailable'
exit 1
