<#
.SYNOPSIS
    Which LabDeploy sticks are up to date, and which need syncing.

.DESCRIPTION
    Verdicts come from the master ledger (sticks.json): every sync - GUI or CLI -
    stamps the stick's whole-payload manifestSignature, and this compares each
    stamp against staging's CURRENT manifest. That answers for every stick the
    master has ever seen, plugged in or not, with zero stick I/O.

    -Deep additionally walks each ATTACHED stick and fingerprints what it
    actually carries right now (about 30-60s per stick) - catches a stick that
    was modified outside the sync pipeline since its last stamp.

    The stick's identity is its drive-id GUID, never its label - relabelling
    (LABDEPLOY04 -> LabDeploy-04) does not create a new entry or lose history.
#>
[CmdletBinding()]
param(
    [string]$StagingRoot = 'C:\Users\admin\Desktop\LabDeploy-Flash-Staging',
    [string]$MasterRoot  = 'C:\LabDeployMaster',
    [switch]$Deep
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-PayloadManifest.ps1')

$srcRoot = Join-Path $StagingRoot 'LabDeployment'
if (-not (Test-Path $srcRoot)) { throw "staging not found: $srcRoot" }

$currentSig = Get-PayloadManifest $srcRoot
Write-Host ''
Write-Host "Current staging manifest: $currentSig" -ForegroundColor Cyan
Write-Host "  (staging GUI: $((Get-Item (Join-Path $srcRoot 'LabDeploy\Deploy-LabGUI.ps1')).LastWriteTime))"
Write-Host ''

function Get-Verdict {
    param($Entry)
    if (-not $Entry) { return @('UNKNOWN', 'never seen by the master') }
    $m = "$($Entry.manifestSignature)"
    if (-not $m) { return @('UNKNOWN', "never fingerprinted (last seen $($Entry.lastSeen)) - sync it once") }
    if ($m -eq $currentSig) { return @('CURRENT', "synced $($Entry.lastSynced)") }
    $extra = ''
    try {
        if ($Entry.lastSeen -and $Entry.lastSynced -and ([datetime]$Entry.lastSeen) -gt ([datetime]$Entry.lastSynced).AddMinutes(5)) {
            $extra = ' - VISITED after last sync without updating!'
        }
    } catch { }
    return @('NEEDS SYNC', "stamped $m, synced $($Entry.lastSynced)$extra")
}

# ---- ledger ------------------------------------------------------------------
$ledger = @{}
$ledgerFile = Join-Path $MasterRoot 'sticks.json'
foreach ($cand in @($ledgerFile, "$ledgerFile.bak")) {
    if (-not (Test-Path $cand)) { continue }
    try {
        $o = Get-Content $cand -Raw | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) { $ledger[$p.Name] = $p.Value }
        break
    } catch { $ledger = @{} }
}

# ---- attached sticks -----------------------------------------------------------
$attached = @{}
$rows = @()
foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Removable' })) {
    $ldRoot = "$($vol.DriveLetter):\LabDeployment"
    if (-not (Test-Path "$ldRoot\LabDeploy")) {
        $rows += [pscustomobject]@{ Label = "$($vol.FileSystemLabel)"; Id = '-'; Where = "$($vol.DriveLetter): (attached)"
                                    Status = 'NO PAYLOAD'; Detail = 'never initialised' }
        continue
    }
    $id = try { (Get-Content "$ldRoot\LabDeploy\drive-id.txt" -TotalCount 1 -ErrorAction Stop).Trim() } catch { $null }
    if ($id) { $attached[$id] = $true }
    $entry = if ($id) { $ledger[$id] } else { $null }
    $v = Get-Verdict $entry
    $status = $v[0]; $detail = $v[1]
    if ($Deep) {
        $live = Get-PayloadManifest $ldRoot
        if ($live -eq $currentSig) { $status = 'CURRENT'; $detail = "verified live: $live" }
        else { $status = 'NEEDS SYNC'; $detail = "live manifest $live != staging (ledger said: $($v[0]))" }
    }
    $rows += [pscustomobject]@{
        Label  = "$($vol.FileSystemLabel)"
        Id     = if ($id) { $id.Substring(0,8) } else { 'NO ID' }
        Where  = "$($vol.DriveLetter): (attached)"
        Status = $status
        Detail = $detail
    }
}

# ---- sticks the master has seen but that are not plugged in ------------------------
foreach ($k in $ledger.Keys) {
    if ($attached.ContainsKey($k)) { continue }
    $e = $ledger[$k]
    $v = Get-Verdict $e
    $rows += [pscustomobject]@{
        Label  = "$($e.label)"
        Id     = $k.Substring(0, [math]::Min(8, $k.Length))
        Where  = "not plugged in (last on $($e.lastLetter))"
        Status = $v[0]
        Detail = $v[1]
    }
}

if ($rows.Count -eq 0) { Write-Host 'No sticks attached and no ledger history.' -ForegroundColor Yellow; return }

$rows | Sort-Object Label | Format-Table Label, Id, Status, Where, Detail -AutoSize

$need = @($rows | Where-Object { $_.Status -ne 'CURRENT' })
Write-Host ''
if ($need.Count -eq 0) { Write-Host 'ALL KNOWN STICKS ARE CURRENT' -ForegroundColor Green }
else {
    Write-Host "$($need.Count) stick(s) need attention:" -ForegroundColor Yellow
    $need | ForEach-Object { Write-Host "   $($_.Label)  [$($_.Status)]  $($_.Where)" -ForegroundColor Yellow }
}
