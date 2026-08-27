@echo off
rem ============================================================
rem  VS2015 Isolated Shell scout  (Rockwell CCW prerequisite)
rem
rem  WHY: LabDeploy twice detected this product with paths that turned
rem  out not to exist (VSIsoShell.exe, then appenv.exe) while the shell
rem  itself installed fine - the bundle's registry key said INSTALLED
rem  but nobody had ground truth about the FILES. This prints exactly
rem  what is (and is not) on this machine, to a text file next to this
rem  script, so the detect paths never have to be guessed again.
rem
rem  Run by double-click on the lab machine. No admin needed. ~30s.
rem  Output: vsshell-scout-<COMPUTERNAME>.txt beside this script.
rem ============================================================
setlocal EnableExtensions
set "OUT=%~dp0vsshell-scout-%COMPUTERNAME%.txt"
set "VSROOT=C:\Program Files (x86)\Microsoft Visual Studio 14.0"

echo VS2015 Isolated Shell scout - %DATE% %TIME% - %COMPUTERNAME% > "%OUT%"

echo.>> "%OUT%"
echo === 1. the bundle registry key the wrapper trusts === >> "%OUT%"
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{030A6785-C3A9-37DA-8530-444C320629FA}" >> "%OUT%" 2>&1

echo.>> "%OUT%"
echo === 2. every 'Isolated Shell' entry in Add/Remove === >> "%OUT%"
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" /f "Isolated Shell" /s >> "%OUT%" 2>&1

echo.>> "%OUT%"
echo === 3. does the VS 14.0 tree exist, and what is in it === >> "%OUT%"
if exist "%VSROOT%\" (echo EXISTS: %VSROOT%) else (echo MISSING: %VSROOT%) >> "%OUT%"
dir "%VSROOT%" /b >> "%OUT%" 2>&1

echo.>> "%OUT%"
echo === 4. LabDeploy detect candidates (current + both failed guesses) === >> "%OUT%"
for %%P in (
    "%VSROOT%\Common7\IDE\CommonExtensions\Platform\Shell"
    "%VSROOT%\Common7\IDE\ShellExtensions\AppEnvBaseConfig"
    "%VSROOT%\Common7\IDE\ShellExtensions\AppEnvBaseConfig\BaseConfig.pkgdef"
    "%VSROOT%\Common7\IDE\PrivateAssemblies"
    "%VSROOT%\Common7\IDE\appenv.exe"
    "%VSROOT%\Common7\IDE\devenv.exe"
    "%VSROOT%\Common7\IDE\VSIsoShell.exe"
) do (
    if exist "%%~P" (echo EXISTS   %%~P) else (echo missing  %%~P) >> "%OUT%"
)

echo.>> "%OUT%"
echo === 5. contents of Common7\IDE (if present) === >> "%OUT%"
dir "%VSROOT%\Common7\IDE" /b >> "%OUT%" 2>&1

echo.>> "%OUT%"
echo === 6. any appenv.exe anywhere under Program Files (x86)? === >> "%OUT%"
where /r "C:\Program Files (x86)" appenv.exe >> "%OUT%" 2>&1

echo.>> "%OUT%"
echo === 7. Rockwell CCW itself === >> "%OUT%"
if exist "C:\Program Files (x86)\Rockwell Automation\Connected Components Workbench\CCW.Shell.exe" (echo EXISTS: CCW.Shell.exe) else (echo missing: CCW.Shell.exe) >> "%OUT%"

echo done. >> "%OUT%"
echo.
echo Scout finished. Results written to:
echo   %OUT%
echo Bring this stick back to the master (or read the file anywhere).
pause
