# The payload fingerprint exists in TWO implementations that are compared as
# opaque strings: Get-PayloadManifest inside Deploy-LabGUI.ps1 (master verdicts,
# E74 tripwire) and Get-PayloadManifest in scripts\Lib-PayloadManifest.ps1
# (CLI sync stamp). Any drift silently marks every stick STALE forever - this
# is the parity test both files' comments have promised all along.
#
# It also locks in the 2026-08-14 fix: fleet-issues.json is rewritten into
# staging by Publish-FleetIssues on EVERY fleet refresh (= every master app
# launch), and counting it in the fingerprint flipped the whole fleet to
# STALE on every restart ("the program forgets what usbs are up to date").
# Transient/per-stick files must never move the fingerprint; real payload
# files always must.
#
# READ-ONLY on the repo. Builds a tiny synthetic LabDeployment tree in TEMP.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

# ---- the CLI implementation, captured before anything can shadow it ---------
. (Join-Path $LabRoot 'scripts\Lib-PayloadManifest.ps1')
$cliManifest = (Get-Command Get-PayloadManifest).ScriptBlock

# ---- the GUI implementation, lifted by AST (the GUI is not executed) --------
$guiPath = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tok, [ref]$errs)
ok ($errs.Count -eq 0) "Deploy-LabGUI.ps1 parses ($($errs.Count) errors)"
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PayloadManifest' }, $true)
ok ($fn.Count -eq 1) 'found exactly one Get-PayloadManifest in the GUI'
$guiManifest = $fn[0].Body.GetScriptBlock()

# ---- synthetic tree ---------------------------------------------------------
$root = Join-Path $env:TEMP ("manifest-parity-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$ld = Join-Path $root 'LabDeployment'
$null = New-Item -ItemType Directory -Force -Path "$ld\LabDeploy\config", "$ld\LabDeploy\logs", "$ld\LabDeploy-InstallerSources\Science"
Set-Content "$ld\LabDeploy\Deploy-LabGUI.ps1" 'gui code' -Encoding UTF8
Set-Content "$ld\LabDeploy\config\apps.json" '{"apps":{}}' -Encoding UTF8
Set-Content "$ld\LabDeploy\config\fleet-issues.json" '{"generated":"2026-08-14 10:00:00","machines":{}}' -Encoding UTF8
Set-Content "$ld\LabDeploy\config\gui-settings.json" '{"theme":"dark"}' -Encoding UTF8
Set-Content "$ld\LabDeploy\logs\session.log" 'log line' -Encoding UTF8
Set-Content "$ld\LabDeploy\drive-id.txt" 'abc-123' -Encoding UTF8
Set-Content "$ld\timestamp_Cart.txt" '2026-08-14' -Encoding UTF8
Set-Content "$ld\LabDeploy-InstallerSources\Science\thing.msi" 'payload bytes' -Encoding UTF8

try {
    Write-Host "`n--- parity: GUI vs CLI over the same tree ---"
    $g1 = & $guiManifest -LabDeploymentRoot $ld
    $c1 = & $cliManifest -LabDeploymentRoot $ld
    ok ($g1 -eq $c1) "identical fingerprints (GUI $g1 / CLI $c1)"
    ok ($g1 -match '^[0-9A-F]{16}$') 'fingerprint is a 16-hex-char string'

    Write-Host "`n--- files that must NEVER move the fingerprint ---"
    $churn = @(
        'LabDeploy\config\fleet-issues.json',
        'LabDeploy\config\gui-settings.json',
        'LabDeploy\logs\session.log',
        'LabDeploy\drive-id.txt',
        'timestamp_Cart.txt',
        # per-drive telemetry cursors: a stick that ran in the field writes these, and
        # they must NOT move the fingerprint or the stick falsely fails the E74 stamp check.
        'LabDeploy\telemetry-pushed.json',
        'LabDeploy\markreq-pulled.json',
        'LabDeploy\telemetry-http.json'
    )
    foreach ($rel in $churn) {
        $p = Join-Path $ld $rel
        if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p -Force | Out-Null }
        Add-Content $p 'CHANGED' -Encoding UTF8
        (Get-Item $p).LastWriteTime = (Get-Item $p).LastWriteTime.AddMinutes(7)
        $g2 = & $guiManifest -LabDeploymentRoot $ld
        $c2 = & $cliManifest -LabDeploymentRoot $ld
        ok ($g2 -eq $g1) "GUI fingerprint stable after rewriting $rel"
        ok ($c2 -eq $c1) "CLI fingerprint stable after rewriting $rel"
    }

    Write-Host "`n--- files that must ALWAYS move the fingerprint ---"
    (Get-Item "$ld\LabDeploy-InstallerSources\Science\thing.msi").LastWriteTime = [datetime]::Now.AddMinutes(9)
    $g3 = & $guiManifest -LabDeploymentRoot $ld
    $c3 = & $cliManifest -LabDeploymentRoot $ld
    ok ($g3 -ne $g1) 'GUI fingerprint moves when a real payload file changes'
    ok ($c3 -ne $c1) 'CLI fingerprint moves when a real payload file changes'
    ok ($g3 -eq $c3) 'and the two implementations still agree afterwards'

    Write-Host "`n--- GUI-only -ExcludeRel (scoped sticks) ---"
    $e1 = & $guiManifest -LabDeploymentRoot $ld -ExcludeRel @('\LabDeploy-InstallerSources\Science\')
    (Get-Item "$ld\LabDeploy-InstallerSources\Science\thing.msi").LastWriteTime = [datetime]::Now.AddMinutes(23)
    $e2 = & $guiManifest -LabDeploymentRoot $ld -ExcludeRel @('\LabDeploy-InstallerSources\Science\')
    ok ($e1 -eq $e2) 'excluded prefix does not move the scoped fingerprint'
    ok ($e1 -ne $g3) 'but the scoped fingerprint differs from the full one'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
