<#
.SYNOPSIS
    Label a new LabDeploy USB stick safely: LABDEPLOY01 .. LABDEPLOY99.

.DESCRIPTION
    Renaming ten drives by hand invites typos, and a duplicate label makes two
    sticks indistinguishable in the Sticks tab and the master ledger. This does the
    rename with the same positive-identification guard the tool itself uses, so
    it physically cannot touch C: or any internal disk:

        drive must be Removable  AND  on a USB bus

    It also refuses a number already claimed by a DIFFERENT stick, checked
    against the master ledger (C:\LabDeployMaster\sticks.json), which is keyed by
    each stick's permanent drive-id GUID rather than its label.

    Changing a volume label does NOT format, erase, or alter any file. It is a
    metadata rename and is safe to re-run.

    ORDER OF OPERATIONS for a new stick:
        1. this script   -> gives it a human name
        2. LabDeploy GUI -> Master > Sticks > Initialize (writes the payload and
                            issues the permanent drive-id)

.EXAMPLE
    .\Set-StickLabel.ps1 -DriveLetter F -Number 3
    Labels F: as LABDEPLOY03.

.EXAMPLE
    .\Set-StickLabel.ps1 -List
    Shows every attached USB stick and every label the master has on record.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DriveLetter,
    [ValidateRange(1, 99)]
    [int]$Number,
    [string]$Prefix = 'LABDEPLOY',
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$LedgerFile = 'C:\LabDeployMaster\sticks.json'

function Get-UsbSticks {
    # Same positive-ID rule as Deploy-LabGUI.ps1's Get-UsbCandidates: a drive is
    # only ever considered if it is a Removable volume on a USB-bus disk.
    $out = @()
    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                      Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
        $usb = $false; $bus = ''
        try {
            $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop | Select-Object -First 1
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
            $bus  = "$($disk.BusType)"
            $usb  = ($bus -eq 'USB')
        } catch { }
        if (-not $usb) { continue }
        $ld = "$($vol.DriveLetter):\LabDeployment\LabDeploy"
        $id = $null
        try { $id = (Get-Content (Join-Path $ld 'drive-id.txt') -TotalCount 1 -ErrorAction Stop).Trim() } catch { }
        $out += [pscustomobject]@{
            Letter     = "$($vol.DriveLetter)"
            Label      = "$($vol.FileSystemLabel)"
            FileSystem = "$($vol.FileSystem)"
            Bus        = $bus
            SizeGB     = [math]::Round($vol.Size / 1GB, 1)
            DriveId    = $id
            Initialized = (Test-Path (Join-Path $ld 'Deploy-LabGUI.ps1'))
        }
    }
    return @($out)
}

function Get-Ledger {
    if (-not (Test-Path $LedgerFile)) { return @{} }
    try {
        $o = Get-Content $LedgerFile -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}

$sticks = Get-UsbSticks
$ledger = Get-Ledger

if ($List -or (-not $DriveLetter -and -not $Number)) {
    Write-Host ''
    Write-Host 'USB sticks attached right now:' -ForegroundColor Cyan
    if ($sticks.Count -eq 0) {
        Write-Host '   (none - plug one in)'
    } else {
        $sticks | ForEach-Object {
            $idTxt = if ($_.DriveId) { $_.DriveId.Substring(0, 8) } else { 'not initialized' }
            '   {0}:  [{1}]  {2}  {3} GB  id {4}' -f $_.Letter, $_.Label, $_.FileSystem, $_.SizeGB, $idTxt
        }
    }
    Write-Host ''
    Write-Host 'Labels on record in the master ledger:' -ForegroundColor Cyan
    if ($ledger.Keys.Count -eq 0) {
        Write-Host '   (ledger empty)'
    } else {
        foreach ($k in $ledger.Keys) {
            '   id {0}   [{1}]   last seen {2}' -f $k.Substring(0, 8), $ledger[$k].label, $ledger[$k].lastSeen
        }
    }
    Write-Host ''
    Write-Host 'Usage:  .\Set-StickLabel.ps1 -DriveLetter F -Number 3' -ForegroundColor Yellow
    return
}

if (-not $DriveLetter -or -not $Number) {
    throw 'Both -DriveLetter and -Number are required (or use -List).'
}

$letter = $DriveLetter.TrimEnd(':').ToUpper()
# New fleet scheme (2026-07-29): LabDeploy-NN. 12 chars, mixed case -
# fine on NTFS (32-char labels), NOT on FAT32/exFAT (11-char ceiling). All
# fleet sticks are NTFS by our own init pipeline; the guard below refuses the
# long label on anything else instead of letting Set-Volume fail or truncate.
$label  = 'LabDeploy-{0:D2}' -f $Number

if ($label.Length -gt 32) {
    throw "Label '$label' is $($label.Length) chars. NTFS caps volume labels at 32."
}

$target = $sticks | Where-Object { $_.Letter -eq $letter } | Select-Object -First 1
if (-not $target) {
    Write-Host "REFUSED: ${letter}: is not a removable USB drive." -ForegroundColor Red
    Write-Host 'Only Removable volumes on a USB-bus disk can be labelled by this script.' -ForegroundColor Red
    Write-Host 'Attached USB sticks:' -ForegroundColor Yellow
    if ($sticks.Count -eq 0) { Write-Host '   (none)' } else { $sticks | ForEach-Object { "   $($_.Letter):  [$($_.Label)]" } }
    throw "Refusing to touch ${letter}:"
}

# Is this label already claimed by a DIFFERENT stick? Compare on drive-id, not
# label, so re-labelling the same stick is allowed but duplicating is not.
# NORMALIZED comparison: the fleet has both spellings during the migration
# (LABDEPLOY03 minted here, LabDeploy-03 after the master renames it) - a raw
# -eq treats those as different and lets the same NUMBER be claimed twice.
function Get-NormLabel { param($L) ("$L" -replace '[^0-9A-Za-z]', '').ToUpperInvariant() }
$normNew = Get-NormLabel $label
foreach ($k in $ledger.Keys) {
    if ((Get-NormLabel $ledger[$k].label) -eq $normNew -and $k -ne "$($target.DriveId)") {
        Write-Host "REFUSED: '$label' (as '$($ledger[$k].label)') already belongs to stick id $($k.Substring(0,8)) (last seen $($ledger[$k].lastSeen))." -ForegroundColor Red
        throw 'Pick a different number, or re-run with -List to see what is taken.'
    }
}
$dupNow = $sticks | Where-Object { (Get-NormLabel $_.Label) -eq $normNew -and $_.Letter -ne $letter }
if ($dupNow) {
    Write-Host "REFUSED: '$label' is already on $($dupNow[0].Letter): right now (as '$($dupNow[0].Label)')." -ForegroundColor Red
    throw 'Two attached sticks cannot share a label.'
}

# The 12-char mixed-case label needs NTFS. A factory-fresh FAT32 stick must be
# initialized (which formats NTFS) before it can carry the new-style name.
if ("$($target.FileSystem)" -ne 'NTFS' -and $label.Length -gt 11) {
    Write-Host "REFUSED: $letter`: is $($target.FileSystem) - '$label' needs NTFS (FAT-family caps labels at 11 chars)." -ForegroundColor Red
    throw "Initialize the stick first (Initialize-NewStick.ps1 formats NTFS), then label it."
}

Write-Host ''
Write-Host ("  {0}:  [{1}]  ->  [{2}]" -f $letter, $(if ($target.Label) { $target.Label } else { 'no label' }), $label) -ForegroundColor Cyan
Write-Host ("  {0}, {1} GB, id {2}" -f $target.FileSystem, $target.SizeGB,
            $(if ($target.DriveId) { $target.DriveId.Substring(0,8) } else { 'not initialized yet' }))
Write-Host '  (renames the volume only - no format, no files touched)'

if ($PSCmdlet.ShouldProcess("${letter}: ($($target.Label))", "set volume label to $label")) {
    Set-Volume -DriveLetter $letter -NewFileSystemLabel $label
    $after = (Get-Volume -DriveLetter $letter).FileSystemLabel
    if ($after -eq $label) {
        Write-Host "  OK - ${letter}: is now [$after]" -ForegroundColor Green
        if (-not $target.Initialized) {
            Write-Host '  NEXT: LabDeploy GUI > Master > Sticks > Initialize (writes payload + drive-id)' -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: label reads back as '$after', not '$label'." -ForegroundColor Red
        Write-Host '  FAT32 folds to uppercase and truncates past 11 chars.' -ForegroundColor Red
    }
}
