# Headless test of the Layout Designer's two pop-out ACTIONS (Add Building,
# Add Classroom). It tests Add-BuildingRecord / Add-ClassroomRecord - the pure
# logic - not the dialog shells, which are only three textboxes and a Save
# button. Every disk write is stubbed, so this NEVER touches the real config.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)

$want = @('Add-BuildingRecord','Add-ClassroomRecord','Get-AssignRoomRules',
          'Test-BuildingCodeFree','Test-BuildingCodesFree','Test-ClassroomFree','Add-ProgramsRecord',
          'Get-RoomProfileChoices','Get-CoverageBuildings',
          'Get-CoverageSegments','Get-CoverageSegLabel','ConvertFrom-MachineToken','New-AppSet',
          'Test-RuleHasApps','Get-RuleApps','Get-RoomMachineCount',
          # segment surgery (2026-07-31) - the four Assign capabilities
          'Test-SegmentSplit','Split-SegmentRecord','Remove-ProgramsRecord',
          'Test-SegmentMerge','Merge-SegmentRecord','Set-RoomSizeRecord',
          # claim / unclaim / ordered insert
          'Add-RoomRuleOrdered','Test-SegmentClaim','Claim-SegmentRecord',
          'Test-SegmentUnclaim','Remove-SegmentRecord','Get-CoverageSegState',
          'Resolve-CoverageInherited','Get-FleetExpected','Resolve-DeployRule','Get-RuleLabel')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$miss = @($want | Where-Object { $loaded -notcontains $_ })
if ($miss.Count) { "!! NOT FOUND: $($miss -join ', ')"; exit 1 }
# Promote every loaded function to GLOBAL scope.
#
# THIS FIXES 4 LONG-STANDING FAILURES (2026-08-05). Invoke-Expression above binds
# these at SCRIPT scope. That is enough for calls the test makes itself, but NOT
# for one loaded function calling another from inside a nested scriptblock - that
# lookup missed, the call yielded $null, and the new rule came back with
# apps = $null instead of the parent's list. It then read as "the split lost the
# programs" in four assertions, when the real behaviour was fine all along - the
# same defect was confirmed absent when the identical split runs with the
# functions bound globally. Classic @($null).Count -eq 1 masking, too: the failing
# assertions saw a 1-element array holding $null, so a COUNT check would have
# passed while the join produced ''.
foreach ($n in $loaded) {
    $sb = (Get-Item "function:$n" -ErrorAction SilentlyContinue).ScriptBlock
    if ($sb) { Set-Item -Path "function:global:$n" -Value $sb -Force }
}

$pass = 0; $fail = 0
function ok { param([bool]$Cond, [string]$Msg)
    if ($Cond) { $script:pass++; "  ok    $Msg" } else { $script:fail++; "  FAIL  $Msg" } }

# Disk writes stubbed. $script:SaveOk flips them to failure so the rollback
# paths get exercised for real rather than assumed.
$script:SaveOk = $true
$script:SavedB = 0; $script:SavedR = 0
function Save-BuildingsConfig { $script:SavedB++; return $script:SaveOk }
function Save-RulesConfig     { $script:SavedR++; return $script:SaveOk }
function Write-LabLog { param($Event, $Data) }
# Real implementation, minus the disk write (its Save-BuildingsConfig is stubbed
# above), so the roomSizes path is exercised rather than faked.
function Save-RoomMachineCount {
    param([string]$Building, [string]$Room, [int]$Count)
    if (-not $script:BuildingsConfig) { return $false }
    if (-not $script:BuildingsConfig.roomSizes) {
        $script:BuildingsConfig | Add-Member -NotePropertyName 'roomSizes' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $script:BuildingsConfig.roomSizes | Add-Member -NotePropertyName "$Building-$Room" -NotePropertyValue $Count -Force
    return (Save-BuildingsConfig)
}

function Reset-Fixture {
    $script:SaveOk = $true
    $script:BuildingsConfig = [pscustomobject]@{
        buildings = [pscustomobject]@{ '55' = [pscustomobject]@{ abbr = 'ENG'; fullName = '' }
                                       '902' = [pscustomobject]@{ abbr = 'EXT'; fullName = '' } }
        typeCodes = [pscustomobject]@{ '_note' = 'ignored'
                                       'CART'  = [pscustomobject]@{ machine01Role = 'Instructor Station' }
                                       'LAB' = [pscustomobject]@{ machine01Role = 'ask' }
                                       'POD'   = [pscustomobject]@{ machine01Role = 'ask' } } }
    $script:RulesConfig = [pscustomobject]@{ rules = @(
        [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; apps = @('LTSpice','PuTTY') }) }
    # Catalog + profiles for the programs/profile paths. Get-RuleApps filters
    # against the catalog, so every id used in these tests must exist here.
    $script:AppsConfig = [pscustomobject]@{ apps = [pscustomobject]@{
        'LTSpice' = [pscustomobject]@{ displayName = 'LTSpice' }
        'PuTTY'   = [pscustomobject]@{ displayName = 'PuTTY' }
        'Python'  = [pscustomobject]@{ displayName = 'Python 3.14' }
        'MATLAB'  = [pscustomobject]@{ displayName = 'MATLAB' }
        'Logisim' = [pscustomobject]@{ displayName = 'Logisim Evolution' } } }
    $script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{
        '_note' = 'ignored'
        'ENG'   = [pscustomobject]@{ displayName = 'ENG labs'; apps = @('Logisim','LTSpice','PuTTY') } } }
}

'--- Add Building: the happy path ---'
Reset-Fixture
$r = Add-BuildingRecord -Code '14' -Abbr 'HUM' -Name 'Academic Hall'
ok $r.Ok "added: $($r.Msg)"
ok ($null -ne $script:BuildingsConfig.buildings.'14') 'building 14 is in the config'
ok ("$($script:BuildingsConfig.buildings.'14'.abbr)" -eq 'HUM') 'abbr stored'
ok ("$($script:BuildingsConfig.buildings.'14'.fullName)" -eq 'Academic Hall') 'full name stored'
ok ($script:SavedB -ge 1) 'it actually tried to save'

'--- Add Building: what it refuses ---'
Reset-Fixture
foreach ($case in @(
    @{ code = '1';    abbr = 'X';  why = 'a 1-digit code' },
    @{ code = '1234'; abbr = 'X';  why = 'a 4-digit code' },
    @{ code = 'AB';   abbr = 'X';  why = 'a non-numeric code' },
    @{ code = '14';   abbr = '';   why = 'a missing abbreviation' },
    @{ code = '55';   abbr = 'X';  why = 'a code that already exists' }
)) {
    $r = Add-BuildingRecord -Code $case.code -Abbr $case.abbr
    ok (-not $r.Ok) "refuses $($case.why): $($r.Msg)"
}

'--- Add Building: the 90-vs-902 prefix landmine, BOTH directions ---'
Reset-Fixture
$r = Add-BuildingRecord -Code '90' -Abbr 'NEW'
ok (-not $r.Ok) "refuses 90 when 902 exists: $($r.Msg)"
ok ($r.Msg -match 'prefix') 'the refusal says the word prefix'
ok ($null -eq $script:BuildingsConfig.buildings.'90') 'the refused building was not stored'
Reset-Fixture
$script:BuildingsConfig.buildings = [pscustomobject]@{ '90' = [pscustomobject]@{ abbr = 'X'; fullName = '' } }
$r = Add-BuildingRecord -Code '902' -Abbr 'EXT'
ok (-not $r.Ok) 'refuses 902 when 90 exists (the other direction)'
# 55 vs 56 must still be fine - neither is a prefix of the other.
Reset-Fixture
$r = Add-BuildingRecord -Code '56' -Abbr 'ENG'
ok $r.Ok '56 is allowed alongside 55 (not a prefix - this is the real ENG case)'

'--- Add Building: a failed write rolls back ---'
Reset-Fixture
$script:SaveOk = $false
$r = Add-BuildingRecord -Code '14' -Abbr 'HUM'
ok (-not $r.Ok) "reports the write failure: $($r.Msg)"
ok ($null -eq $script:BuildingsConfig.buildings.'14') 'a building that failed to save is NOT left in memory'

'--- Add Classroom: the happy path ---'
Reset-Fixture
$before = @($script:RulesConfig.rules).Count
$r = Add-ClassroomRecord -Building '55' -Room '201'
ok $r.Ok "added: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq $before + 1) "exactly one rule added ($before -> $($rules.Count))"
ok ("$($rules[-1].rooms)" -eq '201') 'the new rule is the LAST one (append, never insert)'
ok ("$($rules[0].rooms)" -eq '103') 'the pre-existing rule kept its position, so first-match-wins is undisturbed'
ok (@($rules[-1].apps).Count -eq 0) 'the new room starts with nothing assigned'
ok ("$($rules[-1].machines)" -eq '') 'blank machines token = the whole room'

'--- Add Classroom: what it refuses ---'
Reset-Fixture
foreach ($case in @(
    @{ b = '55'; room = 'ANNEX'; why = 'a non-numeric room' },
    @{ b = '55'; room = '';      why = 'an empty room' },
    @{ b = '55'; room = '12345'; why = 'a 5-digit room' },
    @{ b = '';   room = '201';   why = 'no building selected' },
    @{ b = '55'; room = '103';   why = 'a room that already has rules' }
)) {
    $r = Add-ClassroomRecord -Building $case.b -Room $case.room
    ok (-not $r.Ok) "refuses $($case.why): $($r.Msg)"
}
ok (@($script:RulesConfig.rules).Count -eq 1) 'no refused case wrote a rule'

'--- Add Classroom: a failed write rolls back ---'
Reset-Fixture
$script:SaveOk = $false
$r = Add-ClassroomRecord -Building '55' -Room '201'
ok (-not $r.Ok) "reports the write failure: $($r.Msg)"
ok (@($script:RulesConfig.rules).Count -eq 1) 'the half-added rule was rolled back'
ok ("$(@($script:RulesConfig.rules)[0].rooms)" -eq '103') 'the original rule survived the rollback intact'

'--- Add Classroom: machine type ---'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -Types 'LAB'
ok $r.Ok "type accepted: $($r.Msg)"
ok ("$(@($script:RulesConfig.rules)[-1].types)" -eq 'LAB') 'the type landed on the rule'
ok ($r.Msg -match 'LAB') 'the confirmation names the type'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -Types ''
ok $r.Ok 'blank type is allowed (means any type)'
ok ("$(@($script:RulesConfig.rules)[-1].types)" -eq '') 'blank type stored as blank, not as a literal'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -Types 'LA TS!'
ok (-not $r.Ok) "refuses a junk type: $($r.Msg)"

'--- multi-code buildings: "55 56" makes ONE building with two codes ---'
Reset-Fixture
$r = Add-BuildingRecord -Code '24 25' -Abbr 'SC'
ok $r.Ok "multi-code added: $($r.Msg)"
ok ("$($script:BuildingsConfig.buildings.'24'.abbr)" -eq 'SC' -and "$($script:BuildingsConfig.buildings.'25'.abbr)" -eq 'SC') 'both codes stored, sharing the abbreviation'
ok ($r.Msg -match '2 codes') 'the message says how many codes'
Reset-Fixture
$r = Add-BuildingRecord -Code '24  25,26   27' -Abbr 'SC'
ok $r.Ok 'spaces and commas both separate, any number of codes'
ok (@('24','25','26','27' | Where-Object { $script:BuildingsConfig.buildings.$_ }).Count -eq 4) 'all four codes landed'
Reset-Fixture
$r = Add-BuildingRecord -Code '24 55' -Abbr 'SC'
ok (-not $r.Ok -and $r.Msg -match 'already exists') 'one bad code in the list refuses the whole add'
ok ($null -eq $script:BuildingsConfig.buildings.'24') 'and the good code in that list was NOT added'
Reset-Fixture
$r = Add-BuildingRecord -Code '24 249' -Abbr 'SC'
ok (-not $r.Ok -and $r.Msg -match 'prefix') "sibling codes are prefix-checked against EACH OTHER: $($r.Msg)"
Reset-Fixture
$r = Add-BuildingRecord -Code '24 24' -Abbr 'SC'
ok (-not $r.Ok -and $r.Msg -match 'twice') 'the same code typed twice is caught'
Reset-Fixture
$script:SaveOk = $false
$r = Add-BuildingRecord -Code '24 25' -Abbr 'SC'
ok (-not $r.Ok) 'write failure reported'
ok ($null -eq $script:BuildingsConfig.buildings.'24' -and $null -eq $script:BuildingsConfig.buildings.'25') 'ALL codes rolled back, not just the last'

'--- the Layout Designer folds those codes into ONE card ---'
Reset-Fixture
$script:BuildingsConfig.buildings | Add-Member -NotePropertyName '56' -NotePropertyValue ([pscustomobject]@{ abbr='ENG'; fullName='' }) -Force
$blds = @(Get-CoverageBuildings)
$vep = @($blds | Where-Object { $_.Abbr -eq 'ENG' })
ok ($vep.Count -eq 1) "ENG appears exactly once, not twice (got $($vep.Count))"
ok ("$(@($vep[0].Codes) -join ',')" -eq '55,56') "and owns both codes (got $(@($vep[0].Codes) -join ','))"
ok ($vep[0].Code -eq '55') 'the primary code is the lowest - stable across launches'
ok ($vep[0].Configured) 'configured because ONE of its codes has a rule'
ok ($vep[0].Display -eq 'ENG') 'the card title is just the abbreviation now - no code suffix needed'
# A building whose codes are all ruleless still merges, just greyed out.
$script:BuildingsConfig.buildings | Add-Member -NotePropertyName '26' -NotePropertyValue ([pscustomobject]@{ abbr='ARTS'; fullName='' }) -Force
$script:BuildingsConfig.buildings | Add-Member -NotePropertyName '27' -NotePropertyValue ([pscustomobject]@{ abbr='ARTS'; fullName='' }) -Force
$blds = @(Get-CoverageBuildings)
$arts = @($blds | Where-Object { $_.Abbr -eq 'ARTS' })
ok ($arts.Count -eq 1 -and @($arts[0].Codes).Count -eq 2) 'ARTS 26+27 merges too'
ok (-not $arts[0].Configured) 'and stays unconfigured when neither code has a rule'

'--- Add Classroom no longer asks about machine type ---'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201'
ok $r.Ok 'a room adds with no type given'
ok ("$(@($script:RulesConfig.rules)[-1].types)" -eq '') 'the rule is type-blank, so 10109LAB and 10109CART both match it'

'--- Add Classroom: optional machine count ---'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -MaxMachine '30'
ok $r.Ok "count accepted: $($r.Msg)"
ok ("$($script:BuildingsConfig.roomSizes.'55-201')" -eq '30') 'the room size was recorded'
ok ($r.Msg -match '30') 'the confirmation states the size'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -MaxMachine ''
ok $r.Ok 'blank count is allowed - the normal answer'
ok ($null -eq $script:BuildingsConfig.roomSizes) 'a blank count writes NO room size (auto-grow, no database)'
Reset-Fixture
foreach ($bad in 'abc', '0', '-5', '99999') {
    $r = Add-ClassroomRecord -Building '55' -Room '201' -MaxMachine $bad
    ok (-not $r.Ok) "refuses machine count '$bad': $($r.Msg)"
}

'--- live validators (shared by the dialogs as-you-type check) ---'
Reset-Fixture
$r = Test-BuildingCodeFree -Code '24'
ok $r.Ok "a free code reads as free: $($r.Msg)"
$r = Test-BuildingCodeFree -Code '90'
ok (-not $r.Ok -and $r.Msg -match 'prefix') 'live check catches the 90-vs-902 collision'
$r = Test-BuildingCodeFree -Code '55'
ok (-not $r.Ok -and $r.Msg -match 'ENG') 'a taken code names WHO has it'
$r = Test-ClassroomFree -Building '55' -Room '103'
ok (-not $r.Ok) 'live check knows 103 already has rules'
$r = Test-ClassroomFree -Building '55' -Room '201'
ok $r.Ok 'live check confirms 201 is new'

'--- Add Classroom: start-with-profile ---'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -Profile 'ENG'
ok $r.Ok "profile room added: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[-1]
ok ("$($rule.profile)" -eq 'ENG') 'the rule references the profile'
ok (-not (Test-RuleHasApps -Rule $rule)) 'a profile rule carries NO apps property (apps=[] would mean "gets nothing")'
ok ($r.Msg -match '3 programs') 'the confirmation states the profile size'
ok ($r.Msg -match 'tracks future edits') 'the confirmation says it follows the profile'
Reset-Fixture
$r = Add-ClassroomRecord -Building '55' -Room '201' -Profile 'NOPE'
ok (-not $r.Ok) "unknown profile refused: $($r.Msg)"

'--- profile choices come from rooms.json ---'
Reset-Fixture
$p = @(Get-RoomProfileChoices)
ok ($p.Count -eq 1 -and $p[0].Key -eq 'ENG') 'profiles listed from the config'
ok ($p[0].Label -match '3 programs') 'the label carries the program count'

'--- segments: a blank-machines rule IS the whole room (what Add Classroom writes) ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '201'; types = ''; machines = ''; apps = @('LTSpice') }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '201' -SeenMax 0)
ok ($segs.Count -eq 1) "one segment, not a bogus '01' plus a tail (got $($segs.Count))"
ok ([bool]$segs[0].Tail -and [bool]$segs[0].Assigned) 'that segment is the assigned open tail'
ok ((Get-CoverageSegLabel -Seg $segs[0]) -match '01-') 'labelled from machine 01'
ok ($null -ne $segs[0].RuleRef) 'and it carries its rule for editing'

'--- Add Programs: append to an inline rule, order preserved ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ($null -ne $segs[0].RuleRef) 'assigned segment carries RuleRef'
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python','MATLAB')
ok $r.Ok "added: $($r.Msg)"
$apps = @(@($script:RulesConfig.rules)[0].apps)
ok ("$($apps -join ',')" -eq 'LTSpice,PuTTY,Python,MATLAB') "existing order kept, new ones at the END (got $($apps -join ','))"
ok (@($script:RulesConfig.rules).Count -eq 1) 'no extra rule was created'

'--- Add Programs: dedupe against what is already there ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('PuTTY','Python')
ok $r.Ok 'partial overlap still saves'
ok ($r.Msg -match '1 already there') "and says what it skipped: $($r.Msg)"
ok ("$(@(@($script:RulesConfig.rules)[0].apps) -join ',')" -eq 'LTSpice,PuTTY,Python') 'no duplicate entry appeared'
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('LTSpice')
ok (-not $r.Ok) "all-duplicates refused: $($r.Msg)"

'--- Add Programs: refusals ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @()
ok (-not $r.Ok) "empty selection refused: $($r.Msg)"
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('NotAnApp')
ok (-not $r.Ok -and $r.Msg -match 'NotAnApp') "unknown id refused by name: $($r.Msg)"

'--- Add Programs: an unassigned GAP gets its own bounded rule ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = 'LAB'; machines = '1-20';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = 'LAB'; machines = '41-60'; apps = @('PuTTY') }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$gap = @($segs | Where-Object { -not $_.Assigned -and -not $_.Tail })[0]
ok ($null -ne $gap -and $gap.From -eq 21 -and $gap.To -eq 40) "the 21-40 gap was found (got $($gap.From)-$($gap.To))"
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $gap -AppIds @('Python')
ok $r.Ok "gap filled: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[-1]
ok ("$($rule.machines)" -eq '21-40') 'new rule claims exactly the gap'
ok ("$($rule.types)" -eq '') 'new rule is type-blank (the mixed-room lesson), not stamped LAB'
ok (@($script:RulesConfig.rules).Count -eq 3) 'appended as a third rule, existing two untouched'

'--- Add Programs: the open tail gets a whole-room rule via first-match-wins ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$tail = $segs[$segs.Count - 1]
ok ([bool]$tail.Tail -and -not $tail.Assigned) 'tail starts unassigned'
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $tail -AppIds @('Python','Logisim')
ok $r.Ok "tail filled: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[-1]
ok ("$($rule.machines)" -eq '') 'the tail rule has a blank token - everything the earlier rules did not claim'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$t2 = $segs2[$segs2.Count - 1]
ok ([bool]$t2.Tail -and [bool]$t2.Assigned -and $t2.Apps.Count -eq 2) 'rendering agrees: the tail is now assigned with 2 programs'
ok ($t2.From -eq 61) "and still starts at 61 (got $($t2.From))"

'--- Add Programs: a profile segment converts to inline, and says so ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; profile = 'ENG' }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ($segs[0].Source -match 'ENG') 'segment shows its profile source'
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python')
ok $r.Ok "conversion add: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[0]
ok ("$(@($rule.apps) -join ',')" -eq 'Logisim,LTSpice,PuTTY,Python') 'inline list = profile order + the addition'
ok (@($rule.PSObject.Properties.Name) -notcontains 'profile') 'the profile reference is gone - the room no longer tracks it'
ok ($r.Msg -match 'no longer tracks') 'and the message says exactly that'

'--- Add Programs: write failures roll back BOTH shapes ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python')
ok (-not $r.Ok) 'mutation failure reported'
ok ("$(@(@($script:RulesConfig.rules)[0].apps) -join ',')" -eq 'LTSpice,PuTTY') 'the apps list was restored exactly'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; profile = 'ENG' }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python')
ok (-not $r.Ok) 'profile-conversion failure reported'
$rule = @($script:RulesConfig.rules)[0]
ok ("$($rule.profile)" -eq 'ENG' -and -not (Test-RuleHasApps -Rule $rule)) 'the profile reference came back and the inline list did not stay'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[$segs.Count - 1] -AppIds @('Python')
ok (-not $r.Ok) 'creation failure reported'
ok (@($script:RulesConfig.rules).Count -eq 1) 'the half-created tail rule was rolled back'

'--- Split: a bounded segment splits in two, in place ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok $r.Ok "split: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 2) "one rule became two (got $($rules.Count))"
ok ("$($rules[0].machines)" -eq '1-30') "parent keeps the low half (got '$($rules[0].machines)')"
ok ("$($rules[1].machines)" -eq '31-60') "the new rule takes the high half (got '$($rules[1].machines)')"
ok ("$(@($rules[1].apps) -join ',')" -eq 'LTSpice,PuTTY') 'both halves start with the same programs, in the same order'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok (@($segs2 | Where-Object { -not $_.Tail }).Count -eq 2) 'the room now renders as two bounded segments'
ok (@($segs2 | Where-Object { -not $_.Assigned -and -not $_.Tail }).Count -eq 0) 'and no gap opened between them'

'--- Split: the new half is INSERTED beside its parent, never appended ---'
# The ordering proof from the header comment. With a blank-token rule sitting
# after the parent, an APPENDED second half would land behind it and never
# match - machines 31-60 would silently fall to the blank rule instead.
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '';     apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok $r.Ok 'split with a catch-all rule present'
$rules = @($script:RulesConfig.rules)
ok ("$($rules[1].machines)" -eq '31-60') "the new half sits at index 1, right after its parent (got '$($rules[1].machines)')"
ok ("$($rules[2].machines)" -eq '') 'the blank-token rule stayed last, so it still only gets what nobody claimed'

'--- Split: the open tail splits into a bounded head + the same tail ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = ''; apps = @('LTSpice') }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ([bool]$segs[0].Tail) 'starts as one open tail'
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok $r.Ok "tail split: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 2) 'a second rule appeared'
ok ("$($rules[0].machines)" -eq '1-30') 'the bounded head was inserted FIRST, so it wins 1-30'
ok ("$($rules[1].machines)" -eq '') 'the tail rule kept its blank token and is still the tail'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ($segs2.Count -eq 2 -and [bool]$segs2[1].Tail -and $segs2[1].From -eq 31) 'renders as 1-30 plus a tail from 31'

'--- Split: a profile segment splits into TWO profile rules ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; profile = 'ENG' }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok $r.Ok 'profile segment split'
$rules = @($script:RulesConfig.rules)
ok ("$($rules[1].profile)" -eq 'ENG') 'the new half references the profile too'
ok (-not (Test-RuleHasApps -Rule $rules[1])) 'it carries NO inline apps - both halves still track the profile'

'--- Split: what it refuses ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Test-SegmentSplit -Segment $segs[0] -At 1
ok (-not $r.Ok) "refuses splitting at the first machine: $($r.Msg)"
$r = Test-SegmentSplit -Segment $segs[0] -At 61
ok (-not $r.Ok) "refuses splitting past the end: $($r.Msg)"
$r = Test-SegmentSplit -Segment $segs[$segs.Count - 1] -At 70
ok (-not $r.Ok -and $r.Msg -match 'no rule') "refuses an unclaimed gap/tail: $($r.Msg)"
$r = Test-SegmentSplit -Segment @{ From = 1; To = 9; Complex = $true; Token = '1,5,9'; Tail = $false; RuleRef = [pscustomobject]@{} } -At 5
ok (-not $r.Ok -and $r.Msg -match 'list') "refuses a list-style token by name: $($r.Msg)"
# The live preview and the record must agree, or the dialog enables a Save that fails.
$r = Test-SegmentSplit -Segment $segs[0] -At 31
ok ($r.Ok -and $r.Lo -eq '01-30' -and $r.Hi -eq '31-60') "the preview names both halves: $($r.Msg)"

'--- Split: a failed write rolls the token back ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok (-not $r.Ok) 'split write failure reported'
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 1) 'the half-inserted rule was rolled back'
ok ("$($rules[0].machines)" -eq '1-60') "and the parent's token was restored (got '$($rules[0].machines)')"

'--- Remove Programs: takes them off, keeps the rest in order ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python','MATLAB')
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('PuTTY')
ok $r.Ok "removed: $($r.Msg)"
ok ("$(@(@($script:RulesConfig.rules)[0].apps) -join ',')" -eq 'LTSpice,Python,MATLAB') 'the survivors kept their install order'
ok (@($script:RulesConfig.rules).Count -eq 1) 'no rule was added or deleted'

'--- Remove Programs: emptying a segment is a real answer, not a blank one ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('LTSpice','PuTTY')
ok $r.Ok "emptied: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[0]
ok (Test-RuleHasApps -Rule $rule) 'the apps property still EXISTS - apps=[] means "gets nothing", not "follows a profile"'
ok (@($rule.apps).Count -eq 0) 'and it is empty'
ok ($r.Msg -match 'NOTHING') 'the message says so out loud'

'--- Remove Programs: a profile segment converts to inline, and says so ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; profile = 'ENG' }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('LTSpice')
ok $r.Ok "conversion remove: $($r.Msg)"
$rule = @($script:RulesConfig.rules)[0]
ok ("$(@($rule.apps) -join ',')" -eq 'Logisim,PuTTY') 'inline list = the profile minus the removal, order intact'
ok (@($rule.PSObject.Properties.Name) -notcontains 'profile') 'the profile reference is gone'
ok ($r.Msg -match 'no longer tracks') 'and the message says exactly that'

'--- Remove Programs: what it refuses ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @()
ok (-not $r.Ok) "empty selection refused: $($r.Msg)"
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('MATLAB')
ok (-not $r.Ok) "a program the segment does not have is refused: $($r.Msg)"
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[$segs.Count - 1] -AppIds @('LTSpice')
ok (-not $r.Ok -and $r.Msg -match 'nothing') "an unassigned segment is refused: $($r.Msg)"
# Partial hits still save, and report what was not there.
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('PuTTY','MATLAB')
ok ($r.Ok -and $r.Msg -match 'not there') "partial removal saves and says what it skipped: $($r.Msg)"

'--- Remove Programs: write failures roll back BOTH shapes ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('PuTTY')
ok (-not $r.Ok) 'remove failure reported'
ok ("$(@(@($script:RulesConfig.rules)[0].apps) -join ',')" -eq 'LTSpice,PuTTY') 'the apps list was restored exactly'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-60'; profile = 'ENG' }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('LTSpice')
ok (-not $r.Ok) 'profile-conversion remove failure reported'
$rule = @($script:RulesConfig.rules)[0]
ok ("$($rule.profile)" -eq 'ENG' -and -not (Test-RuleHasApps -Rule $rule)) 'the profile reference came back and no inline list stayed'

'--- Merge: two bounded segments become one, first list wins ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '31-60'; apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Merge-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok $r.Ok "merged: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 1) "two rules became one (got $($rules.Count))"
ok ("$($rules[0].machines)" -eq '1-60') "the survivor covers both (got '$($rules[0].machines)')"
ok ("$(@($rules[0].apps) -join ',')" -eq 'LTSpice') "the FIRST segment's list survived, as the dialog promised"

'--- Merge: swallowing an unclaimed gap needs no second rule ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-20';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '41-60'; apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok (-not $segs[1].Assigned -and $segs[1].From -eq 21) 'the 21-40 gap is the next segment'
$r = Merge-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok $r.Ok "gap swallowed: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 2) 'still two rules - a gap has none to delete'
ok ("$($rules[0].machines)" -eq '1-40') "the first widened over the gap (got '$($rules[0].machines)')"
ok ("$($rules[1].machines)" -eq '41-60') 'the far rule was not touched'

'--- Merge: into the open tail, the TAIL rule is the survivor ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30'; apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '';     apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ([bool]$segs[1].Tail) 'the next segment is the open tail'
$r = Merge-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok $r.Ok "merged into the tail: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 1 -and "$($rules[0].machines)" -eq '') 'only the blank-token rule remains - it is what means "and everything above"'
ok ("$(@($rules[0].apps) -join ',')" -eq 'LTSpice') "and it took the first segment's programs"
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ($segs2.Count -eq 1 -and $segs2[0].From -eq 1) 'the room renders as one segment from machine 1'

'--- Merge: refuses rather than moving machines nobody picked ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '31-60'; apps = @('PuTTY')   },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '35-40'; apps = @('Python')  }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Test-SegmentMerge -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok (-not $r.Ok -and $r.Msg -match '35-40') "names the overlapping rule instead of guessing: $($r.Msg)"
ok (@($script:RulesConfig.rules).Count -eq 3) 'and nothing was written'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Test-SegmentMerge -Building '55' -Room '103' -Segment $segs[$segs.Count - 1] -Next $null
ok (-not $r.Ok -and $r.Msg -match 'tail') "the open tail has nothing after it: $($r.Msg)"
$r = Test-SegmentMerge -Building '55' -Room '103' -Segment $segs[0] -Next $null
ok (-not $r.Ok) 'no next segment is refused'

'--- Merge: a failed write rolls back ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '31-60'; apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Merge-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok (-not $r.Ok) 'merge write failure reported'
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 2 -and "$($rules[0].machines)" -eq '1-30') 'both rules and the original token came back'

'--- Room Size ---'
Reset-Fixture
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count '30'
ok $r.Ok "size saved: $($r.Msg)"
ok ("$($script:BuildingsConfig.roomSizes.'55-103')" -eq '30') 'the count reached buildings.json'
ok ((Get-RoomMachineCount -Building '55' -Room '103' -SeenMax 0) -eq 30) 'and the segment strip reads it back'
ok ($r.Msg -match 'still work') 'the message keeps the no-room-size-database promise: rules past it still match'
# '' is deliberately NOT in this list any more: blank now means "clear the
# declared size", which is tested in its own block below.
foreach ($bad in 'abc', '0', '-5') {
    $r = Set-RoomSizeRecord -Building '55' -Room '103' -Count $bad
    ok (-not $r.Ok) "refuses size '$bad': $($r.Msg)"
}
Reset-Fixture
$script:SaveOk = $false
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count '30'
ok (-not $r.Ok) 'size write failure reported'
ok ($null -eq $script:BuildingsConfig.roomSizes.'55-103') 'a size that failed to save is NOT left in memory'

'--- Claim: Blake case - carve 100-120 out of an unassigned 61-oo tail ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$tail = $segs[$segs.Count - 1]
ok ([bool]$tail.Tail -and -not $tail.Assigned -and $null -eq $tail.RuleRef) 'the tail starts unassigned with no rule'
$r = Claim-SegmentRecord -Building '55' -Room '103' -Segment $tail -From '100' -To '120'
ok $r.Ok "claimed: $($r.Msg)"
$rules = @($script:RulesConfig.rules)
ok ($rules.Count -eq 2) "exactly ONE rule was written (got $($rules.Count - 1) new)"
ok ("$($rules[-1].machines)" -eq '100-120') "and it claims exactly 100-120 (got '$($rules[-1].machines)')"
ok ((Test-RuleHasApps -Rule $rules[-1]) -and @($rules[-1].apps).Count -eq 0) 'it is No installs - apps=[] exists and is empty'
ok ($r.Msg -match 'No installs') 'the message says so'
# The leftovers must be LEFT ALONE - writing apps:[] over them would stop them
# inheriting from a building-wide rule, which nobody asked for.
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$lbl = @($segs2 | ForEach-Object { Get-CoverageSegLabel -Seg $_ })
ok ("$($lbl -join ' ')" -eq "01-60 61-99 100-120 121-$([string][char]0x221E)") "room derives as 01-60 61-99 100-120 121-oo (got $($lbl -join ' '))"
ok (-not @($segs2 | Where-Object { (Get-CoverageSegLabel -Seg $_) -eq '61-99' })[0].Assigned) '61-99 stayed UNCLAIMED, not written as empty'
ok ($r.Msg -match '61-99') "and the confirmation names what was left: $($r.Msg)"

'--- Claim: what it refuses ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$tail = $segs[$segs.Count - 1]
foreach ($c in @(
    @{ f = '';    t = '';    why = 'a blank start' },
    @{ f = 'abc'; t = '';    why = 'a non-numeric start' },
    @{ f = '0';   t = '';    why = 'machine #0' },
    @{ f = '50';  t = '';    why = 'a start below the segment' },
    @{ f = '100'; t = '90';  why = 'an end below the start' },
    @{ f = '100'; t = 'abc'; why = 'a non-numeric end' }
)) {
    $r = Test-SegmentClaim -Segment $tail -From $c.f -To $c.t
    ok (-not $r.Ok) "refuses $($c.why): $($r.Msg)"
}
# The one that is subtle: "and up" from partway into the tail would swallow
# everything below it, because a blank machines token matches EVERY machine.
$r = Test-SegmentClaim -Segment $tail -From '100' -To ''
ok (-not $r.Ok -and $r.Msg -match 'swallow') "refuses an open-ended claim from partway up the tail: $($r.Msg)"
# ...but claiming the WHOLE tail open-ended is exactly what a blank token means.
$r = Test-SegmentClaim -Segment $tail -From '61' -To ''
ok ($r.Ok -and $r.Token -eq '') 'claiming the whole tail open-ended writes the blank token'
# An assigned segment is a split, not a claim.
$r = Test-SegmentClaim -Segment $segs[0] -From '10' -To '20'
ok (-not $r.Ok -and $r.Msg -match 'Split') "an assigned segment is redirected to Split: $($r.Msg)"

'--- Claim: a gap, and a failed write ---'
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-20';  apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '41-60'; apps = @('PuTTY')   }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$gap = @($segs | Where-Object { -not $_.Assigned -and -not $_.Tail })[0]
$r = Claim-SegmentRecord -Building '55' -Room '103' -Segment $gap -From '25' -To '30' -AppIds @('Python')
ok $r.Ok "part of a gap claimed: $($r.Msg)"
ok ("$(@($script:RulesConfig.rules | ForEach-Object { $_.machines }) -join ',')" -match '25-30') 'the sub-range rule exists'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok (@($segs2 | Where-Object { -not $_.Assigned -and -not $_.Tail }).Count -eq 2) 'the two leftover slivers of the gap are still unclaimed'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Claim-SegmentRecord -Building '55' -Room '103' -Segment $segs[$segs.Count - 1] -From '61' -To '99'
ok (-not $r.Ok) 'claim write failure reported'
ok (@($script:RulesConfig.rules).Count -eq 1) 'the half-written rule was rolled back'

'--- ordered insert: a bounded rule must never land behind the catch-all ---'
# The shadowing trap. A blank machines token matches EVERY machine, so a rule
# appended after it can never fire and the machines silently keep the old list.
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = ''; apps = @('LTSpice') }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ([bool]$segs[0].Tail -and [bool]$segs[0].Assigned) 'room is one assigned catch-all'
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 31
ok $r.Ok 'split the catch-all'
$rules = @($script:RulesConfig.rules)
ok ("$($rules[0].machines)" -eq '1-30') 'the bounded piece is FIRST'
ok ("$($rules[1].machines)" -eq '') 'the catch-all stayed last'
# Now claim into the room while the catch-all exists.
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30'; apps = @('LTSpice') },
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '';     apps = @('PuTTY')   }) }
$new = [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '31-40'; apps = @() }
$out = @(Add-RoomRuleOrdered -Rules @($script:RulesConfig.rules) -NewRule $new -Building '55' -Room '103')
ok ($out.Count -eq 3) 'one rule added'
ok ("$($out[1].machines)" -eq '31-40') 'the bounded rule was INSERTED before the catch-all, not appended behind it'
ok ("$($out[2].machines)" -eq '') 'the catch-all is still last'
# With no catch-all present it is an ordinary append.
$plain = @([pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = '1-30'; apps = @() })
$out2 = @(Add-RoomRuleOrdered -Rules $plain -NewRule $new -Building '55' -Room '103')
ok ("$($out2[-1].machines)" -eq '31-40') 'with no catch-all it simply appends'
# A DIFFERENT room's catch-all must not attract the insert.
$other = @([pscustomobject]@{ building = '55'; rooms = '201'; types = ''; machines = ''; apps = @() })
$out3 = @(Add-RoomRuleOrdered -Rules $other -NewRule $new -Building '55' -Room '103')
ok ("$($out3[-1].machines)" -eq '31-40') "another room's catch-all is ignored"

'--- Split: the three-way carve (from AND to) ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 21 -To 30
ok $r.Ok "three-way carve: $($r.Msg)"
$toks = @($script:RulesConfig.rules | ForEach-Object { "$($_.machines)" })
ok ("$($toks -join ' ')" -eq '1-20 21-30 31-60') "covers the parent exactly, in order (got $($toks -join ' '))"
foreach ($rr in @($script:RulesConfig.rules)) {
    ok ("$(@($rr.apps) -join ',')" -eq 'LTSpice,PuTTY') "piece $($rr.machines) kept the parent's programs, in order"
}
# Carving from the very first machine leaves two pieces, not three.
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 1 -To 30
ok $r.Ok 'carving from the first machine is allowed when an end is given'
ok ("$(@($script:RulesConfig.rules | ForEach-Object { $_.machines }) -join ' ')" -eq '1-30 31-60') 'two pieces, no empty head'
# Three-way on the open tail: head + middle, tail keeps the blank token.
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building = '55'; rooms = '103'; types = ''; machines = ''; apps = @('LTSpice') }) }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 100 -To 120
ok $r.Ok "tail carve: $($r.Msg)"
ok ("$(@($script:RulesConfig.rules | ForEach-Object { $_.machines }) -join ' ')" -eq '1-99 100-120 ') 'head + middle inserted, blank tail last'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ((Get-CoverageSegLabel -Seg $segs2[$segs2.Count - 1]) -eq "121-$([string][char]0x221E)") 'the tail now starts at 121'

'--- Split: three-way refusals ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
foreach ($c in @(
    @{ a = 21; t = '20';  why = 'an end below the start' },
    @{ a = 21; t = '70';  why = 'an end past the segment' },
    @{ a = 1;  t = '60';  why = 'a carve that is the whole segment' },
    @{ a = 21; t = 'abc'; why = 'a non-numeric end' }
)) {
    $r = Test-SegmentSplit -Segment $segs[0] -At $c.a -To $c.t
    ok (-not $r.Ok) "refuses $($c.why): $($r.Msg)"
}
$r = Test-SegmentSplit -Segment $segs[0] -At 21 -To 30
ok ($r.Ok -and @($r.Pieces).Count -eq 3) "the preview lists all three pieces: $($r.Msg)"

'--- Unclaim: a segment can be deleted, and says what replaces it ---'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Test-SegmentUnclaim -Segment $segs[$segs.Count - 1]
ok (-not $r.Ok -and $r.Msg -match 'nothing to unclaim') "an unassigned segment has nothing to delete: $($r.Msg)"
$r = Remove-SegmentRecord -Building '55' -Room '103' -Segment $segs[0]
ok $r.Ok "deleted: $($r.Msg)"
ok (@($script:RulesConfig.rules).Count -eq 0) 'the rule is gone'
ok ($r.Msg -match 'unclaimed|inherit') 'the message says what those machines get now'
$segs2 = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
ok ($segs2.Count -eq 1 -and -not $segs2[0].Assigned) 'the room is one unclaimed tail again'
Reset-Fixture
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$script:SaveOk = $false
$r = Remove-SegmentRecord -Building '55' -Room '103' -Segment $segs[0]
ok (-not $r.Ok) 'unclaim write failure reported'
ok (@($script:RulesConfig.rules).Count -eq 1) 'the rule came back'

'--- everything this tab writes can be un-written ---'
# The round trip Blake asked for: claim it, edit it, split it, then delete it
# and land back where you started.
Reset-Fixture
$script:RulesConfig = [pscustomobject]@{ rules = @() }
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Claim-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -From '1' -To '30'
ok $r.Ok 'claim'
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Add-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('Python','MATLAB')
ok $r.Ok 'add programs to it'
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-ProgramsRecord -Building '55' -Room '103' -Segment $segs[0] -AppIds @('MATLAB')
ok $r.Ok 'remove one again'
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Split-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -At 11
ok $r.Ok 'split it'
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Merge-SegmentRecord -Building '55' -Room '103' -Segment $segs[0] -Next $segs[1]
ok $r.Ok 'merge it back'
$segs = @(Get-CoverageSegments -Building '55' -Room '103' -SeenMax 0)
$r = Remove-SegmentRecord -Building '55' -Room '103' -Segment $segs[0]
ok $r.Ok 'delete it'
ok (@($script:RulesConfig.rules).Count -eq 0) 'back to an empty rules file - nothing was left stranded'

'--- Room Size can be cleared, not just set ---'
Reset-Fixture
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count '30'
ok $r.Ok 'size set'
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count ''
ok $r.Ok "size cleared: $($r.Msg)"
ok ($null -eq $script:BuildingsConfig.roomSizes.'55-103') 'the key is gone from buildings.json'
ok ((Get-RoomMachineCount -Building '55' -Room '103' -SeenMax 0) -eq 0) 'the room grows on its own again'
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count ''
ok (-not $r.Ok) "clearing a size that is not there is refused, not silently ok: $($r.Msg)"
Reset-Fixture
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count '30'
$script:SaveOk = $false
$r = Set-RoomSizeRecord -Building '55' -Room '103' -Count ''
ok (-not $r.Ok) 'clear write failure reported'
ok ("$($script:BuildingsConfig.roomSizes.'55-103')" -eq '30') 'the size came back'

'--- messages are sentences, not codes ---'
Reset-Fixture
$r = Add-BuildingRecord -Code '1' -Abbr 'X'
ok ($r.Msg.Length -gt 20 -and $r.Msg -notmatch '^E\d+$') "plain English: '$($r.Msg)'"

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
