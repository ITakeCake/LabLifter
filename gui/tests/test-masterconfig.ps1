# Master config: the Deployment Tracker's "hide unknown" flag lives in
# master-config.json (moved out of the per-drive gui-settings.json 2026-08-02
# because it is a master-only Tracker setting). Proves read/default,
# write-preserves-siblings, the one-time migration, and the non-master guard.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @('Get-MasterHideUnknown','Set-MasterHideUnknown','Initialize-MasterHideUnknown')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$missing = @($want | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) { "NOT FOUND in source: $($missing -join ', ')"; exit 1 }

$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { $script:pass++; "  ok    $m" } else { $script:fail++; "  FAIL  $m" } }

$sand = Join-Path $env:TEMP ("labdeploy_mastercfg_" + (Get-Random))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
$script:MasterConfigFile = Join-Path $sand 'master-config.json'
$script:GuiSettingsFile  = Join-Path $sand 'gui-settings.json'
$script:IsMaster = $true

'=== default read (no file) ==='
ok (Get-MasterHideUnknown) 'defaults to TRUE when master-config is absent'

'=== write preserves stagingRoot ==='
@{ stagingRoot = 'X:\Staging' } | ConvertTo-Json | Set-Content $script:MasterConfigFile -Encoding UTF8
Set-MasterHideUnknown -Value $false
$cfg = Get-Content $script:MasterConfigFile -Raw | ConvertFrom-Json
ok ($cfg.stagingRoot -eq 'X:\Staging') 'stagingRoot survives the write'
ok ($cfg.hideUnknownMachines -eq $false) 'hideUnknownMachines written'
ok (-not (Get-MasterHideUnknown)) 'read-back returns the written value'

'=== migration from legacy gui-settings ==='
Remove-Item $script:MasterConfigFile -Force
@{ uiScale = 1.0; hideUnknownMachines = $false } | ConvertTo-Json | Set-Content $script:GuiSettingsFile -Encoding UTF8
$eff = Initialize-MasterHideUnknown
ok (-not $eff) 'migration returns the legacy value (false)'
$cfg2 = Get-Content $script:MasterConfigFile -Raw | ConvertFrom-Json
ok ($cfg2.hideUnknownMachines -eq $false) 'legacy value now persisted in master-config'

'=== migration does not clobber an existing master-config value ==='
@{ stagingRoot = 'Y:'; hideUnknownMachines = $true } | ConvertTo-Json | Set-Content $script:MasterConfigFile -Encoding UTF8
@{ hideUnknownMachines = $false } | ConvertTo-Json | Set-Content $script:GuiSettingsFile -Encoding UTF8
$eff2 = Initialize-MasterHideUnknown
ok ($eff2) 'existing master-config value wins over legacy (no clobber)'

'=== non-master guard ==='
$script:IsMaster = $false
Set-MasterHideUnknown -Value $false   # must no-op on a field machine
$cfg3 = Get-Content $script:MasterConfigFile -Raw | ConvertFrom-Json
ok ($cfg3.hideUnknownMachines -eq $true) 'Set-MasterHideUnknown is a no-op on a field machine'

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
