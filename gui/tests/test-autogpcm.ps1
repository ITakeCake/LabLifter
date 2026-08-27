# tests/test-autogpcm.ps1 — theFuture item 4: auto GP update + CM actions at startup.
# Covers detection (Test-MachineNeedsGpCm) and the startup orchestrator (Invoke-AutoGpCm):
# the master / disabled / already-confirmed / detect-only no-op paths, and that the launchers
# fire ONLY when enabled + needed. The real Start-GpUpdateRun/Start-CmActionsRun are NOT
# lifted — they are replaced by counting stubs, so NOTHING launches (no gpupdate, no CM).
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

# NB: Start-GpUpdateRun / Start-CmActionsRun are deliberately NOT lifted (stubbed below).
$want = @('Test-MachineNeedsGpCm','Invoke-AutoGpCm','Get-AutoGpCmEnabled')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every auto-gpcm function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

# --- stubs the AST loader does NOT bring in ---
function script:Write-LabLog { param($Event, $Data) $script:LogEvents += ,@{ Event = $Event; Data = $Data } }
$script:LogEvents = @()
$script:GpStarted = 0; $script:CmStarted = 0
function script:Start-GpUpdateRun { param([switch]$DetectOnly) $script:GpStarted++; return @{ pid = 1 } }
function script:Start-CmActionsRun { param([switch]$DetectOnly) $script:CmStarted++; return 1 }
$script:MockRoll = @{}
function script:Get-FleetRollup { param($LogsDir, $Machine) return $script:MockRoll }
$mn = $env:COMPUTERNAME
$script:IsMaster = $false

$sand = Join-Path $env:TEMP ("autogpcm_test_{0}" -f (Get-Date -Format 'HHmmssfff'))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
$onFile  = Join-Path $sand 'startup-on.json';  [pscustomobject]@{ autoGpCm = $true }  | ConvertTo-Json | Set-Content $onFile -Encoding UTF8
$offFile = Join-Path $sand 'startup-off.json'; [pscustomobject]@{ autoGpCm = $false } | ConvertTo-Json | Set-Content $offFile -Encoding UTF8

Write-Host "`n--- Test-MachineNeedsGpCm detection ---"
$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; Sessions = 1 } }
$n = Test-MachineNeedsGpCm
ok ($n.NeedsGp -and $n.NeedsCm) "no history this image -> needs BOTH"

$script:MockRoll = @{ $mn = @{ GpLast = (Get-Date); CmLast = (Get-Date); Sessions = 2 } }
$n = Test-MachineNeedsGpCm
ok (-not $n.NeedsGp -and -not $n.NeedsCm) "both recorded -> needs NEITHER"

$script:MockRoll = @{ $mn = @{ GpLast = (Get-Date); CmLast = $null; Sessions = 1 } }
$n = Test-MachineNeedsGpCm
ok (-not $n.NeedsGp -and $n.NeedsCm) "GP recorded, CM not -> needs only CM"

# regression (bug #1): the AUTO path logs gp/cm.auto_started, never gp.update_done. If
# detection ignored the "tried" signal it would re-fire gpupdate on EVERY launch forever.
$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; GpTried = (Get-Date); CmTried = (Get-Date); Sessions = 2 } }
$n = Test-MachineNeedsGpCm
ok (-not $n.NeedsGp -and -not $n.NeedsCm) "an AUTO launch already tried (GpTried/CmTried) -> does NOT re-fire"
$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; GpTried = (Get-Date); CmTried = $null; Sessions = 1 } }
$n = Test-MachineNeedsGpCm
ok (-not $n.NeedsGp -and $n.NeedsCm) "GP already auto-tried, CM not -> only CM still needed"

Write-Host "`n--- Invoke-AutoGpCm no-op guards (nothing launches) ---"
$script:StartupFile = $onFile
$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; Sessions = 1 } }

$script:IsMaster = $true
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm
ok ($r.Skipped -eq 'master' -and $script:GpStarted -eq 0 -and $script:CmStarted -eq 0) "master -> skipped, launches nothing"
$script:IsMaster = $false

$script:StartupFile = $offFile
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm
ok ($r.Skipped -eq 'disabled' -and $script:GpStarted -eq 0 -and $script:CmStarted -eq 0) "toggle off -> skipped, launches nothing"

$script:StartupFile = $onFile
$script:MockRoll = @{ $mn = @{ GpLast = (Get-Date); CmLast = (Get-Date); Sessions = 3 } }
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm
ok ($r.Skipped -eq 'already confirmed' -and $script:GpStarted -eq 0 -and $script:CmStarted -eq 0) "already confirmed -> skipped, launches nothing"

$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; Sessions = 1 } }
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm -DetectOnly
ok ($r.Skipped -eq 'detect-only' -and $script:GpStarted -eq 0 -and $script:CmStarted -eq 0) "detect-only -> decides but launches nothing"
ok ($r.NeedsGp -and $r.NeedsCm) "detect-only still reports the need"

Write-Host "`n--- Invoke-AutoGpCm live path (stubbed launchers) ---"
$script:MockRoll = @{ $mn = @{ GpLast = $null; CmLast = $null; Sessions = 1 } }
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm
ok ($r.Ran -and $script:GpStarted -eq 1 -and $script:CmStarted -eq 1) "needs both -> starts GP + CM once each"

$script:MockRoll = @{ $mn = @{ GpLast = (Get-Date); CmLast = $null; Sessions = 1 } }
$script:GpStarted = 0; $script:CmStarted = 0
$r = Invoke-AutoGpCm
ok ($r.Ran -and $script:GpStarted -eq 0 -and $script:CmStarted -eq 1) "needs only CM -> starts CM, not GP"

try { Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host "`n================  $pass passed, $fail failed  ================"
if ($fail) { exit 1 } else { exit 0 }
