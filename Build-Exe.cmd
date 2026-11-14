@echo off
rem ---------------------------------------------------------------------------
rem  Builds Run-Maintenance.exe - double-click this file.
rem
rem  Uses the C# compiler (csc.exe) that is already part of Windows, so there is
rem  nothing to download or install.
rem
rem  Keep these files in the same folder:
rem     Run-Maintenance.ps1   Launcher.cs   app.manifest   Build-Exe.cmd
rem  Optional: put an icon called app.ico in the folder to give the exe an icon.
rem
rem  Run this again every time you change Run-Maintenance.ps1.
rem ---------------------------------------------------------------------------
setlocal
title Build Run-Maintenance.exe
cd /d "%~dp0"

echo.
echo  Building Run-Maintenance.exe ...
echo.

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" goto :nocsc

if not exist "Run-Maintenance.ps1" goto :missing
if not exist "Launcher.cs" goto :missing
if not exist "app.manifest" goto :missing

set "ICON="
if exist "app.ico" set "ICON=/win32icon:app.ico"

if exist "Run-Maintenance.exe" del /q "Run-Maintenance.exe"

"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /out:Run-Maintenance.exe /win32manifest:app.manifest %ICON% /resource:Run-Maintenance.ps1,Run-Maintenance.ps1 /reference:System.Windows.Forms.dll Launcher.cs
if errorlevel 1 goto :failed
if not exist "Run-Maintenance.exe" goto :failed

echo.
echo  Done! Created:
echo    %~dp0Run-Maintenance.exe
echo.
echo  Double-click it to start. Windows will ask for administrator rights.
echo  The first time, Windows SmartScreen may say "Windows protected your PC":
echo  click "More info" and then "Run anyway".
echo.
pause
exit /b 0

:nocsc
echo  Could not find the Windows C# compiler (csc.exe). Expected here:
echo    %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
echo.
echo  It is part of the .NET Framework 4.x that comes with Windows 10 and 11.
echo.
pause
exit /b 1

:missing
echo  One of these files is missing from this folder:
echo    Run-Maintenance.ps1, Launcher.cs, app.manifest
echo.
echo  Put all the files in the same folder and try again.
echo.
pause
exit /b 1

:failed
echo.
echo  The build failed. Read the message above, and send it to the maintainer.
echo.
pause
exit /b 1
