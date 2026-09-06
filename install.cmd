@echo off
cd /d "%~dp0"
if not exist .installer-venv\Scripts\python.exe py -3.12 -m venv .installer-venv
if errorlevel 1 goto fail
.installer-venv\Scripts\python.exe -m pip -q install -r installer\requirements.txt
if errorlevel 1 goto fail
.installer-venv\Scripts\python.exe installer\install.py %*
:fail
pause
