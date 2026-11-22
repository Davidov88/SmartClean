@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0SmartClean.exe" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Desktop.ps1"
start "" "%~dp0SmartClean.exe"
if errorlevel 1 pause
