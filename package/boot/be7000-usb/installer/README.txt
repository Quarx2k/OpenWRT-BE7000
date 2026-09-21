Xiaomi BE7000 - OpenWrt snapshot / Linux 6.18 USB installer

1. Boot Xiaomi stock 1.1.16 or 1.1.38 with root SSH already enabled.
2. Connect one ext4 USB partition. At least 2 GB free is recommended.
3. Extract this entire archive. Windows: run install.cmd. Linux: sh install.sh.
4. Enter router IPv4 address, choose autostart, then enter the SSH password.
   Files are installed and OpenWrt starts automatically. The window stays open.

Windows uses its built-in OpenSSH Client and tar.exe (Windows 10/11).
Linux needs OpenSSH Client and tar. No Python, PowerShell, pip or extra ports.
The first SSH connection may require normal host-key confirmation.

To use another build, replace firmware.tar.gz with that build's *-usb.tar.gz.
Only installer-capable Linux 6.18 BE7000 bundles are supported. Do not substitute
an initramfs .itb or a sysupgrade image. System and kernel must be from one build.

Installation uses BE7000-OpenWrt-Snapshot on USB. It never formats the disk.
Existing userdata.img and its settings are kept; initial userdata is created
only when absent. The installer reads this router's stock WLAN calibration.
Installation must run from stock, because the OpenWrt system image is mounted
while OpenWrt is running. Do not unplug power/USB during the update.

OpenWrt is normally at http://192.168.1.1/; an existing installation keeps its
LAN address and passwords. A fresh installation has the standard OpenWrt
defaults: set a root password and configure networking/Wi-Fi in LuCI.

Autostart changes only the named firewall include be7000_snapshot in stock,
with its launcher under /data/BE7000-OpenWrt-Snapshot. The older be7000_openwrt
include is disabled to avoid two launchers. Without USB, stock boots normally.
After three unconfirmed automatic boots, the launcher stays in stock.
To disable autostart from stock:
  uci set firewall.be7000_snapshot.enabled=0
  uci commit firewall
For one-off manual startup in stock, run sh <USB mount>/BE7000-OpenWrt-Snapshot/boot/start.sh.

No automatic retries after a failed installation. Read the error in the open
window. Runtime logs stay on USB under boot/logs and logs/openwrt-<boot-id>.
