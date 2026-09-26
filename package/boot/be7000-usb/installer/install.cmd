@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
where ssh.exe >nul 2>nul
if errorlevel 1 goto tools
where tar.exe >nul 2>nul
if errorlevel 1 goto tools
if not exist firmware.bin (
 echo Place our BE7000 sysupgrade image here as firmware.bin.
 goto failed
)
set "ROUTER_IP=192.168.32.1"
set /p "ROUTER_IP=Router IP [192.168.32.1]: "
set ROUTER_IP | findstr /r /x "ROUTER_IP=[0-9.][0-9.]*" >nul
if errorlevel 1 (
 echo Enter an IPv4 address.
 goto failed
)
set "SSH_OPTIONS=-o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o GlobalKnownHostsFile=NUL"
echo Enter the current root SSH password. It may be requested again for the installation menu.
tar.exe -cf - installer firmware.bin | ssh.exe %SSH_OPTIONS% root@%ROUTER_IP% "set -e; echo 'Connected. Transferring firmware; please wait...'; mkdir /tmp/be7000-install.lock; transferred=no; trap 'rmdir /tmp/be7000-install.lock; [ $transferred = yes ] || rm -f /tmp/be7000-installing' EXIT; trap 'exit 1' HUP INT TERM; touch /tmp/be7000-installing; mkdir -p /tmp/be7000-snapshot-install; tar -xf - -C /tmp/be7000-snapshot-install; transferred=yes; echo 'Transfer complete.'"
if errorlevel 1 goto failed
ssh.exe -t %SSH_OPTIONS% root@%ROUTER_IP% "sh /tmp/be7000-snapshot-install/installer/router-install.sh"
if errorlevel 1 goto failed
pause
exit /b 0
:tools
echo Windows OpenSSH Client and tar.exe are required. No Python or PowerShell is used.
:failed
echo Installation did not finish. Read the message above.
pause
exit /b 1
