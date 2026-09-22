#!/bin/sh
# Linux host: OpenSSH and tar only.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
finish() { printf '\nPress Enter to close... '; read -r unused || :; }
trap finish EXIT
printf 'Router IP [192.168.32.1]: '
read -r router
router=${router:-192.168.32.1}
case "$router" in *[!0-9.]*|'') echo 'Enter an IPv4 address.'; exit 1;; esac
printf 'Start OpenWrt automatically after reboot? [y/N]: '
read -r answer
case "$answer" in y|Y|yes|YES) auto=yes;; *) auto=no;; esac
test -s firmware.tar.gz || { echo 'Place the build USB archive here as firmware.tar.gz.'; exit 1; }
command -v ssh >/dev/null
command -v tar >/dev/null
echo 'Installing and starting OpenWrt. Enter the stock root SSH password when asked.'
tar -cf - installer firmware.tar.gz | ssh -o ConnectTimeout=10 \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o "HostKeyAlias=be7000-stock-$router" -o StrictHostKeyChecking=accept-new "root@$router" \
    "set -e; echo 'Connected. Installation in progress: transferring files to the router. Please wait...'; mkdir /tmp/be7000-install.lock; trap 'rmdir /tmp/be7000-install.lock' EXIT; touch /tmp/be7000-installing; mkdir -p /tmp/be7000-autostart.lock /tmp/be7000-snapshot-install; tar -xf - -C /tmp/be7000-snapshot-install; sh /tmp/be7000-snapshot-install/installer/router-install.sh $auto"
echo 'OpenWrt startup is scheduled. Wait for the router, then open http://192.168.1.1/ (or your saved LAN address).'
