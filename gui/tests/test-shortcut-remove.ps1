# The vanishing-icon bug (2026-08-14): Remove-AppShortcut matched icons by
# fuzzy name-containment with NO wrong-target guard, while Test-AppShortcut
# had one. Every New-AppShortcut starts with Remove-AppShortcut, so a rebuild
# of one card could delete a NEIGHBOUR card's icon:
#   - LabCourse (displayName 'Lt LabStation Course Content') swallowed the
#     'Lt LabStation' icon,
#   - LabChart (displayName 'ADInstruments LabChart') swallowed the
#     'AD Instruments' folder icon - and vice versa,
# and Verify Shortcuts oscillated: each pass recreated one icon by deleting
# another. This suite locks in the guard and the behaviours it must NOT break
# (rename sweeps, version-pair icon takeover, uninstall cleanup).
#
# Functions are lifted out of Deploy-LabGUI.ps1 by AST, the same way
# test-appcatalog.ps1 does it - the GUI is not executed. Filesystem access is
# stubbed; no real .lnk is read, written, or deleted.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

# ---- lift the shortcut functions out of the GUI -----------------------------
$guiPath = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tok, [ref]$errs)
ok ($errs.Count -eq 0) "Deploy-LabGUI.ps1 parses ($($errs.Count) errors)"

$want = @('Get-NormalizedName','Get-AppShortcutName','Test-AppShortcut','Remove-AppShortcut','Clear-DetectionIndexes')
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$loaded = @()
foreach ($fn in $funcs) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
foreach ($w in $want) { ok ($loaded -contains $w) "lifted $w out of the GUI" }

# ---- stubs: fake desktop, fake install dirs, recorded deletions -------------
$script:PublicDesktop = 'C:\Users\Public\Desktop'
$script:FakeDirs      = @{}     # appId -> install dir (null = not detected)
$script:FakeLnks      = @()     # the fake Public Desktop
$script:Deleted       = @()     # what Remove-Item was asked to delete
$script:LogEvents     = @()

function script:Get-AppInstallDir { param([string]$AppId) return $script:FakeDirs[$AppId] }
function script:Get-PublicLnkIndex { param([switch]$Force) return $script:FakeLnks }
function script:Write-LabLog { param($Event, $Data) $script:LogEvents += @{ Event = $Event; Data = $Data } }
function script:Remove-Item { param($Path, [switch]$Force, $ErrorAction) $script:Deleted += $Path }

# The three real cards from apps.json, reduced to the fields the functions read.
$script:AppsConfig = @'
{ "apps": {
    "LtLabStation": { "displayName": "Lt LabStation", "shortcutName": "Lt LabStation",
                      "shortcutTarget": "Lt LabStation.exe",
                      "detect": { "searchExe": "Lt LabStation.exe" }, "install": {} },
    "LabCourse":    { "displayName": "Lt LabStation Course Content", "shortcutName": "AD Instruments",
                      "shortcutTarget": "C:\\AD Instruments",
                      "detect": {}, "install": {} },
    "LabChart":     { "displayName": "ADInstruments LabChart",
                      "detect": { "searchExe": "LabChart8.exe" }, "install": {} },
    "FooRenamed":   { "displayName": "Foo", "shortcutName": "Foo New",
                      "detect": {}, "install": {} },
    "BareCard":     { "displayName": "Bare Thing", "detect": {}, "install": {} },
    "RavenStrict":  { "displayName": "Raven Lite 2",
                      "shortcutTarget": "Raven Lite.exe", "shortcutTargetStrict": true,
                      "detect": { "searchExe": "Raven Lite.exe" }, "install": {} },
    "RavenLoose":   { "displayName": "Raven Loose",
                      "shortcutTarget": "Raven Lite.exe",
                      "detect": { "searchExe": "Raven Lite.exe" }, "install": {} },
    "RCard":        { "displayName": "R for Windows", "shortcutName": "R 4.3.2",
                      "shortcutTarget": "Rgui.exe",
                      "detect": { "searchExe": "Rgui.exe" }, "install": {} }
} }
'@ | ConvertFrom-Json

function New-Lnk($base, $target) { @{ Base = $base; Target = $target; Path = "C:\Users\Public\Desktop\$base.lnk" } }
function Reset-Desktop {
    $script:FakeLnks = @(
        (New-Lnk 'AD Instruments' 'C:\AD Instruments'),
        (New-Lnk 'Lt LabStation'  'C:\Program Files\ADInstruments\Lt LabStation\Lt LabStation.exe'),
        (New-Lnk 'LabChart 8'     'C:\Program Files\ADInstruments\LabChart8\LabChart8.exe')
    )
    $script:Deleted   = @()
    $script:LogEvents = @()
}
$script:FakeDirs = @{
    LtLabStation = 'C:\Program Files\ADInstruments\Lt LabStation'
    LabCourse    = 'C:\AD Instruments'
    LabChart     = 'C:\Program Files\ADInstruments\LabChart8'
    RavenStrict  = 'C:\Program Files\Raven Lite 2'
    RavenLoose   = 'C:\Program Files\Raven Lite 2'
}

Write-Host "`n--- the two field-reported vanishes ---"
Reset-Desktop
Remove-AppShortcut -AppId 'LabCourse'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\AD Instruments.lnk') 'LabCourse rebuild removes its own icon'
ok ($script:Deleted -notcontains 'C:\Users\Public\Desktop\Lt LabStation.lnk') "LabCourse rebuild does NOT swallow 'Lt LabStation' (the reported vanish)"
ok ($script:Deleted.Count -eq 1) 'LabCourse rebuild deletes exactly one icon'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'shortcut.remove_skipped_foreign' }).Count -ge 1) 'the skip is logged'

Reset-Desktop
Remove-AppShortcut -AppId 'LabChart'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\LabChart 8.lnk') 'LabChart rebuild removes its own icon'
ok ($script:Deleted -notcontains 'C:\Users\Public\Desktop\AD Instruments.lnk') "LabChart rebuild does NOT swallow 'AD Instruments' (the reverse vanish)"

Reset-Desktop
Remove-AppShortcut -AppId 'LtLabStation'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\Lt LabStation.lnk') 'LtLabStation rebuild removes its own icon'
ok ($script:Deleted.Count -eq 1) 'LtLabStation rebuild touches nothing else'

Write-Host "`n--- behaviours the guard must not break ---"
# Rename sweep: the stale OLD-named icon can point anywhere; exact name wins.
$script:FakeLnks = @((New-Lnk 'Foo' 'C:\OldPlace\foo.exe'))
$script:Deleted = @(); $script:FakeDirs['FooRenamed'] = 'C:\NewPlace'
Remove-AppShortcut -AppId 'FooRenamed'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\Foo.lnk') 'rename sweep: exact old-named icon deleted even with a foreign target'

# Version-pair takeover: 1.10.6 retakes the exact-named 'Lt LabStation' icon
# even though its dir differs from where the icon points.
$script:FakeLnks = @((New-Lnk 'Lt LabStation' 'C:\Program Files\ADInstruments\Lt LabStation\Lt LabStation.exe'))
$script:Deleted = @(); $script:FakeDirs['LtLabStation'] = 'C:\Somewhere\Else'
Remove-AppShortcut -AppId 'LtLabStation'
ok ($script:Deleted.Count -eq 1) 'version pair: exact-named shared icon is retaken on upgrade'
$script:FakeDirs['LtLabStation'] = 'C:\Program Files\ADInstruments\Lt LabStation'

# Uninstall cleanup (install dir no longer resolvable): own icon still swept,
# neighbour still safe via the expected-leaf fallback.
Reset-Desktop
$script:FakeDirs['LabCourse'] = $null
Remove-AppShortcut -AppId 'LabCourse'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\AD Instruments.lnk') 'uninstall: own icon swept with no install dir'
ok ($script:Deleted -notcontains 'C:\Users\Public\Desktop\Lt LabStation.lnk') 'uninstall: neighbour icon still safe (leaf fallback)'
$script:FakeDirs['LabCourse'] = 'C:\AD Instruments'

# A card with no dir, no shortcutTarget, no searchExe: nothing to disprove a
# fuzzy match, so the pre-guard delete-on-name behaviour is preserved.
$script:FakeLnks = @((New-Lnk 'Bare Thing Pro' 'C:\Vendor\bare.exe'))
$script:Deleted = @(); $script:FakeDirs['BareCard'] = $null
Remove-AppShortcut -AppId 'BareCard'
ok ($script:Deleted.Count -eq 1) 'no evidence either way: fuzzy delete behaves as before'

Write-Host "`n--- Test-AppShortcut stays symmetric ---"
Reset-Desktop
$state = Test-AppShortcut -AppId 'LabCourse'
ok ($state.Present -and $state.NameOk) "LabCourse converged: neighbour icons don't inflate its match count"
ok ($state.Lnk -eq 'AD Instruments') 'LabCourse claims only its own icon'
$state = Test-AppShortcut -AppId 'LtLabStation'
ok ($state.Present -and $state.NameOk) 'LtLabStation converged on its own icon'

Write-Host "`n--- shortcutTargetStrict: right folder is not enough (2026-08-18) ---"
# Raven Lite 2 installs RavenHelper.exe (6.08 MB) beside the real Raven Lite.exe
# (0.86 MB), and Resolve-AppExePath falls back to "biggest .exe in the folder".
# Folder-membership matching then accepted an icon aimed at the helper, so Verify
# Shortcuts reported OK while a student clicking it launched the licensing helper
# instead of the app. Reproduced live on DEV-DESKTOP before this fix.
$script:FakeLnks = @( (New-Lnk 'Raven Lite 2' 'C:\Program Files\Raven Lite 2\RavenHelper.exe') )
$script:Deleted = @(); $script:LogEvents = @()
$state = Test-AppShortcut -AppId 'RavenStrict'
ok (-not $state.Present) 'an icon aimed at the WRONG exe in the right folder is not present'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'shortcut.wrong_exe_in_right_folder' }).Count -eq 1) 'and the reason is logged, not silent'

# The correctly-aimed icon must still be accepted, or Repair would loop forever.
$script:FakeLnks = @( (New-Lnk 'Raven Lite 2' 'C:\Program Files\Raven Lite 2\Raven Lite.exe') )
$script:LogEvents = @()
$state = Test-AppShortcut -AppId 'RavenStrict'
ok ($state.Present -and $state.NameOk) 'the correctly-aimed icon IS accepted (no Repair loop)'

# OPT-IN: a card that declares shortcutTarget but NOT shortcutTargetStrict keeps
# the old fuzzy behaviour. Eight cards are in that position today, and tightening
# them silently would have Repair rewriting icons across the whole fleet.
$script:FakeLnks = @( (New-Lnk 'Raven Loose' 'C:\Program Files\Raven Lite 2\RavenHelper.exe') )
$script:LogEvents = @()
$state = Test-AppShortcut -AppId 'RavenLoose'
ok ($state.Present) 'a card WITHOUT the opt-in is unchanged: folder membership still counts'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'shortcut.wrong_exe_in_right_folder' }).Count -eq 0) 'and the strict path never fires for it'

Write-Host ""
# --- Refresh All must drop the public-lnk cache (Raven Lite flap fix, 2026-08-19) ---
# Clear-DetectionIndexes is what Refresh All calls to force a fresh look at disk. If it
# leaves $script:LnkCache set, a rescan re-checks shortcuts against a stale <=15s snapshot
# and a just-repaired strict-exe icon (Raven Lite) flaps back to "missing".
$script:LnkCache = @{ At = [datetime]::Now; Items = @(@{ Base = 'stale'; Target = 'x'; Path = 'y' }) }
Clear-DetectionIndexes
ok ($null -eq $script:LnkCache) 'Clear-DetectionIndexes (Refresh All) drops the shortcut-index cache so a rescan re-reads disk'


Write-Host "`n--- install-dir prefix needs a directory boundary (10103 flap, 2026-08-20) ---"
# R detects at "C:\Program Files\R". Plain StartsWith let that dir claim
# "C:\Program Files\RStudio\..." and "C:\Program Files\Raven Lite 2\..." too, so
# R's Test counted 3 matches (NameOk=false forever) and R's every Repair DELETED
# both neighbours' icons - Verify recreated them each pass (created=2 renamed=1
# in 10103LAB30-22's log) and on other machines the fixed icon just vanished.
$script:FakeDirs['RCard'] = 'C:\Program Files\R'
$script:FakeLnks = @(
    (New-Lnk 'R 4.3.2'      'C:\Program Files\R\R-4.3.2\bin\x64\Rgui.exe'),
    (New-Lnk 'RStudio'      'C:\Program Files\RStudio\rstudio.exe'),
    (New-Lnk 'Raven Lite 2' 'C:\Program Files\Raven Lite 2\Raven Lite.exe')
)
$state = Test-AppShortcut -AppId 'RCard'
ok ($state.Present -and $state.NameOk) 'R converges: neighbour dirs sharing the prefix do not inflate its match count'
ok ($state.Lnk -eq 'R 4.3.2') 'R claims only its own icon'
$script:Deleted = @()
Remove-AppShortcut -AppId 'RCard'
ok ($script:Deleted -contains 'C:\Users\Public\Desktop\R 4.3.2.lnk') 'R sweep still removes its OWN icon (true subdir of its dir)'
ok ($script:Deleted -notcontains 'C:\Users\Public\Desktop\RStudio.lnk') 'R sweep leaves RStudio alone (prefix, not subdir)'
ok ($script:Deleted -notcontains 'C:\Users\Public\Desktop\Raven Lite 2.lnk') 'R sweep leaves Raven Lite 2 alone (prefix, not subdir)'
# A folder shortcut whose target IS the install dir (no trailing content) must
# still count as ours - LabCourse's "AD Instruments" icon is exactly that shape.
$script:FakeDirs['RCard'] = 'C:\Program Files\R\R-4.3.2'
$script:FakeLnks = @((New-Lnk 'R Folder' 'C:\Program Files\R\R-4.3.2'))
$state = Test-AppShortcut -AppId 'RCard'
ok ($state.Present) 'a target EQUAL to the install dir still matches (folder shortcuts)'
$script:FakeDirs['RCard'] = $null

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
