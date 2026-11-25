@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0local\serve_production.ps1" -Directory "%~dp0." -OpenBrowser
if errorlevel 1 pause
