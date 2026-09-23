Xiaomi BE7000 - OpenWrt snapshot / Linux 6.18 USB installer

Run install.cmd on Windows or sh install.sh on Linux. Enter the current router
IP (stock default: 192.168.32.1; OpenWrt usually: 192.168.1.1) and root SSH password.
A second SSH connection opens the installation menu and may ask for the password
again. No Python, PowerShell or additional network ports are used.

The installer detects Xiaomi stock 1.1.16/1.1.38 or our running USB OpenWrt 6.18.
When an installation exists, choose Update (default), Install from scratch, or
Cancel. A new installation asks for confirmation. The window stays open.

Update creates clean userdata and restores the standard sysupgrade config backup:
package configuration files, /lib/upgrade/keep.d and /etc/sysupgrade.conf rules.
It does not copy old modules, the APK database or all files from the old overlay.
Installed programs come from firmware.bin; extra packages must be reinstalled.
Use attended sysupgrade (ASU) when an image with your selected packages is needed.
Install from scratch erases OpenWrt settings and installed packages in this USB
installation. Both modes preserve this router's Wi-Fi calibration.

On stock, settings are read from the old USB installation without booting it.
The installer asks about USB autostart and starts OpenWrt immediately afterward.
On OpenWrt, the installer adds USB sysupgrade support when missing and updates
through sysupgrade. No preliminary reboot to stock is needed. Stock autostart
configuration is kept; it must already be enabled to return automatically to
OpenWrt after the final reboot. The actual boot still goes through stock/kexec.

Only BE7000-OpenWrt-Snapshot is replaced. No disk formatting or firmware-partition
writes are performed. Connect one mounted ext4 USB partition with 1.5 GiB free.
Do not unplug power/USB during the update. The default fresh userdata is 256 MiB.

To change firmware, replace firmware.bin with our *-native-ext4-sysupgrade.bin.
Do not use an upstream image, a USB tar archive, an initramfs .itb, or a 5.4 image.
The installer kit includes firmware.bin and all helpers needed for offline use.
The firmware defaults to https://openwrt.quarx2k.dev for attended updates; an
existing custom server address is preserved. No kernel ABI change is involved.

Existing network settings/passwords survive Update. Install from scratch uses
standard OpenWrt defaults at http://192.168.1.1/. Configure a root password and
networking/Wi-Fi after a fresh installation.

Progress from an OpenWrt upgrade is logged on USB in boot/offline-upgrade.log
and boot/sysupgrade.log. Stock startup uses boot/logs/installer-start-*.log.
