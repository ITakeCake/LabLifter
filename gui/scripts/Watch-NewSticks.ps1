<#
.SYNOPSIS
    Watch for USB sticks being plugged in and name them in the order they appear.

.DESCRIPTION
    Plug in physical sticker #2, then #3, then #4 - a few seconds apart - and
    this names each one as it appears: LABDEPLOY02, LABDEPLOY03, LABDEPLOY04.
    Insertion ORDER is the mapping, so the physical sticker and the Windows
    label can never drift apart.

    THE ONE RULE: leave a couple of seconds between sticks. The watcher polls
    fast, but if two brand-new sticks show up inside the SAME poll they are
    indistinguishable (identical model, size and label) and it will STOP rather
    than coin-flip which is which. Nothing gets formatted in that case.

    Already-prepared (LABDEPLOY*) sticks are ignored, so previously named ones
    can stay plugged in.

    Formatting is destructive, so every target must pass: Removable + USB bus +
    not the system disk + not boot + not system.

.EXAMPLE
    .\Watch-NewSticks.ps1 -Numbers 2,3,4
    Waits for three sticks and names them 02, 03, 04 in insertion order.

.EXAMPLE
    .\Watch-NewSticks.ps1 -Numbers 5,6,7 -ThenSync
    Same, then copies the payload to all of them (2 at a time).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int[]]$Numbers,

    [string]$Prefix = 'LABDEPLOY',
    [int]$TimeoutMinutes = 20,
    [switch]$ThenSync,
    [string]$StagingRoot = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging'
)

$ErrorActionPreference = 'Stop'

function Get-UsbVolumes {
    $out = @{}
    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                      Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
        try {
            $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop | Select-Object -First 1
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        } catch { continue }
        if ("$($disk.BusType)" -ne 'USB') { continue }
        $out["$($vol.DriveLetter)"] = [pscustomobject]@{
            Letter  = "$($vol.DriveLetter)"
            Label   = "$($vol.FileSystemLabel)"
            FS      = "$($vol.FileSystem)"
            SizeGB  = [math]::Round($vol.Size / 1GB, 1)
            DiskNum = $part.DiskNumber
            Disk    = $disk
        }
    }
    return $out
}

function Test-SafeToFormat {
    param($stick)
    $sysDisk = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue).DiskNumber
    $d = $stick.Disk
    return (("$($d.BusType)" -eq 'USB') -and ($stick.DiskNum -ne $sysDisk) -and (-not $d.IsBoot) -and (-not $d.IsSystem))
}

# ---- baseline: everything already plugged in is off-limits -------------------
$baseline = Get-UsbVolumes
Write-Host ''
Write-Host "Watching for new USB sticks. Will name them, in order: $(($Numbers | ForEach-Object { 'LabDeploy-{0:D2}' -f $_ }) -join ', ')" -ForegroundColor Cyan
if ($baseline.Count) {
    Write-Host 'Already attached (ignored):' -ForegroundColor DarkGray
    $baseline.Values | ForEach-Object { "   $($_.Letter): [$($_.Label)]" }
}
Write-Host ''
Write-Host 'Plug them in ONE AT A TIME, a couple of seconds apart. Ctrl+C to stop.' -ForegroundColor Yellow
Write-Host ''

$done = @()
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

foreach ($n in $Numbers) {
    # new fleet scheme - formats NTFS below, so the 12-char mixed-case label is safe
    $label = 'LabDeploy-{0:D2}' -f $n
    Write-Host "Waiting for the stick to become $label ..." -ForegroundColor Cyan

    $target = $null
    while (-not $target) {
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes minutes waiting for $label." }
        Start-Sleep -Milliseconds 1200
        $now = Get-UsbVolumes
        $new = @($now.Keys | Where-Object { -not $baseline.ContainsKey($_) })

        if ($new.Count -eq 0) { continue }

        if ($new.Count -gt 1) {
            Write-Host ''
            Write-Host "STOPPING: $($new.Count) new sticks appeared at the same time." -ForegroundColor Red
            $new | ForEach-Object { "     $($_): [$($now[$_].Label)]  $($now[$_].SizeGB) GB" }
            Write-Host 'They are identical, so I cannot tell which sticker is which. Nothing was changed.' -ForegroundColor Red
            Write-Host 'Unplug all but one and re-run, leaving a gap between insertions.' -ForegroundColor Yellow
            throw 'Ambiguous insertion - aborted before formatting anything.'
        }

        $letter = $new[0]
        # let Windows finish mounting before touching it
        Start-Sleep -Seconds 2
        $now = Get-UsbVolumes
        if (-not $now.ContainsKey($letter)) { continue }
        $target = $now[$letter]
    }

    Write-Host ("  detected {0}: [{1}] {2} {3} GB  ({4})" -f `
        $target.Letter, $target.Label, $target.FS, $target.SizeGB, $target.Disk.FriendlyName)

    if ($target.Label -like "$Prefix*") {
        Write-Host "  already named [$($target.Label)] - skipping, not reformatting." -ForegroundColor Yellow
        $baseline[$target.Letter] = $target
        continue
    }
    if (-not (Test-SafeToFormat $target)) {
        throw "SAFETY CHECK FAILED for $($target.Letter): - refusing to format."
    }

    Write-Host "  formatting NTFS as $label ..." -ForegroundColor Cyan
    $null = cmd.exe /c "echo Y| format $($target.Letter): /FS:NTFS /V:$label /Q" 2>&1
    Start-Sleep -Seconds 3
    $v = Get-Volume -DriveLetter $target.Letter -ErrorAction SilentlyContinue
    if ("$($v.FileSystemLabel)" -ne $label -or "$($v.FileSystem)" -ne 'NTFS') {
        throw "Format did not take on $($target.Letter): (label='$($v.FileSystemLabel)' fs='$($v.FileSystem)')"
    }
    Write-Host ("  OK -> {0}: is [{1}] NTFS, {2:N1} GB free" -f $target.Letter, $v.FileSystemLabel, ($v.SizeRemaining/1GB)) -ForegroundColor Green
    Write-Host ''

    $baseline[$target.Letter] = $target      # so it is not re-detected
    $done += [pscustomobject]@{ Letter = $target.Letter; Label = $label }
}

Write-Host '================ NAMED ================' -ForegroundColor Cyan
$done | ForEach-Object { "   $($_.Letter): -> $($_.Label)" }
Write-Host ''

if ($ThenSync) {
    Write-Host 'Starting payload sync (2 at a time)...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Sync-AllSticks.ps1') -StagingRoot $StagingRoot -MaxParallel 2
} else {
    Write-Host 'Next:  .\Sync-AllSticks.ps1     (copies the payload to all of them, 2 at a time)' -ForegroundColor Yellow
}
