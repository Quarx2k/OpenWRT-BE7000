@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
where ssh.exe >nul 2>nul
if errorlevel 1 goto tools
where tar.exe >nul 2>nul
if errorlevel 1 goto tools
if not exist factory.ubi goto failed
set "ROUTER_IP=192.168.32.1"
set /p "ROUTER_IP=Router IP [192.168.32.1]: "
set ROUTER_IP | findstr /r /x "ROUTER_IP=[0-9.][0-9.]*" >nul
if errorlevel 1 (
 echo Enter an IPv4 address.
 goto failed
)
echo This installs OpenWrt in the opposite NAND slot and reboots the router.
echo First boot erases the stock data/settings partition. Backups are saved on this PC.
set "CONFIRM="
set /p "CONFIRM=Type YES to install: "
set CONFIRM | findstr /i /x "CONFIRM=YES" >nul
if errorlevel 1 goto cancelled
set "SESSION=%RANDOM%-%RANDOM%"
set "REMOTE_DIR=/tmp/be7000-nand-install-%SESSION%"
set "BACKUP=backups\%ROUTER_IP%-%SESSION%.tar"
if not exist backups mkdir backups
if errorlevel 1 goto failed
set "SSH_OPTIONS=-o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o GlobalKnownHostsFile=NUL"
echo Enter the current root SSH password. It will be requested again to start flashing.
tar.exe -cf - installer/router-install.sh factory.ubi | ssh.exe %SSH_OPTIONS% root@%ROUTER_IP% "set -e; umask 077; mkdir '%REMOTE_DIR%'; tar -xf - -C '%REMOTE_DIR%'; sh '%REMOTE_DIR%/installer/router-install.sh' prepare" >"%BACKUP%"
if errorlevel 1 goto failed
tar.exe -tf "%BACKUP%" >nul
if errorlevel 1 goto failed
echo Backups saved: %CD%\%BACKUP%
ssh.exe %SSH_OPTIONS% root@%ROUTER_IP% "sh '%REMOTE_DIR%/installer/router-install.sh' flash"
if errorlevel 1 goto failed
echo Done. Wait for OpenWrt to boot, then open http://192.168.1.1
pause
exit /b 0
:tools
echo Windows OpenSSH Client and tar.exe are required.
:failed
echo Installation did not finish. Read the message above. Do not reboot if flashing failed.
pause
exit /b 1
:cancelled
echo Cancelled.
pause
exit /b 0
