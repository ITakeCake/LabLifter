@echo off
:: ============================================================
::  LabDeploy MASTER - launches the master copy of the tool
:: ============================================================
::  Lives in the LabDeploy folder and locates itself with %~dp0,
::  so moving or renaming the parent folder cannot break it. The
::  desktop shortcut "LabDeploy MASTER" points here.
::
::  This is the master/working copy - the one you edit, and the one
::  scripts\Promote-ToStaging.ps1 pushes out to the sticks.
::
::  Because C:\LabDeployMaster exists on this PC, launching from
::  here gives the master face: Fleet, Assign, Coverage, Config,
::  Sticks and Add App tabs alongside Deploy. On a lab machine
::  the same script shows only Deploy.
::
::  NOTE: deliberately NOT in Promote-ToStaging's allow-list -
::  this is a master convenience launcher and has no business on a
::  stick, where Launch.bat / Launch-Auto.bat are the entry points.
:: ============================================================

set "LABDEPLOY=%~dp0"
if "%LABDEPLOY:~-1%"=="\" set "LABDEPLOY=%LABDEPLOY:~0,-1%"

if not exist "%LABDEPLOY%\Deploy-LabGUI.ps1" (
    echo.
    echo   Deploy-LabGUI.ps1 is not next to this file.
    echo     looked in: %LABDEPLOY%
    echo.
    echo   Keep this .bat inside the LabDeploy folder.
    echo.
    pause
    exit /b 1
)

:: Elevate - installs, BitLocker trust, and the GP/CM actions all need admin.
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%LABDEPLOY%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LABDEPLOY%\Deploy-LabGUI.ps1"
