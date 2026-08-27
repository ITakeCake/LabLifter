# tests/test-requestedits.ps1 — theFuture Tier 0: config-plane mirror + USB request-edits.
# Covers: whitelist load/seed + membership, Push-MasterConfig payload shape, Request-FleetMark
# whitelist gating, and Pull-FleetMarkRequests merge (set / clear / cursor advance).
#
# Self-contained: lifts only its own function set (mocks the network + the marks store),
# so it touches none of the five fleet $want lists.
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

$want = @('Import-Whitelist','Test-UserWhitelisted','Get-AutoGpCmEnabled','Push-MasterConfig',
          'Request-FleetMark','Pull-FleetMarkRequests','Get-MarkReqCursor','Save-MarkReqCursor')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every request-edit function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

# --- top-level helpers + $script: state the AST loader does NOT bring in ---
function script:Write-LabLog { param($Event, $Data) $script:LogEvents += ,@{ Event = $Event; Data = $Data } }
$script:LogEvents = @()
$script:IsMaster = $true
$sand = Join-Path $env:TEMP ("reqedit_test_{0}" -f (Get-Date -Format 'HHmmssfff'))
New-Item -ItemType Directory -Path $sand -Force | Out-Null

# ============================================================
Write-Host "`n--- whitelist load + membership ---"
$script:WhitelistFile = Join-Path $sand 'whitelist.json'
[pscustomobject]@{ _note = 'test'; users = @('admin','viewer1') } | ConvertTo-Json | Set-Content $script:WhitelistFile -Encoding UTF8
$script:WhitelistCache = $null
$wl = Import-Whitelist
ok (@($wl).Count -eq 2 -and ($wl -contains 'admin') -and ($wl -contains 'viewer1')) "whitelist loads 2 users"
ok (Test-UserWhitelisted 'ADMIN')  "membership is case-insensitive (ADMIN ok)"
ok (Test-UserWhitelisted 'viewer1')   "viewer1 approved"
ok (-not (Test-UserWhitelisted 'stranger')) "stranger rejected"
ok (-not (Test-UserWhitelisted ''))  "empty user rejected"

Write-Host "`n--- whitelist seed when absent (master) ---"
$script:WhitelistFile = Join-Path $sand 'seeded.json'   # does not exist yet
$script:WhitelistCache = $null
$seeded = Import-Whitelist
ok (Test-Path $script:WhitelistFile) "master seeds whitelist.json when absent"
ok (@($seeded).Count -ge 1) "seeded whitelist has the current user"
ok (Test-UserWhitelisted "$($env:USERNAME)") "current Windows user ($($env:USERNAME)) is approved after seed"

# ============================================================
Write-Host "`n--- Get-AutoGpCmEnabled default + file ---"
$script:StartupFile = Join-Path $sand 'startup-missing.json'
ok (Get-AutoGpCmEnabled) "autoGpCm defaults TRUE when startup.json absent"
$script:StartupFile = Join-Path $sand 'startup.json'
[pscustomobject]@{ autoGpCm = $false } | ConvertTo-Json | Set-Content $script:StartupFile -Encoding UTF8
ok (-not (Get-AutoGpCmEnabled)) "autoGpCm reads FALSE from startup.json"

# ============================================================
Write-Host "`n--- Push-MasterConfig payload shape ---"
function script:Import-TelemetryConfig { @{ enabled = $true; obsUrl = 'https://api.example/obs'; timeoutSec = 3 } }
function script:Import-StickToken { 'tok-abc' }
function script:Import-FleetYears { @{ Current = 2026; Pages = @(
    @{ Label = 2026; Cutoff = $null; Created = (Get-Date) },
    @{ Label = 2027; Cutoff = [datetime]'2027-06-01'; Created = (Get-Date) }) } }
$script:WhitelistCache = @('admin')
$script:BuildingsConfig = [pscustomobject]@{ buildings = [pscustomobject]@{
    '55' = [pscustomobject]@{ abbr = 'ENG' }; '60' = [pscustomobject]@{ abbr = 'LIB' } } }
$script:CapturedConfig = $null; $script:ConfigUrl = $null
function script:Invoke-ConfigPost { param([array]$Config,[string]$Url,[string]$Token,[int]$TimeoutSec)
    $script:CapturedConfig = $Config; $script:ConfigUrl = $Url; return $true }
$script:AppsConfig = [pscustomobject]@{ apps = [pscustomobject]@{
    Vivado = [pscustomobject]@{ needsOpen = $true }; Python = [pscustomobject]@{} } }
function script:Test-AppNeedsOpenConfirm { param($AppId) $AppId -eq 'Vivado' }
$r = Push-MasterConfig
ok ($r.ok -and $r.keys -eq 6) "Push-MasterConfig posts 6 keys (health_excluded 2026-08-19, assignments 2026-08-26)"
ok ($script:ConfigUrl -eq 'https://api.example/config') "obs URL rewritten to /config"
$byKey = @{}; foreach ($c in $script:CapturedConfig) { $byKey[$c.key] = $c.value }
ok ($byKey.ContainsKey('years') -and $byKey.ContainsKey('whitelist') -and $byKey.ContainsKey('buildings') -and $byKey.ContainsKey('needsopen') -and $byKey.ContainsKey('health_excluded')) "years+whitelist+buildings+needsopen+health_excluded present"
ok (@($byKey['needsopen']) -contains 'Vivado' -and @($byKey['needsopen']) -notcontains 'Python') "needsopen carries only confirm-required apps"
ok ($byKey['years'].current -eq 2026 -and @($byKey['years'].pages).Count -eq 2) "years payload has current + 2 pages"
ok (@($byKey['whitelist'].users) -contains 'admin') "whitelist payload carries admin"
ok ($byKey['buildings']['55'] -eq 'ENG') "buildings payload maps 55 -> ENG abbr"

# ============================================================
Write-Host "`n--- Request-FleetMark whitelist gating ---"
$script:WhitelistCache = @('admin')
$script:CapturedReq = $null
function script:Invoke-MarkRequestPost { param($Request,[string]$Url,[string]$Token,[int]$TimeoutSec)
    $script:CapturedReq = $Request; return [pscustomobject]@{ ok = $true; applied = $true; req_id = 'abc' } }

$blocked = Request-FleetMark -Machine '55A-9' -State 'missing' -User 'stranger'
ok (-not $blocked.Ok) "non-whitelisted request is blocked locally"
ok ($null -eq $script:CapturedReq) "blocked request never hits the network"

$okReq = Request-FleetMark -Machine '55A-1' -State 'missing' -User 'admin' -Note 'left the room'
ok ($okReq.Ok -and $okReq.Applied) "whitelisted request sent + applied"
ok ($script:CapturedReq.machine -eq '55A-1' -and $script:CapturedReq.state -eq 'missing' -and $script:CapturedReq.by -eq 'admin') "request payload carries machine/state/by"
ok ("$($script:CapturedReq.ts)".Trim().Length -gt 0) "request carries an assertion ts"

# ============================================================
Write-Host "`n--- Pull-FleetMarkRequests merge (set / clear / cursor) ---"
$script:FleetMarks = @{ '55A-3|pending' = @{ State = 'missing'; Ts = (Get-Date); By = 'old' } }
function script:Import-FleetMarks { return $script:FleetMarks }
function script:Save-FleetMarks { return $true }
$script:MarkReqCursorFile = Join-Path $sand 'markreq-pulled.json'   # real Get/Save cursor funcs use this
function script:Invoke-RestMethod {
    param($Uri, $Method, $Headers, $TimeoutSec, $ErrorAction)
    [pscustomobject]@{ ok = $true; requests = @(
        [pscustomobject]@{ machine='55A-2'; state='broken';  by='admin'; ts='2026-08-18T10:00:00'; received_at='2026-08-18T10:00:01Z' },
        [pscustomobject]@{ machine='55A-3'; state='clear';   by='admin'; ts='2026-08-18T10:00:00'; received_at='2026-08-18T10:00:02Z' }
    ) }
}
$pr = Pull-FleetMarkRequests
ok ($pr.ok -and $pr.applied -eq 2) "pull applied 2 request-edits"
ok ($script:FleetMarks.ContainsKey('55A-2|pending') -and $script:FleetMarks['55A-2|pending'].State -eq 'broken') "broken request merged to hostname|pending"
ok ($script:FleetMarks['55A-2|pending'].By -eq 'admin') "merged mark carries requester as By"
ok (-not $script:FleetMarks.ContainsKey('55A-3|pending')) "clear request removed the existing mark"
$cur = Get-MarkReqCursor
ok ($cur -eq '2026-08-18T10:00:02Z') "cursor advanced to the newest received_at"

# ============================================================
try { Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host "`n================  $pass passed, $fail failed  ================"
if ($fail) { exit 1 } else { exit 0 }
