# The published fleet snapshot (Blake, 2026-08-18).
#
# A read-only copy of the Deployment Tracker that can live somewhere other than
# the master. The whole point is that it is ONE-WAY: the master writes a file and
# returns. This suite defends the two properties that make that true and would
# be easy to erode later:
#
#   1. The page is INERT - no <script>, no external requests, no event handlers,
#      no forms. Nothing on it can act, and nothing it loads can be swapped.
#   2. It renders from Get-RoomTally, the same single tally the WPF tiles, the
#      bar, the sub-line and the fleet title read - so the web view cannot drift
#      from the app the way a JavaScript re-implementation would.
#
# Also covers -Redact, which drops hostnames and error text for anywhere less
# private than a share you control. Hostnames encode building+room+machine, so
# publishing them publishes the lab topology.
#
# Fully sandboxed: renders from a fixture rollup into %TEMP%, never reads
# C:\LabDeployMaster and never writes into the repo.
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

$want = @('Export-FleetHtml','ConvertTo-HtmlText','Get-FleetRoomGroups','Get-FleetRoomOrder',
          'Get-RoomTally','Get-RoomMachineCount','Get-FleetTileTip','Get-FleetMachineStatus',
          'Test-AppCountsForFleetHealth','Test-AppNeedsOpenConfirm','Get-FleetExpected','Test-FleetMatch',
          'Resolve-DeployRule','Test-RuleHasApps','Get-RuleApps','Get-RuleLabel','Test-NumToken',
          'ConvertFrom-MachineToken','New-AppSet','Get-FleetMarkKey','Import-FleetMarks','Get-FleetMark',
          'Import-FleetWatermarks','Get-FleetWatermark','Import-FleetYears','ConvertTo-FleetDate',
          'Get-FleetPageFor')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

function script:Write-LabLog { param($Event, $Data) $script:LogEvents += @{ Event = $Event; Data = $Data } }
function script:Set-StickStatus { param($t) $script:LastStatus = $t }
$script:LogEvents = @(); $script:LastStatus = ''

# ---- sandbox ---------------------------------------------------------------
$sand = Join-Path $env:TEMP "labdeploy-html-test-$PID"
New-Item -ItemType Directory -Force $sand | Out-Null
$script:MasterRoot          = $sand
$script:FleetMarksFile      = Join-Path $sand 'fleet-marks.json'
$script:HideUnknownMachines = $true
$script:FleetMarks = @{}; $script:FleetWatermarks = @{}
$script:FleetYears = @{ Current = 2026; Pages = @(@{ Label = 2026; Cutoff = $null; Created = $null }); Removed = @() }

$script:AppsConfig = [pscustomobject]@{ apps = [pscustomobject]@{
    'LTSpice' = [pscustomobject]@{ displayName = 'LTSpice' }
    'PuTTY'   = [pscustomobject]@{ displayName = 'PuTTY' } } }
$script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{} }
$script:BuildingsConfig = [pscustomobject]@{
    buildings = [pscustomobject]@{ '55' = [pscustomobject]@{ abbr = 'ENG' } }
    roomSizes = [pscustomobject]@{ '55-103' = 4 } }
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building='55'; rooms='103'; types=''; machines=''; apps=@('LTSpice','PuTTY') }) }

# Four machines: one healthy, one partial, one with an error, one never touched.
function New-Rec {
    param([string]$Name, [int]$Num, [string[]]$Have, [string[]]$Fails = @(), [bool]$GpOk = $true, [bool]$CmOk = $true)
    $inst = @{}; foreach ($a in $Have) { $inst[$a] = $true }
    $fl = New-Object System.Collections.ArrayList
    $fa = @{}
    foreach ($x in $Fails) { [void]$fl.Add($x); $fa['PuTTY'] = 1 + [int]$fa['PuTTY'] }
    return @{ Machine=$Name; Building='55'; BuildingAbbr='ENG'; Room='103'; Type='LAB'; Num=$Num
              Installed=$inst; Opened=@{}; Failures=$fl; FailApps=$fa; GpOk=$GpOk; CmOk=$CmOk
              LastSeen=(Get-Date); ImagedGen='2026-07-11'; Sessions=1; Sticks=@{} }
}
$script:FleetRollup = @{
    '10101LAB34-01' = New-Rec '10101LAB34-01' 1 @('LTSpice','PuTTY')
    '10101LAB34-02' = New-Rec '10101LAB34-02' 2 @('LTSpice')
    # present but GP/CM not run -> purple (also carries an error, to test redaction)
    '10101LAB34-03' = New-Rec '10101LAB34-03' 3 @('LTSpice','PuTTY') @('PuTTY E23 @ 08-18 15:42') -GpOk $false -CmOk $false
}

Write-Host "`n--- it renders ---"
$out = Join-Path $sand 'fleet.html'
$p = Export-FleetHtml -Path $out -Quiet
ok ($p -and (Test-Path $out)) 'a page is written'
$html = Get-Content $out -Raw
ok ($html -match '(?i)^\s*<!doctype html>') 'it is a real HTML document'
ok ($html -match '</html>') 'and it is complete, not truncated'
ok (@($script:LogEvents | Where-Object { $_.Event -eq 'fleet.html_export' }).Count -eq 1) 'the export is logged'

Write-Host "`n--- INERT: nothing on the page can act (the one-way contract) ---"
ok ($html -notmatch '(?i)<script')      'no <script> tag'
ok ($html -notmatch '(?i)\son[a-z]+\s*=') 'no inline event handlers (onclick etc.)'
ok ($html -notmatch '(?i)<form')        'no form'
ok ($html -notmatch '(?i)<iframe')      'no iframe'
ok ($html -notmatch '(?i)\ssrc\s*=')    'nothing is fetched - no src attribute anywhere'
ok ($html -notmatch '(?i)href\s*=\s*"https?:') 'no external link'
ok ($html -notmatch '(?i)fetch\(|XMLHttpRequest|WebSocket') 'no network primitive named anywhere'
# Self-contained: everything the page needs is in the page.
ok ($html -match '(?i)<style>') 'styling is inlined, so it renders with no assets'

Write-Host "`n--- it agrees with the app, because it uses the app's tally ---"
# Fixture: room size 4, machines 1-3 seen, #4 never touched.
#   #1 all present + GP/CM -> green | #2 missing PuTTY -> yellow | #3 present but GP/CM not run -> purple | #4 never touched, needs programs -> red
ok ($html -match "class='t g'")  'the healthy machine renders green'
ok ($html -match "class='t y'")  'the partial machine renders yellow'
ok ($html -match "class='t p'")  'the GP/CM-owed machine renders purple'
ok ($html -match "class='t r'")  'the never-touched-with-programs slot renders red'
ok ($html -match '1 of 2 program\(s\) missing|ENG 103') 'the room is on the page'
# The headline must be the SAME sentence shape the tracker title uses.
ok ($html -match '\d+% done - \d+ of \d+ machines, \d+ need attention') 'the headline matches the tracker''s own wording'

Write-Host "`n--- -Redact: room counts without the topology ---"
$outR = Join-Path $sand 'fleet-redacted.html'
$null = Export-FleetHtml -Path $outR -Redact -Quiet
$htmlR = Get-Content $outR -Raw
ok ($html  -match '10101LAB34-01') 'the normal page carries hostnames'
ok ($htmlR -notmatch '10101LAB34') 'the redacted page carries NONE'
ok ($htmlR -notmatch 'E23')          'and no error text either'
ok ($htmlR -match "class='t g'")     'but the tile colours survive, so it is still a dashboard'
ok ($htmlR -match 'redacted')        'and it says on its face that it is redacted'

Write-Host "`n--- HTML escaping ---"
ok ((ConvertTo-HtmlText '<b>&"x') -eq '&lt;b&gt;&amp;&quot;x') 'angle brackets, ampersand and quote are escaped'
ok ((ConvertTo-HtmlText $null) -eq '') 'null is safe'
# A hostname with a quote in it must not be able to break out of title="..."
$script:FleetRollup['10101LAB34-04'] = New-Rec '10101LAB34-04" onmouseover="alert(1)' 4 @('LTSpice','PuTTY')
$outX = Join-Path $sand 'fleet-xss.html'
$null = Export-FleetHtml -Path $outX -Quiet
$htmlX = Get-Content $outX -Raw
# The literal text 'onmouseover=' IS on the page - it is part of the hostname.
# That is harmless. The security property is that its QUOTE was escaped, so it
# stays inside title="..." as text instead of closing the attribute and starting
# a real handler. Assert that, not the absence of a substring.
ok ($htmlX -notmatch '"\s*onmouseover') 'no unescaped quote precedes it - the attribute cannot be broken out of'
ok ($htmlX -match '&quot;\s*onmouseover') 'it is inert escaped text inside the title instead'
ok ($htmlX -match '&quot;')          'its quote is escaped instead'

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
