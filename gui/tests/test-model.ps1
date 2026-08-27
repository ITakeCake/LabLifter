# Headless test of the new assignment model. Pulls the pure functions out of
# Deploy-LabGUI.ps1 by AST so nothing GUI-related has to run.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)

$want = @('Test-NumToken','Resolve-DeployRule','Test-RuleHasApps','Get-RuleApps','Get-RuleLabel',
          'Resolve-DeployProfile','Get-FleetExpected','Get-FleetMachineStatus','Test-AppCountsForFleetHealth','Test-AppNeedsOpenConfirm','Get-RoomMachineCount',
          'ConvertFrom-MachineToken','New-AppSet','Get-AssignRoomRules','Register-AssignedProfile',
          'ConvertFrom-LabHostname')
$defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$loaded = @()
foreach ($d in $defs) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
"loaded: $($loaded.Count)/$($want.Count) functions"
$miss = @($want | Where-Object { $loaded -notcontains $_ })
if ($miss.Count) { "!! NOT FOUND: $($miss -join ', ')" }

# ---- fixtures: the real shapes, trimmed --------------------------------------
$ENG = @('Logisim','ArduinoIDE','LTSpice','WaveForms','AnsysHFSS','PuTTY','Python','MSYS2','VSCode',
         'VisualStudio','Vivado','STLinkDriver','Keil','AppLab','LabVIEW','RockwellCCW','Wireshark',
         'MATLAB','MatlabArduino')
$appsObj = New-Object psobject
foreach ($a in ($ENG + @('ImageJ','JASP','R'))) {
    $appsObj | Add-Member -NotePropertyName $a -NotePropertyValue ([pscustomobject]@{ displayName = $a; needsOpen = $false })
}
$script:AppsConfig  = [pscustomobject]@{ apps = $appsObj }
$script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{
    ENG = [pscustomobject]@{ displayName='ENG Lab'; match=[pscustomobject]@{building='55'}; apps=$ENG }
    SCI = [pscustomobject]@{ displayName='SCI';     match=[pscustomobject]@{building='03'}; apps=@('ImageJ','JASP') }
} }
$script:BuildingsConfig = [pscustomobject]@{
    buildings = [pscustomobject]@{ '55' = [pscustomobject]@{abbr='ENG'}; '03' = [pscustomobject]@{abbr='SCI-1'} }
    typeCodes = [pscustomobject]@{ LAB = [pscustomobject]@{machine01Role='ask'} }
    roomSizes = [pscustomobject]@{ '55-103' = 90 }
}
# the exact ask, plus a building-wide catch-all UNDERNEATH it to prove
# first-match-wins really lets "(none)" override a broader rule.
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building='55'; rooms='103'; types='LAB'; machines='1-60';  apps=$ENG },
    [pscustomobject]@{ building='55'; rooms='103'; types='LAB'; machines='61-90'; apps=@() },
    [pscustomobject]@{ building='55'; rooms='';    types='';    machines='';      profile='ENG' }
) }

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" }
}

'--- room capacity ---'
ok ((Get-RoomMachineCount -Building '55' -Room '103' -SeenMax 34) -eq 90) 'declared 90 beats the 34 ever seen in logs'
ok ((Get-RoomMachineCount -Building '55' -Room '999' -SeenMax 12) -eq 12) 'undeclared room falls back to highest seen'
ok ((Get-RoomMachineCount -Building '55' -Room '999' -SeenMax 0)  -eq 0)  'nothing known -> 0'

'--- machine token parsing ---'
$t = ConvertFrom-MachineToken -Token '30-60' -Max 90
ok ($t.From -eq 30 -and $t.To -eq 60 -and -not $t.Complex) 'range 30-60'
$t = ConvertFrom-MachineToken -Token '' -Max 90
ok ($t.From -eq 1 -and $t.To -eq 90 -and -not $t.Complex) 'blank = whole room'
$t = ConvertFrom-MachineToken -Token '7' -Max 90
ok ($t.From -eq 7 -and $t.To -eq 7) 'single machine'
$t = ConvertFrom-MachineToken -Token '1,5,9' -Max 90
ok ($t.From -eq 1 -and $t.To -eq 9 -and $t.Complex) 'comma list keeps span and flags Complex'

'--- inline apps detection ---'
ok (Test-RuleHasApps -Rule $script:RulesConfig.rules[0]) 'rule with apps -> HasApps'
ok (Test-RuleHasApps -Rule $script:RulesConfig.rules[1]) 'rule with EMPTY apps -> still HasApps (the whole point)'
ok (-not (Test-RuleHasApps -Rule $script:RulesConfig.rules[2])) 'profile-only rule -> no inline apps'
ok ((Get-RuleApps -Rule $script:RulesConfig.rules[1]).Count -eq 0) 'empty inline list reads as 0 apps'
ok ($null -eq (Get-RuleApps -Rule $script:RulesConfig.rules[2])) 'profile-only rule returns $null, not @()'
ok ((Get-RuleLabel -Rule $script:RulesConfig.rules[1]) -eq '(none)') 'empty list labels as (none)'

'--- the reported scenario: #01-60 get ENG, #61-90 get nothing ---'
$e20 = Get-FleetExpected -Building '55' -Room '103' -Type 'LAB' -Num 20
ok ($e20 -and $e20.Apps.Count -eq 19) "machine #20 expects 19 programs (got $($e20.Apps.Count))"
$e75 = Get-FleetExpected -Building '55' -Room '103' -Type 'LAB' -Num 75
ok ($null -ne $e75) 'machine #75 still RESOLVES (does not fall through)'
ok ($e75.Apps.Count -eq 0) "machine #75 expects nothing (got $($e75.Apps.Count))"
ok ($e75.Profile -eq '(none)') "machine #75 profile label is (none) (got '$($e75.Profile)')"

'--- the override that was impossible before ---'
# rule 3 is a building-wide catch-all granting the whole ENG set. If ordering
# or the empty-array handling were wrong, #75 would inherit those 19 apps.
ok ($e75.Apps.Count -eq 0) 'room-specific (none) beats the building-wide catch-all below it'
$eOther = Get-FleetExpected -Building '55' -Room '204' -Type 'LAB' -Num 5
ok ($eOther -and $eOther.Apps.Count -eq 19) 'a DIFFERENT room in bldg 55 still gets the catch-all ENG set'

'--- status colour semantics (2026-08-19 model: programs + GP/CM) ---'
# GREEN needs programs present AND GP+CM both run.
$bareGC = @{ Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList); GpOk=$true; CmOk=$true }
ok ((Get-FleetMachineStatus -Rec $bareGC -Expected $e75).State -eq 'green') 'nothing required + GP+CM run reads GREEN'
# Programs present (or none required) but GP/CM not run -> PURPLE.
$barePurple = @{ Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList); GpOk=$false; CmOk=$false }
ok ((Get-FleetMachineStatus -Rec $barePurple -Expected $e75).State -eq 'purple') 'programs OK but GP/CM not run reads PURPLE'
# A required program missing -> YELLOW (gp/cm irrelevant).
ok ((Get-FleetMachineStatus -Rec $barePurple -Expected $e20).State -eq 'yellow') 'a required program missing reads YELLOW'
# Fully installed + GP+CM -> GREEN; missing a GP run -> PURPLE.
$full = @{ Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList); GpOk=$true; CmOk=$true }
foreach ($a in $ENG) { $full.Installed[$a] = $true }
ok ((Get-FleetMachineStatus -Rec $full -Expected $e20).State -eq 'green') 'all programs present + GP+CM reads GREEN'
$fullNoGp = @{ Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList); GpOk=$false; CmOk=$true }
foreach ($a in $ENG) { $fullNoGp.Installed[$a] = $true }
ok ((Get-FleetMachineStatus -Rec $fullNoGp -Expected $e20).State -eq 'purple') 'all programs present but GP not run reads PURPLE'
# A failed install that left an EXPECTED app missing -> YELLOW (errors are no longer their own colour).
$errd = @{ Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList); GpOk=$true; CmOk=$true }
foreach ($a in $ENG) { if ($a -ne 'Vivado') { $errd.Installed[$a] = $true } }
[void]$errd.Failures.Add('Vivado E24 @ 07-28 14:02')
ok ((Get-FleetMachineStatus -Rec $errd -Expected $e20).State -eq 'yellow') 'a failed install (app still missing) reads YELLOW, not red'

'--- room-specific rule lookup (what Save-AssignRoom replaces) ---'
$mine = @(Get-AssignRoomRules -Building '55' -Room '103')
ok ($mine.Count -eq 2) "found the 2 room-specific rules, not the catch-all (got $($mine.Count))"

'--- synthetic profile for a machine whose rule owns its list ---'
$dec = @{ Matched=$true; Building='55'; Room='103'; Type='LAB'; Machine=20; BuildingAbbr='ENG' }
$pid2 = Register-AssignedProfile -Rule $script:RulesConfig.rules[0] -Decode $dec
ok ($pid2 -eq '_assigned_') 'returns the _assigned_ key'
ok ($script:RoomsConfig.rooms.'_assigned_'.apps.Count -eq 19) 'synthetic profile carries the 19 apps'
ok ($script:RoomsConfig.rooms.'_assigned_'.displayName -like 'ENG 103*') "label reads '$($script:RoomsConfig.rooms.'_assigned_'.displayName)'"

'--- splitting arithmetic (mirrors Split-AssignAt) ---'
$segs = @(@{From=1;To=90})
foreach ($at in 30,45,70,80) {
    $s = $segs | Where-Object { $at -ge $_.From -and $at -le $_.To } | Select-Object -First 1
    $tail = @{From=$at;To=$s.To}; $s.To = $at-1
    $l = New-Object System.Collections.ArrayList
    foreach ($x in $segs) { [void]$l.Add($x); if ($x -eq $s) { [void]$l.Add($tail) } }
    $segs = @($l)
}
ok ($segs.Count -eq 5) "4 splits -> 5 segments (got $($segs.Count))"
$cov = 0; foreach ($s in $segs) { $cov += ($s.To - $s.From + 1) }
ok ($cov -eq 90) "segments still cover all 90 machines exactly once (got $cov)"
ok (($segs | ForEach-Object { "$($_.From)-$($_.To)" }) -join ' ' -eq '1-29 30-44 45-69 70-79 80-90') 'boundaries land where clicked'

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
