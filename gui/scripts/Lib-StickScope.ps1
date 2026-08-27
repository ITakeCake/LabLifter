<#
    Lib-StickScope.ps1
    ==================
    Data layer for per-stick scoping: which rooms/programs a stick carries, how
    big that is, and which slot number it occupies.

    NO UI, NO WRITES TO CONFIG. Pure functions plus a single registry file, so
    the whole thing is testable on the master before any XAML changes. Dot-source
    it; the GUI and the CLI sync scripts share it the way Lib-PayloadManifest.ps1
    is shared today.

    THE FOUR PROBLEMS THIS SOLVES
      1. Sizing that does not lie. Naively summing each card's folder
         double-counts: LTSpice and WaveForms both live under Updated-Files and
         a per-card sum reported 66 GB each, 132 GB for two cards that together
         occupy 66 GB. Scope size is therefore computed over the UNION OF
         FOLDERS, which is also exactly what robocopy will copy.
      2. Room collapsing. Rooms with byte-identical card lists are one choice,
         computed from the lists themselves so drift splits the group instead of
         hiding in it.
      3. Slots. Stick numbers are positions, not a counter. Retiring #10 while
         #11 exists leaves a hole that the next stick fills.
      4. Fit. A selection that does not fit the drive must be refused before
         anything is written.
#>

# ---------------------------------------------------------------- paths -----
# DERIVED, never hard-coded: this has to run from a stick, a second PC, or a
# clone under any username - same rule the test suites follow.
if (-not $script:LabRoot) { $script:LabRoot = Split-Path $PSScriptRoot -Parent }
$script:ScopeMasterRoot   = 'C:\LabDeployMaster'
$script:StickSlotFile     = Join-Path $script:ScopeMasterRoot 'stick-slots.json'

function Get-ScopeConfigPath { param([string]$Name) Join-Path (Join-Path $script:LabRoot 'config') $Name }

# Payload root sits beside the program folder, not inside it.
function Get-ScopeSourceRoot {
    param([string]$LabRootOverride)
    $lr = if ($LabRootOverride) { $LabRootOverride } else { $script:LabRoot }
    Join-Path (Split-Path $lr -Parent) 'LabDeploy-InstallerSources'
}

# ============================================================ sizing =========
<#
    Get-CardFolderMap
    Returns @{ cardId = @(folder1, folder2...) } - the payload FOLDERS a card
    needs, relative to the sources root.

    WHY FOLDERS AND NOT FILES. A card's sourceSub may be a lone .exe sitting in
    a directory shared with other cards, or a .bat wrapper that depends on every
    sibling beside it (Install-LoggerPro.bat needs the three LoggerPro exes;
    Install-RavenLite.bat needs the JRE and the registration file). There is no
    reliable way to know which siblings a wrapper reads without executing it, so
    the honest unit is the folder. Sync copies folders anyway.
#>
function Get-CardFolderMap {
    param($Apps, [string]$SourceRoot)
    $map = @{}
    $rootFull = try { [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\') } catch { $SourceRoot }
    # Which cards live under each TOP-LEVEL sources folder. Needed below to
    # decide how much of that folder a single card may claim.
    $topOwners = @{}
    foreach ($p in $Apps.apps.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $sub = $p.Value.install.sourceSub
        if (-not $sub -or $sub.StartsWith('..')) { continue }
        $seg = ($sub -split '[\\/]')[0]
        if ($seg) {
            if (-not $topOwners.ContainsKey($seg)) { $topOwners[$seg] = @() }
            $topOwners[$seg] += $p.Name
        }
    }
    foreach ($p in $Apps.apps.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $sub = $p.Value.install.sourceSub
        if (-not $sub) { $map[$p.Name] = @(); continue }
        $full = Join-Path $SourceRoot $sub

        $unit = $null
        if (Test-Path -LiteralPath $full -PathType Container) {
            $unit = "D:$sub"
        } else {
            # FILE sourceSub. Its folder is the right unit ONLY when that folder is a
            # real subfolder of the sources root. Two cases break that and both are
            # live in this catalog:
            #   'LTspice64-26.0.2.msi'      -> parent is '' (the root itself). Sizing
            #                                  the root would charge one card 120 GB.
            #   '..\pingplotter_install.exe'-> parent is '..', i.e. Desktop\Installers,
            #                                  the parent of the sources root. This is
            #                                  what made PingPlotter and MbedStudio
            #                                  each measure 77 GB.
            # In both cases the honest unit is the single file.
            $parent = Split-Path $sub -Parent
            $kind = 'F'
            if ($parent) {
                $pFull = try { [System.IO.Path]::GetFullPath((Join-Path $SourceRoot $parent)).TrimEnd('\') } catch { $null }
                if ($pFull -and $pFull.Length -gt $rootFull.Length -and
                    $pFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $kind = 'D' }
            }
            $unit = if ($kind -eq 'D') { "D:$parent" } else { "F:$sub" }
        }

        # PROMOTE A NESTED UNIT TO ITS TOP-LEVEL FOLDER when the installer needs
        # siblings the nested unit would orphan. Vivado is the proof: sourceSub
        # 'VivadoImage\bin\xsetup.bat' made the unit 'VivadoImage\bin' (0 GB),
        # so a scoped stick excluded payload\ (18.4 GB), data\, lib\, tps\ -
        # carrying the launcher and nothing it installs from. Promote when:
        #   - install.offload is set: offload copies the WHOLE first path
        #     segment to local disk (Start-SingleInstall takes sourceSub's first
        #     segment), so the stick must carry that same unit; or
        #   - this card is the top-level folder's ONLY card: the folder is one
        #     product's image, and its internal layout is the vendor's business.
        # Shared folders (Science, MatlabImage, LabVIEW-Feed) never promote -
        # their second-level dirs are separate products and scoping inside them
        # is the whole point.
        if ($unit -and $unit.StartsWith('D:') -and $unit.Substring(2).Contains('\')) {
            $topSeg = ($unit.Substring(2) -split '\\')[0]
            $owners = if ($topOwners.ContainsKey($topSeg)) { @($topOwners[$topSeg]) } else { @() }
            if (($p.Value.install.offload -or $owners.Count -le 1) -and
                (Test-Path -LiteralPath (Join-Path $SourceRoot $topSeg) -PathType Container)) {
                $unit = "D:$topSeg"
            }
        }
        $map[$p.Name] = @($unit)
    }
    return $map
}

<#
    Get-FolderSizeMap
    Measures each UNIT once. Units are tagged 'D:<rel>' for a folder and
    'F:<rel>' for a single file, so two cards sharing a folder collapse to one
    measurement while two loose files at the root stay independent.

    Measured once and cached - walking the payload on every checkbox click is
    the difference between an instant UI and a multi-second stall.
#>
function Get-FolderSizeMap {
    param([string]$SourceRoot, [string[]]$Folders)
    $sizes = @{}
    foreach ($u in ($Folders | Sort-Object -Unique)) {
        if (-not $u) { continue }
        $kind = $u.Substring(0,1)
        $rel  = $u.Substring(2)
        $path = if ($rel) { Join-Path $SourceRoot $rel } else { $SourceRoot }
        if (-not (Test-Path -LiteralPath $path)) { $sizes[$u] = 0; continue }
        if ($kind -eq 'F') {
            $sizes[$u] = [int64](Get-Item -LiteralPath $path -Force).Length
        } else {
            $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            $sizes[$u] = [int64]($(if ($sum) { $sum } else { 0 }))
        }
    }
    return $sizes
}

<#
    Get-ScopeSize
    Bytes required for a set of card ids. Folders shared by several selected
    cards are counted ONCE - that is the whole point of this function.
#>
function Get-ScopeSize {
    param([string[]]$CardIds, [hashtable]$CardFolderMap, [hashtable]$FolderSizeMap)
    $folders = New-Object System.Collections.Generic.HashSet[string]
    foreach ($id in @($CardIds)) {
        if (-not $CardFolderMap.ContainsKey($id)) { continue }
        foreach ($f in @($CardFolderMap[$id])) { if ($f) { [void]$folders.Add($f) } }
    }
    $total = [int64]0
    foreach ($f in $folders) { if ($FolderSizeMap.ContainsKey($f)) { $total += [int64]$FolderSizeMap[$f] } }
    return @{ Bytes = $total; GB = [math]::Round($total / 1GB, 2); Folders = @($folders); CardCount = @($CardIds).Count }
}

function Format-ScopeSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -le 0)   { return '0 MB' }
    return '< 1 MB'
}

# ====================================================== room profiles ========
<#
    Get-RoomProfiles
    Collapses rooms whose card lists are IDENTICAL into one selectable profile.

    The key is the sorted card list, so this is self-maintaining: edit one room
    of a trio and the group splits by itself on next load, which also surfaces
    accidental drift that a hand-maintained grouping would hide.

    ALL-SCI and any other bundle profile is returned too but flagged IsBundle,
    because it is a convenience set rather than a physical room.
#>
function Get-RoomProfiles {
    param($Rooms, $Apps, [hashtable]$CardFolderMap, [hashtable]$FolderSizeMap)
    $byKey = @{}
    foreach ($p in $Rooms.rooms.PSObject.Properties) {
        $apps = @($p.Value.apps)
        if (-not $apps.Count) { continue }
        $key = ($apps | Sort-Object) -join '|'
        if (-not $byKey.ContainsKey($key)) {
            $byKey[$key] = [pscustomobject]@{
                Key = $key; Rooms = @(); Cards = @($apps | Sort-Object)
                Bytes = 0; Label = ''; IsBundle = $false
            }
        }
        $byKey[$key].Rooms += $p.Name
    }
    $out = @()
    foreach ($k in $byKey.Keys) {
        $prof = $byKey[$k]
        $prof.Rooms = @($prof.Rooms | Sort-Object)
        $sz = Get-ScopeSize -CardIds $prof.Cards -CardFolderMap $CardFolderMap -FolderSizeMap $FolderSizeMap
        $prof.Bytes = $sz.Bytes
        $prof.Label = Get-ProfileLabel -RoomNames $prof.Rooms
        # a "room" nobody can be standing in - ALL-SCI, ENG-wide sets
        $prof.IsBundle = ($prof.Rooms.Count -eq 1 -and $prof.Rooms[0] -match '^(ALL|EVERY)')
        $out += $prof
    }
    return @($out | Sort-Object @{E={$_.IsBundle}}, @{E={$_.Label}})
}

<#
    Get-ProfileLabel
    "SCI2-142","SCI2-143","SCI2-145"  ->  "SCI2 142 / 143 / 145"
    Only merges the tail when the prefix matches; unrelated rooms stay listed in
    full so a grouping is never implied where none exists.
#>
function Get-ProfileLabel {
    param([string[]]$RoomNames)
    $names = @($RoomNames)
    if ($names.Count -eq 1) { return ($names[0] -replace '-', ' ') }
    $prefixes = @($names | ForEach-Object { if ($_ -match '^(.*)-([^-]+)$') { $Matches[1] } else { $_ } } | Sort-Object -Unique)
    if ($prefixes.Count -eq 1) {
        $tails = @($names | ForEach-Object { if ($_ -match '^.*-([^-]+)$') { $Matches[1] } else { $_ } })
        return ('{0} {1}' -f $prefixes[0], ($tails -join ' / '))
    }
    return (($names | ForEach-Object { $_ -replace '-', ' ' }) -join ', ')
}

# ============================================================= slots =========
<#
    SLOT MODEL
    A slot is a position in the fleet, written on the physical stick's label.
    Slot numbers come from the stick label (LabDeploy-07 -> 7), so they already
    exist in the field - this formalises what the labels already mean.

    stick-slots.json holds the things a stick cannot record about itself:
        slots: { "7": { driveId, label, capacityGB, scope, retiredOn, retiredLabel } }
    A slot with retiredOn set and no driveId is a TOMBSTONE.

    THE TRAILING RULE. Retiring the highest slot deletes it outright - there is
    no hole to preserve, and leaving a tombstone at the end would make the fleet
    look permanently damaged. Retiring anything below the highest leaves a
    tombstone so the number is held for the replacement.
#>
function Get-SlotNumberFromLabel {
    param([string]$Label)
    if ($Label -match '(\d+)\s*$') { return [int]$Matches[1] }
    return $null
}

function Get-StickSlotRegistry {
    foreach ($cand in @($script:StickSlotFile, "$($script:StickSlotFile).bak")) {
        if (-not (Test-Path $cand)) { continue }
        try {
            $o = Get-Content $cand -Raw | ConvertFrom-Json
            $h = @{}
            foreach ($p in $o.slots.PSObject.Properties) { $h[$p.Name] = $p.Value }
            return @{ slots = $h; version = $o.version }
        } catch { }
    }
    return @{ slots = @{}; version = 1 }
}

# Same torn-file protection as Save-StickLedger: .bak, temp, then swap.
function Save-StickSlotRegistry {
    param([hashtable]$Registry)
    if (-not (Test-Path $script:ScopeMasterRoot)) { return $false }
    try {
        $slots = New-Object psobject
        foreach ($k in ($Registry.slots.Keys | Sort-Object { [int]$_ })) {
            Add-Member -InputObject $slots -MemberType NoteProperty -Name $k -Value $Registry.slots[$k]
        }
        $doc = [pscustomobject]@{ version = 1; slots = $slots }
        $json = $doc | ConvertTo-Json -Depth 8
        if (Test-Path $script:StickSlotFile) { Copy-Item $script:StickSlotFile "$($script:StickSlotFile).bak" -Force -ErrorAction SilentlyContinue }
        $tmp = "$($script:StickSlotFile).tmp"
        Set-Content $tmp $json -Encoding UTF8 -Force
        Move-Item $tmp $script:StickSlotFile -Force
        return $true
    } catch { return $false }
}

<#
    Merge-StickSlots
    Builds the display model: every slot from 1..highest, marked ACTIVE,
    TOMBSTONE or FREE, by folding the existing sticks.json ledger together with
    the slot registry.

    Reads sticks.json rather than replacing it - that ledger already carries
    firstSeen/lastSeen/lastSynced/manifestSignature and is written by the sync
    path. This adds slot and scope on top instead of forking the data.

    DUPLICATE LABELS ARE REAL: sticks.json currently holds two entries labelled
    LabDeploy-07 with different drive-ids - an old stick and its replacement.
    The most recently seen one wins the slot; the other is recorded as a prior
    occupant so the history is not silently dropped.
#>
function Merge-StickSlots {
    param([hashtable]$Ledger, [hashtable]$Registry)
    $bySlot = @{}
    foreach ($id in $Ledger.Keys) {
        $e = $Ledger[$id]
        $n = Get-SlotNumberFromLabel -Label "$($e.label)"
        if ($null -eq $n) { continue }
        $k = "$n"
        $seen = $null; try { if ($e.lastSeen) { $seen = [datetime]$e.lastSeen } } catch { }
        if (-not $bySlot.ContainsKey($k)) { $bySlot[$k] = @() }
        $bySlot[$k] += [pscustomobject]@{ DriveId = $id; Entry = $e; LastSeen = $seen }
    }

    $slots = @()
    $numbers = @()
    foreach ($k in $bySlot.Keys)          { $numbers += [int]$k }
    foreach ($k in $Registry.slots.Keys)  { $numbers += [int]$k }
    if (-not $numbers.Count) { return @() }
    $highest = ($numbers | Measure-Object -Maximum).Maximum

    for ($n = 1; $n -le $highest; $n++) {
        $k = "$n"
        $reg = if ($Registry.slots.ContainsKey($k)) { $Registry.slots[$k] } else { $null }
        # ASSIGN THE ARRAY IN ITS OWN STATEMENT. Writing
        #     $occupants = if (...) { @(...) } else { @() }
        # unrolls a single-element array back to a bare PSCustomObject, whose
        # .Count is $null - so every slot silently read FREE even when a stick
        # was sitting in it. Caught by the slot tests, not by inspection.
        $occupants = @()
        if ($bySlot.ContainsKey($k)) { $occupants = @($bySlot[$k] | Sort-Object LastSeen -Descending) }
        $current = $null
        if ($occupants.Count -ge 1) { $current = $occupants[0] }
        $prior = @()
        if ($occupants.Count -gt 1) { $prior = @($occupants[1..($occupants.Count - 1)]) }

        $state =
            if ($reg -and $reg.retiredOn -and -not $current) { 'TOMBSTONE' }
            elseif ($current) { 'ACTIVE' }
            elseif ($reg -and $reg.retiredOn) { 'TOMBSTONE' }
            else { 'FREE' }

        $slots += [pscustomobject]@{
            Slot        = $n
            State       = $state
            DriveId     = if ($current) { $current.DriveId } else { $null }
            Label       = if ($current) { "$($current.Entry.label)" } elseif ($reg) { "$($reg.retiredLabel)" } else { $null }
            CapacityGB  = if ($current) { [double]$current.Entry.sizeGB } elseif ($reg) { [double]$reg.capacityGB } else { 0 }
            LastSeen    = if ($current) { "$($current.Entry.lastSeen)" } else { $null }
            LastSynced  = if ($current) { "$($current.Entry.lastSynced)" } else { $null }
            ManifestSig = if ($current) { "$($current.Entry.manifestSignature)" } else { $null }
            Scope       = if ($reg -and $reg.scope) { $reg.scope } else { $null }
            RetiredOn   = if ($reg) { "$($reg.retiredOn)" } else { $null }
            PriorOccupants = @($prior | ForEach-Object { $_.DriveId })
        }
    }
    return @($slots)
}

# The number Initialize should offer: lowest FREE or TOMBSTONE slot, else next up.
#
# RETURNS AN INT, DELIBERATELY CAST. Measure-Object hands back its Maximum as a
# System.Double, and a double formatted with '{0:D2}' throws "Format specifier
# was invalid" - D is the integer-only decimal specifier. That took down the
# whole Initialize picker on a fleet with no free slots, where the "(new)" entry
# was the only item in the list. Cast here so no caller has to remember.
function Get-NextFreeSlot {
    param([array]$Slots)
    foreach ($s in @($Slots | Sort-Object Slot)) {
        if ($s.State -eq 'FREE' -or $s.State -eq 'TOMBSTONE') { return [int]$s.Slot }
    }
    if (@($Slots).Count) { return [int](($Slots | Measure-Object -Property Slot -Maximum).Maximum) + 1 }
    return 1
}

<#
    Remove-StickSlot
    Retire a stick. Returns the action taken so the caller can phrase the toast:
      'DELETED'   - it was the highest slot, the row disappears entirely
      'TOMBSTONED'- something above it exists, so the number is held
#>
function Remove-StickSlot {
    param([hashtable]$Registry, [array]$Slots, [int]$Slot, [string]$Label, [double]$CapacityGB, $Scope)
    # [int] for the same reason as Get-NextFreeSlot - Measure-Object returns a Double.
    $highest = if (@($Slots).Count) { [int](($Slots | Measure-Object -Property Slot -Maximum).Maximum) } else { 0 }
    $k = "$Slot"
    if ($Slot -ge $highest) {
        if ($Registry.slots.ContainsKey($k)) { $Registry.slots.Remove($k) }
        return 'DELETED'
    }
    $Registry.slots[$k] = [pscustomobject]@{
        driveId = $null; label = $null
        retiredLabel = $Label; capacityGB = $CapacityGB
        retiredOn = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        scope = $Scope
    }
    return 'TOMBSTONED'
}

# ============================================================== fit ==========
<#
    Test-ScopeFits
    HEADROOM IS NOT OPTIONAL. A stick filled to the byte cannot take the next
    card added to the catalog, and FAT32/exFAT slack means the copied size is
    always a little larger than the sum of file lengths. 5% or 1 GB, whichever
    is larger, keeps a stick usable rather than merely valid today.
#>
function Test-ScopeFits {
    param([int64]$Bytes, [double]$CapacityGB)
    $cap = [int64]($CapacityGB * 1GB)
    if ($cap -le 0) { return @{ Fits = $false; Verdict = 'UNKNOWN'; Text = 'drive capacity unknown'; SpareBytes = 0 } }
    # BOTH args cast to int64 explicitly: [math]::Max(1GB, $cap*0.05) picks the
    # Int32 overload and throws on any drive over ~2 GB, because $cap*0.05 comes
    # back a double. Caught by the 233 GB case.
    $headroom = [int64][math]::Max([int64]1GB, [int64]($cap * 0.05))
    $spare = $cap - $Bytes
    if ($Bytes -gt $cap) {
        return @{ Fits = $false; Verdict = 'OVER'; SpareBytes = $spare
                  Text = ("won't fit - {0} over" -f (Format-ScopeSize ($Bytes - $cap))) }
    }
    if ($spare -lt $headroom) {
        return @{ Fits = $true; Verdict = 'TIGHT'; SpareBytes = $spare
                  Text = ('fits, but only {0} spare - no room to grow' -f (Format-ScopeSize $spare)) }
    }
    return @{ Fits = $true; Verdict = 'OK'; SpareBytes = $spare
              Text = ('fits - {0} spare' -f (Format-ScopeSize $spare)) }
}

<#
    Resolve-ScopeCards
    A stored scope -> the flat set of card ids to sync.
      scope.mode 'all'      : everything (and it TRACKS new cards automatically)
      scope.mode 'rooms'    : union of the named room profiles' cards
      scope.mode 'programs' : an explicit card list, nothing implied
    Unknown/absent scope falls back to 'all' - an unscoped stick keeps behaving
    exactly as it does today, so this feature cannot break existing sticks.
#>
function Resolve-ScopeCards {
    param($Scope, $Rooms, $Apps)
    $allCards = @($Apps.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
    if (-not $Scope -or -not $Scope.mode -or $Scope.mode -eq 'all') { return $allCards }
    $set = New-Object System.Collections.Generic.HashSet[string]
    if ($Scope.mode -eq 'programs') {
        foreach ($c in @($Scope.cards)) { if ($allCards -contains $c) { [void]$set.Add($c) } }
    } elseif ($Scope.mode -eq 'rooms') {
        foreach ($rn in @($Scope.rooms)) {
            $r = $Rooms.rooms.$rn
            if (-not $r) { continue }
            foreach ($c in @($r.apps)) { if ($allCards -contains $c) { [void]$set.Add($c) } }
        }
    } else {
        return $allCards
    }
    # DEPENDENCY CLOSURE. A scope is what the stick must be able to INSTALL, and
    # installing a card means installing its install.requires chain first. The
    # cards that exist only as someone's dependency are in no room list at all -
    # DotNet35 and VSIsoShell2015 exist purely so RockwellCCW can auto-install
    # them - so a room-derived set missed them, the sync excluded their folders,
    # and every Rockwell install off a ENG-only stick died with E67 before its
    # own 8 GB DVD (which WAS on the stick) got a look-in. Same walk as
    # Get-RoomScanIds: requires may be a string or an array, at card level or
    # under install. autoFollow is deliberately NOT walked here - followers'
    # payloads live inside their leader's folder, and pulling followers in by id
    # would cross-license room-specific cards (the Sci1/Sci2Bio licence split).
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($c in $set) { $queue.Enqueue($c) }
    while ($queue.Count -gt 0) {
        $def = $Apps.apps.($queue.Dequeue())
        if (-not $def) { continue }
        foreach ($dep in @(@($def.requires) + @($def.install.requires))) {
            if (-not $dep) { continue }
            $dd = $Apps.apps.$dep
            if (-not $dd -or $dd.disabled) { continue }
            if ($set.Add([string]$dep)) { $queue.Enqueue([string]$dep) }
        }
    }
    return @($set)
}

<#
    Get-ScopeExcludeDirs
    The payload folders a scoped stick must NOT receive, as paths relative to
    the sources root. Feeds robocopy /XD.

    EXCLUDE-WHAT-IS-NOT-KEPT, rather than include-what-is. NOTE the honest
    consequence: a payload folder no card references IS excluded from a scoped
    stick (an unscoped stick still mirrors everything). Folders the PROGRAM
    reads directly - not via any card - are pinned in $infraKeep below, because
    no card audit can protect them: WingetBootstrap is read by the winget
    bootstrap path (E64) for every winget-method card.

    Descends only as far as it must: a top-level folder with nothing kept inside
    is excluded whole, otherwise its children are considered individually. That
    keeps the /XD list short - robocopy takes every one as a separate operand.
#>
function Get-ScopeExcludeDirs {
    param([string[]]$CardIds, [hashtable]$CardFolderMap, [string]$SourceRoot, [switch]$FullPath)
    $keep = New-Object System.Collections.Generic.HashSet[string]
    # Read by Deploy-LabGUI.ps1 itself (Join-Path $script:SourceRoot ...), so no
    # scope may drop them. Keep this list in sync with any new code-side reads.
    foreach ($infra in @('WingetBootstrap')) { [void]$keep.Add($infra) }
    foreach ($c in @($CardIds)) {
        if (-not $CardFolderMap.ContainsKey($c)) { continue }
        foreach ($u in @($CardFolderMap[$c])) {
            if ($u -and $u.StartsWith('D:')) { [void]$keep.Add($u.Substring(2)) }
        }
    }
    # A folder kept IN ITS ENTIRETY must not be descended into. The first version
    # did, and excluded every child of every kept folder one by one - VS_Layout
    # alone contributed hundreds. That produced 397 exclusions and 70,081
    # characters of /XD, well past the 32,767-character Windows process limit,
    # so robocopy could not even start: zero output, nothing copied, no error.
    # Descend ONLY where the folder itself is not kept but something inside is.
    $isExactlyKept = {
        param($rel)
        foreach ($k in $keep) { if ($k -eq $rel) { return $true } }
        return $false
    }
    $hasKeptDescendant = {
        param($rel)
        foreach ($k in $keep) { if ($k.StartsWith("$rel\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    $out = @()
    foreach ($top in (Get-ChildItem -LiteralPath $SourceRoot -Directory -ErrorAction SilentlyContinue)) {
        if (& $isExactlyKept $top.Name) { continue }                      # whole folder stays
        if (& $hasKeptDescendant $top.Name) {
            foreach ($sub in (Get-ChildItem -LiteralPath $top.FullName -Directory -ErrorAction SilentlyContinue)) {
                $rel = "$($top.Name)\$($sub.Name)"
                if (& $isExactlyKept $rel) { continue }
                if (& $hasKeptDescendant $rel) { continue }               # deeper keep - leave it alone
                $out += $(if ($FullPath) { $sub.FullName } else { $rel })
            }
        } else {
            $out += $(if ($FullPath) { $top.FullName } else { $top.Name })
        }
    }
    return @($out)
}

<#
    Get-RoomCoverage
    What a scoped stick can actually do for a room - the honest-degradation
    answer the Install tab needs. Present/missing rather than pass/fail, because
    a stick deliberately carrying 11 of 12 cards is correct, not broken.
#>
function Get-RoomCoverage {
    param([string]$RoomName, $Rooms, [string[]]$StickCards)
    $r = $Rooms.rooms.$RoomName
    if (-not $r) { return $null }
    $want = @($r.apps)
    $have = @($want | Where-Object { $StickCards -contains $_ })
    $miss = @($want | Where-Object { $StickCards -notcontains $_ })
    return [pscustomobject]@{
        Room = $RoomName; Required = $want.Count; Present = $have.Count
        Missing = $miss; Complete = ($miss.Count -eq 0)
        Text = if ($miss.Count -eq 0) { "all $($want.Count) cards present" }
               else { "$($have.Count) of $($want.Count) present - not on this stick: $($miss -join ', ')" }
    }
}
