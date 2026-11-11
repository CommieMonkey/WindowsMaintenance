@echo off
rem ---------------------------------------------------------------------------
rem  Double-click launcher for Run-Maintenance.ps1
rem
rem  - Runs the script with the execution policy bypassed for this one run only
rem    (nothing on your system is changed permanently).
rem  - The script asks for admin rights itself (UAC prompt) and shows the menu.
rem  - Keep this file in the SAME folder as Run-Maintenance.ps1.
rem  - Extra options are passed through, e.g. from a command prompt:
rem        Run-Maintenance.cmd -All
rem        Run-Maintenance.cmd -Steps "1,3,5-6"
rem ---------------------------------------------------------------------------
title PC Maintenance
set "SCRIPT=%~dp0Run-Maintenance.ps1"

if not exist "%SCRIPT%" goto :missing

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
if errorlevel 1 pause
exit /b %errorlevel%

:missing
echo Cannot find Run-Maintenance.ps1 next to this file:
echo   %SCRIPT%
echo.
pause
exit /b 1
