@echo off
REM Vintage Story friend mod-sync launcher — just double-click this file.
REM Needs nothing installed; uses Windows' built-in PowerShell.
REM Keep this .bat in the SAME folder as friend_sync.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0friend_sync.ps1" %*
echo.
pause
