@echo off
:: LabLifter - UNATTENDED launcher with auto-elevation.
::
:: Same tool as Launch.bat, but it presses "Install All Missing" for you once
:: it has worked out which machine this is.
::
:: It only does that when the hostname matches a known room profile or
:: deployment rule. On a machine it does not recognise it installs NOTHING and
:: waits for a person - guessing a package set is how the wrong multi-GB image
:: ends up on someone's PC.
::
:: Every normal safeguard still applies: it needs admin, it still asks about an
:: old/unimaged machine, it still refuses to start on a pending reboot, and it
:: still installs one program at a time in dependency order.
::
:: Use Launch.bat instead if you want to pick and choose by hand.

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-LabGUI.ps1" -Auto
