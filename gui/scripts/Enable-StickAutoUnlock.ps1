# ============================================================
#  Enable-StickAutoUnlock.ps1
#  "Trust this BitLocker stick on THIS PC" - no password on every plug-in.
# ============================================================
# WHAT IT DOES
#   Turns on BitLocker auto-unlock for every plugged-in LabDeploy USB stick.
#   Windows then stores that stick's key inside the MASTER's own BitLocker-
#   protected registry, so the drive silently unlocks here and nowhere else.
#
# WHY THIS IS SAFE
#   The key never touches the stick. It is sealed by C:'s encryption, so a
#   thief with the stick still needs the password, and a thief with the stick
#   AND this PC still needs this PC to boot. Auto-unlock is per-machine by
#   design: lab machines keep prompting for the password, which is the whole
#   point of encrypting them.
#
# REQUIREMENTS (both already true on this master as of 2026-07-30)
#   - C: must be BitLocker-protected            <- the hard prerequisite
#   - the stick must be ENCRYPTED and UNLOCKED right now
#   - admin (the script self-elevates)
#
# SAFETY CORE (same rule as the GUI's stick updater)
#   Only Removable-type volumes on USB-bus disks are ever touched. C: and every
#   internal disk are physically unreachable from this script.
#
# UNDO:  Disable-BitLockerAutoUnlock -MountPoint 'G:'
#        (or clear every stored key on this PC: manage-bde -autounlock -clearallkeys C:)
param(
    [switch]$ListOnly,             # report what WOULD happen, change nothing
    [string]$ResultFile = ''       # optional: write a plain-text summary here
)

# ---- self-elevate (same pattern as Launch.bat) ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator privileges...' -ForegroundColor Yellow
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($ListOnly)   { $argl += '-ListOnly' }
    if ($ResultFile) { $argl += @('-ResultFile', "`"$ResultFile`"") }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argl
    exit
}

$out = New-Object System.Collections.ArrayList
function Say { param([string]$Text, [string]$Colour = 'Gray')
    Write-Host $Text -ForegroundColor $Colour
    [void]$out.Add($Text)
}

Say '=== LabDeploy stick auto-unlock ===' 'Cyan'

# ---- prerequisite: the OS volume must be encrypted ----
$osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
if (-not $osVol -or $osVol.ProtectionStatus -ne 'On') {
    Say "STOP: $env:SystemDrive is NOT BitLocker-protected (status: $(if($osVol){$osVol.ProtectionStatus}else{'unknown'}))." 'Red'
    Say '      Windows refuses to store auto-unlock keys unless the OS drive is encrypted,' 'Red'
    Say '      because that is what protects the stored keys. Encrypt C: first.' 'Red'
    if ($ResultFile) { $out | Set-Content $ResultFile -Encoding UTF8 }
    exit 1
}
Say "OK: $env:SystemDrive is BitLocker-protected - auto-unlock keys can be stored here." 'Green'

# ---- find USB removable volumes (positive identification only) ----
$sticks = @()
foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
    $usb = $false
    try {
        $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop | Select-Object -First 1
        $usb  = ("$((Get-Disk -Number $part.DiskNumber -ErrorAction Stop).BusType)" -eq 'USB')
    } catch { }
    if ($usb) { $sticks += $vol }
}
if ($sticks.Count -eq 0) { Say 'No USB removable drives are plugged in.' 'Yellow' }

$done = 0; $already = 0; $skipped = 0; $failed = 0
foreach ($vol in ($sticks | Sort-Object DriveLetter)) {
    $l   = [string]$vol.DriveLetter
    $lbl = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { '(no label)' }
    $marker = Test-Path "${l}:\LabDeployment\LabDeploy\Deploy-LabGUI.ps1"
    Say ''
    Say "${l}: $lbl$(if ($marker) { '   [LabDeploy stick]' })" 'White'

    $bv = Get-BitLockerVolume -MountPoint "${l}:" -ErrorAction SilentlyContinue
    if (-not $bv -or $bv.ProtectionStatus -ne 'On') {
        Say '   not BitLocker-protected - nothing to trust. Encrypt it first (right-click > Turn on BitLocker).' 'Yellow'
        $skipped++; continue
    }
    if ("$($bv.LockStatus)" -eq 'Locked') {
        Say '   LOCKED right now. Unlock it once in Explorer (type the password), then re-run this script.' 'Yellow'
        $skipped++; continue
    }
    if ($bv.AutoUnlockEnabled) {
        Say '   already trusted on this PC - no password needed here.' 'Green'
        $already++; continue
    }
    if ($ListOnly) {
        Say '   WOULD enable auto-unlock (list-only mode, nothing changed).' 'Cyan'
        $done++; continue
    }
    try {
        Enable-BitLockerAutoUnlock -MountPoint "${l}:" -ErrorAction Stop | Out-Null
        $chk = Get-BitLockerVolume -MountPoint "${l}:" -ErrorAction SilentlyContinue
        if ($chk.AutoUnlockEnabled) {
            Say '   TRUSTED. This stick now unlocks automatically on this PC only.' 'Green'
            $done++
        } else {
            Say '   command ran but the drive still does not report auto-unlock - check manually.' 'Red'
            $failed++
        }
    } catch {
        Say "   FAILED: $($_.Exception.Message)" 'Red'
        $failed++
    }
}

Say ''
Say "Summary: $done newly trusted, $already already trusted, $skipped skipped, $failed failed." 'Cyan'
if ($failed -eq 0 -and $skipped -eq 0 -and ($done + $already) -gt 0) {
    Say 'Every plugged-in stick unlocks silently on this PC from now on.' 'Green'
}
Say 'Reminder: lab machines still ask for the password - that is intended, and it is what encrypting them buys you.' 'DarkGray'

if ($ResultFile) { $out | Set-Content $ResultFile -Encoding UTF8 }
if (-not $ListOnly) { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
