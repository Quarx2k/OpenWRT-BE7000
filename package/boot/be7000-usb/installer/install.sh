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
test -s firmware.bin || { echo 'Place our BE7000 sysupgrade image here as firmware.bin.'; exit 1; }
command -v ssh >/dev/null
command -v tar >/dev/null
set -- -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o "HostKeyAlias=be7000-stock-$router" -o StrictHostKeyChecking=accept-new
echo 'Enter the current root SSH password. It may be requested again for the installation menu.'
tar -cf - installer firmware.bin | ssh "$@" "root@$router" \
    "set -e; echo 'Connected. Transferring firmware; please wait...'; mkdir /tmp/be7000-install.lock; trap 'rmdir /tmp/be7000-install.lock' EXIT; touch /tmp/be7000-installing; mkdir -p /tmp/be7000-snapshot-install; tar -xf - -C /tmp/be7000-snapshot-install; echo 'Transfer complete.'"
ssh -t "$@" "root@$router" 'sh /tmp/be7000-snapshot-install/installer/router-install.sh'
