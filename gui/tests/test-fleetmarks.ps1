# Tech marks and watermarks: the master-side human assertions layered over the
# machine-report fold. This is the suite that defends the precedence rules -
# get them wrong and the tracker silently misreports 90 machines.
#
# Every disk write is redirected into a sandbox under %TEMP%, so this NEVER
# touches C:\LabDeployMaster. Paths are DERIVED, never hard-coded.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)

$want = @('Get-FleetMarkKey','Import-FleetMarks','Save-FleetMarks','Get-FleetMark',
          'Set-FleetMarkRecord','Remove-FleetMarkRecord','Update-FleetAutoFound',
          'Import-FleetWatermarks','Get-FleetWatermark','Set-FleetWatermarkRecord',
          'Import-FleetYears','Get-FleetPageFor','Save-FleetYears','Show-FleetYearPage',
          'Add-FleetYearRecord','Remove-FleetYearRecord','Test-FleetYearCutoff',
          'ConvertTo-FleetDate','Get-FleetRestorableYears','Limit-FleetYearBin','Get-FleetYearBinCap',
          'Restore-FleetYearRecord','Get-FleetRestoreLabel',
          'Get-VendorLogGroupKey','Get-VendorLogCap','Get-VendorLogPurgeSet','Invoke-VendorLogPurge',
          'Copy-FleetMissingForward',
          'Get-RoomTally','Get-FleetMachineStatus','Test-AppCountsForFleetHealth','Get-FleetTileTip','Test-FleetMatch',
          'Get-FleetExpected','Resolve-DeployRule','Test-RuleHasApps','Get-RuleApps',
          'Get-RuleLabel','Test-AppNeedsOpenConfirm',
          # Resolve-DeployRule's own dependency chain
          'Test-NumToken','ConvertFrom-MachineToken','New-AppSet')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
if ($miss.Count) { "!! NOT FOUND: $($miss -join ', ')"; exit 1 }

$pass = 0; $fail = 0
function ok { param([bool]$Cond, [string]$Msg)
    if ($Cond) { $script:pass++; "  ok    $Msg" } else { $script:fail++; "  FAIL  $Msg" } }

function Write-LabLog { param($Event, $Data) }
# Sandbox: MasterRoot is what the marks file hangs off.
$script:MasterRoot = Join-Path $env:TEMP "labdeploy-marks-test-$PID"
New-Item -ItemType Directory -Force $script:MasterRoot | Out-Null
$script:FleetMarksFile = Join-Path $script:MasterRoot 'fleet-marks.json'

$script:AppsConfig  = [pscustomobject]@{ apps = [pscustomobject]@{
    'LTSpice' = [pscustomobject]@{ displayName = 'LTSpice' }
    'PuTTY'   = [pscustomobject]@{ displayName = 'PuTTY' } } }
$script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{} }
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = ''; apps = @('LTSpice','PuTTY') }) }

function Reset-Marks {
    $script:FleetMarks      = $null
    $script:FleetWatermarks = $null
    $script:FleetYears      = $null
    if (Test-Path $script:FleetMarksFile) { Remove-Item $script:FleetMarksFile -Force }
}

# A machine record shaped like the real fold's output.
function New-Rec {
    param([string]$Name, [int]$Num, [datetime]$Seen, [string]$Gen = '2026-07-11', [string[]]$Have = @('LTSpice','PuTTY'),
          [bool]$GpOk = $true, [bool]$CmOk = $true)
    $inst = @{}; foreach ($a in $Have) { $inst[$a] = $true }
    return @{ Machine = $Name; Building = '55'; BuildingAbbr = 'ENG'; Room = '103'; Type = 'LAB'
              Num = $Num; Installed = $inst; Opened = @{}; Failures = (New-Object System.Collections.ArrayList)
              GpOk = $GpOk; CmOk = $CmOk
              LastSeen = $Seen; ImagedGen = $Gen; Sessions = 1; Sticks = @{} }
}
function New-Group { param($Recs) $g = @{ Abbr='ENG'; Room='103'; Building='55'; Type='LAB'; Recs=@{}; SeenMax=0
                                          Unnumbered=(New-Object System.Collections.ArrayList) }
    foreach ($r in $Recs) { $g.Recs[[int]$r.Num] = $r; if ($r.Num -gt $g.SeenMax) { $g.SeenMax = $r.Num } }
    return $g }

'--- identity: a mark keys on (hostname, image date) ---'
Reset-Marks
$a = New-Rec -Name '10101LAB34-27' -Num 27 -Seen ([datetime]'2026-08-01 09:00') -Gen '2026-07-11'
$b = New-Rec -Name '10101LAB34-27' -Num 27 -Seen ([datetime]'2026-08-01 09:00') -Gen '2027-01-20'
ok ((Get-FleetMarkKey -Rec $a) -ne (Get-FleetMarkKey -Rec $b)) 'same hostname, different image date = different key'
ok ((Get-FleetMarkKey -Rec $a) -eq '10101LAB34-27|2026-07-11') "key is hostname|imageStamp (got $(Get-FleetMarkKey -Rec $a))"
$noGen = New-Rec -Name 'X' -Num 1 -Seen (Get-Date) -Gen ''
ok ((Get-FleetMarkKey -Rec $noGen) -eq 'X|none') 'a machine with no image stamp keys on |none'
ok ((Get-FleetMarkKey -Rec $null -RoomKey 'ENG 103' -Num 12) -eq 'room:ENG 103|12') 'a never-touched machine keys on room+number'

'--- marks round-trip to disk ---'
Reset-Marks
$r = Set-FleetMarkRecord -Rec $a -State 'missing'
ok $r.Ok "mark written: $($r.Msg)"
ok (Test-Path $script:FleetMarksFile) 'fleet-marks.json created'
$script:FleetMarks = $null                       # force a reload from disk
ok ("$((Get-FleetMark -Rec $a).State)" -eq 'missing') 'and it reads back'
ok ((Get-FleetMark -Rec $b) -eq $null) 'the other generation of the same hostname is unmarked'
$r = Remove-FleetMarkRecord -Rec $a
ok $r.Ok "cleared: $($r.Msg)"
ok ($null -eq (Get-FleetMark -Rec $a)) 'and it is gone'
$r = Remove-FleetMarkRecord -Rec $a
ok (-not $r.Ok) "clearing an unmarked machine is refused, not silently ok: $($r.Msg)"

'--- precedence: newest report beats Verified, never beats Override ---'
Reset-Marks
$flag = [datetime]'2026-08-01 12:00'
$rec  = New-Rec -Name '10101LAB34-05' -Num 5 -Seen ([datetime]'2026-08-01 11:00') -Have @('LTSpice')  # missing PuTTY -> yellow
$g = New-Group @($rec)
$t = Get-RoomTally -Group $g -Count 5 -Query '' -RoomKey 'ENG 103'
ok (($t.Entries | Where-Object { $_.Num -eq 5 }).State -eq 'yellow') 'unmarked, a partial machine is yellow'
[void](Set-FleetMarkRecord -Rec $rec -State 'verified')
(Get-FleetMark -Rec $rec).Ts = $flag              # mark placed at 12:00
$t = Get-RoomTally -Group $g -Count 5 -Query '' -RoomKey 'ENG 103'
ok (($t.Entries | Where-Object { $_.Num -eq 5 }).State -eq 'green') 'Verified makes it green while the report is older'
# now the machine reports AFTER the mark
$rec.LastSeen = [datetime]'2026-08-01 13:00'
$t = Get-RoomTally -Group $g -Count 5 -Query '' -RoomKey 'ENG 103'
ok (($t.Entries | Where-Object { $_.Num -eq 5 }).State -eq 'yellow') 'a NEWER report takes over from Verified'
# override is sticky
[void](Set-FleetMarkRecord -Rec $rec -State 'override')
(Get-FleetMark -Rec $rec).Ts = $flag
$t = Get-RoomTally -Group $g -Count 5 -Query '' -RoomKey 'ENG 103'
ok (($t.Entries | Where-Object { $_.Num -eq 5 }).State -eq 'green') 'Override survives a newer report'

'--- missing leaves the percentage denominator ---'
Reset-Marks
$recs = @()
for ($i = 1; $i -le 4; $i++) { $recs += New-Rec -Name ('10101LAB34-{0:D2}' -f $i) -Num $i -Seen (Get-Date) }
$g = New-Group $recs
$t = Get-RoomTally -Group $g -Count 4 -Query '' -RoomKey 'ENG 103'
ok ($t.Ok -eq 4 -and $t.Counted -eq 4 -and $t.Pct -eq 100) 'four healthy machines = 100%'
# one machine is physically gone and one is broken
$recs[3].Installed.Remove('PuTTY')
$t = Get-RoomTally -Group $g -Count 4 -Query '' -RoomKey 'ENG 103'
ok ($t.Pct -eq 75) 'a partial machine drops it to 75%'
[void](Set-FleetMarkRecord -Rec $recs[3] -State 'missing')
$t = Get-RoomTally -Group $g -Count 4 -Query '' -RoomKey 'ENG 103'
ok ($t.Missing -eq 1) 'the missing machine is counted separately'
ok ($t.Counted -eq 3) 'and leaves the denominator'
ok ($t.Pct -eq 100) 'so the room reads 100% again - a machine that is gone is not work'
ok (($t.Entries | Where-Object { $_.Num -eq 4 }).State -eq 'blue') 'and its tile is blue'

'--- Report Missing works on a machine no stick has ever seen ---'
Reset-Marks
$g = New-Group @()          # nobody has reported at all
$t = Get-RoomTally -Group $g -Count 3 -Query '' -RoomKey 'ENG 103'
ok ($t.Bad -eq 3 -and $t.Pct -eq 0) 'three never-touched machines that need programs = 3 red, 0% done'
$r = Set-FleetMarkRecord -Rec $null -RoomKey 'ENG 103' -Num 2 -State 'missing'
ok $r.Ok 'a never-touched machine can still be reported missing (its main use)'
$t = Get-RoomTally -Group $g -Count 3 -Query '' -RoomKey 'ENG 103'
ok ($t.Missing -eq 1 -and $t.Counted -eq 2) 'it leaves the denominator too'
ok (($t.Entries | Where-Object { $_.Num -eq 2 }).State -eq 'blue') 'and turns blue rather than staying grey'

'--- auto-found: only evidence NEWER than the flag clears it ---'
Reset-Marks
$script:FleetRollup = @{}
$rec = New-Rec -Name '10101LAB34-09' -Num 9 -Seen ([datetime]'2026-08-01 10:00')
$script:FleetRollup[$rec.Machine] = $rec
[void](Set-FleetMarkRecord -Rec $rec -State 'missing')
(Get-FleetMark -Rec $rec).Ts = [datetime]'2026-08-01 12:00'
$n = Update-FleetAutoFound
ok ($n -eq 0) 'a stale stick replaying PRE-flag sessions does not resurrect the machine'
ok ("$((Get-FleetMark -Rec $rec).State)" -eq 'missing') 'the flag stands'
$rec.LastSeen = [datetime]'2026-08-01 13:30'          # it reported after the flag
$n = Update-FleetAutoFound
ok ($n -eq 1) 'evidence stamped after the flag clears it'
ok ($null -eq (Get-FleetMark -Rec $rec)) 'and the flag is removed, not merely suppressed'
# the same, for a room-keyed flag placed before the machine ever reported
Reset-Marks
$script:FleetRollup = @{}
[void](Set-FleetMarkRecord -Rec $null -RoomKey 'ENG 103' -Num 21 -State 'missing')
(Get-FleetMark -Rec $null -RoomKey 'ENG 103' -Num 21).Ts = [datetime]'2026-08-01 12:00'
$late = New-Rec -Name '10101LAB34-21' -Num 21 -Seen ([datetime]'2026-08-02 08:00')
$script:FleetRollup[$late.Machine] = $late
ok ((Update-FleetAutoFound) -eq 1) 'a room-keyed flag clears when that machine finally reports'

'--- Override does not silence a conflict, only the colour ---'
Reset-Marks
$rec = New-Rec -Name '10101LAB34-31' -Num 31 -Seen (Get-Date)
[void]$rec.Failures.Add('CONFLICT [E13] LTSpice: stick D: vs stick G:')
[void](Set-FleetMarkRecord -Rec $rec -State 'override')
$g = New-Group @($rec)
$t = Get-RoomTally -Group $g -Count 31 -Query '' -RoomKey 'ENG 103'
ok (($t.Entries | Where-Object { $_.Num -eq 31 }).State -eq 'green') 'override paints it green'
ok ($rec.Failures.Count -eq 1) 'but the E13 conflict is STILL on the record for the inspector'

'--- tooltips always say a manual state in words ---'
$mk = @{ State = 'override'; Ts = [datetime]'2026-08-01 09:00'; By = 'master' }
$tip = Get-FleetTileTip -State 'green' -Rec $rec -Status @{ Text = 'all present' } -Num 31 -Mark $mk
ok ($tip -match 'Override active') "override is named, not just coloured: '$($tip -split "`n" | Select-Object -First 1)'"
$mk = @{ State = 'missing'; Ts = [datetime]'2026-08-01 09:00'; By = 'master' }
$tip = Get-FleetTileTip -State 'blue' -Rec $null -Num 12 -Mark $mk
ok ($tip -match 'Missing - excluded from room totals') 'missing says it is excluded'
ok ($tip -match 'returns automatically') 'and that it self-clears'

'--- watermarks: Forget This Machine ---'
Reset-Marks
$r = Set-FleetWatermarkRecord -Machine '10101LAB34-07' -At ([datetime]'2026-08-03 17:00')
ok $r.Ok "watermark written: $($r.Msg)"
ok ($r.Msg -match 'kept' -and $r.Msg -match 'nothing was deleted') 'the message promises nothing is deleted'
$script:FleetWatermarks = $null
ok ((Get-FleetWatermark -Machine '10101LAB34-07') -eq [datetime]'2026-08-03 17:00') 'and reads back from disk'
ok ($null -eq (Get-FleetWatermark -Machine '10101LAB34-08')) 'other machines are unaffected'
# marks and watermarks share one file and must not clobber each other
[void](Set-FleetMarkRecord -Rec $a -State 'override')
$script:FleetMarks = $null; $script:FleetWatermarks = $null
ok ("$((Get-FleetMark -Rec $a).State)" -eq 'override') 'a mark survives a watermark write'
ok ($null -ne (Get-FleetWatermark -Machine '10101LAB34-07')) 'and the watermark survives a mark write'

'--- write failures roll back in memory ---'
Reset-Marks
[void](Set-FleetMarkRecord -Rec $a -State 'verified')
$keep = $script:MasterRoot
$script:MasterRoot = Join-Path $env:TEMP "labdeploy-nope-$PID"   # Save-FleetMarks refuses: no such root
$r = Set-FleetMarkRecord -Rec $a -State 'missing'
ok (-not $r.Ok) "write failure reported: $($r.Msg)"
ok ("$((Get-FleetMark -Rec $a).State)" -eq 'verified') 'the previous mark was restored in memory'
$r = Remove-FleetMarkRecord -Rec $a
ok (-not $r.Ok) 'a failed clear is reported too'
ok ($null -ne (Get-FleetMark -Rec $a)) 'and the mark came back'
$r = Set-FleetWatermarkRecord -Machine 'ZZZ' -At (Get-Date)
ok (-not $r.Ok -and $null -eq (Get-FleetWatermark -Machine 'ZZZ')) 'a failed watermark write rolls back too'
$script:MasterRoot = $keep

'--- year pages: a machine is (hostname, image date) ---'
Reset-Marks
$y = Import-FleetYears
ok (@($y.Pages).Count -eq 1 -and $null -eq @($y.Pages)[0].Cutoff) 'first run is one page catching every generation'
$r = Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15')
ok $r.Ok "new page opened: $($r.Msg)"
ok ((Import-FleetYears).Current -eq 2027) 'and it becomes the page you are looking at'
# Membership is decided by IMAGE DATE, never by when evidence arrived.
ok ((Get-FleetPageFor -ImagedGen '2026-07-11') -eq 2026) 'a July 2026 image stays on 2026'
ok ((Get-FleetPageFor -ImagedGen '2026-12-20') -eq 2027) 'a December image for next year lands on 2027 - the case a calendar cutoff would get wrong'
ok ((Get-FleetPageFor -ImagedGen '2027-03-02') -eq 2027) 'a March 2027 image is on 2027'
ok ((Get-FleetPageFor -ImagedGen '2024-01-01') -eq 2026) 'anything older than every cutoff falls on the first page'
ok ((Get-FleetPageFor -ImagedGen '') -eq (Import-FleetYears).Current) 'a machine with NO image stamp lands on the current page rather than vanishing'
ok ((Get-FleetPageFor -ImagedGen 'not a date') -eq (Import-FleetYears).Current) 'and so does an unparseable one'
# the design rule, stated as a test: same hostname, two generations, two machines.
$old = New-Rec -Name '10101LAB34-27' -Num 27 -Seen (Get-Date) -Gen '2026-07-11'
$new = New-Rec -Name '10101LAB34-27' -Num 27 -Seen (Get-Date) -Gen '2027-01-20'
ok ((Get-FleetPageFor -ImagedGen $old.ImagedGen) -ne (Get-FleetPageFor -ImagedGen $new.ImagedGen)) 'the same hostname sits on two pages when it has been reimaged'
[void](Set-FleetMarkRecord -Rec $old -State 'missing')
ok ($null -eq (Get-FleetMark -Rec $new)) "a 2026 flag does not leak onto the 2027 replacement"

'--- removing a page is safe: it merges back, nothing is deleted ---'
$before = Get-FleetPageFor -ImagedGen '2026-12-20'
$r = Remove-FleetYearRecord -Label 2027
ok $r.Ok "page removed: $($r.Msg)"
ok ($r.Msg -match 'No logs were deleted') 'the message says nothing was deleted'
ok ((Get-FleetPageFor -ImagedGen '2026-12-20') -eq 2026) 'its machines rejoined the earlier page'
ok ((Import-FleetYears).Current -eq 2026) 'and the view fell back to the remaining page'
ok ("$((Get-FleetMark -Rec $old).State)" -eq 'missing') 'marks survived the page removal untouched'
$r = Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15')
ok ($r.Ok -and (Get-FleetPageFor -ImagedGen '2026-12-20') -eq $before) 'starting it again restores it exactly - which is what makes deleting safe to test with'
$r = Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15')
ok (-not $r.Ok) "a duplicate page is refused: $($r.Msg)"
[void](Remove-FleetYearRecord -Label 2027)
$r = Remove-FleetYearRecord -Label 2026
ok (-not $r.Ok -and $r.Msg -match 'only page') "the last page cannot be removed: $($r.Msg)"

'--- excludeFromFleetHealth: a card that must never colour the map ---'
# 2026-08-18: MatlabLabDefaults is a per-user MATLAB preference refresh,
# so a machine that has not had it re-applied is not a broken machine. Thirty ENG
# boxes were YELLOW purely because of it, which buries the ones that genuinely
# need attention. The card still goes red on its own Deploy-tab card; this is
# only about the fleet map's tile colour and the room percentage.
$script:AppsConfig = [pscustomobject]@{ apps = [pscustomobject]@{
    'LTSpice' = [pscustomobject]@{ displayName = 'LTSpice' }
    'PuTTY'   = [pscustomobject]@{ displayName = 'PuTTY' }
    'Prefs'   = [pscustomobject]@{ displayName = 'Prefs refresh'; excludeFromFleetHealth = $true } } }

ok (Test-AppCountsForFleetHealth -AppId 'LTSpice') 'an ordinary card counts toward health'
ok (-not (Test-AppCountsForFleetHealth -AppId 'Prefs')) 'an excludeFromFleetHealth card does not'
ok (Test-AppCountsForFleetHealth -AppId 'NoSuchCard') 'an unknown id counts, rather than silently exempting itself'

$expected = @{ Apps = @('LTSpice','PuTTY','Prefs') }
# 1. everything real present, only the exempt card missing -> GREEN, not yellow.
$recG = @{ Machine='M1'; Installed=@{ LTSpice=$true; PuTTY=$true }; Opened=@{}
           Failures=(New-Object System.Collections.ArrayList); FailApps=@{}; GpOk=$true; CmOk=$true }
$st = Get-FleetMachineStatus -Rec $recG -Expected $expected
ok ($st.State -eq 'green') "only the exempt card missing reads GREEN (got $($st.State))"
ok ($st.Text -match 'not counted toward health: Prefs') "and the row still names it: '$($st.Text)'"
ok ($st.Text -match 'all 2 program\(s\) present') 'the count reflects the cards that actually count'

# 2. a REAL app missing still goes yellow - the exemption must not mask anything.
$recY = @{ Machine='M2'; Installed=@{ LTSpice=$true }; Opened=@{}
           Failures=(New-Object System.Collections.ArrayList); FailApps=@{} }
$st = Get-FleetMachineStatus -Rec $recY -Expected $expected
ok ($st.State -eq 'yellow') 'a genuinely missing app still reads YELLOW'
ok ($st.Text -match '1 of 2 program\(s\) missing') 'and counts only the cards that count'

# 3. an error on the exempt card must not turn the tile red.
$recE = @{ Machine='M3'; Installed=@{ LTSpice=$true; PuTTY=$true }; Opened=@{}
           Failures=(New-Object System.Collections.ArrayList); FailApps=@{ Prefs = 1 } }
[void]$recE.Failures.Add('Prefs E24 @ 08-18 15:42')
$st = Get-FleetMachineStatus -Rec $recE -Expected $expected
ok ($st.State -ne 'red') "an error on an exempt card does NOT turn the tile red (got $($st.State))"
ok ($recE.Failures.Count -eq 1) 'and the failure is still ON the record for the inspector and the CSV'
ok ($st.Text -match 'not counted toward health: Prefs') 'the row explains why it is not red'

# 4. a failed install that left a REAL app missing goes yellow, counting only the
#    real error in the note (the exempt one is subtracted).
$recR = @{ Machine='M4'; Installed=@{ LTSpice=$true }; Opened=@{}
           Failures=(New-Object System.Collections.ArrayList); FailApps=@{ Prefs = 1; PuTTY = 1 }; GpOk=$true; CmOk=$true }
[void]$recR.Failures.Add('Prefs E24 @ 08-18 15:42')
[void]$recR.Failures.Add('PuTTY E23 @ 08-18 15:43')
$st = Get-FleetMachineStatus -Rec $recR -Expected $expected
ok ($st.State -eq 'yellow') 'a failed real install (app still missing) reads YELLOW'
ok ($st.Text -match '1 error\(s\)' -and $st.Text -notmatch '2 error') "and reports 1 error, not 2 - the exempt one is subtracted: '$($st.Text)'"

# 5. a machine whose ONLY expectation is the exempt card is green, not 'nothing expected'.
$recO = @{ Machine='M5'; Installed=@{}; Opened=@{}
           Failures=(New-Object System.Collections.ArrayList); FailApps=@{}; GpOk=$true; CmOk=$true }
$st = Get-FleetMachineStatus -Rec $recO -Expected @{ Apps = @('Prefs') }
ok ($st.State -eq 'green') 'a room expecting ONLY an exempt card (GP+CM run) reads green rather than permanently short'

'--- switching pages: making a year lands you ON that year ---'
# Show-FleetYearPage is the ONE switch. Both the year dropdown and Start New
# Year go through it, so a page can never be set in one place and drawn from
# another. Update-FleetRooms is the redraw and needs a window; stub it.
$script:Redraws = 0
function Update-FleetRooms { $script:Redraws++ }
Reset-Marks
[void](Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15'))
[void](Show-FleetYearPage -Label 2026)
ok ((Import-FleetYears).Current -eq 2026) 'switching back to an older page works'
$was = $script:Redraws
ok ((Show-FleetYearPage -Label 2027) -and (Import-FleetYears).Current -eq 2027) 'and forward again'
ok ($script:Redraws -eq $was + 1) 'a switch redraws the board exactly once'
ok (-not (Show-FleetYearPage -Label 2099) -and (Import-FleetYears).Current -eq 2027) 'a page that does not exist is refused, and the view does not move'
# The regression this fixes: running Start New Year a second time used to leave
# the board on the year he was trying to leave. The page already exists, so the
# right answer is to go to it, not to error and sit still.
[void](Show-FleetYearPage -Label 2026)
$dup = Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15')
ok (-not $dup.Ok) 'a second Start New Year still refuses to duplicate the page'
ok ((Show-FleetYearPage -Label 2027) -and (Import-FleetYears).Current -eq 2027) 'and the flow can still land the tech on the page that already existed'

'--- deleting a year puts it in the bin, it does not destroy it ---'
# Deliberately NOT set here: Get-FleetYearBinCap has to work from the fallback,
# because the AST loader never brings the top-level variable across.
ok ((Get-FleetYearBinCap) -eq 2) 'the bin cap survives the AST loader, which takes functions only'
Reset-Marks
[void](Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15') -Created ([datetime]'2026-08-03 09:00'))
ok ($null -ne @((Import-FleetYears).Pages | Where-Object { $_.Label -eq 2027 })[0].Created) 'a page records the day it was opened'
ok (@(Get-FleetRestorableYears).Count -eq 0) 'the bin starts empty'
$r = Remove-FleetYearRecord -Label 2027
ok ($r.Ok -and $r.Msg -match 'Restore Year') "delete points at the way back: $($r.Msg)"
$bin = @(Get-FleetRestorableYears)
ok ($bin.Count -eq 1 -and $bin[0].Label -eq 2027) 'the deleted page is in the bin'
ok ($bin[0].Cutoff -eq ([datetime]'2026-12-15')) 'with its cutoff intact - this is what makes restore exact'
ok ($bin[0].Created -eq ([datetime]'2026-08-03 09:00')) 'and the original opening date, which the prompt quotes back'
ok ((Get-FleetRestoreLabel -Rec $bin[0]) -match 'created 2026-08-03') "and it describes itself in words: $(Get-FleetRestoreLabel -Rec $bin[0])"

'--- restore brings the page back as the SAME page ---'
$r = Restore-FleetYearRecord -Label 2027
ok $r.Ok "restored: $($r.Msg)"
ok ((Get-FleetPageFor -ImagedGen '2026-12-20') -eq 2027) 'its machines came back onto it'
$back = @((Import-FleetYears).Pages | Where-Object { $_.Label -eq 2027 })[0]
ok ($back.Created -eq ([datetime]'2026-08-03 09:00')) 'it kept its ORIGINAL opening date - a restore is not a new page wearing an old label'
ok (@(Get-FleetRestorableYears).Count -eq 0) 'and it left the bin, so it cannot be restored twice'
ok (-not (Restore-FleetYearRecord -Label 2027).Ok) 'restoring an open page is refused'
ok (-not (Restore-FleetYearRecord -Label 2011).Ok) 'restoring a year that was never deleted is refused'

'--- the bin keeps 2 deletions per year, and drops the oldest ---'
Reset-Marks
foreach ($n in 1..3) {
    [void](Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]"2026-12-1$n") -Created ([datetime]"2026-08-0$n"))
    [void](Remove-FleetYearRecord -Label 2027)
}
$bin = @(Get-FleetRestorableYears | Where-Object { $_.Label -eq 2027 })
ok ($bin.Count -eq 2) "three deletions of 2027, two kept (got $($bin.Count))"
ok ($bin[0].Cutoff -eq ([datetime]'2026-12-13')) 'newest deletion is first in the list'
ok (-not @($bin | Where-Object { $_.Cutoff -eq ([datetime]'2026-12-11') }).Count) 'and the OLDEST of the three fell off the end'
# The cap is per YEAR, not per bin: deleting a different year must not evict 2027.
[void](Add-FleetYearRecord -Label 2028 -Cutoff ([datetime]'2027-12-15'))
[void](Remove-FleetYearRecord -Label 2028)
ok (@(Get-FleetRestorableYears | Where-Object { $_.Label -eq 2027 }).Count -eq 2) 'deleting a different year does not evict the 2027 backups'
ok (@(Get-FleetRestorableYears).Count -eq 3) 'so the bin holds 3 entries across 2 years'
# Restoring with a Created stamp picks WHICH of the two backups comes back.
$want = @(Get-FleetRestorableYears | Where-Object { $_.Label -eq 2027 })[1]
$r = Restore-FleetYearRecord -Label 2027 -Created $want.Created
ok ($r.Ok -and @((Import-FleetYears).Pages | Where-Object { $_.Label -eq 2027 })[0].Cutoff -eq $want.Cutoff) 'a Created stamp picks which of the two backups is restored'
ok (@(Get-FleetRestorableYears | Where-Object { $_.Label -eq 2027 }).Count -eq 1) 'and only that one left the bin'

'--- cutoff validation: sane years only, and the deliberate debug hole ---'
$c = Test-FleetYearCutoff -Text '2026-12-15' -NewLabel 2027
ok ($c.Ok) 'a December date in the closing year is legal - imaging for next September happens in December'
ok ((Test-FleetYearCutoff -Text '2027-03-01' -NewLabel 2027).Ok) 'so is a date inside the new year'
ok (-not (Test-FleetYearCutoff -Text '2029-01-01' -NewLabel 2027).Ok) 'a typo two years out is refused'
ok (-not (Test-FleetYearCutoff -Text '2020-01-01' -NewLabel 2027).Ok) 'and so is one far in the past'
ok (-not (Test-FleetYearCutoff -Text 'banana' -NewLabel 2027).Ok) 'a non-date is refused'
ok (-not (Test-FleetYearCutoff -Text '' -NewLabel 2027).Ok) 'and so is an empty box'
ok ((Test-FleetYearCutoff -Text '2026-12-15' -NewLabel 2027).Msg -match 'on or after') 'the live line says what the cutoff means'

'--- watermark and year state share one file without clobbering ---'
Reset-Marks
[void](Add-FleetYearRecord -Label 2027 -Cutoff ([datetime]'2026-12-15'))
[void](Set-FleetWatermarkRecord -Machine 'M1' -At ([datetime]'2026-08-03 17:00'))
[void](Set-FleetMarkRecord -Rec $old -State 'override')
$script:FleetMarks = $null; $script:FleetWatermarks = $null; $script:FleetYears = $null
ok (@((Import-FleetYears).Pages).Count -eq 2) 'years survived'
ok ($null -ne (Get-FleetWatermark -Machine 'M1')) 'watermark survived'
ok ("$((Get-FleetMark -Rec $old).State)" -eq 'override') 'and the mark survived'

'--- carrying Missing flags across a year rollover ---'
# The bug this covers: the New Year dialog used to ASK whether to carry flags
# and then ignore the answer.
Reset-Marks
$gone26 = New-Rec -Name '10101LAB34-40' -Num 40 -Seen ([datetime]'2026-05-01') -Gen '2026-07-11'
$ok26   = New-Rec -Name '10101LAB34-41' -Num 41 -Seen ([datetime]'2026-05-01') -Gen '2026-07-11'
[void](Set-FleetMarkRecord -Rec $gone26 -State 'missing')
[void](Set-FleetMarkRecord -Rec $ok26   -State 'override')
$n = Copy-FleetMissingForward
ok ($n -eq 1) "only Missing carries forward (got $n) - an Override describes one Windows install, not its successor"
ok ((Copy-FleetMissingForward) -eq 0) 'carrying twice in a row does not duplicate flags'
# The replacement box, same hostname, new image date, has no mark of its own.
$new27 = New-Rec -Name '10101LAB34-40' -Num 40 -Seen ([datetime]'2027-02-01') -Gen '2027-01-20'
ok ("$((Get-FleetMark -Rec $new27).State)" -eq 'missing') 'the new generation inherits the carried flag while nothing has reported'
$fine27 = New-Rec -Name '10101LAB34-41' -Num 41 -Seen ([datetime]'2027-02-01') -Gen '2027-01-20'
ok ($null -eq (Get-FleetMark -Rec $fine27)) 'and a machine that was merely overridden starts the year clean'
# ...and it clears itself the moment the replacement actually reports.
$script:FleetRollup = @{ '10101LAB34-40' = $new27 }
(Import-FleetMarks)['10101LAB34-40|pending'].Ts = [datetime]'2027-01-01'
ok ((Update-FleetAutoFound) -eq 1) 'a carried flag clears once the replacement reports'
ok ($null -eq (Get-FleetMark -Rec $new27)) 'so a replaced machine does not stay blue forever'
# IDENTITY: exactly ONE flag cleared - the carried one. The 2026 machine's own
# flag must survive, because the box that reported is a different machine that
# merely reuses the hostname.
ok ("$((Get-FleetMark -Rec $gone26).State)" -eq 'missing') "the 2026 machine's own flag is untouched by its replacement reporting"

'--- vendor installer logs: capped per machine per installer, fleet logs never touched ---'
$script:VendorLogCapDefault = 2
$script:VendorLogCapHigh    = 5
$script:VendorLogHighPrefix = @('vs','rockwell','labview')
$script:VendorPurgeLedger   = Join-Path $script:MasterRoot 'vendor-purged.txt'
$vlogs = Join-Path $script:MasterRoot 'logs'
New-Item -ItemType Directory -Force $vlogs | Out-Null
function New-Log { param([string]$Name, [int]$AgeDays)
    $p = Join-Path $vlogs $Name
    Set-Content $p 'x' -Encoding UTF8
    (Get-Item $p).LastWriteTime = (Get-Date).AddDays(-$AgeDays) }

ok ((Get-VendorLogGroupKey -Name 'vs-isoshell-10101LAB34-01_032_core.log') -eq 'vs|10101LAB34-01') 'group key is installer + machine'
ok ((Get-VendorLogGroupKey -Name 'matlab-10101LAB34-09.log') -eq 'matlab|10101LAB34-09') 'and works for other vendors'
ok ((Get-VendorLogCap -Key 'vs|X') -eq 5) 'Visual Studio keeps 5 - it writes several files per attempt'
ok ((Get-VendorLogCap -Key 'rockwell|X') -eq 5) 'Rockwell keeps 5 - under active root-cause investigation'
ok ((Get-VendorLogCap -Key 'labview|X') -eq 5) 'LabVIEW keeps 5'
ok ((Get-VendorLogCap -Key 'matlab|X') -eq 2) 'everything else keeps 2'

# 6 VS logs for one machine (cap 5), 4 MATLAB for another (cap 2), plus fleet history.
for ($i = 1; $i -le 6; $i++) { New-Log -Name "vs-isoshell-10101LAB34-01_$i.log" -AgeDays $i }
for ($i = 1; $i -le 4; $i++) { New-Log -Name "matlab-10101LAB34-09_$i.log" -AgeDays $i }
New-Log -Name 'LabDeploy_10101LAB34-01_20260801.log' -AgeDays 30
New-Log -Name 'LabDeploy_10101LAB34-09_20260701.log' -AgeDays 60
$set = Get-VendorLogPurgeSet
$names = @($set.Files | ForEach-Object { $_.Name })
ok (@($names).Count -eq 3) "over-cap files identified (1 VS + 2 MATLAB = 3, got $(@($names).Count))"
ok (@($names | Where-Object { $_ -like 'LabDeploy_*' }).Count -eq 0) 'FLEET HISTORY IS NEVER IN THE PURGE SET'
ok ($names -contains 'vs-isoshell-10101LAB34-01_6.log') 'the OLDEST vs log is the one over the cap'
ok ($names -notcontains 'vs-isoshell-10101LAB34-01_1.log') 'and the newest is kept'
$r = Invoke-VendorLogPurge
ok ($r.Ok -and $r.Removed -eq 3) "purge removed exactly those: $($r.Msg)"
ok ((Get-ChildItem $vlogs -Filter 'LabDeploy_*').Count -eq 2) 'both fleet logs survived'
ok ((Get-ChildItem $vlogs -Filter 'vs-*').Count -eq 5) 'five VS logs remain'
ok ((Get-ChildItem $vlogs -Filter 'matlab-*').Count -eq 2) 'two MATLAB logs remain'
ok ((Get-VendorLogPurgeSet).Files.Count -eq 0) 'running again finds nothing - the cap is now satisfied'
# The ledger is what stops copy-new-only sync re-importing what was purged.
ok (Test-Path $script:VendorPurgeLedger) 'a purge ledger is written'
$led = @(Get-Content $script:VendorPurgeLedger)
ok ($led -contains 'vs-isoshell-10101LAB34-01_6.log') 'and it names the purged files, so the next sync will not boomerang them back'
$r = Invoke-VendorLogPurge
ok ($r.Ok -and $r.Removed -eq 0) 'a no-op purge reports honestly rather than claiming work'

'--- messages are sentences, not codes ---'
Reset-Marks
$r = Set-FleetMarkRecord -Rec $a -State 'missing'
ok ($r.Msg.Length -gt 30 -and $r.Msg -notmatch '^E\d+') "plain English: '$($r.Msg)'"

try { Remove-Item $script:MasterRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
