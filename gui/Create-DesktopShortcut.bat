@echo off
:: Puts a "LabLifter" shortcut on the desktop, with the purple LabDeploy icon,
:: pointing at Launch.bat (which self-elevates). Run once after cloning.
powershell -NoProfile -Command ^
  "$ws = New-Object -ComObject WScript.Shell;" ^
  "$lnk = $ws.CreateShortcut([IO.Path]::Combine($env:USERPROFILE, 'Desktop', 'LabLifter.lnk'));" ^
  "$lnk.TargetPath = '%~dp0Launch.bat';" ^
  "$lnk.WorkingDirectory = '%~dp0';" ^
  "$lnk.IconLocation = '%~dp0tools\labdeploy-master.ico';" ^
  "$lnk.Description = 'LabLifter - lab software deployment';" ^
  "$lnk.Save();" ^
  "Write-Host 'Desktop shortcut created.'"
pause
