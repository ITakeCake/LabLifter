# Install-pipeline end-to-end WITHOUT real installers.
#
# Drives the REAL Start-SingleInstall -> install-timer tick -> verification ->
# Resume-InstallQueue machinery against fake app cards whose "installers" are
# stub .cmd files that create (or don't create) a detect artifact and exit
# with a chosen code. This is the "will installing actually work when nobody
# is standing there" test: queue mechanics, dependency chains, exit-code
# judgement, detection-overrides-exitcode, shortcut policy gating, batch
# ledger - everything EXCEPT vendor installer internals, which the daily
# bench runs already cover.
#
# The install timer's Add_Tick body is top-level code, not a function, so it
# is pulled out of the AST (same spirit as the function extraction the other
# suites use) and driven by DIRECT invocation in a pump loop - deterministic,
# no dispatcher needed. The late-registration retry timer path uses $this and
# needs a real dispatcher, so it is out of scope here (see the note at the
# bottom; smoke.ps1 territory).
#
# SANDBOXED: fake catalog, stub installers and artifacts all live in %TEMP%
# and are deleted at the end. The real config/ is never read or written.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @('Start-SingleInstall','Resume-InstallQueue','Test-AppInstalled','Test-PostInstallDone',
          'Test-AppAutoShortcut','Clear-DetectionIndexes','Confirm-CommandPreview',
          'Reset-AppCardState','New-FrozenBrush','Add-FollowOnInstalls',
          'Get-AppDetectedPath','Get-AppInstallStamp','Format-LabStamp','Get-AppCardDetail')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$missing = @($want | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) { "NOT FOUND in source: $($missing -join ', ')"; exit 1 }

# ---- the install timer's tick body, straight from the AST ----
$tickText = $null
foreach ($inv in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
    if ("$($inv.Member)" -eq 'Add_Tick' -and $inv.Expression.Extent.Text -match 'installTimer') {
        $tickText = $inv.Arguments[0].Extent.Text; break
    }
}
if (-not $tickText) { 'NOT FOUND: $script:installTimer.Add_Tick({...}) block'; exit 1 }
Invoke-Expression "`$script:InstallTick = $tickText"

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }

# ---- sandbox ----
$sand = Join-Path $env:TEMP ("labdeploy_pipe_" + (Get-Random))
$src  = Join-Path $sand 'source'
$det  = Join-Path $sand 'detect'
New-Item -ItemType Directory -Path $src, $det -Force | Out-Null

# stub "installer": optionally creates the detect artifact, exits with a code
function New-StubInstaller($name, $artifact, $exitCode, [bool]$makeArtifact) {
    $lines = @('@echo off')
    if ($makeArtifact) { $lines += "echo installed> `"$artifact`"" }
    $lines += "exit /b $exitCode"
    $p = Join-Path $src $name
    $lines | Set-Content $p -Encoding ASCII
    return $p
}
function ArtifactOf($id) { Join-Path $det "$id.txt" }

$J = ($det -replace '\\', '\\')   # JSON-escaped detect dir
$catalog = @"
{ "apps": {
    "FakeAlpha":   { "displayName": "Fake Alpha",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeAlpha.txt" ] },
                     "install": { "method": "exe", "sourceSub": "alpha.cmd" } },
    "FakeBeta":    { "displayName": "Fake Beta",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeBeta.txt" ] },
                     "install": { "method": "exe", "sourceSub": "beta.cmd" } },
    "FakeGamma":   { "displayName": "Fake Gamma",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeGamma.txt" ] },
                     "install": { "method": "exe", "sourceSub": "gamma.cmd" } },
    "FakeDelta":   { "displayName": "Fake Delta", "autoShortcut": false,
                     "detect":  { "method": "path", "paths": [ "$J\\FakeDelta.txt" ] },
                     "install": { "method": "exe", "sourceSub": "delta.cmd" } },
    "FakeDep":     { "displayName": "Fake Dependency",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeDep.txt" ] },
                     "install": { "method": "exe", "sourceSub": "dep.cmd" } },
    "FakeChild":   { "displayName": "Fake Child",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeChild.txt" ] },
                     "install": { "method": "exe", "sourceSub": "child.cmd", "requires": [ "FakeDep" ] } },
    "FakeEcho":    { "displayName": "Fake Echo",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeEcho.txt" ] },
                     "install": { "method": "exe", "sourceSub": "echo.cmd" } },
    "FakeFox":     { "displayName": "Fake Fox",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeFox.txt" ] },
                     "install": { "method": "exe", "sourceSub": "fox.cmd" } },
    "FakeMissing": { "displayName": "Fake Missing",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeMissing.txt" ] },
                     "install": { "method": "exe", "sourceSub": "does-not-exist.cmd" } },
    "FakeWeird":   { "displayName": "Fake Weird",
                     "detect":  { "method": "path", "paths": [ "$J\\FakeWeird.txt" ] },
                     "install": { "method": "hologram", "sourceSub": "x.cmd" } }
} }
"@
$script:AppsConfig = $catalog | ConvertFrom-Json
$null = New-StubInstaller 'alpha.cmd' (ArtifactOf FakeAlpha) 0 $true
$null = New-StubInstaller 'beta.cmd'  (ArtifactOf FakeBeta)  7 $false
$null = New-StubInstaller 'gamma.cmd' (ArtifactOf FakeGamma) 5 $true
$null = New-StubInstaller 'delta.cmd' (ArtifactOf FakeDelta) 0 $true
$null = New-StubInstaller 'dep.cmd'   (ArtifactOf FakeDep)   0 $true
$null = New-StubInstaller 'child.cmd' (ArtifactOf FakeChild) 0 $true
$null = New-StubInstaller 'echo.cmd'  (ArtifactOf FakeEcho)  0 $true
$null = New-StubInstaller 'fox.cmd'   (ArtifactOf FakeFox)   0 $true

# ---- $script: state the pipeline touches ----
$script:SourceRoot        = $src
$script:DetectionCache    = @{}
$script:installQueue      = New-Object System.Collections.Queue
$script:BatchQueued       = @()
$script:BatchStarted      = $null
$script:DepChainTried     = @{}
$script:WingetFallback    = @{}
$script:WingetSrcFixed    = @{}
$script:OffloadEnabled    = $false
$script:SuppressPreviewOnce = $false
$script:installProcess    = $null
$script:installAppId      = $null
$script:installAction     = $null
$script:progressFile      = $null
$script:progressMode      = 'timer'
$script:installDriveName  = 'C'
$script:installExpectedBytes = 0
$script:installStartFreeBytes = 0
$script:NeedsOpenPromptTimeoutSec = 1
$script:retryTimer        = $null
$script:BrushOrange = New-FrozenBrush 0xC8 0x82 0x1A
$script:BrushRed    = New-FrozenBrush 0x6E 0x1E 0x1E
$script:BrushYellow = New-FrozenBrush 0xC8 0xB4 0x1A
$script:BrushGreen  = New-FrozenBrush 0x14 0x5A 0x2E
$script:BrushMuted  = New-FrozenBrush 0x78 0x78 0x78
$script:BrushText   = New-FrozenBrush 0xE0 0xE0 0xE0
$script:installTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:installTimer.Interval = [TimeSpan]::FromSeconds(1)

$txtStatus = New-Object System.Windows.Controls.TextBlock
$btnInstallMissing = New-Object System.Windows.Controls.Button

function New-FakeCard {
    @{ Dot = (New-Object System.Windows.Shapes.Ellipse)
       Detail = (New-Object System.Windows.Controls.TextBlock)
       Progress = (New-Object System.Windows.Controls.ProgressBar)
       BtnInstall = (New-Object System.Windows.Controls.Button)
       BtnCancel = (New-Object System.Windows.Controls.Button)
       BtnUninstall = (New-Object System.Windows.Controls.Button)
       BtnOpen = (New-Object System.Windows.Controls.Button)
       Status = 'Missing' }
}
$script:Cards = @{}
foreach ($id in $script:AppsConfig.apps.PSObject.Properties.Name) { $script:Cards[$id] = New-FakeCard }

# ---- stubs (recorders where the assertions need them) ----
$script:LogEvents = New-Object System.Collections.ArrayList
function Write-LabLog { param($Event, $Data)
    $null = $script:LogEvents.Add([pscustomobject]@{ E = $Event; Id = $(if ($Data -and $Data.appId) { $Data.appId } else { '' }); Code = $(if ($Data -and $Data.errorCode) { $Data.errorCode } else { '' }) }) }
# ,@() so a single hit survives the return as a real array (.Count works) -
# plain @() unrolled to a bare object and .Count came back $null. Yes: the
# exact trap test-collections documents, caught in this suite's OWN helper.
function evs($e, $id) { return ,@($script:LogEvents | Where-Object { $_.E -eq $e -and (-not $id -or $_.Id -eq $id) }) }
$script:RepairCalls = @()
function Repair-AppShortcut { param([string]$AppId) $script:RepairCalls += $AppId; return @{ Applicable = $true; Present = $true; Lnk = '(stub)' } }
$script:VerifySweeps = 0
function Invoke-VerifyShortcuts { param([switch]$Auto) $script:VerifySweeps++; return @{ Text = '(stub sweep)' } }
function Update-AppCard { param([string]$AppId, $Result) }
function Update-Summary { }
function Update-ShortcutBox { param([string]$AppId) }
function Clear-OffloadTemp { }
function Clear-InstallQueue { $script:installQueue.Clear() }
function Confirm-ImageGate { return $true }
function Test-WindowsInstallerBusy { return $false }
function Wait-WindowsInstallerFree { param($ForApp) return $true }
function Test-PendingReboot { return @{ Pending = $false; Reasons = @() } }
function Invoke-AppPostInstall { param([string]$AppId, $Card) return $null }
function Show-TimedConfirm { param($Message, $Title, $TimeoutSec) return 'Yes' }
function Open-App { param([string]$AppId) }
function Test-AppOpened { param([string]$AppId) return $true }
function Set-AppOpened { param([string]$AppId) }
function Remove-AppShortcut { param([string]$AppId) }
function Get-UninstallResidue { param([string]$AppId) return @() }
function Get-RegInstallIndex { return @() }
function Get-ExeFileIndex { return @{} }
function Get-AppxProvisionedIndex { return @() }

# ---- the pump: drive the real tick until the pipeline goes quiet ----
function Invoke-InstallPump {
    param([int]$TimeoutSec = 30)
    $deadline = [datetime]::Now.AddSeconds($TimeoutSec)
    while ($script:installTimer.IsEnabled -and [datetime]::Now -lt $deadline) {
        if ($script:installProcess -and -not $script:installProcess.HasExited) { Start-Sleep -Milliseconds 60 }
        & $script:InstallTick
    }
    return (-not $script:installTimer.IsEnabled)
}

'=== 1. single install, clean success ==='
Start-SingleInstall -AppId 'FakeAlpha'
ok ($null -ne $script:installProcess) 'stub installer process launched'
ok ($script:installTimer.IsEnabled) 'install timer armed'
ok (Invoke-InstallPump) 'pipeline went quiet (timer stopped)'
ok (Test-Path (ArtifactOf FakeAlpha)) 'stub created its detect artifact'
ok ($script:DetectionCache['FakeAlpha'].Installed) 're-detect after exit sees it installed'
ok ((evs 'install.verified' 'FakeAlpha').Count -eq 1) 'install.verified logged'
ok ($script:RepairCalls -contains 'FakeAlpha') 'shortcut repaired (policy defaults ON)'
ok ((evs 'operation.timer_error' '').Count -eq 0) 'no E70 timer errors anywhere'

'=== 2. failure: bad exit code, nothing on disk ==='
Start-SingleInstall -AppId 'FakeBeta'
ok (Invoke-InstallPump) 'pipeline went quiet'
ok (-not $script:DetectionCache['FakeBeta'].Installed) 'still not installed'
ok ((evs 'install.failed' 'FakeBeta').Count -eq 1) 'install.failed logged'
ok ((evs 'install.failed' 'FakeBeta')[0].Code -eq 'E23') 'classified E23 (generic exit-code failure)'
$bCard = $script:Cards['FakeBeta']
ok ($bCard.Detail.Text -like '*E23*') "card says why: '$($bCard.Detail.Text)'"
ok ($bCard.BtnInstall.IsEnabled) 'Install button re-enabled for retry'
ok ($bCard.BtnCancel.Visibility -eq [System.Windows.Visibility]::Collapsed) 'stale Cancel retired on failure'

'=== 3. detection overrides the exit code (the NIPM/LabVIEW lesson) ==='
Start-SingleInstall -AppId 'FakeGamma'
ok (Invoke-InstallPump) 'pipeline went quiet'
ok ($script:DetectionCache['FakeGamma'].Installed) 'app IS on disk despite exit 5'
ok ((evs 'install.failure_overridden_by_detection' 'FakeGamma').Count -eq 1) 'override branch taken'
ok ((evs 'install.verified_despite_exitcode' 'FakeGamma').Count -eq 1) 'success-with-warning logged, not failure'
ok ((evs 'install.failed' 'FakeGamma').Count -eq 0) 'no install.failed for it'
ok ($script:RepairCalls -contains 'FakeGamma') 'shortcut still repaired on override success'

'=== 4. desktop-icon policy OFF skips the shortcut step ==='
$script:RepairCalls = @()
Start-SingleInstall -AppId 'FakeDelta'
ok (Invoke-InstallPump) 'pipeline went quiet'
ok ($script:DetectionCache['FakeDelta'].Installed) 'installed fine'
ok ($script:RepairCalls.Count -eq 0) 'Repair-AppShortcut NOT called'
ok ((evs 'shortcut.post_install_skipped' 'FakeDelta').Count -eq 1) 'skip is logged with its reason'

'=== 5. dependency chain: child pulls its dep in first ==='
Start-SingleInstall -AppId 'FakeChild'
ok (Invoke-InstallPump -TimeoutSec 40) 'pipeline went quiet'
ok ((evs 'install.dependency_first' 'FakeChild').Count -eq 1) 'dep-first detour logged'
ok ($script:DetectionCache['FakeDep'].Installed) 'dependency installed'
ok ($script:DetectionCache['FakeChild'].Installed) 'child installed after it'
$starts = @($script:LogEvents | Where-Object { $_.E -eq 'install.process_started' } | ForEach-Object { $_.Id })
$depIdx = [array]::IndexOf($starts, 'FakeDep'); $chiIdx = [array]::IndexOf($starts, 'FakeChild')
ok ($depIdx -ge 0 -and $chiIdx -gt $depIdx) "dep launched before child (order: $($starts -join ' -> '))"

'=== 6. launch-refusal paths keep the queue alive ==='
$script:installQueue.Enqueue('FakeMissing')   # E21: installer file absent
$script:installQueue.Enqueue('FakeWeird')     # E20: unknown method
$script:installQueue.Enqueue('FakeEcho')      # healthy - must still run
Resume-InstallQueue
ok (Invoke-InstallPump) 'pipeline went quiet'
ok ((evs 'install.source_missing' 'FakeMissing')[0].Code -eq 'E21') 'missing installer -> E21'
ok ((evs 'install.unknown_method' 'FakeWeird')[0].Code -eq 'E20') 'unknown method -> E20'
ok ($script:DetectionCache['FakeEcho'].Installed) 'the healthy app after two refusals still installed'
ok ($btnInstallMissing.IsEnabled) 'Install All button re-enabled after drain'

'=== 7. batch drain contract: ledger + auto shortcut sweep ==='
# HANDOVER 6/check-verify contract: when an Install All batch drains, log
# installall.finished and ALWAYS run Verify Shortcuts. FakeFox is the batch;
# FakeAlpha is queued too but already installed, so the dedupe should skip it.
$script:VerifySweeps = 0
$script:BatchQueued  = @('FakeFox', 'FakeAlpha')
$script:BatchStarted = Get-Date
$script:installQueue.Enqueue('FakeFox')
$script:installQueue.Enqueue('FakeAlpha')
Resume-InstallQueue
ok (Invoke-InstallPump) 'pipeline went quiet'
ok ($script:DetectionCache['FakeFox'].Installed) 'batch app installed'
ok ((evs 'install.queue_skip_already_installed' 'FakeAlpha').Count -ge 1) 'already-installed queue entry skipped, not reinstalled'
ok ((evs 'installall.finished' '').Count -eq 1) 'installall.finished ledger written on drain'
ok ($script:VerifySweeps -eq 1) 'Verify Shortcuts auto-ran exactly once at batch end'

# NOT covered here, deliberately:
#  - late-registration verify retry ($script:retryTimer): its tick uses $this,
#    which only binds under a real dispatcher - smoke.ps1 territory.
#  - offload staging, winget fallback, uninstall: separate suites when needed.

''
'--- card detail line: a sentence, not raw detection output ---'
# 2026-08-03: green printed the whole install path and red printed the
# entire searched-locations list. Both wrapped; neither said "is it on, and
# since when". These four functions are the display layer that replaced them.

# The path parser has to survive every suffix Test-AppInstalled can append.
ok ((Get-AppDetectedPath -Result @{ Detail = 'C:\Program Files\ImageJ' }) -eq 'C:\Program Files\ImageJ') 'a bare path comes back untouched'
ok ((Get-AppDetectedPath -Result @{ Detail = 'C:\PF\a.exe  (found via search)' }) -eq 'C:\PF\a.exe') 'the "(found via search)" suffix is stripped'
ok ((Get-AppDetectedPath -Result @{ Detail = 'C:\PF\b  (registered)' }) -eq 'C:\PF\b') 'and "(registered)"'
ok ((Get-AppDetectedPath -Result @{ Detail = 'C:\PF\c.exe  [USER-ONLY: installed for x only]' }) -eq 'C:\PF\c.exe') 'and the USER-ONLY bracket'
ok ((Get-AppDetectedPath -Result @{ Detail = '' }) -eq '') 'an empty Detail yields an empty path, not a crash'
ok ((Get-AppDetectedPath -Result $null) -eq '') 'and so does a null result'

# AM/PM is the whole point of the format, and it must not depend on the desktop
# locale - 'tt' under a non-English culture is not "AM"/"PM".
$noon = [datetime]'2026-08-03 13:47:00'
ok ((Format-LabStamp -At $noon) -eq '2026-08-03 at 1:47 PM') "afternoon reads 12-hour with PM: '$(Format-LabStamp -At $noon)'"
ok ((Format-LabStamp -At ([datetime]'2026-08-03 09:05:00')) -eq '2026-08-03 at 9:05 AM') 'morning reads AM'
ok ((Format-LabStamp -At ([datetime]'2026-08-03 00:30:00')) -eq '2026-08-03 at 12:30 AM') 'midnight is 12:30 AM, not 0:30'
ok ((Format-LabStamp -At ([datetime]'2026-08-03 12:00:00')) -eq '2026-08-03 at 12:00 PM') 'noon is 12:00 PM, not 0:00'

# A real file on disk, so the stamp comes from the filesystem and not from now.
$stampDir = Join-Path $sand 'stamped'
New-Item -ItemType Directory -Force $stampDir | Out-Null
$stampFile = Join-Path $stampDir 'thing.exe'
Set-Content $stampFile 'x' -Encoding ASCII
$made = [datetime]'2026-01-09 15:22:00'
(Get-Item $stampFile).CreationTime = $made
$got = Get-AppInstallStamp -Result @{ Detail = "$stampFile  (found via search)" }
ok ($got -eq $made) "the stamp is the file's creation time, not the scan time ($got)"
# detect.paths legitimately hold wildcards (Java8's "...\jre1.8*\bin\java.exe"),
# so Test-Path/LiteralPath alone would find nothing here.
$wild = Join-Path $stampDir 'thin*.exe'
ok ((Get-AppInstallStamp -Result @{ Detail = $wild }) -eq $made) 'a WILDCARD detect path still resolves to a stamp'
ok ($null -eq (Get-AppInstallStamp -Result @{ Detail = 'C:\nope\gone.exe' })) 'a path that is not there yields no stamp'

$green = Get-AppCardDetail -Result @{ Installed = $true; Detail = $stampFile }
ok ($green -eq 'Installed 2026-01-09 at 3:22 PM') "green is one short line: '$green'"
ok ($green -notmatch '(?i)successfully|program') 'no "Successfully" (the dot is green) and no noun (the name is right above)'

# The red line is about the SCAN, not the app, so it has its own shape.
$dot = [char]0x00B7
$red = Get-AppCardDetail -Result @{ Installed = $false; Detail = 'Not found - checked 4 location(s): %PF%\a | %PF86%\b' } -Now (Get-Date).Date.AddHours(14).AddMinutes(21)
ok ($red -eq "Not installed  $dot  checked at 2:21 PM") "red leads with the state: '$red'"
ok ($red -notmatch '%PF%|location\(s\)') 'the searched-locations list is gone from the visible line'
# A check from TODAY needs no date - it is noise. A check from any other day
# does, or a tool left open across midnight would present a stale scan as fresh.
ok ($red -notmatch '\d{4}-\d{2}-\d{2}') 'a same-day check shows the time only'
$stale = Get-AppCardDetail -Result @{ Installed = $false; Detail = 'x' } -Now ([datetime]'2026-08-02 14:21:00')
ok ($stale -eq "Not installed  $dot  checked 2026-08-02 at 2:21 PM") "a check from another day puts the date back: '$stale'"
# Format-LabStamp already carries an "at", so the same-day branch owns its own.
ok (([regex]::Matches($stale, '\bat\b')).Count -eq 1) 'and does not end up saying "at" twice'

# Registry-value and provisioned-MSIX hits resolve to no file. Stamping those
# with "now" would read as "installed this second", which is a lie.
$noFile = Get-AppCardDetail -Result @{ Installed = $true; Detail = 'SomeProduct_1.0_x64  (provisioned)' }
ok ($noFile -eq 'Installed - date not recorded') "a fileless detection says so rather than inventing a date: '$noFile'"

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
if ($env:PIPE_DEBUG) { ''; '--- event log ---'; $script:LogEvents | ForEach-Object { "  ev: $($_.E)  [$($_.Id)]  $($_.Code)" } }
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
