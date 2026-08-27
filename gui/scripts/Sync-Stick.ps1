<#
.SYNOPSIS
    Copy the LabDeploy payload onto one prepared stick and VERIFY it file-by-file.

.DESCRIPTION
    Why the verification matters: on LABDEPLOY01, robocopy exited 0 and the byte
    totals matched at 54.338 GB, yet one 796-byte MATLAB resource file had FAILED
    with "ERROR 3 - the system cannot find the path specified". At that scale a
    sub-kilobyte miss is invisible in the summary. Exit code 0 is NOT proof of a
    complete copy, so this diffs every path afterwards and repairs what's missing.

    Field data on the stick is never touched: its own logs, gui-settings.json,
    timestamp_Cart.txt and drive-id.txt are excluded from both copy AND deletion,
    and /MIR is scoped to \LabDeployment so the drive root is untouched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DriveLetter,
    [string]$StagingRoot = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$L = $DriveLetter.TrimEnd(':').ToUpper()

function Say { param($m, $c = 'Gray') if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

# --- safety: only ever a removable USB volume -------------------------------
$vol = Get-Volume -DriveLetter $L -ErrorAction Stop
if ("$($vol.DriveType)" -ne 'Removable') { throw "${L}: is not removable - refusing." }
$part = Get-Partition -DriveLetter $L -ErrorAction Stop | Select-Object -First 1
$disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
if ("$($disk.BusType)" -ne 'USB') { throw "${L}: is not on a USB bus - refusing." }

$srcLD = Join-Path $StagingRoot 'LabDeployment'
$dstLD = "${L}:\LabDeployment"
if (-not (Test-Path $srcLD)) { throw "staging source missing: $srcLD" }

# --- free-space guard (E69 rule) --------------------------------------------
$need = (Get-ChildItem $srcLD -Recurse -File -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum).Sum
$free = [int64]$vol.SizeRemaining
$isFresh = -not (Test-Path $dstLD)
$required = if ($isFresh) { $need + 1GB } else { 2GB }
if ($free -lt $required) {
    throw ("[E69] {0}: has {1:N1} GB free but needs about {2:N1} GB." -f $L, ($free/1GB), ($required/1GB))
}

Say ''
Say ("=== {0}: [{1}] ===" -f $L, $vol.FileSystemLabel) Cyan
Say ("  payload {0:N2} GB -> {1:N1} GB free" -f ($need/1GB), ($free/1GB))

# --- mirror ------------------------------------------------------------------
$out = Join-Path $env:TEMP ("sync_{0}_{1}.txt" -f $L, (Get-Date -Format 'HHmmss'))
$rcArgs = @(
    ('"{0}"' -f $srcLD), ('"{0}"' -f $dstLD),
    '/MIR', '/R:1', '/W:1', '/NP', '/NFL', '/NDL',
    '/XD', '"System Volume Information"', ('"{0}\LabDeploy\logs"' -f $dstLD), ('"{0}\LabDeploy\logs"' -f $srcLD),
    '/XF', 'gui-settings.json', 'timestamp_Cart.txt', 'drive-id.txt', 'telemetry-pushed.json'
)
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process robocopy.exe -ArgumentList ($rcArgs -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $out
$null = $p.Handle
$p.WaitForExit()
$sw.Stop()
$code = $p.ExitCode
Say ("  robocopy exit {0} in {1}m {2}s" -f $code, [int]$sw.Elapsed.TotalMinutes, $sw.Elapsed.Seconds)
if ($code -ge 8) {
    Get-Content $out -Tail 15 | ForEach-Object { Say "    $_" Red }
    throw "[E68] robocopy failed on ${L}: (exit $code)"
}

# --- VERIFY: exit 0 is not proof ---------------------------------------------
Say '  verifying every file...'
$s = Get-ChildItem $srcLD -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($srcLD.Length) }
$d = Get-ChildItem $dstLD -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($dstLD.Length) }
$dh = @{}; foreach ($x in $d) { $dh[$x] = $true }
# these are excluded on purpose and must NOT be reported as missing
$byDesign = '(\\LabDeploy\\logs\\|\\LabDeploy\\config\\gui-settings\.json$|timestamp_Cart\.txt$|drive-id\.txt$|telemetry-pushed\.json$)'
$missing = @($s | Where-Object { -not $dh.ContainsKey($_) -and $_ -notmatch $byDesign })

if ($missing.Count -gt 0) {
    Say ("  {0} file(s) missing after robocopy exit {1} - repairing" -f $missing.Count, $code) Yellow
    $fixed = 0
    foreach ($rel in $missing) {
        $sf = Join-Path $srcLD $rel.TrimStart('\')
        $df = Join-Path $dstLD $rel.TrimStart('\')
        $dd = Split-Path $df -Parent
        if (-not (Test-Path $dd)) { New-Item -ItemType Directory $dd -Force | Out-Null }
        try {
            Copy-Item $sf $df -Force
            if ((Get-FileHash $sf).Hash -eq (Get-FileHash $df).Hash) { $fixed++ }
            Say "     repaired: $rel"
        } catch { Say "     FAILED  : $rel  ($($_.Exception.Message))" Red }
    }
    Say ("  repaired {0} of {1}" -f $fixed, $missing.Count) $(if ($fixed -eq $missing.Count) { 'Green' } else { 'Red' })
} else {
    Say '  no missing files' Green
}

# --- post-init: launcher + permanent drive-id --------------------------------
$bat = Join-Path $StagingRoot 'START LabDeploy.bat'
if (Test-Path $bat) { Copy-Item $bat "${L}:\" -Force }
$idFile = "$dstLD\LabDeploy\drive-id.txt"
if (-not (Test-Path $idFile)) {
    $g = [guid]::NewGuid().ToString()
    Set-Content $idFile $g -Encoding ASCII
    Say "  drive-id issued: $g" Green
} else {
    Say "  drive-id kept  : $((Get-Content $idFile -TotalCount 1).Trim())"
}
$logDir = "$dstLD\LabDeploy\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir -Force | Out-Null }

# --- ledger stamp: record what this stick NOW carries -------------------------
# Closes the gap where CLI-synced sticks stayed "unknown" to the master forever:
# the GUI's verdicts (CURRENT/STALE per stick, plugged in or not) read the
# manifestSignature written here. Signed from the stick's own files - a botched
# copy stamps the truth, not the intention. No-op on a non-master machine.
try {
    . (Join-Path $PSScriptRoot 'Lib-PayloadManifest.ps1')
    $stampSig = Update-StickLedgerStamp -Letter $L
    if ($stampSig) {
        # TRIPWIRE: metadata must match what just happened. Post-sync+verify the
        # stick's fingerprint MUST equal staging's; a difference means something
        # still didn't copy (or the manifest math drifted between tools).
        $stagingSig = Get-PayloadManifest $srcLD
        if ($stampSig -eq $stagingSig) { Say "  fingerprint verified against staging: $stampSig" Green }
        else { Say "  WARNING [E74]: stick fingerprint $stampSig != staging $stagingSig AFTER sync+verify - investigate before trusting this stick" Red }
    }
} catch { Say "  ledger stamp skipped: $($_.Exception.Message)" Yellow }

# --- final report -------------------------------------------------------------
$tot = Get-ChildItem $dstLD -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
$feed = @(Get-ChildItem "$dstLD\LabDeploy-InstallerSources\LabVIEW-Feed\packages" -Filter *.nipkg -ErrorAction SilentlyContinue).Count
Say ("  RESULT: {0:N0} files, {1:N2} GB, feed={2} packages, launcher={3}" -f `
     $tot.Count, ($tot.Sum/1GB), $feed, (Test-Path "${L}:\START LabDeploy.bat")) Green
[pscustomobject]@{
    Drive = "${L}:"; Label = $vol.FileSystemLabel; Files = $tot.Count
    GB = [math]::Round($tot.Sum/1GB,2); FeedPackages = $feed
    Repaired = $missing.Count; Minutes = [int]$sw.Elapsed.TotalMinutes
}
