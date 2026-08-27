# ============================================================
#  Promote-ToStaging.ps1  -  working tree -> staging, allow-list only
# ============================================================
# THE two-tree hazard fixer (ROADMAP 2026-07-28): Installers\LabDeploy is where
# code gets edited; LabDeploy-Flash-Staging\LabDeployment\LabDeploy is what
# sticks are cut from; nothing kept them in step, so sticks have shipped stale
# builds before. This promotes EXACTLY the files a stick should carry - a
# blanket mirror is not safe because the working tree also holds ~15
# apps.json.preXXX hand-backups, lv-*.txt scratch, design mockups and bench
# manifests that must never reach a lab machine.
#
# Safety rails:
#   - REFUSES to promote a Deploy-LabGUI.ps1 that does not parse.
#   - Backs up staging's current script as Deploy-LabGUI.ps1.prev_<stamp>.
#   - Copy-only: never deletes anything from staging.
#   - Leaves staging's config\gui-settings.json alone (per-stick field data).
#   - -DryRun shows every action without touching a byte.
#
# Usage (from the working tree):  powershell -File scripts\Promote-ToStaging.ps1 [-DryRun]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent                     # ...\Installers\LabDeploy
$dst = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging\LabDeployment\LabDeploy'
try {
    $mc = 'C:\LabDeployMaster\master-config.json'
    if (Test-Path $mc) {
        $cfg = Get-Content $mc -Raw | ConvertFrom-Json
        if ($cfg.stagingRoot) { $dst = Join-Path $cfg.stagingRoot 'LabDeployment\LabDeploy' }
    }
} catch { }

if (-not (Test-Path $dst)) { Write-Host "STOP: staging target not found: $dst" -ForegroundColor Red; exit 1 }

# -- gate: the GUI must parse before it is allowed anywhere near a stick
$tok = $null; $err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'Deploy-LabGUI.ps1'), [ref]$tok, [ref]$err)
if ($err.Count -gt 0) {
    Write-Host "STOP: Deploy-LabGUI.ps1 has $($err.Count) parse error(s) - refusing to promote a broken build:" -ForegroundColor Red
    $err | Select-Object -First 5 | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    exit 1
}

# -- the allow-list. Files a stick needs, nothing else.
$rootFiles = @(
    'Deploy-LabGUI.ps1', 'Launch.bat', 'Launch-Auto.bat',
    'ERROR-CODES.md', 'ERROR-CODES.txt', 'KNOWN-ISSUES.md',
    'MATLAB-DEPLOY-NOTES.md', 'ROADMAP.md', 'TONIGHT-SUMMARY.md', 'RandomToDos.txt'
)
$configFiles = @('apps.json', 'rooms.json', 'buildings.json', 'deployment-rules.json', 'fleet-issues.json', 'tokens.json', 'telemetry.json', 'whitelist.json', 'startup.json')
                # tokens.json is gitignored but SHIPS to sticks (like licences.json); telemetry.json is the endpoint config.
                # whitelist.json (request-edit approvers) + startup.json (autoGpCm) are theFuture config that must reach sticks.
                # NOT gui-settings.json (field data), NOT *.preXXX / snapshots\ / saved\ (master-local)

$actions = New-Object System.Collections.ArrayList
function Add-Copy {
    param([string]$From, [string]$To)
    if (-not (Test-Path $From)) { return }
    $same = $false
    if (Test-Path $To) {
        $a = Get-Item $From; $b = Get-Item $To
        $same = ($a.Length -eq $b.Length -and $a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc)
    }
    if (-not $same) { [void]$actions.Add(@{ From = $From; To = $To }) }
}

foreach ($f in $rootFiles)   { Add-Copy (Join-Path $src $f) (Join-Path $dst $f) }
foreach ($f in $configFiles) { Add-Copy (Join-Path $src "config\$f") (Join-Path $dst "config\$f") }
foreach ($f in (Get-ChildItem (Join-Path $src 'scripts') -File -ErrorAction SilentlyContinue)) {
    Add-Copy $f.FullName (Join-Path $dst "scripts\$($f.Name)")
}
foreach ($f in (Get-ChildItem (Join-Path $src 'tools') -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring((Join-Path $src 'tools').Length).TrimStart('\')
    Add-Copy $f.FullName (Join-Path $dst "tools\$rel")
}

if ($actions.Count -eq 0) {
    Write-Host 'Nothing to promote - staging already matches the working tree (allow-listed files).' -ForegroundColor Green
    exit 0
}

Write-Host "Promoting $($actions.Count) file(s) from`n  $src`nto`n  $dst`n" -ForegroundColor Cyan
foreach ($a in $actions) {
    $rel = $a.To.Substring($dst.Length).TrimStart('\')
    if ($DryRun) { Write-Host "  would copy  $rel"; continue }
    $toDir = Split-Path $a.To -Parent
    if (-not (Test-Path $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
    if ($rel -ieq 'Deploy-LabGUI.ps1' -and (Test-Path $a.To)) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        Copy-Item $a.To "$($a.To).prev_$stamp" -Force
        Write-Host "  (kept staging's old build as Deploy-LabGUI.ps1.prev_$stamp)" -ForegroundColor DarkGray
    }
    Copy-Item $a.From $a.To -Force
    Write-Host "  copied      $rel"
}
if ($DryRun) { Write-Host "`nDry run - nothing was changed." -ForegroundColor Yellow; exit 0 }
Write-Host "`nDone. Next: open the tool's Sticks tab and Update ALL Known Sticks." -ForegroundColor Green
