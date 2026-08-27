# Reconciliation tests: crafted session-log FILES fed through the REAL
# Get-FleetRollup. Covers Blake's spec verbatim: newest-wins across sticks,
# exact-tie conflicts in plain English, 15 agreeing sticks vs one newer
# all-clear, same-session ties resolving by file order, plus Layer 1 closure
# and the Layer 2 issues file round-trip.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @('Get-FleetRollup','Get-FleetExpected','Get-FleetMachineStatus','Test-AppCountsForFleetHealth','Test-AppNeedsOpenConfirm','Resolve-DeployRule',
          # the fold consults a per-machine watermark at ingest, and
          # Publish-FleetIssues skips machines reported missing (2026-08-03)
          'Import-FleetWatermarks','Get-FleetWatermark',
          'Get-FleetMarkKey','Import-FleetMarks','Get-FleetMark',
          'Test-RuleHasApps','Get-RuleApps','Get-RuleLabel','Test-NumToken','ConvertFrom-LabHostname',
          'Get-RoomScanIds','Publish-FleetIssues','Get-MasterStagingRoot','Get-RoomMachineCount')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name -and $loaded -notcontains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
if ($miss.Count) { "!! NOT FOUND: $($miss -join ', ')"; exit 1 }
function Write-LabLog { param($Event, $Data) }

# ---- sandbox master root ----
$root = Join-Path $env:TEMP ("labdeploy_recon_" + (Get-Random))
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$script:MasterRoot = $root
$script:IsMaster = $true
$script:MasterConfigFile = Join-Path $root 'master-config.json'
$staging = Join-Path $root 'staging'
New-Item -ItemType Directory -Path (Join-Path $staging 'LabDeployment\LabDeploy\config') -Force | Out-Null
@{ stagingRoot = $staging } | ConvertTo-Json | Set-Content $script:MasterConfigFile -Encoding UTF8
$cfgDir = Join-Path $root 'config'
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
$ConfigRoot = $cfgDir

# minimal catalog / configs
$appsObj = New-Object psobject
foreach ($a in 'AppX','AppY','RockwellCCW','DotNet35','VSIsoShell2015','MATLAB','R','RStudio') {
    $appsObj | Add-Member -NotePropertyName $a -NotePropertyValue ([pscustomobject]@{ displayName = $a })
}
# REAL shape: requires lives INSIDE install (verified against apps.json + the
# install chain). One top-level case kept to prove both levels are read.
$appsObj.RockwellCCW | Add-Member install ([pscustomobject]@{ requires = @('DotNet35','VSIsoShell2015') })
$appsObj.RStudio     | Add-Member install ([pscustomobject]@{ requires = 'R' })   # STRING form, not array
$appsObj.DotNet35    | Add-Member requires @('RockwellCCW')  # top-level + artificial CYCLE for the guard
$script:AppsConfig  = [pscustomobject]@{ apps = $appsObj }
$script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{} }
$script:BuildingsConfig = $null
$script:RulesConfig = $null

# session-log writer. Machine name deliberately non-campus so the decode
# fallback (needs buildings) stays out of the way.
$script:fileSeq = 0
function New-SessionLog {
    param([string]$Mach, [string]$Stamp, [string]$Stick, [string[]]$Lines)
    $script:fileSeq++
    $p = Join-Path $logs ("LabDeploy_{0}_{1}_{2}.log" -f $Mach, $Stamp, $Stick)
    ($Lines -join "`r`n") | Set-Content $p -Encoding UTF8
    return $p
}
$T = "`t"
function L-err  { param($ts,$app,$code) "ts=$ts${T}event=install.exit_error${T}errorCode=$code${T}appId=$app" }
function L-ok   { param($ts,$app)       "ts=$ts${T}event=install.verified${T}appId=$app" }
function L-snap { param($ts,$inst,$miss) "ts=$ts${T}event=scan.snapshot${T}installed=$inst${T}missing=$miss${T}partial=${T}userOnly=${T}count=9" }
function L-unin { param($ts,$app)       "ts=$ts${T}event=uninstall.verified_removed${T}appId=$app" }
function L-gp   { param($ts)            "ts=$ts${T}event=gp.update_done${T}computerOk=True${T}userOk=True" }
function L-cm   { param($ts)            "ts=$ts${T}event=cm.actions_done${T}total=3${T}failed=0" }

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }
function Clear-Logs { Get-ChildItem $logs -File | Remove-Item -Force }
function Roll([string]$m) { $r = Get-FleetRollup; return $r[$m] }
function StatusOf($rec, $exp = $null) { return (Get-FleetMachineStatus -Rec $rec -Expected $exp) }
$expX = @{ Apps = @('AppX') }   # a profile that expects AppX, for the colour checks

'=== T1: Blake scenario - err 1:00 (stick aa), fixed 1:02 (stick bb), err again 1:10 (stick ee) -> RED with the 1:10 error ==='
Clear-Logs
New-SessionLog 'RECON-T1' '20260730_125900' 'aaaaaa' @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
New-SessionLog 'RECON-T1' '20260730_130100' 'bbbbbb' @( (L-ok  '2026-07-30 13:02:00.000' 'AppX') ) | Out-Null
New-SessionLog 'RECON-T1' '20260730_130900' 'eeeeee' @( (L-err '2026-07-30 13:10:00.000' 'AppX' 'E23') ) | Out-Null
$r = Roll 'RECON-T1'
ok ($r.Failures.Count -eq 1 -and $r.Failures[0] -match 'AppX E23') "1:10 error stands: '$($r.Failures[0])'"
ok ((StatusOf $r $expX).State -ne 'green') 'a standing error keeps the tile off green (recheck queued)'
ok ($r.RecheckApps -contains 'AppX') 'AppX queued for master-directed recheck'

'=== T2: err then fixed 2 min later -> clean, no failures ==='
Clear-Logs
New-SessionLog 'RECON-T2' '20260730_125900' 'aaaaaa' @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
New-SessionLog 'RECON-T2' '20260730_130100' 'bbbbbb' @( (L-ok  '2026-07-30 13:02:00.000' 'AppX') ) | Out-Null
$r = Roll 'RECON-T2'
ok ($r.Failures.Count -eq 0) 'error retired by the newer fix'
ok ($r.Installed.ContainsKey('AppX')) 'AppX counts as installed'
ok ($r.RecheckApps.Count -eq 0) 'nothing to recheck'

'=== T3: EXACT tie, two sticks, contradicting -> plain-English E13 conflict, red, recheck ==='
Clear-Logs
New-SessionLog 'RECON-T3' '20260730_125900' 'aaaaaa' @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
New-SessionLog 'RECON-T3' '20260730_125901' 'bbbbbb' @( (L-ok  '2026-07-30 13:00:00.000' 'AppX') ) | Out-Null
$r = Roll 'RECON-T3'
$conf = @($r.Failures | Where-Object { $_ -match 'CONFLICT \[E13\]' })
ok ($conf.Count -eq 1) "exactly one conflict line: '$($conf[0])'"
ok ($conf[0] -match 'aaaaaa' -and $conf[0] -match 'bbbbbb') 'names BOTH sticks'
ok ($conf[0] -match 'recheck') 'tells the tech what to do'
ok ((StatusOf $r $expX).State -ne 'green') 'an unresolved conflict keeps the tile off green'
ok ($r.RecheckApps -contains 'AppX') 'conflicted app queued for recheck'

'=== T4: FIFTEEN sticks report the same error at the same instant, ONE all-clear a minute later -> all good, 15 ignored ==='
Clear-Logs
for ($i = 1; $i -le 15; $i++) {
    New-SessionLog 'RECON-T4' ("20260730_1300{0:D2}" -f $i) ("s{0:D5}" -f $i) @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
}
New-SessionLog 'RECON-T4' '20260730_130200' 'zzzzzz' @( (L-snap '2026-07-30 13:01:00.000' 'AppX' ''), (L-gp '2026-07-30 13:01:30.000'), (L-cm '2026-07-30 13:01:40.000') ) | Out-Null
$r = Roll 'RECON-T4'
ok ($r.Failures.Count -eq 0) '15 identical same-instant errors all retired by ONE newer all-clear'
ok ($r.Installed.ContainsKey('AppX')) 'AppX installed'
ok ((StatusOf $r $expX).State -eq 'green') 'installed + GP+CM run -> GREEN'

'=== T5: 15 agreeing errors AND the all-clear ALL at the same instant -> ONE conflict line, not fifteen ==='
Clear-Logs
for ($i = 1; $i -le 15; $i++) {
    New-SessionLog 'RECON-T5' ("20260730_1300{0:D2}" -f $i) ("s{0:D5}" -f $i) @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
}
New-SessionLog 'RECON-T5' '20260730_130200' 'zzzzzz' @( (L-ok '2026-07-30 13:00:00.000' 'AppX') ) | Out-Null
$r = Roll 'RECON-T5'
$conf = @($r.Failures | Where-Object { $_ -match 'CONFLICT \[E13\]' })
ok ($conf.Count -eq 1) "agreeing sticks collapse: $($conf.Count) conflict line(s) (want 1)"
ok (@($r.Failures).Count -eq 1) 'and no separate standing-failure line'

'=== T6: tie WITHIN one session (parse-fallback case) -> file order decides, NO conflict ==='
Clear-Logs
New-SessionLog 'RECON-T6' '20260730_130000' 'aaaaaa' @(
    (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26'),
    (L-ok  '2026-07-30 13:00:00.000' 'AppX')          # same ms, later line = later truth
) | Out-Null
$r = Roll 'RECON-T6'
ok ($r.Failures.Count -eq 0) 'later line in the same sitting wins - error retired'
ok ($r.Installed.ContainsKey('AppX')) 'AppX installed'
'--- and reversed order -> the error is the later truth ---'
Clear-Logs
New-SessionLog 'RECON-T6B' '20260730_130000' 'aaaaaa' @(
    (L-ok  '2026-07-30 13:00:00.000' 'AppX'),
    (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26')
) | Out-Null
$r = Roll 'RECON-T6B'
ok ($r.Failures.Count -eq 1 -and $r.Failures[0] -notmatch 'CONFLICT') 'error stands, still no conflict'

'=== T7: presence tie - installed (stick aa) vs missing (stick bb) at the same instant ==='
Clear-Logs
New-SessionLog 'RECON-T7' '20260730_125900' 'aaaaaa' @( (L-snap '2026-07-30 13:00:00.000' 'AppX' '') ) | Out-Null
New-SessionLog 'RECON-T7' '20260730_125901' 'bbbbbb' @( (L-snap '2026-07-30 13:00:00.000' '' 'AppX') ) | Out-Null
$r = Roll 'RECON-T7'
$conf = @($r.Failures | Where-Object { $_ -match 'CONFLICT \[E13\]' })
ok ($conf.Count -eq 1 -and $conf[0] -match 'INSTALLED' -and $conf[0] -match 'MISSING') "presence conflict in English: '$($conf[0])'"
ok (-not $r.Installed.ContainsKey('AppX')) 'pessimistic: NOT counted installed until rechecked'

'=== T8: error vs deliberate uninstall at the same instant, different sticks ==='
Clear-Logs
New-SessionLog 'RECON-T8' '20260730_125900' 'aaaaaa' @( (L-err  '2026-07-30 13:00:00.000' 'AppX' 'E45') ) | Out-Null
New-SessionLog 'RECON-T8' '20260730_125901' 'bbbbbb' @( (L-unin '2026-07-30 13:00:00.000' 'AppX') ) | Out-Null
$r = Roll 'RECON-T8'
$conf = @($r.Failures | Where-Object { $_ -match 'CONFLICT \[E13\]' })
ok ($conf.Count -eq 1 -and $conf[0] -match 'removed') "uninstall-vs-error conflict: '$($conf[0])'"

'=== T9: milliseconds count - 13:00:00.000 vs 13:00:00.001 is NOT a tie ==='
Clear-Logs
New-SessionLog 'RECON-T9' '20260730_125900' 'aaaaaa' @( (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26') ) | Out-Null
New-SessionLog 'RECON-T9' '20260730_125901' 'bbbbbb' @( (L-ok  '2026-07-30 13:00:00.001' 'AppX') ) | Out-Null
$r = Roll 'RECON-T9'
ok ($r.Failures.Count -eq 0) '1ms newer all-clear wins cleanly, no conflict'

'=== T10: mixed multi-app - conflicts on one app never leak onto another ==='
Clear-Logs
New-SessionLog 'RECON-T10' '20260730_125900' 'aaaaaa' @(
    (L-err '2026-07-30 13:00:00.000' 'AppX' 'E26'),
    (L-ok  '2026-07-30 13:05:00.000' 'AppY')
) | Out-Null
New-SessionLog 'RECON-T10' '20260730_125901' 'bbbbbb' @( (L-ok '2026-07-30 13:00:00.000' 'AppX') ) | Out-Null
$r = Roll 'RECON-T10'
ok (@($r.Failures | Where-Object { $_ -match 'AppY' }).Count -eq 0) 'AppY untouched by AppX conflict'
ok ($r.Installed.ContainsKey('AppY')) 'AppY installed normally'
ok ($r.RecheckApps.Count -eq 1 -and $r.RecheckApps[0] -eq 'AppX') 'recheck list is exactly AppX'

'=== Layer 1: requires-closure (array + string forms, cycle-guarded) ==='
$ids = Get-RoomScanIds -AppIds @('RockwellCCW','RStudio')
ok ($ids -contains 'DotNet35' -and $ids -contains 'VSIsoShell2015') 'array-form deps included'
ok ($ids -contains 'R') 'string-form dep included'
ok (@($ids).Count -eq 5) "cycle guard held: $(@($ids).Count) ids, no infinite loop (RockwellCCW<->DotNet35)"
ok ($ids[0] -eq 'RockwellCCW' -and $ids[1] -eq 'RStudio') 'room apps stay first in order'

'=== Layer 2: issues file round-trip ==='
Clear-Logs
New-SessionLog 'RECON-L2' '20260730_125900' 'aaaaaa' @( (L-err '2026-07-30 13:00:00.000' 'VSIsoShell2015' 'E24') ) | Out-Null
$script:FleetRollup = Get-FleetRollup
Publish-FleetIssues
$fiLocal = Join-Path $cfgDir 'fleet-issues.json'
$fiStage = Join-Path $staging 'LabDeployment\LabDeploy\config\fleet-issues.json'
ok (Test-Path $fiLocal) 'fleet-issues.json written locally'
ok (Test-Path $fiStage) 'and pushed into staging for the sticks'
$fi = Get-Content $fiLocal -Raw | ConvertFrom-Json
ok (@($fi.machines.'RECON-L2') -contains 'VSIsoShell2015') 'machine -> app mapping correct'
'--- and the all-clear empties it (an empty file is what retires old issues) ---'
Clear-Logs
New-SessionLog 'RECON-L2' '20260730_130100' 'bbbbbb' @( (L-snap '2026-07-30 13:01:00.000' 'VSIsoShell2015' '') ) | Out-Null
$script:FleetRollup = Get-FleetRollup
Publish-FleetIssues
$fi = Get-Content $fiLocal -Raw | ConvertFrom-Json
ok (-not $fi.machines.'RECON-L2') 'machine dropped from the issues file once healthy'

'=== Self-check mode: -LogsDir + -Machine (the stick remembers its own visits) ==='
Clear-Logs
# this stick saw an error on MACH-A yesterday; MACH-B logs must be ignored
New-SessionLog 'RECON-SELFA' '20260729_140000' 'aaaaaa' @( (L-err '2026-07-29 14:00:00.000' 'AppX' 'E26') ) | Out-Null
New-SessionLog 'RECON-SELFB' '20260729_150000' 'aaaaaa' @( (L-err '2026-07-29 15:00:00.000' 'AppY' 'E23') ) | Out-Null
# ...and today's fresh session on MACH-A (no failures yet) must NOT retire it
New-SessionLog 'RECON-SELFA' '20260730_090000' 'aaaaaa' @( "ts=2026-07-30 09:00:00.000${T}event=app.start" ) | Out-Null
$self = Get-FleetRollup -LogsDir $logs -Machine 'RECON-SELFA'
ok ($self.Count -eq 1) "machine filter: only own machine folded (got $($self.Count))"
ok ($self['RECON-SELFA'].RecheckApps -contains 'AppX') 'own unresolved error found -> recheck AppX'
ok (-not ($self['RECON-SELFA'].RecheckApps -contains 'AppY')) "other machine's error NOT picked up"
'--- and once this stick sees it fixed, self-check goes quiet ---'
New-SessionLog 'RECON-SELFA' '20260730_100000' 'aaaaaa' @( (L-snap '2026-07-30 10:00:00.000' 'AppX' '') ) | Out-Null
$self = Get-FleetRollup -LogsDir $logs -Machine 'RECON-SELFA'
ok ($self['RECON-SELFA'].RecheckApps.Count -eq 0) 'fixed-and-seen -> nothing to recheck'

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
