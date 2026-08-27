# tests/test-printsheets.ps1 - theFuture items 12-14: printable sheets.
# Covers the PURE HTML builders (recheck + config, incl. the one-room-per-page rule and
# HTML escaping), the gatherers (mocked rollup/config), and Export-PrintPdf's fallback
# path (Edge stubbed ABSENT so nothing launches - the .html fallback must appear).
# Self-contained AST loader; touches none of the five fleet $want lists.
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

$want = @('ConvertTo-PrintHtmlText','New-RecheckSheetHtml','New-ConfigSheetHtml',
          'Export-PrintPdf','Get-RecheckSheetRooms','Get-ConfigSheetRooms')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
ok ($miss.Count -eq 0) "every print function lifted$(if ($miss.Count) { ' -- MISSING: ' + ($miss -join ', ') })"

function script:Write-LabLog { param($Event, $Data) $script:LogEvents += ,@{ Event = $Event; Data = $Data } }
$script:LogEvents = @()

Write-Host "`n--- HTML escaping ---"
ok ((ConvertTo-PrintHtmlText '<b>&"x"') -eq '&lt;b&gt;&amp;&quot;x&quot;') 'angle brackets, ampersand, quote escaped'

Write-Host "`n--- recheck sheet builder ---"
$rooms = @(
    @{ Room = '10101'; Abbr = 'ENG'; Items = @(
        @{ Name = '10101LAB34-2'; Needs = 'Install: Vivado  |  Run: GP update' },
        @{ Name = '#7'; Needs = 'Full setup: programs + GP update + CM actions' }) },
    @{ Room = '60201'; Abbr = ''; Items = @(@{ Name = '60201X-1'; Needs = 'Run: CM actions' }) }
)
$html = New-RecheckSheetHtml -Rooms $rooms -Options 'all rooms'
ok ($html -like '*<!doctype html>*') 'is a complete document'
ok ($html -like '*10101*' -and $html -like '*ENG*') 'room + abbr present'
ok ($html -like '*10101LAB34-2*' -and $html -like '*Install: Vivado*') 'machine + needs present'
ok ($html -like '*#7*' -and $html -like '*Full setup*') 'untouched slot present'
ok ($html -like '*3 item(s)*') 'item count totalled across rooms'
ok (([regex]::Matches($html, 'class="box"')).Count -eq 3) 'one checkbox per item'
$evil = New-RecheckSheetHtml -Rooms @(@{ Room = '<x>'; Abbr = ''; Items = @(@{ Name = '<script>'; Needs = 'a & b' }) }) -Options ''
ok ($evil -notlike '*<script>*' -and $evil -like '*&lt;script&gt;*') 'item text is escaped, never markup'

Write-Host "`n--- config sheet builder (one room per page) ---"
$cfgRooms = @(
    @{ Room = '10101'; Abbr = 'ENG'; ExpectedCount = 34; Apps = @('Python','Vivado') },
    @{ Room = '60201'; Abbr = 'LIB'; ExpectedCount = 10; Apps = @() }
)
$chtml = New-ConfigSheetHtml -Rooms $cfgRooms
ok (([regex]::Matches($chtml, 'class="roompage"')).Count -eq 2) 'each room is its own page section'
ok ($chtml -like '*page-break-after:always*') 'page-break CSS present (rooms never share a page)'
ok ($chtml -like '*Python*' -and $chtml -like '*Vivado*') 'apps listed'
ok ($chtml -like '*GP/CM-only room*') 'empty-app room says so instead of a blank page'
ok ($chtml -like '*34 machines*') 'machine count shown'

Write-Host "`n--- Export-PrintPdf fallback (Edge stubbed absent - nothing launches) ---"
function script:Get-EdgePath { return $null }
$sand = Join-Path $env:TEMP ("print_test_{0}" -f (Get-Date -Format 'HHmmssfff'))
$out = Export-PrintPdf -Html '<!doctype html><html><body>hi</body></html>' -OutPdf (Join-Path $sand 'sheet.pdf')
ok ($out -and $out.EndsWith('.html')) 'no Edge -> returns the .html fallback path'
ok ($out -and (Test-Path $out)) 'fallback file actually written'
ok ((@($script:LogEvents | Where-Object { $_.Event -eq 'print.pdf_fallback' })).Count -eq 1) 'fallback is logged'

Write-Host "`n--- gatherers (mocked master) ---"
$script:BuildingsConfig = [pscustomobject]@{ buildings = [pscustomobject]@{ '55' = [pscustomobject]@{ abbr = 'ENG' } } }
$script:FleetRollup = $null   # force the gatherer to call the mocked Get-FleetRollup
function script:Get-FleetRoomGroups { @{ '55|103' = @{ Building = '55'; Room = '103'; Type = 'LAB'; SeenMax = 2 } } }
function script:Get-FleetExpected { param($Building,$Room,$Type,$Num) @{ Apps = @('Python','Vivado','ExemptApp') } }
function script:Test-AppCountsForFleetHealth { param($AppId) $AppId -ne 'ExemptApp' }
function script:Get-RoomMachineCount { param($Building,$Room,$SeenMax) 3 }
function script:Get-FleetMark { param($Rec, [string]$RoomKey = '', $Num = $null) $null }   # no tech marks in this fixture
function script:Import-FleetYears { @{ Current = 2026 } }
function script:Get-FleetPageFor { param([string]$ImagedGen) 2026 }                          # every gen on the current page
function script:Get-FleetRollup {
    @{ '10101LAB34-1' = @{ Machine = '10101LAB34-1'; Building = '55'; Room = '103'; Num = 1; ImagedGen = '2026-01-01'
                            Installed = @{ Python = $true; Vivado = $true }; GpOk = $true;  CmOk = $true; RecheckApps = @() }
       '10101LAB34-2' = @{ Machine = '10101LAB34-2'; Building = '55'; Room = '103'; Num = 2; ImagedGen = '2026-01-01'
                            Installed = @{ Python = $true }; GpOk = $false; CmOk = $true; RecheckApps = @() } }
}
$g = @(Get-RecheckSheetRooms)
ok ($g.Count -eq 1 -and $g[0].Room -eq '10101') 'one room gathered'
$names = @($g[0].Items | ForEach-Object { $_.Name })
ok ($names -notcontains '10101LAB34-1') 'fully-green machine is NOT on the recheck list'
ok ($names -contains '10101LAB34-2') 'machine missing Vivado + owing GP is listed'
$m2 = @($g[0].Items | Where-Object { $_.Name -eq '10101LAB34-2' })[0]
ok ($m2.Needs -like '*Vivado*' -and $m2.Needs -like '*GP update*' -and $m2.Needs -notlike '*ExemptApp*') 'needs = missing counted apps + owed GP, exempt app excluded'
ok ($names -contains '#3') 'untouched slot #3 included by default'
$g2 = @(Get-RecheckSheetRooms -IgnoreUntouched)
ok (@($g2[0].Items | ForEach-Object { $_.Name }) -notcontains '#3') '-IgnoreUntouched drops the empty slot'
$c = @(Get-ConfigSheetRooms)
ok ($c.Count -eq 1 -and $c[0].Abbr -eq 'ENG' -and @($c[0].Apps).Count -eq 3) 'config gatherer: full app list (config truth, incl. exempt)'
$cf = @(Get-ConfigSheetRooms -Rooms @('99999'))
ok ($cf.Count -eq 0) 'room filter excludes non-matching rooms'

Write-Host "`n--- empty gather -> 'nothing' sheet, no phantom row (bug #2) ---"
$emptyHtml = New-RecheckSheetHtml -Rooms (Get-RecheckSheetRooms -Rooms @('99999')) -Options 'none'
ok ($emptyHtml -like '*Nothing needs a recheck*') 'empty recheck sheet says so'
ok ((([regex]::Matches($emptyHtml,'class="box"')).Count) -eq 0) 'and prints ZERO checkbox items'
$emptyCfg = New-ConfigSheetHtml -Rooms (Get-ConfigSheetRooms -Rooms @('99999'))
ok ($emptyCfg -like '*No rooms selected*' -and (([regex]::Matches($emptyCfg,'class="roompage"')).Count) -eq 0) 'empty config sheet: no phantom page'

Write-Host "`n--- tech marks + year page excluded (bugs #3 #4) ---"
function script:Get-FleetMark { param($Rec, [string]$RoomKey = '', $Num = $null) if ($Rec -and $Rec.Machine -eq '10101LAB34-2') { @{ State = 'missing' } } else { $null } }
$gm = @(Get-RecheckSheetRooms -IgnoreUntouched)
ok (@($gm | ForEach-Object { $_.Items } | ForEach-Object { $_.Name }) -notcontains '10101LAB34-2') 'a machine marked Missing is off the recheck sheet'
function script:Get-FleetMark { param($Rec, [string]$RoomKey = '', $Num = $null) $null }
function script:Get-FleetPageFor { param([string]$ImagedGen) 2027 }   # everything on a DIFFERENT page now
$gy = @(Get-RecheckSheetRooms -IgnoreUntouched)
ok ($gy.Count -eq 0) 'records on another year page do not appear on this page''s sheet'
function script:Get-FleetPageFor { param([string]$ImagedGen) 2026 }

try { Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host "`n================  $pass passed, $fail failed  ================"
if ($fail) { exit 1 } else { exit 0 }
