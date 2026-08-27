# tests/test-telemetry.ps1 — telemetry plane client.
# Covers: the observation encoder, deterministic ids, client-side sanity bounds,
# the push cursor, config/token loading, chunked push (mocked transport), and the
# no-op safety paths that guarantee "never worse than today".
#
# Self-contained on purpose: the telemetry functions are decoupled from the fleet
# fold, so this suite lifts only its own function set and touches none of the five
# fleet $want lists.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

$guiPath = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tok, [ref]$errs)
ok ($errs.Count -eq 0) "Deploy-LabGUI.ps1 parses ($($errs.Count) errors)"

$want = @('Get-ObsStableId','ConvertTo-ObsTimestamp','ConvertTo-ObsKvMap','New-LabObservation',
          'ConvertTo-LabObservation','Test-ObsMachineInBounds','Import-TelemetryConfig','Import-StickToken',
          'Get-PushCursor','Save-PushCursor','Push-Observations','ConvertFrom-LabHostname',
          'Get-VendorLogPath','Get-CappedLogBytes')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every telemetry function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

# --- top-level helpers + $script: state the AST loader does NOT bring in ---
function script:Write-LabLog { param($Event, $Data) $script:LogEvents += ,@{ Event = $Event; Data = $Data } }
$script:LogEvents = @()
# mock transport: capture batches instead of hitting the network
$script:PostedBatches = @()
function script:Invoke-ObsPost { param([array]$Observations, [string]$Url, [string]$Token, [int]$TimeoutSec)
    $script:PostedBatches += ,$Observations; return $true }
$script:PostedLogs = @()
function script:Invoke-LogPost { param([byte[]]$Bytes,[bool]$Truncated,[string]$Url,[string]$Token,[int]$TimeoutSec,[string]$ObsId,[string]$Machine,[string]$Session,[string]$AppId)
    $script:PostedLogs += ,@{ ObsId = $ObsId; AppId = $AppId; Bytes = $Bytes.Length; Truncated = $Truncated }; return $true }

$script:BuildingsConfig = (Get-Content (Join-Path $LabRoot 'config\buildings.json') -Raw | ConvertFrom-Json)
$script:DriveId    = '51ccf2ce-8707-43aa-9608-0927f784acc7'
$script:IsMaster      = $false
$script:MasterRoot = 'C:\LabDeployMaster'

$sand = Join-Path $env:TEMP ("telemetry_test_{0}" -f (Get-Date -Format 'HHmmssfff'))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
$script:LogRoot = $sand

# ----- a synthetic session log (new-format filename) -----
$logNew = Join-Path $sand 'LabDeploy_10101LAB34-20_20260818_120000_51ccf2.log'
@(
 "ts=2026-08-18 12:00:00.100`tevent=app.start`tcomputer=10101LAB34-20`tdriveId=51ccf2ce-8707-43aa-9608-0927f784acc7`tisAdmin=True",
 "ts=2026-08-18 12:00:05.200`tevent=machine.imaged_stamp`tdate=2026-08-14`tpresent=True",
 "ts=2026-08-18 12:01:00.300`tevent=scan.snapshot`tcount=3`tinstalled=Python;LTSpice`tmissing=Vivado`tpartial=`tuserOnly=",
 "ts=2026-08-18 12:02:00.400`tevent=install.failed`tappId=Vivado`terrorCode=E24`tname=Xilinx Vivado`texitCode=0",
 "ts=2026-08-18 12:03:00.500`tevent=install.verified`tappId=Vivado`texitCode=0`tname=Xilinx Vivado"
) | Set-Content -Path $logNew -Encoding UTF8

Write-Host "`n--- encoder ---"
$rows = @(ConvertTo-LabObservation -LogPath $logNew)
ok ($rows.Count -eq 5) "5 observations (2 installed + 1 missing from snapshot, 1 error, 1 verified) [$($rows.Count)]"
ok (@($rows | Where-Object { $_.verdict -eq 'installed' }).Count -eq 3) '3 installed (Python, LTSpice, Vivado-verified)'
ok (@($rows | Where-Object { $_.verdict -eq 'missing' }).Count -eq 1)   '1 missing (Vivado snapshot)'
ok (@($rows | Where-Object { $_.verdict -eq 'error' -and $_.code -eq 'E24' }).Count -eq 1) '1 error with code E24'
ok ($rows[0].machine -eq '10101LAB34-20') 'machine parsed'
ok ($rows[0].stick_id -eq '51ccf2')        'stick short-id parsed from filename'
ok (@($rows | Where-Object { $_.imaged_gen -eq '2026-08-14' }).Count -eq 5) 'imaged generation carried on every row'
ok (@($rows | Where-Object { $_.session -eq '20260818_120000' }).Count -eq 5) 'session id synthesised from filename'

Write-Host "`n--- deterministic ids ---"
$rows2 = @(ConvertTo-LabObservation -LogPath $logNew)
$ids1 = @($rows  | ForEach-Object { $_.obs_id })
$ids2 = @($rows2 | ForEach-Object { $_.obs_id })
ok (-not (Compare-Object $ids1 $ids2)) 're-encode gives identical obs_ids (idempotent)'
ok (@($ids1 | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'no duplicate obs_ids within a session'

Write-Host "`n--- old-format filename (machine from app.start, not filename) ---"
$logOld = Join-Path $sand 'LabDeploy_20260818_130000.log'
@(
 "ts=2026-08-18 13:00:00.100`tevent=app.start`tcomputer=10108LAB31-06`tisAdmin=True",
 "ts=2026-08-18 13:01:00.300`tevent=scan.snapshot`tinstalled=QuantStudio`tmissing=`tpartial=`tuserOnly="
) | Set-Content -Path $logOld -Encoding UTF8
$rowsOld = @(ConvertTo-LabObservation -LogPath $logOld)
ok ($rowsOld.Count -ge 1 -and $rowsOld[0].machine -eq '10108LAB31-06') 'old-format machine read from app.start computer='

Write-Host "`n--- GP/CM encode as __gp__ / __cm__ pseudo-apps ---"
$logGC = Join-Path $sand 'LabDeploy_10101LAB34-30_20260818_150000_51ccf2.log'
@(
 "ts=2026-08-18 15:00:00.100`tevent=app.start`tcomputer=10101LAB34-30`tdriveId=51ccf2ce-8707-43aa-9608-0927f784acc7",
 "ts=2026-08-18 15:01:00.000`tevent=gp.update_done`tcomputerOk=True`tuserOk=True`ttotalSec=20",
 "ts=2026-08-18 15:02:00.000`tevent=cm.actions_done`ttotal=3`tfailed=0"
) | Set-Content -Path $logGC -Encoding UTF8
$rowsGC = @(ConvertTo-LabObservation -LogPath $logGC)
ok (@($rowsGC | Where-Object { $_.app_id -eq '__gp__' -and $_.verdict -eq 'installed' }).Count -eq 1) 'gp.update_done (both OK) -> __gp__ installed'
ok (@($rowsGC | Where-Object { $_.app_id -eq '__cm__' -and $_.verdict -eq 'installed' }).Count -eq 1) 'cm.actions_done (0 failed) -> __cm__ installed'
$logGC2 = Join-Path $sand 'LabDeploy_10101LAB34-31_20260818_160000_51ccf2.log'
@(
 "ts=2026-08-18 16:00:00.100`tevent=app.start`tcomputer=10101LAB34-31`tdriveId=51ccf2ce-8707-43aa-9608-0927f784acc7",
 "ts=2026-08-18 16:01:00.000`tevent=gp.update_done`tcomputerOk=True`tuserOk=False",
 "ts=2026-08-18 16:02:00.000`tevent=cm.actions_done`ttotal=3`tfailed=1"
) | Set-Content -Path $logGC2 -Encoding UTF8
$rowsGC2 = @(ConvertTo-LabObservation -LogPath $logGC2)
ok (@($rowsGC2 | Where-Object { $_.app_id -eq '__gp__' -and $_.verdict -eq 'missing' }).Count -eq 1) 'gp not both-OK -> __gp__ missing'
ok (@($rowsGC2 | Where-Object { $_.app_id -eq '__cm__' -and $_.verdict -eq 'missing' }).Count -eq 1) 'cm with a failure -> __cm__ missing'

Write-Host "`n--- sanity bounds (needs buildings.json) ---"
ok (Test-ObsMachineInBounds '10101LAB34-20')  'known building 55 -> in bounds'
ok (Test-ObsMachineInBounds '10108LAB31-06')  'known building 37 -> in bounds'
ok (-not (Test-ObsMachineInBounds 'DEV-DESKTOP')) 'DESKTOP-* -> dropped (no building/room)'
ok (-not (Test-ObsMachineInBounds '')) 'empty hostname -> dropped'

Write-Host "`n--- push cursor round-trip ---"
$script:PushCursorFile = Join-Path $sand 'telemetry-pushed.json'
Save-PushCursor @{ 'a.log' = $true; 'b.log' = $true }
$cur = Get-PushCursor
ok ($cur.ContainsKey('a.log') -and $cur.ContainsKey('b.log') -and $cur.Count -eq 2) 'cursor persists + reloads'

Write-Host "`n--- config + token load ---"
$script:TelemetryConfigFile = Join-Path $sand 'telemetry.json'
'{ "enabled": true, "obsUrl": "https://real.example/obs", "timeoutSec": 4, "chunkSize": 2, "backfill": true }' | Set-Content $script:TelemetryConfigFile -Encoding UTF8
$script:TelemetryConfig = $null
$cfg = Import-TelemetryConfig
ok ($cfg.enabled -eq $true -and $cfg.chunkSize -eq 2 -and $cfg.obsUrl -eq 'https://real.example/obs') 'telemetry.json loads'
$script:TokensFile = Join-Path $sand 'tokens.json'
('{ "' + $script:DriveId + '": { "token": "TESTTOKEN", "label": "Dev" } }') | Set-Content $script:TokensFile -Encoding UTF8
$script:StickTokenCache = $null
ok ((Import-StickToken) -eq 'TESTTOKEN') 'token resolved for this drive-id'

Write-Host "`n--- push no-op safety (never worse than today) ---"
$script:TelemetryConfig = @{ enabled = $false }
$r = Push-Observations -LogsDir $sand
ok ($r.reason -eq 'disabled' -and $r.sent -eq 0) 'disabled -> no-op, no network'
$script:TelemetryConfig = @{ enabled = $true; obsUrl = 'https://x.REPLACE.workers.dev/obs'; timeoutSec = 3; chunkSize = 500; backfill = $true }
$script:StickTokenCache = 'tok'
$r = Push-Observations -LogsDir $sand
ok ($r.reason -eq 'no-endpoint' -and $r.sent -eq 0) 'placeholder URL -> no-op'
$script:TelemetryConfig = @{ enabled = $true; obsUrl = 'https://real.example/obs'; timeoutSec = 3; chunkSize = 500; backfill = $true }
$script:StickTokenCache = ''
$r = Push-Observations -LogsDir $sand
ok ($r.reason -eq 'no-token' -and $r.sent -eq 0) 'no token -> no-op'

Write-Host "`n--- push orchestration (mock transport, chunked) ---"
$pushdir = Join-Path $sand 'pushdir'
New-Item -ItemType Directory -Path $pushdir -Force | Out-Null
Copy-Item $logNew (Join-Path $pushdir (Split-Path $logNew -Leaf))
$script:PushCursorFile = Join-Path $sand 'push-cursor2.json'
$script:PostedBatches = @()
$script:TelemetryConfig = @{ enabled = $true; obsUrl = 'https://real.example/obs'; timeoutSec = 3; chunkSize = 2; backfill = $true }
$script:StickTokenCache = 'tok'
$r = Push-Observations -LogsDir $pushdir
ok ($r.ok -and $r.sent -eq 5 -and $r.files -eq 1) "encoded + pushed 5 obs from 1 file [sent=$($r.sent) files=$($r.files)]"
ok ($script:PostedBatches.Count -eq 3) "chunkSize 2 -> 3 batches [$($script:PostedBatches.Count)]"
$cur2 = Get-PushCursor
ok ($cur2.ContainsKey((Split-Path $logNew -Leaf))) 'cursor advanced for the pushed file'
$script:PostedBatches = @()
$r2 = Push-Observations -LogsDir $pushdir
ok ($r2.sent -eq 0 -and $script:PostedBatches.Count -eq 0) 're-run skips already-pushed file (cursor honoured)'

# out-of-bounds machines are filtered before push
Write-Host "`n--- out-of-bounds filtered from push ---"
$oobdir = Join-Path $sand 'oob'
New-Item -ItemType Directory -Path $oobdir -Force | Out-Null
$logOob = Join-Path $oobdir 'LabDeploy_DEV-DESKTOP_20260818_140000_51ccf2.log'
@(
 "ts=2026-08-18 14:00:00.100`tevent=app.start`tcomputer=DEV-DESKTOP`tdriveId=51ccf2ce-8707-43aa-9608-0927f784acc7",
 "ts=2026-08-18 14:01:00.300`tevent=scan.snapshot`tinstalled=Keil`tmissing=Logisim`tpartial=`tuserOnly="
) | Set-Content -Path $logOob -Encoding UTF8
$script:PushCursorFile = Join-Path $sand 'push-cursor3.json'
$script:PostedBatches = @()
$r3 = Push-Observations -LogsDir $oobdir
ok ($r3.ok -and $r3.sent -eq 0 -and $script:PostedBatches.Count -eq 0) 'DESKTOP-* log yields 0 pushed observations'

Write-Host "`n--- Phase 1: log cap (head + tail) ---"
$bigPath = Join-Path $sand 'big.log'
[System.IO.File]::WriteAllBytes($bigPath, (New-Object byte[] 1500000))
$cap = Get-CappedLogBytes -Path $bigPath
ok ($cap.Truncated -and $cap.Bytes.Length -le 1000000 -and $cap.Bytes.Length -gt 900000) "1.5 MB capped to ~1 MB [$($cap.Bytes.Length)]"
$smallPath = Join-Path $sand 'small.log'
'hello vendor log' | Set-Content $smallPath -Encoding UTF8
$capS = Get-CappedLogBytes -Path $smallPath
ok (-not $capS.Truncated) 'small log kept whole (not truncated)'

Write-Host "`n--- Phase 1: locate vendor MSI log ---"
$vlog = Join-Path $sand 'Vivado-msi-10101LAB34-20-20260818_120500.log'
'msiexec verbose output...' | Set-Content $vlog -Encoding UTF8
$found = Get-VendorLogPath -LogsDir $sand -AppId 'Vivado' -Machine '10101LAB34-20' -Session '20260818_120000'
ok ($found -and ((Split-Path $found -Leaf) -eq 'Vivado-msi-10101LAB34-20-20260818_120500.log')) 'vendor MSI log located for failed install'
ok (-not (Get-VendorLogPath -LogsDir $sand -AppId 'NoSuchApp' -Machine '10101LAB34-20' -Session '20260818_120000')) 'no vendor log -> null (exe/copy/winget failures)'

Write-Host "`n--- Phase 1: failed-install log push integration ---"
$pdir = Join-Path $sand 'p1push'
New-Item -ItemType Directory -Path $pdir -Force | Out-Null
Copy-Item $logNew (Join-Path $pdir (Split-Path $logNew -Leaf))
Copy-Item $vlog (Join-Path $pdir 'Vivado-msi-10101LAB34-20-20260818_120500.log')
$script:PushCursorFile = Join-Path $sand 'p1cursor.json'
$script:PostedBatches = @(); $script:PostedLogs = @()
$script:TelemetryConfig = @{ enabled = $true; obsUrl = 'https://real.example/obs'; logUrl = 'https://real.example/log'; timeoutSec = 5; chunkSize = 500; backfill = $true }
$script:StickTokenCache = 'tok'
$null = Push-Observations -LogsDir $pdir -DeadlineSec 0
ok ($script:PostedLogs.Count -eq 1) "1 failed-install log pushed [$($script:PostedLogs.Count)]"
ok ($script:PostedLogs.Count -ge 1 -and $script:PostedLogs[0].AppId -eq 'Vivado') 'log push tagged with the failing app (Vivado)'

Write-Host "`n--- Phase 1: close-drain skips log uploads ---"
$script:PushCursorFile = Join-Path $sand 'p1cursor2.json'
$script:PostedLogs = @()
$null = Push-Observations -LogsDir $pdir -DeadlineSec 3
ok ($script:PostedLogs.Count -eq 0) 'close-drain (3s) pushes observations but NOT ~1 MB logs'

Write-Host "`n--- verbose logging fires ---"
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'telemetry.push_start' }).Count -ge 1)   'push_start step logged'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'telemetry.file_encoded' }).Count -ge 1)  'per-file encode step logged'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'telemetry.push_skipped' }).Count -ge 1)  'no-op push logs a skip reason'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'telemetry.log_pushed' }).Count -ge 1)     'failed-install log push logged'

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
