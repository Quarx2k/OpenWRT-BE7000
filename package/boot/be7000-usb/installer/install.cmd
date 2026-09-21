@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
where ssh.exe >nul 2>nul
if errorlevel 1 goto tools
where tar.exe >nul 2>nul
if errorlevel 1 goto tools
if not exist firmware.tar.gz (
 echo Place the build USB archive here as firmware.tar.gz.
 goto failed
)
set "ROUTER_IP=192.168.31.1"
set /p "ROUTER_IP=Router IP [192.168.31.1]: "
set ROUTER_IP | findstr /r /x "ROUTER_IP=[0-9.][0-9.]*" >nul
if errorlevel 1 (
 echo Enter an IPv4 address.
 goto failed
)
choice /c YN /n /m "Start OpenWrt automatically after reboot? [Y/N]: "
if errorlevel 3 goto failed
if errorlevel 2 (set "AUTOSTART=no") else (set "AUTOSTART=yes")
echo Installing and starting OpenWrt. Enter the stock root SSH password when asked.
tar.exe -cf - installer firmware.tar.gz | ssh.exe -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new root@%ROUTER_IP% "set -e; mkdir /tmp/be7000-install.lock; trap 'rmdir /tmp/be7000-install.lock' EXIT; touch /tmp/be7000-installing; mkdir -p /tmp/be7000-autostart.lock /tmp/be7000-snapshot-install; tar -xf - -C /tmp/be7000-snapshot-install; sh /tmp/be7000-snapshot-install/installer/router-install.sh %AUTOSTART%"
if errorlevel 1 goto failed
echo OpenWrt startup is scheduled. Wait for the router, then open http://192.168.1.1/ or your saved LAN address.
pause
exit /b 0
:tools
echo Windows OpenSSH Client and tar.exe are required. No Python or PowerShell is used.
:failed
echo Installation did not finish. Read the message above.
pause
exit /b 1
