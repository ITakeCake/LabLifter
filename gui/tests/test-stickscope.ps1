# Stick scoping: sizing, room grouping, slot/tombstone rules, fit verdicts.
#
# Covers the data layer behind per-stick room scoping (scripts\Lib-StickScope.ps1).
# The view can be rebuilt cheaply; getting these wrong ships a stick that is
# silently missing a card, so they are tested before any XAML exists.
#
#   1. sizing      - union-of-units, no double counting, no accidental parents
#   2. grouping    - identical card lists collapse; drift splits them again
#   3. slots       - tombstone vs delete, next-free-slot ordering
#   4. fit         - over / tight / ok, and the int64 overload regression
#   5. scope       - resolve to cards, room coverage, unscoped = everything
#
# READ-ONLY against real config. Slot tests use in-memory fixtures, never
# C:\LabDeployMaster, so running this cannot disturb the live fleet.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
. (Join-Path $LabRoot 'scripts\Lib-StickScope.ps1')
$script:LabRoot = $LabRoot

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

$src   = Get-ScopeSourceRoot -LabRootOverride $LabRoot
$apps  = Get-Content (Join-Path $LabRoot 'config\apps.json')  -Raw | ConvertFrom-Json
$rooms = Get-Content (Join-Path $LabRoot 'config\rooms.json') -Raw | ConvertFrom-Json
# STARTER-CONFIG GATE (2026-08-26): the public repo ships a starter config
# (one example room, ~0.4 GB of demo payloads). Checks that assert the full
# production fleet's SHAPE (specific science rooms, multi-GB images) skip
# there - the LOGIC they exercise is still covered by the fixture-driven
# checks that run either way.
$prodCfg = [bool]($rooms.rooms.PSObject.Properties['SCI2-142'])
function skipnote([string]$What) { Write-Host "  skip  $What (starter config)" }

$cfm   = Get-CardFolderMap -Apps $apps -SourceRoot $src
$units = @(); foreach ($k in $cfm.Keys) { $units += $cfm[$k] }
$units = @($units | Where-Object { $_ } | Sort-Object -Unique)
$fsm   = Get-FolderSizeMap -SourceRoot $src -Folders $units

Write-Host "`n--- 1. sizing ---"
ok ($cfm.Keys.Count -gt 60) "card->unit map covers the catalog ($($cfm.Keys.Count) cards)"

# every unit is tagged D: (folder) or F: (single file) - nothing untagged
$bad = @($units | Where-Object { $_ -notmatch '^[DF]:' })
ok ($bad.Count -eq 0) "every payload unit is tagged D: or F: ($($units.Count) units)"

# NO *FOLDER* UNIT MAY ESCAPE THE SOURCES ROOT. That is the catastrophic case:
# '..\pingplotter_install.exe' resolved its parent to Desktop\Installers and
# charged that one card 77 GB - the entire tree, counted again per card.
$rootFull = [System.IO.Path]::GetFullPath($src).TrimEnd('\')
function Test-Escapes([string]$u) {
    $rel = $u.Substring(2); if (-not $rel) { return $false }
    $full = try { [System.IO.Path]::GetFullPath((Join-Path $src $rel)).TrimEnd('\') } catch { $null }
    return ($full -and -not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase))
}
$escapedDirs = @($units | Where-Object { $_ -like 'D:*' -and (Test-Escapes $_) })
ok ($escapedDirs.Count -eq 0) "no FOLDER unit escapes the sources root (the 77 GB bug)"

# A FILE outside the root is not a sizing bug - it is sized correctly at its own
# length - but it IS a packaging problem: sync mirrors LabDeploy-InstallerSources,
# so a payload sitting beside that folder never reaches a stick. Reported, and
# deliberately not fatal, because the fix is to move the file, not change code.
$escapedFiles = @($units | Where-Object { $_ -like 'F:*' -and (Test-Escapes $_) })
if ($escapedFiles.Count) {
    Write-Host "NOTE  $($escapedFiles.Count) payload file(s) live OUTSIDE LabDeploy-InstallerSources and will not sync to sticks:" -ForegroundColor Yellow
    $escapedFiles | ForEach-Object { Write-Host "      $($_.Substring(2))" -ForegroundColor Yellow }
}
ok $true "file units outside the root are reported, not silently sized ($($escapedFiles.Count) found)"

# no unit IS the sources root - that would charge one card the whole payload
$isRoot = @($units | Where-Object { $_.Substring(2) -eq '' })
ok ($isRoot.Count -eq 0) "no card is sized as the entire sources root (was: LTSpice at root)"

# the union rule: two cards sharing one folder cost that folder once
$shared = $null
foreach ($a in $cfm.Keys) {
    foreach ($b in $cfm.Keys) {
        if ($a -ge $b) { continue }
        $ua = @($cfm[$a] | Where-Object { $_ -like 'D:*' })
        if (-not $ua.Count) { continue }
        if (@($cfm[$b]) -contains $ua[0]) { $shared = @($a, $b, $ua[0]); break }
    }
    if ($shared) { break }
}
if ($shared) {
    $one  = Get-ScopeSize -CardIds @($shared[0])            -CardFolderMap $cfm -FolderSizeMap $fsm
    $both = Get-ScopeSize -CardIds @($shared[0],$shared[1]) -CardFolderMap $cfm -FolderSizeMap $fsm
    ok ($both.Bytes -eq $one.Bytes) "two cards sharing '$($shared[2])' cost it once ($($shared[0])+$($shared[1]))"
} else { ok $true "no shared-folder pair in catalog - union rule vacuously holds" }

# total must be a believable payload, not a multiple-counted fantasy
$total = 0; foreach ($k in $fsm.Keys) { $total += $fsm[$k] }
if ($prodCfg) { ok ($total -gt 10GB -and $total -lt 200GB) "total payload is plausible ($([math]::Round($total/1GB,1)) GB)" } else { skipnote 'payload plausibility' }

# selecting everything can never exceed the measured total
$allIds = @($apps.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
$allSz  = Get-ScopeSize -CardIds $allIds -CardFolderMap $cfm -FolderSizeMap $fsm
ok ($allSz.Bytes -le $total) "whole-catalog scope <= measured total (no double count)"

Write-Host "`n--- 2. room grouping ---"
$profs = Get-RoomProfiles -Rooms $rooms -Apps $apps -CardFolderMap $cfm -FolderSizeMap $fsm
if ($prodCfg) { ok ($profs.Count -gt 0) "profiles built ($($profs.Count) from $(@($rooms.rooms.PSObject.Properties).Count) rooms)" } else { skipnote 'profile grouping (needs science rooms)' }

$roomsInProfiles = @(); foreach ($p in $profs) { $roomsInProfiles += $p.Rooms }
$declared = @($rooms.rooms.PSObject.Properties | Where-Object { @($_.Value.apps).Count } | ForEach-Object { $_.Name })
ok (@($declared | Where-Object { $roomsInProfiles -notcontains $_ }).Count -eq 0) "every room with cards lands in exactly one profile"
ok ((@($roomsInProfiles).Count) -eq (@($roomsInProfiles | Sort-Object -Unique).Count)) "no room appears in two profiles"

# the two known merges
$m1 = @($profs | Where-Object { $_.Rooms -contains 'SCI2-142' })
if ($prodCfg) { ok ($m1.Count -eq 1 -and $m1[0].Rooms.Count -eq 3) "SCI2 142/143/145 collapse into one profile" } else { skipnote 'SCI2 collapse' }
$m2 = @($profs | Where-Object { $_.Rooms -contains 'SCI1-310' })
if ($prodCfg) { ok ($m2.Count -eq 1 -and $m2[0].Rooms.Count -eq 3) "SCI1 310/311/316 collapse into one profile" } else { skipnote 'SCI1 collapse' }
if ($prodCfg) { ok ($m1[0].Label -eq 'SCI2 142 / 143 / 145') "merged label reads '$($m1[0].Label)'" } else { skipnote 'merged label' }

# DRIFT MUST SPLIT THE GROUP - the property that makes grouping self-maintaining
$fake = [pscustomobject]@{ rooms = [pscustomobject]@{
    'X-1' = [pscustomobject]@{ apps = @('ImageJ','JASP') }
    'X-2' = [pscustomobject]@{ apps = @('ImageJ','JASP') }
    'X-3' = [pscustomobject]@{ apps = @('ImageJ','JASP','R') } } }
$fp = Get-RoomProfiles -Rooms $fake -Apps $apps -CardFolderMap $cfm -FolderSizeMap $fsm
ok ($fp.Count -eq 2) "a room that drifts splits out of its group (2 profiles from 3 rooms)"

$single = Get-ProfileLabel -RoomNames @('SCI2-349')
ok ($single -eq 'SCI2 349') "single-room label is plain ('$single')"
$mixed = Get-ProfileLabel -RoomNames @('SCI1-111','ENG')
ok ($mixed -match ',') "unrelated rooms are listed, not falsely merged ('$mixed')"

Write-Host "`n--- 3. slots ---"
$ledger = @{
    'id-a' = [pscustomobject]@{ label='LabDeploy-01'; sizeGB=32;  lastSeen='2026-08-01 09:00:00'; lastSynced='2026-08-01 09:00:00' }
    'id-b' = [pscustomobject]@{ label='LabDeploy-02'; sizeGB=64;  lastSeen='2026-08-02 09:00:00'; lastSynced='2026-08-02 09:00:00' }
    'id-c' = [pscustomobject]@{ label='LabDeploy-04'; sizeGB=233; lastSeen='2026-08-03 09:00:00'; lastSynced='2026-08-03 09:00:00' }
}
$reg = @{ slots = @{}; version = 1 }
$slots = Merge-StickSlots -Ledger $ledger -Registry $reg
ok (@($slots).Count -eq 4) "slots run 1..highest with the gap included (got $(@($slots).Count))"
ok (($slots | Where-Object { $_.Slot -eq 3 }).State -eq 'FREE') "slot 3 with no stick and no record reads FREE"
ok (($slots | Where-Object { $_.Slot -eq 4 }).State -eq 'ACTIVE') "slot 4 is ACTIVE"
ok ((Get-NextFreeSlot -Slots $slots) -eq 3) "next free slot is the lowest hole (3), not highest+1"

# duplicate labels - two physical sticks, same number. Newest wins the slot.
$dup = @{
    'old-07' = [pscustomobject]@{ label='LabDeploy-07'; sizeGB=233; lastSeen='2026-08-04 16:10:24' }
    'new-07' = [pscustomobject]@{ label='LabDeploy-07'; sizeGB=233; lastSeen='2026-08-06 15:35:41' }
}
$ds = Merge-StickSlots -Ledger $dup -Registry @{ slots=@{}; version=1 }
$s7 = $ds | Where-Object { $_.Slot -eq 7 }
ok ($s7.DriveId -eq 'new-07') "when one slot has two sticks, the most recently seen wins"
ok (@($s7.PriorOccupants) -contains 'old-07') "the replaced stick is kept as a prior occupant, not dropped"

# THE TRAILING RULE
$reg2 = @{ slots = @{}; version = 1 }
$act = Remove-StickSlot -Registry $reg2 -Slots $slots -Slot 4 -Label 'LabDeploy-04' -CapacityGB 233 -Scope $null
ok ($act -eq 'DELETED') "retiring the HIGHEST slot deletes it outright (no tombstone)"
ok (-not $reg2.slots.ContainsKey('4')) "no registry entry left behind for a deleted trailing slot"

$reg3 = @{ slots = @{}; version = 1 }
$act2 = Remove-StickSlot -Registry $reg3 -Slots $slots -Slot 2 -Label 'LabDeploy-02' -CapacityGB 64 -Scope $null
ok ($act2 -eq 'TOMBSTONED') "retiring a slot below the highest leaves a tombstone"
ok ($reg3.slots.ContainsKey('2')) "tombstone is recorded in the registry"
ok ($reg3.slots['2'].retiredLabel -eq 'LabDeploy-02') "tombstone remembers what it was"

$ledger2 = @{}; foreach ($k in $ledger.Keys) { if ($k -ne 'id-b') { $ledger2[$k] = $ledger[$k] } }
$slots2 = Merge-StickSlots -Ledger $ledger2 -Registry $reg3
ok ((($slots2 | Where-Object { $_.Slot -eq 2 }).State) -eq 'TOMBSTONE') "the retired slot renders as TOMBSTONE"
ok ((Get-NextFreeSlot -Slots $slots2) -eq 2) "Initialize offers the tombstoned slot before any higher number"

Write-Host "`n--- 3b. slot numbers must be INTEGERS ---"
# REGRESSION, 2026-08-07. Measure-Object returns its Maximum as a Double, so
# Get-NextFreeSlot handed back 14.0 on a full fleet. '{0:D2}' is the
# integer-only decimal specifier and throws "Format specifier was invalid" on a
# double - which killed the entire Initialize picker before it could be shown.
# Every slot number that reaches a D2 format must therefore be an int.
$fullFleet = @{}
1..13 | ForEach-Object { $fullFleet["id-$_"] = [pscustomobject]@{ label = ('LabDeploy-{0:D2}' -f $_); sizeGB = 233; lastSeen = '2026-08-01 09:00:00' } }
$fullSlots = Merge-StickSlots -Ledger $fullFleet -Registry @{ slots=@{}; version=1 }
ok (@($fullSlots | Where-Object { $_.State -ne 'ACTIVE' }).Count -eq 0) 'fixture has no free slots (the case that broke it)'

$next = Get-NextFreeSlot -Slots $fullSlots
ok ($next -is [int]) "Get-NextFreeSlot returns an int on a full fleet (got $($next.GetType().Name))"
ok ($next -eq 14) "and it is highest+1 ($next)"

$fmtOk = $true; $fmtErr = ''
try { $null = '#{0:D2} (new)' -f $next } catch { $fmtOk = $false; $fmtErr = $_.Exception.Message }
ok $fmtOk "the slot number survives '{0:D2}' formatting$(if(-not $fmtOk){" - $fmtErr"})"

$nextHole = Get-NextFreeSlot -Slots $slots
ok ($nextHole -is [int]) "Get-NextFreeSlot returns an int when a hole exists too"

# every Slot property Merge-StickSlots emits must format cleanly
$allFmt = $true
foreach ($s in $fullSlots) { try { $null = '{0:D2}' -f $s.Slot } catch { $allFmt = $false } }
ok $allFmt 'every Slot from Merge-StickSlots formats with D2'

$regT = @{ slots=@{}; version=1 }
$actT = Remove-StickSlot -Registry $regT -Slots $fullSlots -Slot 13 -Label 'LabDeploy-13' -CapacityGB 233 -Scope $null
ok ($actT -eq 'DELETED') 'Remove-StickSlot still identifies the highest slot with an int comparison'

Write-Host "`n--- 4. fit ---"
$f1 = Test-ScopeFits -Bytes ([int64]20GB) -CapacityGB 8
ok (-not $f1.Fits -and $f1.Verdict -eq 'OVER') "20 GB on an 8 GB stick is refused"
$f2 = Test-ScopeFits -Bytes ([int64]2GB) -CapacityGB 32
ok ($f2.Fits -and $f2.Verdict -eq 'OK') "2 GB on a 32 GB stick fits"
$f3 = Test-ScopeFits -Bytes ([int64]31GB) -CapacityGB 32
ok ($f3.Fits -and $f3.Verdict -eq 'TIGHT') "31 GB on a 32 GB stick fits but is flagged TIGHT"
# regression: [math]::Max picked the Int32 overload and threw on any real drive
$f4 = Test-ScopeFits -Bytes ([int64]10GB) -CapacityGB 233.1
ok ($f4.Fits -and $f4.Verdict -eq 'OK') "233 GB drive does not throw on the headroom calculation"
$f5 = Test-ScopeFits -Bytes ([int64]1GB) -CapacityGB 0
ok (-not $f5.Fits -and $f5.Verdict -eq 'UNKNOWN') "unknown capacity refuses rather than guessing"

Write-Host "`n--- 5. scope resolution ---"
$allCards = Resolve-ScopeCards -Scope $null -Rooms $rooms -Apps $apps
ok ($allCards.Count -eq $allIds.Count) "no scope = the whole catalog (existing sticks keep working)"
$modeAll = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='all' }) -Rooms $rooms -Apps $apps
ok ($modeAll.Count -eq $allIds.Count) "mode 'all' = the whole catalog"

$rs = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='rooms'; rooms=@('SCI2-142','SCI2-349') }) -Rooms $rooms -Apps $apps
$expect = @(@($rooms.rooms.'SCI2-142'.apps) + @($rooms.rooms.'SCI2-349'.apps) | Sort-Object -Unique)
ok ($rs.Count -eq $expect.Count) "mode 'rooms' unions the rooms' cards ($($rs.Count))"

$ps = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='programs'; cards=@('LabChart','ImageJ','NoSuchCard') }) -Rooms $rooms -Apps $apps
ok ($ps.Count -eq 2 -and $ps -contains 'LabChart') "mode 'programs' takes the list and drops unknown ids"

$cov = Get-RoomCoverage -RoomName 'SCI2-142' -Rooms $rooms -StickCards $rs
if ($prodCfg) { ok ($cov.Complete) "a stick scoped to SCI2-142 fully covers SCI2-142" } else { skipnote 'scoped coverage' }
$cov2 = Get-RoomCoverage -RoomName 'SCI2-249A' -Rooms $rooms -StickCards $rs
if ($prodCfg) { ok (-not $cov2.Complete -and $cov2.Missing.Count -gt 0) "the same stick reports SCI2-249A as partially covered" } else { skipnote 'partial coverage' }
if ($prodCfg) { ok ($cov2.Text -match 'not on this stick') "partial coverage says 'not on this stick', not 'failed'" } else { skipnote 'coverage wording' }

Write-Host "`n--- 6. sync exclusions ---"
# What robocopy /XD receives for a stick scoped to the SCI2 biology cart.
$bioScope = [pscustomobject]@{ mode='rooms'; rooms=@('SCI2-142','SCI2-143','SCI2-145') }
$bioCards = Resolve-ScopeCards -Scope $bioScope -Rooms $rooms -Apps $apps
$excl = Get-ScopeExcludeDirs -CardIds $bioCards -CardFolderMap $cfm -SourceRoot $src
ok ($excl.Count -gt 0) "a scoped stick excludes something ($($excl.Count) folders)"

# COMMAND-LINE BUDGET, regression 2026-08-07. A folder kept in its entirety was
# still being descended into, so every child was excluded individually -
# VS_Layout alone added hundreds. Slot 14 produced 397 exclusions / 70,081
# characters of /XD, past the 32,767 Windows process limit, and robocopy simply
# never started: zero-byte log, untouched drive, no error anywhere.
$worst = 0; $worstName = ''
foreach ($p in $profs) {
    $c = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='rooms'; rooms=$p.Rooms }) -Rooms $rooms -Apps $apps
    $e = Get-ScopeExcludeDirs -CardIds $c -CardFolderMap $cfm -SourceRoot $src -FullPath
    $chars = 0; foreach ($d in $e) { $chars += $d.Length + 3 }
    if ($chars -gt $worst) { $worst = $chars; $worstName = $p.Label }
}
ok ($worst -lt 24000) "worst-case scope fits the command line ($worstName, $worst chars, limit 32767)"

# a folder kept whole must never have its children listed
$vepCards = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='rooms'; rooms=@('ENG') }) -Rooms $rooms -Apps $apps
$vepExcl  = Get-ScopeExcludeDirs -CardIds $vepCards -CardFolderMap $cfm -SourceRoot $src
$keptWhole = @()
foreach ($c in $vepCards) { foreach ($u in @($cfm[$c])) { if ($u -and $u.StartsWith('D:')) { $keptWhole += $u.Substring(2) } } }
$descended = @($vepExcl | Where-Object { $x = $_; @($keptWhole | Where-Object { $x.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) }).Count })
ok ($descended.Count -eq 0) "no child of a wholly-kept folder is excluded ($($descended.Count) found)"
ok ($vepExcl.Count -lt 60) "ENG scope stays compact ($($vepExcl.Count) exclusions, was 397)"

# NOTHING MAY BE BOTH KEPT AND EXCLUDED - that would delete a payload the stick needs
$keptRel = @()
foreach ($c in $bioCards) { foreach ($u in @($cfm[$c])) { if ($u -and $u.StartsWith('D:')) { $keptRel += $u.Substring(2) } } }
$keptRel = @($keptRel | Sort-Object -Unique)
$clash = @($keptRel | Where-Object { $excl -contains $_ })
ok ($clash.Count -eq 0) "no folder is both kept and excluded"

# and no excluded folder may be a PARENT of something kept, which /MIR would
# delete on the way past
$parentClash = @()
foreach ($e in $excl) {
    foreach ($k in $keptRel) { if ($k.StartsWith("$e\", [StringComparison]::OrdinalIgnoreCase)) { $parentClash += "$e > $k" } }
}
ok ($parentClash.Count -eq 0) "no excluded folder is an ancestor of a kept one"

# every card in scope still resolves to a folder that survives
$survives = $true
foreach ($c in $bioCards) {
    foreach ($u in @($cfm[$c])) {
        if (-not $u -or -not $u.StartsWith('D:')) { continue }
        $rel = $u.Substring(2)
        foreach ($e in $excl) {
            if ($rel -eq $e -or $rel.StartsWith("$e\", [StringComparison]::OrdinalIgnoreCase)) { $survives = $false }
        }
    }
}
ok $survives "every in-scope card's payload survives the exclusion list"

# an UNSCOPED stick must exclude nothing
$allExcl = Get-ScopeExcludeDirs -CardIds $allIds -CardFolderMap $cfm -SourceRoot $src
$allKept = @()
foreach ($c in $allIds) { foreach ($u in @($cfm[$c])) { if ($u -and $u.StartsWith('D:')) { $allKept += $u.Substring(2) } } }
$allKept = @($allKept | Sort-Object -Unique)
$badAll = @($allKept | Where-Object { $allExcl -contains $_ })
ok ($badAll.Count -eq 0) "whole-catalog scope excludes no folder any card needs"

# and it must actually save space, or the feature is pointless
$bioSz = Get-ScopeSize -CardIds $bioCards -CardFolderMap $cfm -FolderSizeMap $fsm
ok ($bioSz.Bytes -lt $total * 0.5) "bio-only stick carries under half the catalog ($(Format-ScopeSize $bioSz.Bytes) of $(Format-ScopeSize $total))"

Write-Host "`n--- 7. dependency closure + keep-unit promotion (regressions 2026-08-12) ---"
# THE ROCKWELL BUG. DotNet35 and VSIsoShell2015 exist in no room list - they are
# reachable only through RockwellCCW's install.requires. The room-derived ENG
# scope missed them, the sync excluded their folders, and Rockwell died with E67
# on every ENG-only stick while its own 8 GB DVD sat right there.
if ($prodCfg) { ok ($vepCards -contains 'RockwellCCW') "fixture check: ENG includes RockwellCCW" } else { skipnote 'Rockwell fixture' }
if ($prodCfg) { ok ($vepCards -contains 'DotNet35') "scope pulls in DotNet35 via RockwellCCW's requires chain" } else { skipnote 'requires chain 1' }
if ($prodCfg) { ok ($vepCards -contains 'VSIsoShell2015') "scope pulls in VSIsoShell2015 via RockwellCCW's requires chain" } else { skipnote 'requires chain 2' }
ok (($vepExcl -notcontains 'DotNet35') -and ($vepExcl -notcontains 'VSIsoShell2015')) "neither prerequisite folder is excluded from a ENG stick"

# closure must be TRANSITIVE and must survive a cycle without hanging
$fixApps = [pscustomobject]@{ apps = [pscustomobject]@{
    A = [pscustomobject]@{ install = [pscustomobject]@{ requires = @('B') } }
    B = [pscustomobject]@{ install = [pscustomobject]@{ requires = 'C' } }   # string form, on purpose
    C = [pscustomobject]@{ install = [pscustomobject]@{ requires = @('A') } } # and a cycle back to A
    D = [pscustomobject]@{ install = [pscustomobject]@{ } }
} }
$fixRooms = [pscustomobject]@{ rooms = [pscustomobject]@{ R1 = [pscustomobject]@{ apps = @('A') } } }
$closed = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='rooms'; rooms=@('R1') }) -Rooms $fixRooms -Apps $fixApps
ok ($closed.Count -eq 3 -and $closed -contains 'C' -and $closed -notcontains 'D') "requires closure is transitive, string-or-array, and cycle-safe"
$closedP = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='programs'; cards=@('A') }) -Rooms $fixRooms -Apps $fixApps
ok ($closedP.Count -eq 3) "mode 'programs' gets the same closure"

# THE VIVADO BUG. sourceSub 'VivadoImage\bin\xsetup.bat' made the keep unit
# VivadoImage\bin, so a scoped stick carried the launcher and excluded the
# 18.4 GB payload\ it installs from. offload copies the whole first segment,
# so the stick's unit must be the whole first segment too.
if ($prodCfg) { ok (@($cfm['Vivado']) -contains 'D:VivadoImage') "Vivado's keep unit is the whole VivadoImage (offload promotion)" } else { skipnote 'Vivado keep unit' }
ok (@($cfm['RockwellCCW'])[0] -match '^D:Rockwell') "Rockwell's keep unit is its whole top-level folder (sole-owner promotion)"
ok (@($cfm['LabChart']) -contains 'D:Science\labchart') "a card in a SHARED folder is not promoted (Science still scopes per-app)"
$vivSz = Get-ScopeSize -CardIds @('Vivado') -CardFolderMap $cfm -FolderSizeMap $fsm
if ($prodCfg) { ok ($vivSz.Bytes -gt 10GB) "Vivado sizes as the full image, not just bin\ ($(Format-ScopeSize $vivSz.Bytes))" } else { skipnote 'Vivado image size' }

# INFRASTRUCTURE FOLDERS. WingetBootstrap is read by the GUI itself (E64), not
# by any card - no scope may drop it.
$tinyCards = Resolve-ScopeCards -Scope ([pscustomobject]@{ mode='programs'; cards=@('LabChart') }) -Rooms $rooms -Apps $apps
$tinyExcl  = Get-ScopeExcludeDirs -CardIds $tinyCards -CardFolderMap $cfm -SourceRoot $src
ok ($tinyExcl -notcontains 'WingetBootstrap') "WingetBootstrap survives even a one-card scope"

Write-Host ""
Write-Host "stick scope: $pass passed, $fail failed"
if ($fail) { exit 1 }
