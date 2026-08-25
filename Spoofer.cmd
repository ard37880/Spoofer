@echo off
rem ---------------------------------------------------------------------------
rem Convenience launcher for Spoofer.ps1.
rem
rem Bypasses the execution policy for this process only - nothing machine-wide is
rem changed - and forwards any arguments through. Spoofer.ps1 asks Windows for
rem administrator rights itself when the action needs them, so this does not have
rem to elevate first:
rem
rem     Spoofer.cmd
rem     Spoofer.cmd -Action Spoof -Interactive
rem     Spoofer.cmd -Action Spoof -Exclude digitalproductid,volumeserial
rem ---------------------------------------------------------------------------
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Spoofer.ps1" %*
echo.
pause
