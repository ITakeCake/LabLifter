<#
.SYNOPSIS
    Prepare ONE fresh USB stick as LABDEPLOYnn: label it, format NTFS, and
    (optionally) copy the full payload.

.DESCRIPTION
    THE MIX-UP PROBLEM this solves: ten identical SanDisks arrive FAT32, all
    labelled "SANDISK USB", and Windows hands out drive letters in whatever
    order it feels like. Once several are plugged in there is no way in software
    to tell physical sticker #3 from #4.

    So this script REFUSES TO GUESS. It acts only when exactly ONE unprepared
    stick is attached. Already-prepared sticks (label LABDEPLOY*) are ignored,
    so you can leave them plugged in.

    WORKFLOW for several drives:
        1. plug in stick #2 ONLY            -> .\Initialize-NewStick.ps1 -Number 2
        2. leave it in, plug in stick #3    -> .\Initialize-NewStick.ps1 -Number 3
        3. ...and so on. Each is named the moment it goes in, so the physical
           sticker and the Windows label can never drift apart.
        4. once all are named, sync them together (-NoSync here, then use the
           GUI's Sticks tab, or Sync-AllSticks.ps1).

    Formatting is destructive, so the target must pass every one of these:
    Removable + USB bus + not the system disk + not boot + not system.

.EXAMPLE
    .\Initialize-NewStick.ps1 -Number 2
    Formats the single fresh stick as LABDEPLOY02 and copies the payload.

.EXAMPLE
    .\Initialize-NewStick.ps1 -Number 3 -NoSync
    Names/formats only - copy the payload later, in parallel with others.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 99)]
    [int]$Number,

    [string]$DriveLetter,          # optional: name it explicitly, skips auto-detect
    [switch]$NoSync,               # label + format only
    [string]$StagingRoot = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging',
    [string]$Prefix = 'LABDEPLOY'
)

$ErrorActionPreference = 'Stop'
# New fleet scheme (2026-07-29): LabDeploy-NN. Safe here because this script
# always formats NTFS (32-char mixed-case labels); $Prefix stays LABDEPLOY for
# the case-insensitive "already prepared" checks, which match both spellings.
$Label = 'LabDeploy-{0:D2}' -f $Number

function Get-UsbSticks {
    $out = @()
    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                      Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
        try {
            $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop | Select-Object -First 1
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
        } catch { continue }
        if ("$($disk.BusType)" -ne 'USB') { continue }
        $out += [pscustomobject]@{
            Letter   = "$($vol.DriveLetter)"
            Label    = "$($vol.FileSystemLabel)"
            FS       = "$($vol.FileSystem)"
            SizeGB   = [math]::Round($vol.Size / 1GB, 1)
            DiskNum  = $part.DiskNumber
            Disk     = $disk
            Prepared = ("$($vol.FileSystemLabel)" -like "$Prefix*")
        }
    }
    return @($out)
}

$sticks = Get-UsbSticks
if ($sticks.Count -eq 0) { throw 'No USB sticks attached.' }

Write-Host ''
Write-Host 'USB sticks attached:' -ForegroundColor Cyan
$sticks | ForEach-Object {
    $tag = if ($_.Prepared) { 'already prepared - ignoring' } else { 'FRESH' }
    '   {0}: [{1,-12}] {2,-6} {3,6:N0} GB   {4}' -f $_.Letter, $_.Label, $_.FS, $_.SizeGB, $tag
}

# --- pick the target, refusing to guess -------------------------------------
if ($DriveLetter) {
    $letter = $DriveLetter.TrimEnd(':').ToUpper()
    $target = $sticks | Where-Object { $_.Letter -eq $letter } | Select-Object -First 1
    if (-not $target) { throw "${letter}: is not an attached USB stick." }
} else {
    $fresh = @($sticks | Where-Object { -not $_.Prepared })
    if ($fresh.Count -eq 0) {
        throw "Every attached stick is already prepared ($Prefix*). Plug in the new one, or pass -DriveLetter to re-do a specific stick."
    }
    if ($fresh.Count -gt 1) {
        Write-Host ''
        Write-Host "REFUSING TO GUESS: $($fresh.Count) unprepared sticks are attached." -ForegroundColor Red
        $fresh | ForEach-Object { "     $($_.Letter): [$($_.Label)] $($_.SizeGB) GB" }
        Write-Host 'They are identical, so I cannot tell which physical sticker is which.' -ForegroundColor Red
        Write-Host 'Either unplug all but one, or name a specific drive with -DriveLetter.' -ForegroundColor Yellow
        throw 'Ambiguous target - nothing was changed.'
    }
    $target = $fresh[0]
}

# --- duplicate-label guard --------------------------------------------------
$clash = $sticks | Where-Object { $_.Label -eq $Label -and $_.Letter -ne $target.Letter }
if ($clash) { throw "'$Label' is already on $($clash[0].Letter): - two sticks cannot share a name." }

# --- hard safety gate -------------------------------------------------------
$sysDisk = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue).DiskNumber
$d = $target.Disk
$checks = [ordered]@{
    'is Removable'      = ($target.FS -ne $null)
    'BusType is USB'    = ("$($d.BusType)" -eq 'USB')
    'not the system disk' = ($target.DiskNum -ne $sysDisk)
    'not boot disk'     = (-not $d.IsBoot)
    'not system disk'   = (-not $d.IsSystem)
}
Write-Host ''
Write-Host "Target: $($target.Letter): -> [$Label]   $($d.FriendlyName)  $($target.SizeGB) GB" -ForegroundColor Cyan
foreach ($k in $checks.Keys) { '   {0,-22} {1}' -f $k, $checks[$k] }
if ($checks.Values -contains $false) { throw 'SAFETY CHECK FAILED - refusing to format.' }

$contents = @(Get-ChildItem "$($target.Letter):\" -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -ne 'System Volume Information' })
Write-Host "   will ERASE $($contents.Count) item(s) currently on the drive" -ForegroundColor Yellow

if (-not $PSCmdlet.ShouldProcess("$($target.Letter): ($($target.Label))", "format NTFS as $Label")) { return }

# --- format -----------------------------------------------------------------
# Format-Volume rejects a FAT32->NTFS change on these (Invalid Parameter), so
# use format.com, which handles it. /Q = quick.
Write-Host ''
Write-Host "Formatting $($target.Letter): as NTFS [$Label] ..." -ForegroundColor Cyan
$null = cmd.exe /c "echo Y| format $($target.Letter): /FS:NTFS /V:$Label /Q" 2>&1
Start-Sleep -Seconds 3
$v = Get-Volume -DriveLetter $target.Letter -ErrorAction SilentlyContinue
if ("$($v.FileSystemLabel)" -ne $Label -or "$($v.FileSystem)" -ne 'NTFS') {
    throw "Format did not take: label='$($v.FileSystemLabel)' fs='$($v.FileSystem)'"
}
Write-Host "   OK - $($target.Letter): is [$($v.FileSystemLabel)] $($v.FileSystem), $([math]::Round($v.SizeRemaining/1GB,1)) GB free" -ForegroundColor Green

if ($NoSync) {
    Write-Host ''
    Write-Host "Named and formatted. Payload NOT copied (-NoSync)." -ForegroundColor Yellow
    Write-Host "Leave it plugged in; sync it later with the GUI or Sync-AllSticks.ps1." -ForegroundColor Yellow
    return
}

# --- payload ----------------------------------------------------------------
& (Join-Path $PSScriptRoot 'Sync-Stick.ps1') -DriveLetter $target.Letter -StagingRoot $StagingRoot
