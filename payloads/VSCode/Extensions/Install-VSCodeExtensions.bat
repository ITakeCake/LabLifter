@echo off
REM Launcher for the VS Code extension seeding step (ENG 5105).
REM LabDeploy's exe method runs a file; PowerShell scripts are not directly
REM runnable that way, so this two-line wrapper is the entry point. All the
REM real work - and all the comments explaining it - live in the .ps1.
REM LabDeploy already runs elevated (Launch.bat), so no self-elevation here.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VSCodeExtensions.ps1"
exit /b %ERRORLEVEL%
