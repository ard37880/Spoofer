@echo off
rem ---------------------------------------------------------------------------
rem Convenience launcher for Spoofer.ps1.
rem
rem Run it with no arguments, or double-click it, for the menu. Spoofer.ps1 asks
rem Windows for administrator rights itself, so this does not have to elevate
rem first; it only bypasses the execution policy for this one process, changing
rem nothing machine-wide.
rem
rem     Spoofer.cmd
rem     Spoofer.cmd -Action Status
rem     Spoofer.cmd -Action Spoof -Exclude digitalproductid,volumeserial
rem ---------------------------------------------------------------------------
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Spoofer.ps1" %*
echo.
pause
