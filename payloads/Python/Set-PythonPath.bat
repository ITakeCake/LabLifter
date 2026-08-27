@echo off
REM Launcher for the Python system-PATH repair (the PythonPath card's install).
REM LabDeploy's exe method runs a file; a .ps1 is not directly runnable that
REM way, so this wrapper is the entry point. All the real work - and the
REM reasoning behind it - lives in Set-PythonPath.ps1 next to this file.
REM LabDeploy already runs elevated (Launch.bat), which the registry write needs.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-PythonPath.ps1"
exit /b %ERRORLEVEL%
