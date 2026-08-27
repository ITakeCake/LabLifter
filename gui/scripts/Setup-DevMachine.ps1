# ============================================================
#  Setup-DevMachine.ps1
#  Stand up a full LabDeploy DEVELOPMENT environment on another PC.
# ============================================================
# WHY THIS EXISTS
#   Copying Deploy-LabGUI.ps1 alone gets you the FIELD face: Deploy + Settings
#   only. The Layout Designer, Deployment Tracker, Assign, Config, Sticks and
#   Add App tabs are all gated behind one check - does C:\LabDeployMaster exist.
#   Miss that and the tabs you came to work on are invisible, with no error to
#   explain why. This script is that gate plus the fleet data behind it.
#
# WHAT IT DOES
#   1. Copies the working tree (tool + config + scripts + tests + docs + .git)
#      to local disk - running from USB is slow and the point of the trip is
#      speed.
#   2. Creates C:\LabDeployMaster and restores the master store into it, so the
#      Deployment Tracker has real machines to draw instead of an empty map.
#   3. Repoints master-config.json's stagingRoot at THIS machine, so nothing
#      quietly writes to a path that only exists on the master.
#   4. Verifies: parses the script and runs the headless suites.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   The ~55 GB installer payload is not copied. Every UI, config, rules, fleet
#   and test path works without it; only actually INSTALLING an app needs it,
#   and that would fail with E21 (source missing). The payload is on the stick
#   under \LabDeployment\LabDeploy-InstallerSources if you genuinely need it.
#
# SAFETY
#   Refuses to overwrite a non-empty destination unless -Force. Never touches
#   the source. Creating C:\LabDeployMaster is what makes this PC a master - see
#   -NoMaster if that is not what you want.
param(
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Installers\LabDeploy'),
    [string]$MasterSnapshot = '',          # folder holding logs\ + sticks.json; auto-detected beside this script
    [string]$StagingRoot = '',             # where sticks would be mirrored FROM on this PC
    [switch]$NoMaster,                        # skip C:\LabDeployMaster (field face only)
    [switch]$SkipTests,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

Say '=== LabDeploy dev machine setup ===' 'Cyan'

# ---- locate the source tree (this script lives in <tree>\scripts\) ----
$srcTree = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $srcTree 'Deploy-LabGUI.ps1'))) {
    Say "STOP: cannot find Deploy-LabGUI.ps1 beside this script (looked in $srcTree)." 'Red'; exit 1
}
Say "source      : $srcTree"
Say "destination : $Destination"

# ---- copy the working tree ----
if ((Test-Path $Destination) -and @(Get-ChildItem $Destination -Force -ErrorAction SilentlyContinue).Count -gt 0 -and -not $Force) {
    Say "STOP: $Destination already exists and is not empty. Re-run with -Force to overwrite." 'Red'; exit 1
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
# /MIR so a -Force re-run is a true refresh. logs\ is excluded: those are the
# SOURCE machine's session logs and would masquerade as this machine's history.
$rc = @($srcTree, $Destination, '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
        '/XD', (Join-Path $srcTree 'logs'))
& robocopy.exe @rc | Out-Null
if ($LASTEXITCODE -ge 8) { Say "STOP: robocopy failed (exit $LASTEXITCODE)." 'Red'; exit 1 }
New-Item -ItemType Directory -Path (Join-Path $Destination 'logs') -Force | Out-Null
$n = @(Get-ChildItem $Destination -Recurse -File -Force).Count
Say "copied      : $n files" 'Green'

# ---- master mode ----
if ($NoMaster) {
    Say 'master         : SKIPPED (-NoMaster) - you will get the field face: Deploy + Settings only' 'Yellow'
} else {
    $master = 'C:\LabDeployMaster'
    New-Item -ItemType Directory -Path (Join-Path $master 'logs') -Force | Out-Null
    Say "master         : $master created - this PC now shows the master tabs" 'Green'

    if (-not $MasterSnapshot) {
        foreach ($c in @((Join-Path (Split-Path $srcTree -Parent) '..\LabDeployMaster-snapshot'),
                         (Join-Path (Split-Path $srcTree -Parent) 'LabDeployMaster-snapshot'))) {
            try { $p = (Resolve-Path $c -ErrorAction Stop).Path; if (Test-Path $p) { $MasterSnapshot = $p; break } } catch { }
        }
    }
    if ($MasterSnapshot -and (Test-Path $MasterSnapshot)) {
        # copy-new-only, exactly like the real log merge: this can be re-run and
        # can never clobber logs already here.
        $sl = Join-Path $MasterSnapshot 'logs'
        $copied = 0
        if (Test-Path $sl) {
            foreach ($f in (Get-ChildItem $sl -Filter '*.log' -File)) {
                $dst = Join-Path $master "logs\$($f.Name)"
                if (-not (Test-Path $dst)) { Copy-Item $f.FullName $dst -Force; $copied++ }
            }
        }
        foreach ($f in 'sticks.json', 'fleet-export.csv') {
            $s = Join-Path $MasterSnapshot $f
            if (Test-Path $s) { Copy-Item $s (Join-Path $master $f) -Force }
        }
        Say "fleet data  : $copied session log(s) restored from $MasterSnapshot" 'Green'
    } else {
        Say 'fleet data  : none found - the Deployment Tracker will be empty (everything else works)' 'Yellow'
    }

    # stagingRoot must describe THIS machine. Left pointing at the master's Desktop
    # it would be a path that does not exist, and any publish would silently
    # skip - the tool reports that, but better not to arm it at all.
    if (-not $StagingRoot) { $StagingRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LabDeploy-Flash-Staging' }
    @{ stagingRoot = $StagingRoot } | ConvertTo-Json |
        Set-Content (Join-Path $master 'master-config.json') -Encoding UTF8
    Say "stagingRoot : $StagingRoot$(if (-not (Test-Path $StagingRoot)) { '   (does not exist yet - fine for dev; stick syncing needs it)' })"
}

# ---- verify ----
$tool = Join-Path $Destination 'Deploy-LabGUI.ps1'
$er = $null; $tk = $null
[System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tk, [ref]$er) | Out-Null
if ($er.Count) { Say "WARNING: the copied script has $($er.Count) parse error(s)!" 'Red' }
else { Say 'parse       : clean' 'Green' }

if (-not $SkipTests) {
    Say ''
    Say 'Running the headless suites (about a minute)...' 'Cyan'
    Push-Location (Join-Path $Destination 'tests')
    foreach ($t in 'test-collections','test-model','test-render','test-reconcile',
                   'test-lastbatch','test-e70fix','test-needsopen','test-layoutdesigner','check-verify') {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$t.ps1" 2>&1
        $line = ($out | Select-String '^PASS' | Select-Object -Last 1)
        $bad  = ("$line" -notmatch 'FAIL 0')
        Say ("  {0,-22} {1}" -f $t, $line) $(if ($bad) { 'Red' } else { 'Green' })
    }
    Pop-Location
}

Say ''
Say 'DONE. Next:' 'Cyan'
Say "  cd `"$Destination`""
Say '  .\Launch.bat                 <- run the tool (self-elevates)'
Say '  cd tests; .\shoot-gui.ps1 -Tab "Layout Designer" -Out "$env:TEMP\ui.png"'
Say ''
Say 'When you are done, from the tree above:  .\scripts\Bring-DevWorkHome.ps1' 'Cyan'
