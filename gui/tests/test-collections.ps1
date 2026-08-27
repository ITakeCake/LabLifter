# Guard against the collection-unrolling family of bug, which has now bitten
# this file FOUR times. Two opposite hazards, and the fix for one causes the
# other, so both directions are checked here.
#
#   A. `return $collection`      -> PowerShell ENUMERATES it. 0 items become
#                                   $null, 1 item becomes a bare scalar.
#                                   Callers MUST wrap: @(f)
#   B. `return ,@($collection)`  -> survives assignment intact at any count.
#                                   Callers must NOT wrap: @(f) NESTS it into
#                                   a single element that is the whole list.
#
# This test reads the real source, finds which convention each function uses,
# then checks every call site obeys the matching rule.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$src = Get-Content $f -Raw
$lines = Get-Content $f

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }

'--- language behaviour these rules rest on ---'
function retPlain { $a = New-Object System.Collections.ArrayList; [void]$a.Add(1); return $a }
function retComma { $a = New-Object System.Collections.ArrayList; [void]$a.Add(1); [void]$a.Add(2); return ,@($a) }
function retCommaEmpty { $a = New-Object System.Collections.ArrayList; return ,@($a) }
$p = retPlain
ok ($p -isnot [array]) 'plain return of a 1-item list collapses to a scalar (hazard A confirmed)'
ok ((@(retPlain)).Count -eq 1) 'plain return + @() wrap = correct'
$c = retComma
ok ($c.Count -eq 2) 'comma return survives assignment at 2 items'
ok ((@(retComma)).Count -eq 1) 'comma return + @() wrap NESTS (hazard B confirmed)'
$ce = retCommaEmpty
ok ($ce.Count -eq 0) 'comma return of an EMPTY list assigns as a 0-count array'

'--- every comma-returning function must not be @()-wrapped at its call sites ---'
$commaFns = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*return\s*,@\(') {
        # walk back to the enclosing function name
        for ($j = $i; $j -ge 0; $j--) {
            if ($lines[$j] -match '^\s*function\s+([A-Za-z][\w-]*)') { $commaFns += $Matches[1]; break }
        }
    }
}
$commaFns = @($commaFns | Select-Object -Unique)
"  (comma-returning functions: $($commaFns -join ', '))"
foreach ($fn in $commaFns) {
    $bad = @([regex]::Matches($src, "@\(\s*$([regex]::Escape($fn))\b"))
    ok ($bad.Count -eq 0) "$fn is never wrapped in @() at a call site$(if($bad.Count){" -- $($bad.Count) offending site(s)"})"
}

'--- plain-returning collection functions MUST be @()-wrapped or assigned safely ---'
# Get-AssignRoomList / Get-CoverageSegments return plain; their call sites wrap.
foreach ($pair in @(
    @{ fn = 'Get-AssignRoomList'; site = '\$script:AS\.Rooms = @\(Get-AssignRoomList\)' },
    @{ fn = 'Get-CoverageBuildings'; site = '\$blds\s+= @\(Get-CoverageBuildings\)' },
    @{ fn = 'Get-CoverageSegments';  site = '\$segs = @\(Get-CoverageSegments ' }
)) {
    ok ([bool]([regex]::Match($src, $pair.site)).Success) "$($pair.fn) call site keeps its @() wrap"
}
# EVERY Get-CoverageSegments call site, not just the first: this function feeds
# both the room cards and the segment strip, and an unwrapped one would hand
# back a bare hashtable for a room with a single segment.
# (?!\s*#) skips COMMENT lines: prose that merely names the function is not a
# call site, and flagging it would push people toward rewording their comments
# to appease a regex - which is how a real guard turns into a nuisance nobody
# trusts. Only lines that could actually be code are checked.
foreach ($m in [regex]::Matches($src, '(?m)^(?!\s*function\s)(?!\s*#).{0,40}Get-CoverageSegments')) {
    ok ($m.Value -match '@\(Get-CoverageSegments') "wrapped: $($m.Value.Trim())"
}

'--- the specific functions that were broken, now exercised for real ---'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (@('Get-LabDeployTempItems','Get-RoomScanIds') -contains $d.Name) { Invoke-Expression $d.Extent.Text }
}
$script:OffloadRoot = Join-Path $env:SystemDrive 'LabDeployOffload_Temp'
$items = Get-LabDeployTempItems
$typesOk = $true
foreach ($i in $items) { if ($i.Path -isnot [string] -or $i.Bytes -isnot [long]) { $typesOk = $false } }
ok $typesOk "Get-LabDeployTempItems yields flat items with String Path / Int64 Bytes ($(@($items).Count) found)"
$sum = 0; foreach ($i in $items) { $sum += [int64]$i.Bytes }
ok ($sum -ge 0) "byte totals are arithmetic-safe (total $sum) - the op_Division crash cannot recur"

# requires-closure: string form, array form, and a cycle
$appsObj = New-Object psobject
foreach ($a in 'A','B','C','D') { $appsObj | Add-Member -NotePropertyName $a -NotePropertyValue ([pscustomobject]@{ displayName = $a }) }
$appsObj.A | Add-Member install ([pscustomobject]@{ requires = @('B','C') })
$appsObj.B | Add-Member install ([pscustomobject]@{ requires = 'D' })
$appsObj.D | Add-Member install ([pscustomobject]@{ requires = @('A') })   # cycle
$script:AppsConfig = [pscustomobject]@{ apps = $appsObj }
$ids = Get-RoomScanIds -AppIds @('A')
ok (@($ids).Count -eq 4) "closure walks array+string forms and survives a cycle (got $(@($ids).Count), want 4)"
$flat = $true; foreach ($x in $ids) { if ($x -isnot [string]) { $flat = $false } }
ok $flat 'closure returns flat strings, not a nested array'

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
