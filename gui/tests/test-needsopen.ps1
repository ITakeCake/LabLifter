# Proves the "App Opened?" chip and "Open App" button appear ONLY for apps that
# genuinely still require a confirmed first launch. 2026-07-30: not
# opening must not count as a failure unless the app specifically needs it.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Test-AppNeedsOpenConfirm','Update-OpenBox','New-FrozenBrush') -contains $d.Name) { Invoke-Expression $d.Extent.Text }
}
function Test-AppOpened { param($AppId) return $false }   # nothing confirmed on this bench
$script:BrushChipGreen = New-FrozenBrush 0x14 0x5A 0x2E
$script:BrushChipAmber = New-FrozenBrush 0x6E 0x58 0x14
$script:AppsConfig = Get-Content (Join-Path $LabRoot 'config\apps.json') -Raw | ConvertFrom-Json

$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { $script:pass++; "  ok    $m" } else { $script:fail++; "  FAIL  $m" } }

function Get-Vis($id) {
    $card = @{ OBox = (New-Object System.Windows.Controls.Border)
               OText = (New-Object System.Windows.Controls.TextBlock)
               BtnOpenApp = (New-Object System.Windows.Controls.Button) }
    $script:Cards = @{ $id = $card }
    $script:DetectionCache = @{ $id = @{ Installed = $true; UserOnly = $false } }
    Update-OpenBox -AppId $id
    return @{ Chip = "$($card.OBox.Visibility)"; Btn = "$($card.BtnOpenApp.Visibility)" }
}

'--- retired apps: the CHIP must be gone (the button is not chip-gated) ---'
# SPEC CHANGED 2026-08-06: 'Open app' is offered on ANY INSTALLED card,
# not just needsOpen ones - after installing something you often just want to
# launch it, and hunting the Start Menu is the friction this tool removes. So
# these apps keep the button and lose only the confirmation chip. 'Show setup
# prompt' stays needsOpen-only, since a card with no prompt has none to reopen.
foreach ($id in 'MATLAB','Logisim') {
    $v = Get-Vis $id
    ok (-not (Test-AppNeedsOpenConfirm -AppId $id)) "$id no longer requires confirmation"
    ok ($v.Chip -eq 'Collapsed') "$id 'App Opened?' chip hidden"
    ok ($v.Btn  -eq 'Visible')   "$id keeps 'Open app' (installed, chip-independent)"
}

'--- apps with a real first-run step: both must remain ---'
foreach ($id in 'ArduinoIDE','LTSpice','LabChart','RavenLite') {
    $v = Get-Vis $id
    ok (Test-AppNeedsOpenConfirm -AppId $id) "$id still requires confirmation"
    ok ($v.Chip -eq 'Visible') "$id chip still shown"
    ok ($v.Btn  -eq 'Visible') "$id Open App button still shown"
}

'--- apps that never had the concept ---'
foreach ($id in 'Wireshark','PuTTY','Python') {
    $v = Get-Vis $id
    ok (-not (Test-AppNeedsOpenConfirm -AppId $id)) "$id never asks"
    ok ($v.Chip -eq 'Collapsed') "$id shows no confirmation chip"
    ok ($v.Btn  -eq 'Visible')   "$id still offers 'Open app' (installed)"
}

'--- not-installed apps never show them either ---'
$card = @{ OBox=(New-Object System.Windows.Controls.Border); OText=(New-Object System.Windows.Controls.TextBlock); BtnOpenApp=(New-Object System.Windows.Controls.Button) }
$script:Cards = @{ ArduinoIDE = $card }
$script:DetectionCache = @{ ArduinoIDE = @{ Installed = $false; UserOnly = $false } }
Update-OpenBox -AppId 'ArduinoIDE'
ok ("$($card.OBox.Visibility)" -eq 'Collapsed' -and "$($card.BtnOpenApp.Visibility)" -eq 'Collapsed') 'uninstalled app shows neither control'

'--- one helper is the single source of truth ---'
$src = Get-Content $f -Raw
$stray = @([regex]::Matches($src, 'apps\.\$\w+\.needsOpen|appDef\.needsOpen'))
ok ($stray.Count -eq 1) "only the helper itself reads needsOpen directly (found $($stray.Count), want 1)"
ok ($src -notmatch '\$asksOpen') 'the duplicated inline askAfterOpen logic is gone'

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
