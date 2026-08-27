# Bug test for the last batch ONLY:
#   1. Desktop-icon policy (Test-/Set-AppAutoShortcut) - incl. the full
#      apps.json rewrite it performs, proven semantically lossless
#   2. Update-ShortcutBox exception-only chip (only missing shows anything)
#   3. Temp cleanup survey + deletion mechanics
#   4. Wiring: button handlers and checkbox actually attached
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$src = Get-Content $f -Raw
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Test-AppAutoShortcut','Set-AppAutoShortcut','Backup-ConfigSnapshot','Publish-ConfigToStaging',
          'Update-ShortcutBox','Get-LabDeployTempItems','New-FrozenBrush') -contains $d.Name) {
        Invoke-Expression $d.Extent.Text
    }
}
function Write-LabLog { param($Event, $Data) $script:LogEvents += ,@($Event) }
$script:LogEvents = @()
$txtStatus = New-Object System.Windows.Controls.TextBlock

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }

# ---- sandbox: a COPY of the real apps.json; publish disabled ----
$sand = Join-Path $env:TEMP ("labdeploy_lastbatch_" + (Get-Random))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
Copy-Item (Join-Path $LabRoot 'config\apps.json') (Join-Path $sand 'apps.json')
$ConfigRoot = $sand
$script:IsMaster = $false   # Publish-ConfigToStaging no-ops

'=== 1. shortcut policy round-trip on the REAL apps.json content (sandboxed) ==='
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (Test-AppAutoShortcut -AppId 'MATLAB') 'MATLAB defaults ON (field absent)'
ok (-not (Test-AppAutoShortcut -AppId 'Python')) 'Python (noShortcut) reads OFF'
ok (Test-AppAutoShortcut -AppId 'NoSuchApp') 'unknown id defaults ON, no crash'

ok (Set-AppAutoShortcut -AppId 'MATLAB' -Enabled $false) 'toggle MATLAB OFF saves'
ok (-not (Test-AppAutoShortcut -AppId 'MATLAB')) 'in-memory config reloaded: MATLAB now OFF'
$disk = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($disk.apps.MATLAB.autoShortcut -eq $false) 'on-disk autoShortcut = false'
ok (Set-AppAutoShortcut -AppId 'MATLAB' -Enabled $true) 'toggle back ON saves'
$disk = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($disk.apps.MATLAB.autoShortcut -eq $true) 'on-disk autoShortcut = true'
ok ((Test-Path (Join-Path $sand 'snapshots')) -and @(Get-ChildItem (Join-Path $sand 'snapshots') -Filter 'apps.json.*.bak').Count -ge 2) 'a snapshot was taken before EACH write'
ok (-not (Set-AppAutoShortcut -AppId 'NoSuchApp' -Enabled $false)) 'unknown app refuses politely'

'--- the rewrite must be semantically lossless (it re-serializes all 42 cards) ---'
$py = @'
import json, io, sys
a = json.load(io.open(sys.argv[1], encoding='utf-8-sig'))
b = json.load(io.open(sys.argv[2], encoding='utf-8-sig'))
# remove the one field the test added, then demand exact equality
b['apps']['MATLAB'].pop('autoShortcut', None)
def norm(x): return json.dumps(x, sort_keys=True)
print('IDENTICAL' if norm(a) == norm(b) else 'DIFFER')
if norm(a) != norm(b):
    ka = set(a['apps']); kb = set(b['apps'])
    print('apps only in original:', sorted(ka-kb)); print('apps only in rewritten:', sorted(kb-ka))
    for k in sorted(ka & kb):
        if norm(a['apps'][k]) != norm(b['apps'][k]): print('first differing app:', k); break
'@
$pyf = Join-Path $sand 'cmp.py'
$py | Set-Content $pyf -Encoding UTF8
$r = & python $pyf (Join-Path $LabRoot 'config\apps.json') (Join-Path $sand 'apps.json') 2>&1
ok ("$r" -match 'IDENTICAL') "double-toggle rewrite is byte-for-meaning lossless: $r"

'=== 2. Update-ShortcutBox exception-only chip (Rail declutter) ==='
# Contract since the Rail card port: OK states show NOTHING. Present is
# silence; deliberately-off is a policy the Desktop-icon checkbox already
# shows. Only installed + policy ON + missing earns a chip.
$script:BrushChipBadInk = New-FrozenBrush 0xFF 0xB3 0xB3
$script:BrushChipBadBg  = New-FrozenBrush 0x6E 0x1E 0x1E
$script:BrushChipBadBrd = New-FrozenBrush 0x8E 0x2E 0x2E
function Test-AppShortcut { param([string]$AppId) return @{ Applicable = $true; Present = $script:StubPresent; Lnk = $null; NameOk = $true } }
$card = @{ SBox = (New-Object System.Windows.Controls.Border)
           SText = (New-Object System.Windows.Controls.TextBlock)
           BtnShortcut = (New-Object System.Windows.Controls.Button) }
$script:Cards = @{ MATLAB = $card }
$script:DetectionCache = @{ MATLAB = @{ Installed = $true; UserOnly = $false } }
$Vis = [System.Windows.Visibility]::Visible
$Col = [System.Windows.Visibility]::Collapsed

$script:StubPresent = $false
Update-ShortcutBox -AppId 'MATLAB'      # policy currently ON (toggled back above)
ok ($card.SBox.Visibility -eq $Vis -and $card.SText.Text -match [char]0x2717) "policy ON + missing -> the ONE state that shows a chip ('$($card.SText.Text)')"
ok ($card.SBox.Background.Equals($script:BrushChipBadBg)) 'chip uses the Bad palette, and the chip is the fix'
ok ($card.BtnShortcut.Visibility -eq $Vis) 'menu row reachable while a shortcut applies'
$script:AppsConfig.apps.MATLAB.autoShortcut = $false
Update-ShortcutBox -AppId 'MATLAB'
ok ($card.SBox.Visibility -eq $Col) 'policy OFF + missing -> NO chip (the checkbox already says off)'
ok ($card.BtnShortcut.Visibility -eq $Vis) 'menu row still reachable with policy OFF'
$script:AppsConfig.apps.MATLAB.autoShortcut = $true
$script:StubPresent = $true
Update-ShortcutBox -AppId 'MATLAB'
ok ($card.SBox.Visibility -eq $Col) 'icon PRESENT -> silence, no green chip'
$script:DetectionCache = @{ MATLAB = @{ Installed = $false; UserOnly = $false } }
Update-ShortcutBox -AppId 'MATLAB'
ok ($card.SBox.Visibility -eq $Col -and $card.BtnShortcut.Visibility -eq $Col) 'not installed -> chip AND menu row hidden'
$script:DetectionCache = @{ MATLAB = @{ Installed = $true; UserOnly = $false } }

'=== 3. temp cleanup survey + deletion mechanics ==='
$fakeRoot = Join-Path $sand 'Offload_Temp'
New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'MATLAB') -Force | Out-Null
$big = Join-Path $fakeRoot 'MATLAB\payload.bin'
$fs = [System.IO.File]::Create($big); $fs.SetLength(5MB); $fs.Close()
$fakeTmp = Join-Path $env:TEMP ("labdeploy_progress_testfake$(Get-Random).txt")
'42' | Set-Content $fakeTmp
$script:OffloadRoot = $fakeRoot
$items = Get-LabDeployTempItems
ok (@($items).Count -ge 2) "survey finds the staged folder AND temp helpers ($(@($items).Count) items)"
$mine = @($items | Where-Object { $_.Path -eq $fakeRoot -or $_.Path -eq $fakeTmp })
ok ($mine.Count -eq 2) 'both planted fakes identified'
$stagedItem = @($items | Where-Object { $_.Path -eq $fakeRoot })[0]
ok ([int64]$stagedItem.Bytes -eq 5MB) "recursive size correct for the staged folder ($($stagedItem.Bytes) bytes)"
ok ($stagedItem.What -eq 'staged installer payload') 'labelled as staged payload'
# the flow's deletion loop, applied to the planted items only
$freed = [int64]0; $gone = 0
foreach ($i in $mine) {
    Remove-Item -LiteralPath $i.Path -Recurse -Force -ErrorAction Stop
    $freed += [int64]$i.Bytes; $gone++
}
ok ($gone -eq 2 -and -not (Test-Path $fakeRoot) -and -not (Test-Path $fakeTmp)) 'deletion loop removes exactly the surveyed paths'
ok ($freed -ge 5MB) "freed bytes tally arithmetic works ($([math]::Round($freed/1MB,1)) MB)"
$after = Get-LabDeployTempItems
ok (@($after | Where-Object { $_.Path -eq $fakeRoot -or $_.Path -eq $fakeTmp }).Count -eq 0) 're-survey confirms clean'

'=== 4. wiring (source-level) ==='
ok ($src -match '\$btnCleanTemp\.Add_Click\(\{ Invoke-TempCleanupFlow \}\)') 'Clean Temp button wired'
ok ($src -match 'Name="btnCleanTemp"') 'Clean Temp button in the XAML'
ok ($src -match '\$tagPanel\.Children\.Add\(\$chkIcon\)') 'Desktop icon checkbox added to the card'
ok ($src -match 'if \(-not \(Test-AppAutoShortcut -AppId \$id\)\) \{ \$off\+\+') 'Verify Shortcuts skips policy-off cards'
ok ($src -match '\$off turned off') 'Verify Shortcuts status line reports the skip count'
$sites = @([regex]::Matches($src, 'Test-AppAutoShortcut -AppId \$(script:installAppId|rd\.AppId)'))
ok ($sites.Count -eq 3) "all 3 post-install shortcut sites gated by policy (found $($sites.Count))"

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
