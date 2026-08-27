<#
.SYNOPSIS
    Shared payload-fingerprint + ledger-stamp helpers for the CLI stick tools.

.DESCRIPTION
    Dot-source this from Sync-Stick.ps1 / Get-FleetStatus.ps1. The manifest
    logic here MUST stay byte-identical to Get-PayloadManifest inside
    Deploy-LabGUI.ps1 - the two are compared as opaque strings, so any drift
    (file list, exclusions, casing, rounding, length) silently marks every
    stick STALE forever. A parity test in the scratchpad suite compares the
    two implementations against the same tree; run it after touching either.

    Why metadata and not content: reading 54 GB off USB takes 6-9 minutes -
    longer than the incremental sync this fingerprint advises about. Path +
    size + mtime is exactly what robocopy /MIR compares, so manifest equality
    means "a sync would copy nothing".
#>

function Get-PayloadManifest {
    param([string]$LabDeploymentRoot)
    if (-not $LabDeploymentRoot -or -not (Test-Path $LabDeploymentRoot)) { return 'NO-PAYLOAD' }
    $rootFull = [System.IO.Path]::GetFullPath($LabDeploymentRoot).TrimEnd('\')
    # exclusions mirror the sync's robocopy args EXACTLY: per-stick field data
    # (logs\, gui-settings.json, timestamp_Cart.txt, drive-id.txt) and SVI
    # legitimately differ per stick and must never count against it.
    # fleet-issues.json is the opposite case (2026-08-14): mirrored to sticks,
    # but rewritten into staging by Publish-FleetIssues on every fleet refresh
    # (= every master app launch), so counting it marked the whole fleet STALE on
    # every restart. Transient master state must never be what makes a sync look
    # needed.
    # per-drive/field files must NOT move the fingerprint (see the GUI copy of this note):
    # a stick that ran in the field carries its own telemetry cursors, which are /XF-excluded.
    $skip = [regex]'(?i)(\\System Volume Information\\|^\\LabDeploy\\logs\\|\\(gui-settings\.json|timestamp_Cart\.txt|drive-id\.txt|fleet-issues\.json|telemetry-pushed\.json|markreq-pulled\.json|telemetry-http\.json)$)'
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length)
        if ($skip.IsMatch($rel)) { continue }
        # UTC (DST-proof) rounded to whole seconds (FAT-family truncation-proof)
        $lines.Add(("{0}|{1}|{2}" -f $rel.ToLowerInvariant(), $f.Length, $f.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')))
    }
    if ($lines.Count -eq 0) { return 'EMPTY' }
    $lines.Sort([System.StringComparer]::Ordinal)
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))) -replace '-','').Substring(0, 16)
}

# Legacy 4-file signature - kept so older readers of sticks.json keep working.
# Identical to Get-PayloadSignature in Get-FleetStatus.ps1 / the GUI.
function Get-Payload4FileSignature {
    param([string]$LabDeployFolder)
    $parts = @()
    foreach ($rel in 'Deploy-LabGUI.ps1', 'config\apps.json', 'config\rooms.json', 'config\buildings.json') {
        $p = Join-Path $LabDeployFolder $rel
        $parts += if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash } else { 'MISSING' }
    }
    $joined = [Text.Encoding]::UTF8.GetBytes(($parts -join '|'))
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($joined)) -replace '-','').Substring(0, 16)
}

# Stamp one stick's post-sync fingerprint into the master ledger. Safe no-op on a
# non-master machine. Same torn-file protection as the GUI's Save-StickLedger:
# .bak first, temp-write, atomic-ish swap - a crash mid-write must never leave
# a half-written sticks.json (a torn ledger used to get silently replaced by
# an empty one, erasing all fleet history).
function Update-StickLedgerStamp {
    param(
        [Parameter(Mandatory = $true)][string]$Letter,
        [string]$MasterRoot = 'C:\LabDeployMaster'
    )
    if (-not (Test-Path $MasterRoot)) { return }
    $ledgerFile = Join-Path $MasterRoot 'sticks.json'
    try {
        $ldRoot = "${Letter}:\LabDeployment"
        $ld = "$ldRoot\LabDeploy"
        $id = (Get-Content (Join-Path $ld 'drive-id.txt') -TotalCount 1 -ErrorAction Stop).Trim()
        if (-not $id) { return }
        $mSig = Get-PayloadManifest $ldRoot
        $sig  = Get-Payload4FileSignature $ld

        $led = @{}
        foreach ($cand in @($ledgerFile, "$ledgerFile.bak")) {
            if (-not (Test-Path $cand)) { continue }
            try {
                $o = Get-Content $cand -Raw | ConvertFrom-Json
                foreach ($p in $o.PSObject.Properties) { $led[$p.Name] = $p.Value }
                break
            } catch { $led = @{} }
        }
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $e = $led[$id]
        if (-not $e) {
            $vol = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
            $e = [pscustomobject]@{
                label = "$(if ($vol) { $vol.FileSystemLabel })"; firstSeen = $now; lastSeen = $now
                lastLetter = "${Letter}:"; sizeGB = $(if ($vol) { [math]::Round($vol.Size/1GB, 0) } else { 0 }); seenCount = 1
            }
        }
        Add-Member -InputObject $e -MemberType NoteProperty -Name lastSeen -Value $now -Force
        Add-Member -InputObject $e -MemberType NoteProperty -Name lastSynced -Value $now -Force
        Add-Member -InputObject $e -MemberType NoteProperty -Name payloadSignature -Value $sig -Force
        Add-Member -InputObject $e -MemberType NoteProperty -Name manifestSignature -Value $mSig -Force
        $led[$id] = $e

        $out = New-Object psobject
        foreach ($k in $led.Keys) { Add-Member -InputObject $out -MemberType NoteProperty -Name $k -Value $led[$k] }
        $json = $out | ConvertTo-Json -Depth 6
        if (Test-Path $ledgerFile) { Copy-Item $ledgerFile "$ledgerFile.bak" -Force -ErrorAction SilentlyContinue }
        $tmp = "$ledgerFile.tmp"
        Set-Content $tmp $json -Encoding UTF8 -Force
        Move-Item $tmp $ledgerFile -Force
        return $mSig
    } catch { }
}
