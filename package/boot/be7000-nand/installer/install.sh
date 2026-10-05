#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
printf 'Router IP [192.168.32.1]: '
read -r router
router=${router:-192.168.32.1}
[[ $router != *[!0-9.]* ]] || { echo 'Enter an IPv4 address.'; exit 1; }
test -s factory.ubi
command -v ssh >/dev/null
command -v tar >/dev/null
echo 'From stock: installs into the opposite NAND slot and erases stock settings.'
echo 'From BE7000 NAND OpenWrt: builds an ASU image with your packages and keeps settings.'
echo 'The router reboots afterwards. Backups are saved on this PC.'
read -r -p 'Type YES to install: ' confirm
[[ ${confirm^^} == YES ]] || { echo 'Cancelled.'; exit 0; }
session=$RANDOM-$RANDOM
remote=/tmp/be7000-nand-install-$session
backup=backups/$router-$session.tar
mkdir -p backups
ssh_options=(-o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null)
echo 'Enter the current root SSH password. It will be requested again to start flashing.'
tar -cf - installer/router-install.sh installer/fix-sysupgrade.sh factory.ubi | ssh "${ssh_options[@]}" "root@$router" \
    "set -e; umask 077; mkdir '$remote'; tar -xf - -C '$remote'; sh '$remote/installer/router-install.sh' prepare" >"$backup"
tar -tf "$backup" >/dev/null
echo "Backups saved: $PWD/$backup"
install_tty=()
if tar -tf "$backup" | grep -q '^backup/active-mtd$'; then
    install_tty=(-t)
fi
ssh "${install_tty[@]}" "${ssh_options[@]}" "root@$router" "sh '$remote/installer/router-install.sh' flash"
echo 'Done. Wait for OpenWrt to boot, then open http://192.168.1.1'
