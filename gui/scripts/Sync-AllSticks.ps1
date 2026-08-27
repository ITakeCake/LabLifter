<#
.SYNOPSIS
    Sync every prepared LABDEPLOY* stick that is plugged in - in parallel.

.DESCRIPTION
    Once each stick has been NAMED (Initialize-NewStick.ps1), drive letters stop
    mattering: the volume label is the identity, so there is no way to mix up
    physical sticker #3 and #4 any more.

    Runs the syncs concurrently because the bottleneck is per-stick write speed,
    not the source read (the payload is in the OS file cache after the first
    pass). Two at a time is the sweet spot on one USB controller; more than that
    and they just contend.

    Each stick is verified file-by-file afterwards - robocopy exit 0 is not proof
    of a complete copy, as LABDEPLOY01 demonstrated.
#>
[CmdletBinding()]
param(
    [string]$StagingRoot = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging',
    [string]$Prefix = 'LABDEPLOY',
    [int]$MaxParallel = 2
)

$ErrorActionPreference = 'Stop'
$syncScript = Join-Path $PSScriptRoot 'Sync-Stick.ps1'
if (-not (Test-Path $syncScript)) { throw "Sync-Stick.ps1 not found beside this script." }

$targets = @()
foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
    try {
        $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop | Select-Object -First 1
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    } catch { continue }
    if ("$($disk.BusType)" -ne 'USB') { continue }
    if ("$($vol.FileSystemLabel)" -notlike "$Prefix*") { continue }   # unnamed sticks are skipped on purpose
    $targets += [pscustomobject]@{ Letter = "$($vol.DriveLetter)"; Label = "$($vol.FileSystemLabel)" }
}

if ($targets.Count -eq 0) {
    Write-Host "No prepared $Prefix* sticks attached." -ForegroundColor Yellow
    Write-Host "Name them first:  .\Initialize-NewStick.ps1 -Number N -NoSync" -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "Syncing $($targets.Count) stick(s), $MaxParallel at a time:" -ForegroundColor Cyan
$targets | ForEach-Object { "   $($_.Letter): [$($_.Label)]" }
Write-Host ''

$jobs = @()
foreach ($t in $targets) {
    # throttle so we never exceed MaxParallel concurrent copies
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallel) {
        Start-Sleep -Seconds 5
    }
    Write-Host "  starting $($t.Letter): [$($t.Label)]" -ForegroundColor Cyan
    $jobs += Start-Job -Name $t.Label -ScriptBlock {
        param($script, $letter, $staging)
        & $script -DriveLetter $letter -StagingRoot $staging -Quiet
    } -ArgumentList $syncScript, $t.Letter, $StagingRoot
}

Write-Host ''
Write-Host 'Waiting for all copies to finish...' -ForegroundColor Cyan
$null = $jobs | Wait-Job

Write-Host ''
Write-Host '================ RESULTS ================' -ForegroundColor Cyan
$bad = 0
foreach ($j in $jobs) {
    $r = Receive-Job $j -ErrorAction SilentlyContinue
    if ($j.State -eq 'Failed' -or -not $r) {
        Write-Host ("  {0,-13} FAILED  {1}" -f $j.Name, ($j.ChildJobs[0].JobStateInfo.Reason.Message)) -ForegroundColor Red
        $bad++
    } else {
        $row = $r | Select-Object -Last 1
        $flag = if ($row.Repaired -gt 0) { "  (repaired $($row.Repaired))" } else { '' }
        Write-Host ("  {0,-13} {1}  {2:N0} files  {3:N2} GB  feed={4}  {5}m{6}" -f `
            $row.Label, $row.Drive, $row.Files, $row.GB, $row.FeedPackages, $row.Minutes, $flag) -ForegroundColor Green
        if ($row.FeedPackages -ne 529) {
            Write-Host ("     WARNING: feed has $($row.FeedPackages) packages, expected 529") -ForegroundColor Red
            $bad++
        }
    }
    Remove-Job $j -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($bad -eq 0) { Write-Host 'ALL STICKS OK' -ForegroundColor Green }
else { Write-Host "$bad stick(s) need attention" -ForegroundColor Red }
