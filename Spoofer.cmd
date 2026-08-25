@echo off
rem ---------------------------------------------------------------------------
rem Convenience launcher for Spoofer.ps1.
rem
rem Elevates if it has to, bypasses the execution policy for this process only
rem (nothing machine-wide is changed), and forwards any arguments through:
rem
rem     Spoofer.cmd
rem     Spoofer.cmd -Action Status
rem     Spoofer.cmd -Action Spoof -Module machineguid,mac
rem ---------------------------------------------------------------------------
setlocal

net session >nul 2>&1
if not errorlevel 1 goto run

echo Spoofer needs administrator rights. Approve the prompt to reopen it elevated.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath cmd.exe -ArgumentList '/k','\"%~f0\" %*'"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Spoofer.ps1" %*
echo.
pause
