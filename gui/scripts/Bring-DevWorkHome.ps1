# ============================================================
#  Bring-DevWorkHome.ps1
#  Package a night's work on another PC so the master can take it back.
# ============================================================
# THE PROBLEM THIS SOLVES
#   Two copies of the tree edited in two places is a merge waiting to go wrong.
#   Git already handles that correctly, so this leans on git rather than
#   inventing a copy scheme: commit here, and hand the master something it can
#   merge instead of a folder it has to trust.
#
# TWO ROUTES, in order of preference:
#   1. PUSH to GitHub - the master just pulls. Needs network + credentials.
#   2. BUNDLE - a single .bundle file (a whole repo in one file) written to the
#      stick. The master fetches from it. Works with no network at all.
#   The bundle is written EVEN IF the push succeeds: it costs a few MB and it
#   is the difference between "the push worked" and "I hope the push worked".
param(
    [string]$Message = '',
    [string]$OutDir  = '',        # where to drop the bundle; defaults to the stick this came from
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

$tree = Split-Path $PSScriptRoot -Parent
Push-Location $tree
try {
    if (-not (Test-Path (Join-Path $tree '.git'))) {
        Say "STOP: $tree is not a git repo - nothing to package." 'Red'; exit 1
    }
    Say '=== Bringing dev work home ===' 'Cyan'
    Say "tree: $tree"

    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    Say "branch: $branch"
    $dirty = @(& git status --porcelain)
    if ($dirty.Count -gt 0) {
        Say ''
        Say "$($dirty.Count) uncommitted path(s):" 'Yellow'
        $dirty | Select-Object -First 20 | ForEach-Object { Say "   $_" }
        if ($dirty.Count -gt 20) { Say "   ... and $($dirty.Count - 20) more" }
        if (-not $Message) {
            $Message = Read-Host 'Commit message (blank = do not commit, just bundle what is already committed)'
        }
        if ($Message) {
            & git add -A
            & git commit -m $Message | Out-Null
            if ($LASTEXITCODE -ne 0) { Say 'STOP: commit failed.' 'Red'; exit 1 }
            Say "committed: $(& git log --oneline -1)" 'Green'
        } else {
            Say 'NOT committed - the bundle will only carry what was already committed.' 'Yellow'
        }
    } else {
        Say 'working tree clean - nothing new to commit' 'Green'
    }

    # ---- route 1: push ----
    $pushed = $false
    if (-not $NoPush) {
        Say ''
        Say 'Trying to push...' 'Cyan'
        & git push origin $branch 2>&1 | ForEach-Object { Say "   $_" }
        if ($LASTEXITCODE -eq 0) { $pushed = $true; Say 'pushed OK' 'Green' }
        else { Say 'push failed - the bundle below is your route home' 'Yellow' }
    }

    # ---- route 2: bundle (always) ----
    if (-not $OutDir) {
        # Prefer the removable drive this tree most likely came from.
        $usb = @(Get-Volume -ErrorAction SilentlyContinue |
                 Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' } |
                 Sort-Object -Property SizeRemaining -Descending)
        $OutDir = if ($usb.Count) { "$($usb[0].DriveLetter):\LabDeploy-DEV" } else { [Environment]::GetFolderPath('Desktop') }
    }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bundle = Join-Path $OutDir "labdeploy_devwork_$stamp.bundle"
    & git bundle create $bundle --all 2>&1 | ForEach-Object { Say "   $_" }
    if (Test-Path $bundle) {
        Say "bundle: $bundle  ($([math]::Round((Get-Item $bundle).Length/1MB,1)) MB)" 'Green'
    } else {
        Say 'WARNING: bundle was not created.' 'Red'
    }

    Say ''
    Say 'ON THE MASTER, do ONE of these:' 'Cyan'
    if ($pushed) {
        Say '   cd C:\Users\admin\Desktop\Installers\LabDeploy'
        Say "   git pull origin $branch"
    }
    Say '   # or, from the bundle (no network needed):'
    Say '   cd C:\Users\admin\Desktop\Installers\LabDeploy'
    Say "   git pull `"$bundle`" $branch"
    Say ''
    Say 'Then re-run the suites and Promote-ToStaging before touching any stick.' 'Yellow'
}
finally { Pop-Location }
