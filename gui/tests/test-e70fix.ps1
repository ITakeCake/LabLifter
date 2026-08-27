# Proves the exact crash recorded in the 11:47 master session is gone:
#   event=master.tabs_error  errorCode=E70
#   at Update-SavedConfigList line 3214
#   "You cannot call a method on a null-valued expression"
# Root cause was the collection-nesting bug: $named = @(Get-NamedConfigs)
# produced ONE element that was the whole (empty) list, so $nc.Saved was $null
# and .ToString() threw.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
# Staging normally sits beside the Installers folder; overridable so a machine
# that keeps it elsewhere (or nowhere) can still run the rest of the suite.
# On a master, master-config.json is the authority on where staging lives.
$StagingRoot = if ($env:LABDEPLOY_STAGING) { $env:LABDEPLOY_STAGING }
               elseif (Test-Path 'C:\LabDeployMaster\master-config.json') {
                   (Get-Content 'C:\LabDeployMaster\master-config.json' -Raw | ConvertFrom-Json).stagingRoot
               }
               else { Join-Path (Split-Path (Split-Path $LabRoot -Parent) -Parent) 'LabDeploy-Flash-Staging' }
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Update-SavedConfigList','Get-NamedConfigs','Get-ConfigSnapshots','New-FleetRow','New-FrozenBrush') -contains $d.Name) {
        Invoke-Expression $d.Extent.Text
    }
}
function Write-LabLog { param($Event, $Data) }
$script:BrushText       = New-FrozenBrush 0xE0 0xE0 0xE0
$script:BrushMuted      = New-FrozenBrush 0x78 0x78 0x78
$script:BrushBtnBlue    = New-FrozenBrush 0x1F 0x4A 0x6E
$script:BrushBtnNeutral = New-FrozenBrush 0x50 0x50 0x58
$script:FleetColors     = @{ card = New-FrozenBrush 0x2D 0x2D 0x33 }
$script:MW = @{ pnlSavedCfg = (New-Object System.Windows.Controls.StackPanel)
                pnlSnapList = (New-Object System.Windows.Controls.StackPanel) }

$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { $script:pass++; "  ok    $m" } else { $script:fail++; "  FAIL  $m" } }

$sand = Join-Path $env:TEMP ("labdeploy_e70_" + (Get-Random))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
$ConfigRoot = $sand
$script:SavedConfigRoot = Join-Path $sand 'saved'

'--- the exact 11:47 case: master with ZERO saved configs ---'
$threw = $null
try { Update-SavedConfigList } catch { $threw = $_.Exception.Message }
ok ($null -eq $threw) "no crash$(if($threw){" -- still throws: $threw"})"
ok ($script:MW.pnlSavedCfg.Children.Count -eq 1) "exactly one row: the empty-state message (got $($script:MW.pnlSavedCfg.Children.Count))"
ok ("$($script:MW.pnlSavedCfg.Children[0].Child.Text)" -match 'Nothing saved yet') 'empty-state message fires (it never did before the fix)'
ok ($script:MW.pnlSnapList.Children.Count -eq 1) 'snapshot list shows its own empty state'

'--- one saved config + one snapshot (the other nesting trap) ---'
New-Item -ItemType Directory -Path (Join-Path $sand 'saved\Summer 2026') -Force | Out-Null
'{}' | Set-Content (Join-Path $sand 'saved\Summer 2026\apps.json')
New-Item -ItemType Directory -Path (Join-Path $sand 'snapshots') -Force | Out-Null
'{}' | Set-Content (Join-Path $sand 'snapshots\apps.json.20260730_120000123.bak')
$threw = $null
try { Update-SavedConfigList } catch { $threw = $_.Exception.Message }
ok ($null -eq $threw) "no crash with 1 of each$(if($threw){" -- $threw"})"
ok ($script:MW.pnlSavedCfg.Children.Count -eq 1) "one saved-config row (got $($script:MW.pnlSavedCfg.Children.Count))"
ok ($script:MW.pnlSnapList.Children.Count -eq 1) "one snapshot row (got $($script:MW.pnlSnapList.Children.Count))"
$rowTxt = "$($script:MW.pnlSavedCfg.Children[0].Child.Children[1].Text)"
ok ($rowTxt -match 'Summer 2026' -and $rowTxt -match '1 file') "row renders real values: '$rowTxt'"
$snapTxt = "$($script:MW.pnlSnapList.Children[0].Child.Children[1].Text)"
ok ($snapTxt -match 'apps\.json') "millisecond-stamped snapshot parsed and listed: '$snapTxt'"

'--- and the fix is what actually shipped to staging ---'
$stgFile = Join-Path $StagingRoot 'LabDeployment\LabDeploy\Deploy-LabGUI.ps1'
if (Test-Path $stgFile) {
    $stg = Get-Content $stgFile -Raw
    ok ($stg -match '\$named = Get-NamedConfigs')      'staging carries the fixed Get-NamedConfigs call site'
    ok ($stg -match '\$snaps = Get-ConfigSnapshots')   'staging carries the fixed Get-ConfigSnapshots call site'
    ok ($stg -notmatch '@\(Get-NamedConfigs\)')        'no @() wrap remains anywhere in staging'
} else {
    "  SKIP  no staging tree at $StagingRoot - 3 staging checks skipped."
    "        (Run scripts\Promote-ToStaging.ps1 to create it, or point `$env:LABDEPLOY_STAGING at it.)"
}

''
"PASS $pass   FAIL $fail"
"(sandbox left at $sand)"
if ($fail -gt 0) { exit 1 }
