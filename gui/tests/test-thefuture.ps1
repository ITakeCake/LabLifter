# tests/test-thefuture.ps1 - theFuture Tier 0/1 spine.
# Covers the request-edit whitelist (item 3), the master config mirror (item 2), the
# mark-request pull/merge (item 1), and the auto GP/CM startup logic (item 4).
#
# Self-contained AST loader like test-telemetry.ps1: lifts ONLY its own function set
# and mocks every top-level dependency, so it touches none of the five fleet $want
# lists. NOTHING here ever launches gpupdate / CM or hits the network - every side
# effect is behind a mock, and the auto-run is exercised in -DetectOnly only.
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

$want = @('Import-Whitelist','Test-UserWhitelisted','Get-AutoGpCmEnabled','Test-MachineNeedsGpCm',
          'Start-GpUpdateRun','Start-CmActionsRun','Invoke-AutoGpCm','Push-MasterConfig','Invoke-ConfigPost',
          'Invoke-MarkRequestPost','Request-FleetMark','Get-MarkReqCursor','Save-MarkReqCursor','Pull-FleetMarkRequests')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every theFuture function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

# ---------- mocks for top-level helpers the AST loader does NOT bring in ----------
$script:LogEvents = @()
function script:Write-LabLog { param($Event, $Data) $script:LogEvents += ,@{ Event = $Event; Data = $Data } }

# Telemetry config + token are configurable per-test via these script vars.
$script:MockCfg = @{ enabled = $false; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
function script:Import-TelemetryConfig { return $script:MockCfg }
$script:MockToken = 'tok-abc'
function script:Import-StickToken { return $script:MockToken }

# Fleet marks: a plain hashtable that IS the cache (matches the real Import/Save pair).
$script:MarksCache = @{}
function script:Import-FleetMarks { return $script:MarksCache }
$script:SavedMarks = 0
function script:Save-FleetMarks { $script:SavedMarks++; return $true }
function script:Import-FleetYears { return @{ Current = 2026; Pages = @() } }

# Fleet rollup is mocked per-test to shape GP/CM history.
$script:MockRoll = @{}
function script:Get-FleetRollup { param([string]$LogsDir='', [string]$Machine='') return $script:MockRoll }

# CM WMI path - must never actually fire.
$script:CmFired = 0
function script:Invoke-CMWmiTriggers { $script:CmFired++; return 9 }

# Start-Process must NEVER run in these tests. If anything calls it, flip the tripwire.
$script:ProcStarted = 0
function script:Start-Process { $script:ProcStarted++; return [pscustomobject]@{ Id = 4242 } }

# Network: Invoke-RestMethod is mocked; each test sets $script:RestReply / captures $script:RestCalls.
$script:RestCalls = @()
$script:RestReply = @{ ok = $true }
function script:Invoke-RestMethod {
    param($Uri, $Method, $Body, $ContentType, $Headers, $TimeoutSec, $ErrorAction)
    $script:RestCalls += ,@{ Uri = "$Uri"; Method = "$Method"; Body = "$Body" }
    return $script:RestReply
}

# ---------- sandbox for whitelist / startup files ----------
$sand = Join-Path $env:TEMP ("thefuture_test_{0}" -f (Get-Date -Format 'HHmmssfff'))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
$script:WhitelistFile     = Join-Path $sand 'whitelist.json'
$script:StartupFile       = Join-Path $sand 'startup.json'
$script:MarkReqCursorFile = Join-Path $sand 'markreq-pulled.json'
$script:WhitelistCache    = $null
$script:IsMaster             = $false
$script:LogRoot           = $sand
$script:BuildingsConfig   = [pscustomobject]@{ buildings = [pscustomobject]@{ '55' = [pscustomobject]@{ abbr = 'SCI1' } } }

# ================= item 3: whitelist =================
'{ "users": ["Blake","Viewer1"] }' | Set-Content $script:WhitelistFile -Encoding UTF8
$script:WhitelistCache = $null
ok ((Import-Whitelist).Count -eq 2) "Import-Whitelist reads both users"
ok (Test-UserWhitelisted 'Blake')   "whitelist: Blake approved"
ok (Test-UserWhitelisted 'blake')   "whitelist: match is case-insensitive"
ok (-not (Test-UserWhitelisted 'mallory')) "whitelist: unknown user rejected"
ok (-not (Test-UserWhitelisted ''))        "whitelist: empty user rejected"

# master seeds whitelist.json when absent
Remove-Item $script:WhitelistFile -Force
$script:WhitelistCache = $null; $script:IsMaster = $true
$seeded = Import-Whitelist
ok ((Test-Path $script:WhitelistFile) -and $seeded.Count -ge 1) "whitelist: master seeds the file when missing"
$script:IsMaster = $false; $script:WhitelistCache = $null
'{ "users": ["Blake"] }' | Set-Content $script:WhitelistFile -Encoding UTF8

# ================= item 4: auto GP/CM =================
# Get-AutoGpCmEnabled: default true (no file), true/false from file.
Remove-Item $script:StartupFile -Force -ErrorAction SilentlyContinue
ok (Get-AutoGpCmEnabled) "autoGpCm: defaults ON when startup.json absent"
'{ "autoGpCm": false }' | Set-Content $script:StartupFile -Encoding UTF8
ok (-not (Get-AutoGpCmEnabled)) "autoGpCm: reads false from startup.json"
'{ "autoGpCm": true }' | Set-Content $script:StartupFile -Encoding UTF8
ok (Get-AutoGpCmEnabled) "autoGpCm: reads true from startup.json"

# Test-MachineNeedsGpCm reads the rollup's GpLast/CmLast.
$script:MockRoll = @{ 'PC1' = @{ GpLast = (Get-Date); CmLast = $null; Sessions = 3 } }
$need = Test-MachineNeedsGpCm -Machine 'PC1'
ok (-not $need.NeedsGp) "needsGpCm: GP confirmed when GpLast present"
ok ($need.NeedsCm)      "needsGpCm: CM needed when CmLast null"
$script:MockRoll = @{}
$need2 = Test-MachineNeedsGpCm -Machine 'PC1'
ok ($need2.NeedsGp -and $need2.NeedsCm) "needsGpCm: both needed for a machine with no history"

# detect-only launchers never touch the OS
$script:ProcStarted = 0; $script:CmFired = 0
$gp = Start-GpUpdateRun -DetectOnly
ok ($gp.WouldRun -and $script:ProcStarted -eq 0) "Start-GpUpdateRun -DetectOnly launches nothing"
$cm = Start-CmActionsRun -DetectOnly
ok ($cm.WouldRun -and $script:CmFired -eq 0) "Start-CmActionsRun -DetectOnly fires nothing"

# Invoke-AutoGpCm gating
$script:IsMaster = $true
$r = Invoke-AutoGpCm -DetectOnly
ok ($r.Skipped -eq 'master' -and -not $r.Ran) "autoGpCm: skipped on the master"
$script:IsMaster = $false
'{ "autoGpCm": false }' | Set-Content $script:StartupFile -Encoding UTF8
$r = Invoke-AutoGpCm -DetectOnly
ok ($r.Skipped -eq 'disabled') "autoGpCm: skipped when toggle off"
'{ "autoGpCm": true }' | Set-Content $script:StartupFile -Encoding UTF8

# needs it, but detect-only => decides + logs, launches NOTHING
$script:MockRoll = @{}; $script:ProcStarted = 0; $script:CmFired = 0
$r = Invoke-AutoGpCm -DetectOnly
ok ($r.NeedsGp -and $r.NeedsCm -and -not $r.Ran) "autoGpCm: detect-only reports need without running"
ok ($script:ProcStarted -eq 0 -and $script:CmFired -eq 0) "autoGpCm: detect-only launches NOTHING"
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'autogpcm.trigger' }).Count -ge 1) "autoGpCm: logs a trigger decision"

# already confirmed => skip
$script:MockRoll = @{ 'PC1' = @{ GpLast = (Get-Date); CmLast = (Get-Date); Sessions = 2 } }
$r = Invoke-AutoGpCm -DetectOnly
# Machine defaults to $env:COMPUTERNAME inside Test-MachineNeedsGpCm; force a match:
$script:MockRoll = @{ "$env:COMPUTERNAME" = @{ GpLast = (Get-Date); CmLast = (Get-Date); Sessions = 2 } }
$r = Invoke-AutoGpCm -DetectOnly
ok ($r.Skipped -eq 'already confirmed' -and -not $r.NeedsGp -and -not $r.NeedsCm) "autoGpCm: skipped when both already confirmed"

# ================= item 2: master config mirror =================
$script:IsMaster = $false; $script:MockCfg = @{ enabled = $true; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
$pc = Push-MasterConfig
ok (-not $pc.ok -and $pc.keys -eq 0) "pushConfig: no-op when not the master"
$script:IsMaster = $true; $script:MockCfg = @{ enabled = $false; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
$pc = Push-MasterConfig
ok (-not $pc.ok) "pushConfig: no-op when telemetry disabled"
# enabled master path -> posts years+whitelist+buildings to /config
$script:MockCfg = @{ enabled = $true; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
$script:RestCalls = @(); $script:RestReply = @{ ok = $true }
$pc = Push-MasterConfig
ok ($pc.ok -and $pc.keys -eq 5) "pushConfig: master pushes 5 config keys (years/whitelist/buildings/needsopen/health_excluded)"
ok ($script:RestCalls.Count -eq 1 -and $script:RestCalls[0].Uri -match '/config$') "pushConfig: posts to the /config endpoint"
ok ($script:RestCalls[0].Body -match 'whitelist' -and $script:RestCalls[0].Body -match 'years') "pushConfig: body carries years + whitelist"
$script:IsMaster = $false

# ================= item 1/3: request-edit + pull-merge =================
# non-whitelisted requester is blocked BEFORE any network call
$script:RestCalls = @()
$out = Request-FleetMark -Machine '10101LAB34-16' -State 'verified' -User 'mallory'
ok (-not $out.Ok -and -not $out.Applied) "requestMark: blocked for non-whitelisted user"
ok ($script:RestCalls.Count -eq 0) "requestMark: no network call when blocked"
# whitelisted but telemetry off -> friendly message, still no post
$script:MockCfg = @{ enabled = $false; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
$out = Request-FleetMark -Machine '10101LAB34-16' -State 'verified' -User 'Blake'
ok (-not $out.Ok -and $out.Msg -match 'off') "requestMark: whitelisted user, telemetry off => told it's off"
# whitelisted + enabled -> posts to /mark-request and reports applied
$script:MockCfg = @{ enabled = $true; obsUrl = 'https://x.example/obs'; timeoutSec = 8 }
$script:RestCalls = @(); $script:RestReply = @{ ok = $true; applied = $true }
$out = Request-FleetMark -Machine '10101LAB34-16' -State 'missing' -User 'Blake' -Note 'test'
ok ($out.Ok -and $out.Applied) "requestMark: whitelisted+enabled => sent and applied"
ok ($script:RestCalls.Count -eq 1 -and $script:RestCalls[0].Uri -match '/mark-request$') "requestMark: posts to /mark-request"

# Pull-FleetMarkRequests merges applied requests into the marks cache (master only).
$script:IsMaster = $false
$r = Pull-FleetMarkRequests
ok (-not $r.ok) "pullMarkReq: no-op when not the master"
$script:IsMaster = $true
$script:MarksCache = @{}; $script:SavedMarks = 0
$script:RestReply = @{ ok = $true; requests = @(
    @{ machine = '10101LAB34-16'; state = 'missing';  by = 'Blake'; ts = (Get-Date).ToString('o'); received_at = '2026-08-19T10:00:00.000Z' },
    @{ machine = '10101LAB34-17'; state = 'verified'; by = 'Blake'; ts = (Get-Date).ToString('o'); received_at = '2026-08-19T10:00:01.000Z' }
) }
$r = Pull-FleetMarkRequests
ok ($r.ok -and $r.applied -eq 2) "pullMarkReq: applies 2 request-edits"
ok ($script:MarksCache.ContainsKey('10101LAB34-16|pending')) "pullMarkReq: merges into the marks cache (pending bucket)"
ok ($script:SavedMarks -ge 1) "pullMarkReq: persists the merged marks"
ok ((Test-Path $script:MarkReqCursorFile)) "pullMarkReq: advances the pull cursor"
# 'clear' removes a machine's marks
$script:RestReply = @{ ok = $true; requests = @(
    @{ machine = '10101LAB34-16'; state = 'clear'; by = 'Blake'; ts = (Get-Date).ToString('o'); received_at = '2026-08-19T11:00:00.000Z' }
) }
Remove-Item $script:MarkReqCursorFile -Force -ErrorAction SilentlyContinue
$r = Pull-FleetMarkRequests
ok (-not $script:MarksCache.ContainsKey('10101LAB34-16|pending')) "pullMarkReq: 'clear' removes the machine's marks"

# tripwire: nothing in this whole suite launched a process or fired CM for real
ok ($script:ProcStarted -eq 0 -and $script:CmFired -eq 0) "no real gpupdate/CM/process was ever launched"

try { Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host ""
Write-Host "PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
