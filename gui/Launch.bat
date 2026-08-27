@echo off
:: LabLifter - Launcher with auto-elevation
:: Double-click this to start the GUI.

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-LabGUI.ps1"
