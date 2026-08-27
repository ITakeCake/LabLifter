# Renders the new Fleet / Assign / Coverage tabs against the REAL controls from
# the real XAML, with no window ever shown. Catches bad property names, brush
# type errors, Grid.SetRow mistakes -- the things a parse check cannot see.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$src = Get-Content $f -Raw

# ---- load the real main window (not shown) ----
$m = [regex]::Match($src, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
[xml]$x = $m.Groups[1].Value
$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))

# ---- pull in the functions under test ----
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @(
 'New-FrozenBrush','Add-SlowScroll','New-FleetRow','New-FleetTile','Get-FleetRoomGroups',
 'Get-FleetRoomOrder','Test-FleetMatch','Update-FleetRooms','Show-FleetMachineInspector',
 # tracker: room bars, tooltips, tile selection (2026-08-03)
 'Get-RoomTally','New-RoomBar','Get-FleetTileTip','New-FleetHint',
 'Get-FleetTileKey','Set-FleetTileRing','Update-FleetSelTitle',
 'Clear-FleetSelection','Add-FleetSelection','Invoke-FleetTileClick','Select-FleetRange',
 'Get-FleetMarkKey','Import-FleetMarks','Get-FleetMark','Update-FleetAutoFound',
 'Import-FleetWatermarks','Get-FleetWatermark',
 'Import-FleetYears','Get-FleetPageFor','New-FleetYearHeader','Test-FleetYearCutoff',
 'Get-FleetRestorableYears','ConvertTo-FleetDate',
 'Get-SegBrush','ConvertFrom-MachineToken','New-AppSet','Get-AssignRoomList','Get-AssignRoomRules',
 'Load-AssignRoom','Get-AssignSel','Get-AssignSegAt','Update-AssignAll','Update-AssignRoomList',
 'Update-AssignRuler','Update-AssignSegList','Update-AssignPrograms','Split-AssignAt','Merge-AssignSeg',
 'Set-AssignProfile','Update-CoverageMap','Get-RoomMachineCount',
 'Get-CoverageBuildings','Get-CoverageSegments','Get-CoverageSegLabel','New-CoverageCard','Get-CVCodes',
 'New-CoverageWrap','New-CoverageNote','Show-CoverageBuildings','Show-CoverageRooms',
 'Show-CoverageRoom','Invoke-CoverageBack',
 # Ledger and Rail (2026-07-31)
 'New-CoverageSegRow','New-CoverageRail','Resolve-CoverageInherited','Get-CoverageSegState',
 'Get-FleetExpected','Get-FleetMachineStatus','Test-AppCountsForFleetHealth','Test-AppNeedsOpenConfirm','Resolve-DeployRule','Test-RuleHasApps','Get-RuleApps',
 'Get-RuleLabel','Test-NumToken','Set-StickStatus','Get-AssignSel','Publish-FleetIssues'
)
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$miss = @($want | Select-Object -Unique | Where-Object { $loaded -notcontains $_ })
if ($miss.Count) { "!! NOT FOUND: $($miss -join ', ')"; exit 1 }
"loaded $($loaded.Count) functions"

# ---- stubs + palette (top-level script code in the real file) ----
function Write-LabLog { param($Event, $Data) }
$script:BrushText   = New-FrozenBrush 0xE0 0xE0 0xE0
$script:BrushMuted  = New-FrozenBrush 0x78 0x78 0x78
$script:BrushGreen  = New-FrozenBrush 0x4E 0xC7 0x49
$script:BrushRed    = New-FrozenBrush 0xF8 0x51 0x49
$script:BrushYellow = New-FrozenBrush 0xD2 0x99 0x22
$script:BrushIntent = New-FrozenBrush 0x6E 0x3F 0xA3
$script:BrushRaiseSel   = New-FrozenBrush 0x33 0x21 0x46
$script:BrushBtnNeutral = New-FrozenBrush 0x50 0x50 0x58
$script:BrushBtnBlue    = New-FrozenBrush 0x1F 0x4A 0x6E
$script:BrushBtnGreen   = New-FrozenBrush 0x10 0x7C 0x10
$script:BrushBtnPurple  = New-FrozenBrush 0x4A 0x2E 0x6E
# Ledger and Rail chrome (2026-07-31). These MUST track the real palette block:
# a missing brush here is not a harmless null - Border.Background goes
# transparent and TextBlock.Foreground falls back to its default BLACK, which on
# a dark ground is invisible. A screenshot then shows a panel that renders
# perfectly in the real app as half-empty, or worse, the reverse.
$script:BrushPlate      = New-FrozenBrush 0x1E 0x1E 0x1E
$script:BrushPlateEdge  = New-FrozenBrush 0x3E 0x3E 0x44
$script:BrushPanelEdge  = New-FrozenBrush 0x30 0x30 0x36
$script:BrushTrough     = New-FrozenBrush 0x1B 0x1B 0x20
$script:BrushRowSel     = New-FrozenBrush 0x23 0x23 0x29
$script:BrushMutedCool  = New-FrozenBrush 0x8A 0x8A 0x95
$script:BrushLabel      = New-FrozenBrush 0x66 0x66 0x66
$script:BrushChipGray   = New-FrozenBrush 0x3A 0x3A 0x40
$script:BrushCard       = New-FrozenBrush 0x2D 0x2D 0x32
$script:BrushBtnGet     = New-FrozenBrush 0x2E 0x4E 0xED
$script:BrushBtnRed     = New-FrozenBrush 0x8B 0x2E 0x2E   # Delete Year
$script:SegBrushes = $null; $script:SegEmptyBrush = $null
$script:FleetColors = @{
    green  = New-FrozenBrush 0x14 0x4A 0x28; yellow = New-FrozenBrush 0x6E 0x58 0x14
    red    = New-FrozenBrush 0x6E 0x1E 0x1E; grey   = New-FrozenBrush 0x3A 0x3A 0x40
    card   = New-FrozenBrush 0x2D 0x2D 0x33
    blue   = New-FrozenBrush 0x1E 0x3A 0x6E   # reported missing
    purple = New-FrozenBrush 0x4A 0x2E 0x6E
    orange = New-FrozenBrush 0x7A 0x3C 0x0A
}
# Machine-tile fills: their own palette, matching the LabBoard dashboard wall so
# a tile reads the same colour in both views. Top-level in the real script, so
# the AST loader (functions only) leaves it $null here and New-FleetTile throws.
$script:TileColors = @{
    green  = New-FrozenBrush 0x2E 0xA0 0x43; yellow = New-FrozenBrush 0xD4 0xA0 0x17
    red    = New-FrozenBrush 0xE5 0x48 0x4D; purple = New-FrozenBrush 0x89 0x57 0xE5
    orange = New-FrozenBrush 0xD9 0x73 0x0D; blue   = New-FrozenBrush 0x3B 0x6F 0xB0
    grey   = New-FrozenBrush 0x3A 0x3A 0x40
}
$script:ScrollScale = 0.75
$script:IsMaster = $false   # Publish-FleetIssues (called by Update-FleetRooms) no-ops off-master
$script:AS = @{ Building=''; Room=''; Abbr=''; Type=''; Count=0; Segs=@(); Sel=0; Complex=$false; SplitMode=$false; Rooms=@() }
# Tile selection state (2026-08-03). Same reason as $script:CV below: the AST
# loader takes FUNCTIONS only, so a top-level hashtable from the real script is
# $null here and New-FleetTile throws on its first ContainsKey.
$script:FleetSel   = @{ Items = @{}; Anchor = $null }
$script:FleetTiles = @{}
$script:FleetTitleBase = ''
$script:FleetMarks = @{}; $script:FleetWatermarks = @{}
# One page catching every generation - the shipped first-run shape.
$script:FleetYears = @{ Current = 2026
                        Pages   = @(@{ Label = 2026; Cutoff = $null; Created = ([datetime]'2025-09-02') })
                        Removed = @() }
# Coverage drill-down state. Mirrors the real top-level declaration - the AST
# loader above pulls in FUNCTIONS only, so script-scope state has to be seeded.
$script:CV = @{ Level='buildings'; Building=''; Codes=@(); Abbr=''; Room=''; Type=''; SeenMax=0; SegIdx=0 }

# ---- fixtures ----
$ENG = @('Logisim','ArduinoIDE','LTSpice','WaveForms','AnsysHFSS','PuTTY','Python','MSYS2','VSCode',
         'VisualStudio','Vivado','STLinkDriver','Keil','AppLab','LabVIEW','RockwellCCW','Wireshark','MATLAB','MatlabArduino')
$appsObj = New-Object psobject
foreach ($a in ($ENG + @('ImageJ','JASP'))) {
    $appsObj | Add-Member -NotePropertyName $a -NotePropertyValue ([pscustomobject]@{ displayName=$a; needsOpen=$false })
}
$script:AppsConfig  = [pscustomobject]@{ apps = $appsObj }
$script:RoomsConfig = [pscustomobject]@{ rooms = [pscustomobject]@{
    ENG = [pscustomobject]@{ displayName='ENG Lab'; match=[pscustomobject]@{building='55'}; apps=$ENG } } }
# Four buildings on purpose, so the Coverage ordering rule has something to
# prove: two configured (HUM, ENG) and two not (ARTS, MARK). Declared here in
# deliberately WRONG order - the sort is what must fix it.
$script:BuildingsConfig = [pscustomobject]@{
    buildings = [pscustomobject]@{ '55'=[pscustomobject]@{abbr='ENG'}
                                   '26'=[pscustomobject]@{abbr='ARTS'}
                                   '14'=[pscustomobject]@{abbr='HUM'}
                                   '13'=[pscustomobject]@{abbr='MARK'} }
    roomSizes = [pscustomobject]@{ '55-103' = 90 } }
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building='55'; rooms='103'; types='LAB'; machines='1-60';  apps=$ENG },
    [pscustomobject]@{ building='55'; rooms='103'; types='LAB'; machines='61-90'; apps=@() },
    [pscustomobject]@{ building='14'; rooms='200'; types='';     machines='1-20';  apps=$ENG }) }

# synthetic rollup: 44 machines touched, #1/#2 red, #19 partial
# $script:ExtraRollup lets a test splice in an extra machine (e.g. one with an
# undecodable hostname) without redefining the whole fixture.
$script:ExtraRollup = @{}
function Get-FleetRollup {
    $r = @{}
    foreach ($k in $script:ExtraRollup.Keys) { $r[$k] = $script:ExtraRollup[$k] }
    for ($n=1; $n -le 44; $n++) {
        $inst = @{}
        foreach ($a in $ENG) { $inst[$a] = $true }
        $fail = New-Object System.Collections.ArrayList
        # #1/#2: a failed RockwellCCW install left it NOT detected -> missing -> yellow.
        if ($n -le 2) { [void]$fail.Add('RockwellCCW E26 @ 07-28 14:02'); $inst.Remove('RockwellCCW') }
        if ($n -eq 19) { $inst.Remove('LabVIEW'); $inst.Remove('MATLAB') }
        $r["10101LAB34-$('{0:D2}' -f $n)"] = @{
            Machine="10101LAB34-$('{0:D2}' -f $n)"; Building='55'; BuildingAbbr='ENG'; Room='103'; Type='LAB'
            Num=$n; Installed=$inst; Opened=@{}; Failures=$fail; LastSeen=(Get-Date '2026-07-28 14:02')
            Sessions=3; Reimaged=0; PriorSessions=0; Imaged='2026-07-11'; ImagedGen='2026-07-11'
            ImageFilePresent=$true; GpLast=(Get-Date '2026-07-27 09:00'); GpOk=$true
            CmLast=(Get-Date '2026-07-27 09:05'); CmOk=$true; CmDetail='3 action(s), 0 failed'; Sticks=@{'01'=$true} }
    }
    return $r
}

# ---- bind the control bag exactly as Initialize-MasterTabs does ----
$script:MW = @{ Bound=$true; Window=$null }
foreach ($n in @('pnlFleet','pnlFleetInsp','txtFleetTitle','txtFleetSearch','chkHideUnknown',
                 'pnlAsgRooms','pnlAsgRuler','pnlAsgSegs','pnlAsgApps','txtAsgTitle','txtAsgSeg',
                 'txtAsgSize','btnAsgSplit','cmbAsgProfile','pnlCover','pnlCoverHead','btnCoverBack','txtCoverTitle',
                 'btnCoverAddBldg','btnCoverAddRoom','btnCoverSize','btnCoverSplit','btnCoverMerge',
                 'btnCoverAddProg','btnCoverRemProg','btnCoverUnclaim','btnCoverRefresh','txtStickStatus')) {
    $script:MW[$n] = $window.FindName($n)
}

$pass=0; $fail=0
function ok($cond,$msg){ if($cond){$script:pass++;"  ok    $msg"}else{$script:fail++;"  FAIL  $msg"} }

'--- Fleet map renders ---'
Update-FleetRooms
ok ($script:MW.pnlFleet.Children.Count -ge 1) "room cards rendered ($($script:MW.pnlFleet.Children.Count))"
# pnlFleet's first child is the YEAR HEADER (a DockPanel) since 2026-08-03, and
# its last is the multi-select hint (a TextBlock). Room cards are Borders that,
# since the building fold-out (theFuture item 12, 2026-08-19), live INSIDE a
# per-building Expander's StackPanel - so tests walk the expanders to reach them.
$allRoomCards = { @($script:MW.pnlFleet.Children | Where-Object { $_ -is [System.Windows.Controls.Expander] } |
                    ForEach-Object { @($_.Content.Children) } | Where-Object { $_ -is [System.Windows.Controls.Border] }) }
$firstRoomCard = { @(& $allRoomCards)[0] }
$card = & $firstRoomCard
$wrap = $card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Select-Object -First 1
ok ($null -ne $wrap) 'room card contains a tile WrapPanel'
ok ($wrap.Children.Count -eq 90) "90 tiles for the declared 90-machine room (got $($wrap.Children.Count))"
$states = @{}
foreach ($t in $wrap.Children) { $k="$($t.Background)"; $states[$k] = 1 + [int]$states[$k] }
ok ($states.Keys.Count -ge 3) "tiles use multiple status colours ($($states.Keys.Count) distinct)"
ok ($script:MW.txtFleetTitle.Text -match '90 machines') "title summarises: '$($script:MW.txtFleetTitle.Text)'"

'--- year header: Restore | Start New Year | Delete ---'
# DockPanel gives each Right-docked child the edge in turn, so the LAST one
# added sits leftmost. Reading .Children back gives add-order, which is the
# reverse of what the tech sees - assert the visual order explicitly, because
# getting it backwards lays out fine and just looks wrong.
$hdr = @($script:MW.pnlFleet.Children | Where-Object { $_ -is [System.Windows.Controls.DockPanel] })[0]
$ybtn = @($hdr.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })
ok ($ybtn.Count -eq 3) "three year buttons in the header (got $($ybtn.Count))"
$addOrder = @($ybtn | ForEach-Object { "$($_.Content)" })
ok ($addOrder[0] -match 'Delete')  'Delete is added first, so it docks rightmost'
ok ($addOrder[1] -match 'New Year') 'Start New Year sits in the middle'
ok ($addOrder[2] -match 'Restore')  'Restore is added last, so it sits leftmost'
# Both destructive/rare actions gate themselves rather than explaining after a click.
ok (-not ($ybtn | Where-Object { "$($_.Content)" -match 'Delete' }).IsEnabled) 'Delete is greyed out when 2026 is the only page'
ok (-not ($ybtn | Where-Object { "$($_.Content)" -match 'Restore' }).IsEnabled) 'Restore is greyed out when the bin is empty'
# A brush that never got defined renders as default light chrome on a dark
# header - the exact failure mode the harness notes warn about.
ok ($null -ne ($ybtn | Where-Object { "$($_.Content)" -match 'Delete' }).Background) 'Delete Year has a real brush, not a null that would draw light'

'--- inspector replaces the MessageBox ---'
$tile = $wrap.Children[0]
Show-FleetMachineInspector -Ctx $tile.Tag
ok ($script:MW.pnlFleetInsp.Children.Count -gt 5) "inspector filled for machine #1 ($($script:MW.pnlFleetInsp.Children.Count) lines)"
$txt = (($script:MW.pnlFleetInsp.Children | ForEach-Object { $_.Text }) -join ' | ')
ok ($txt -match 'E26') 'inspector shows the E26 error'
ok ($txt -match '10101LAB34-01') 'inspector shows the hostname'
Show-FleetMachineInspector -Ctx $wrap.Children[74].Tag   # #75 = never touched, (none) segment
$txt75 = (($script:MW.pnlFleetInsp.Children | ForEach-Object { $_.Text }) -join ' | ')
ok ($txt75 -match '[Nn]ever touched') 'untouched machine reports never touched'

'--- % done, against the highest machine number the room knows ---'
Update-FleetRooms
# Fixture: 90 machines, 44 touched, #1/#2 red and #19 partial -> 41 green.
ok ($script:MW.txtFleetTitle.Text -match '^(\d+)% done') "title leads with the percentage: '$($script:MW.txtFleetTitle.Text)'"
ok ($script:MW.txtFleetTitle.Text -match '45% done') 'floor(41/90) = 45% done'
ok ($script:MW.txtFleetTitle.Text -match '41 of 90 machines') 'and states the raw counts too'
$sub = @((& $firstRoomCard).Child.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })[1]
ok ($sub.Text -match '45% done') "the room card carries its own % ('$($sub.Text)')"
# Untouched machines must COUNT AGAINST the percentage - a room nobody has
# visited is 0% done, not 100%.
ok ($sub.Text -match '46 never touched') 'never-touched machines are still in the denominator'

'--- room progress bar: the % as a shape (2026-08-03) ---'
# Card children are header / sub-line / BAR / tile wrap. The bar is the only
# Border child whose own child is a Grid.
$bar = @((& $firstRoomCard).Child.Children | Where-Object {
    $_ -is [System.Windows.Controls.Border] -and $_.Child -is [System.Windows.Controls.Grid] })[0]
ok ($null -ne $bar) 'room card carries a progress bar'
ok ($bar.Height -eq 10) 'bar is the 10px card-scale trough'
$runs = @($bar.Child.ColumnDefinitions | ForEach-Object { $_.Width.Value })
# Fixture room: 41 green, 3 missing-programs (yellow), 16 never-touched red (need programs, #45-60), 30 never-touched orange (GP/CM-only, #61-90), 0 missing.
ok (($runs | Measure-Object -Sum).Sum -eq 90) "run weights sum to the counted machines (got $(($runs | Measure-Object -Sum).Sum))"
ok ($bar.Child.ColumnDefinitions.Count -eq 4) 'green + yellow + red + orange runs, no gap column and no blue stub'
ok (@($bar.Child.Children | Where-Object { "$($_.Background)" -eq "$($script:FleetColors.blue)" }).Count -eq 0) 'no blue run when nothing is reported missing'
# New-RoomBar in isolation: the missing stub is DETACHED by a gap column, so it
# reads as outside the tally rather than another status.
$b2 = New-RoomBar -Ok 5 -Warn 0 -Bad 0 -Untouched 0 -Missing 2
ok ($b2.Child.ColumnDefinitions.Count -eq 3) 'missing machines add a gap column plus a stub'
ok ($b2.Child.ColumnDefinitions[1].Width.Value -eq 2) 'the gap is a fixed 2px, not proportional'
ok (@($b2.Child.Children | Where-Object { "$($_.Background)" -eq "$($script:TileColors.blue)" }).Count -eq 1) 'and the stub is blue'
ok ($null -eq (New-RoomBar -Ok 0 -Warn 0 -Bad 0 -Untouched 0 -Missing 0)) 'an empty room draws no bar at all'

'--- professional tooltips (Azure / Windows Security language) ---'
$tips = @($wrap.Children | ForEach-Object { "$($_.ToolTip)" })
ok (@($tips | Where-Object { $_ -match '^Healthy - ' }).Count -eq 41) 'green tiles lead with Healthy'
ok (@($tips | Where-Object { $_ -match '^Missing programs - ' }).Count -eq 3) 'missing-program tiles lead with Missing programs'
ok (@($tips | Where-Object { $_ -match 'Never touched by a stick - needs programs' }).Count -eq 16) 'untouched machines that need programs -> red tooltip'
ok (@($tips | Where-Object { $_ -match 'Never touched by a stick - owes GP/CM only' }).Count -eq 30) 'untouched machines that only owe GP/CM -> orange tooltip'
ok ($tips[0] -match "`n10101LAB34-01") 'line 2 names the machine'
ok ((Get-FleetTileTip -State 'blue' -Rec @{ Machine='X' } -Status @{ Text='x' } -Num 1) -match '^Missing - excluded from room totals') 'missing tiles say they are excluded'

'--- tile selection: Border tiles, rings, Alt range (2026-08-03) ---'
# Re-capture: every Update-FleetRooms throws the old tile objects away and
# rebuilds the registry, so a $wrap from before an intervening render points at
# controls that are no longer on screen or in $script:FleetTiles.
$wrap = (& $firstRoomCard).Child.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Select-Object -First 1
# Tiles MUST be Border: SmallBtn (like CardBtn before it) does not TemplateBind
# BorderBrush, so a ring on a styled Button is silently dropped - the bug that
# hid the Layout Designer's selection ring in every shipped build.
ok ($wrap.Children[0] -is [System.Windows.Controls.Border]) 'tiles are Borders so a selection ring can actually paint'
ok ($wrap.Children[0].BorderThickness.Left -eq 1) 'ring thickness is always allocated, so selecting cannot reflow the room'
# Child is a Grid now: the number, plus a mark notch when a tech has marked it.
ok ("$($wrap.Children[0].Child.Children[0].Text)" -eq '01') 'tile still reads the zero-padded machine number'
$k1 = Get-FleetTileKey -Ctx $wrap.Children[0].Tag
ok ($k1 -match '\|1$' -and $k1 -notmatch '^\|') "tile key is room-scoped, so two rooms cannot collide on #1: '$k1'"
ok ($script:FleetTiles.Count -ge 90) "tile registry populated ($($script:FleetTiles.Count))"

Clear-FleetSelection
ok ($script:FleetSel.Items.Count -eq 0) 'selection starts empty'
Add-FleetSelection -Ctx $wrap.Children[0].Tag
ok ($script:FleetSel.Items.Count -eq 1) 'a machine can be selected'
ok ("$($wrap.Children[0].BorderBrush)" -eq "$($script:BrushText)") 'and its ring paints'
Update-FleetSelTitle
ok ($script:MW.txtFleetTitle.Text -match '1 selected \(Esc clears\)') "title states the count: '$($script:MW.txtFleetTitle.Text)'"
Clear-FleetSelection
ok ("$($wrap.Children[0].BorderBrush)" -eq "$([System.Windows.Media.Brushes]::Transparent)") 'clearing removes the ring'
ok ($script:MW.txtFleetTitle.Text -notmatch 'selected') 'and the count leaves the title'

$added = Select-FleetRange -Anchor $wrap.Children[4].Tag -Ctx $wrap.Children[9].Tag
ok ($added -eq 6) "Alt range covers both ends inclusive (#5..#10 = 6, got $added)"
ok ($script:FleetSel.Items.Count -eq 6) 'and all six are selected'
ok ("$($wrap.Children[6].BorderBrush)" -eq "$($script:BrushText)") 'a machine inside the span is ringed'
Clear-FleetSelection
ok ((Select-FleetRange -Anchor $wrap.Children[9].Tag -Ctx $wrap.Children[4].Tag) -eq 6) 'range works high-to-low too'
Clear-FleetSelection
$added = Select-FleetRange -Anchor @{ Num = 3; RoomKey = 'SOME OTHER ROOM' } -Ctx $wrap.Children[9].Tag
ok ($added -eq 0 -and $script:FleetSel.Items.Count -eq 0) 'a range across two rooms selects nothing - machine numbers restart per room'

Add-FleetSelection -Ctx $wrap.Children[2].Tag
$keep = Get-FleetTileKey -Ctx $wrap.Children[2].Tag
Update-FleetRooms
$wrap = (& $firstRoomCard).Child.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Select-Object -First 1
ok ($script:FleetSel.Items.ContainsKey($keep)) 'selection survives a full rebuild'
ok ("$($wrap.Children[2].BorderBrush)" -eq "$($script:BrushText)") 'and the fresh tile re-rings itself'
$script:FleetSel.Items['GHOST ROOM|99'] = @{ Num = 99; RoomKey = 'GHOST ROOM' }
Update-FleetRooms
ok (-not $script:FleetSel.Items.ContainsKey('GHOST ROOM|99')) 'stale selection keys are pruned on rebuild'
Clear-FleetSelection

'--- the multi-select hint is permanent, not a tooltip ---'
$hint = @($script:MW.pnlFleet.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })[-1]
ok ($null -ne $hint) 'a hint line is rendered under the map'
ok ($hint.Text -match 'Shift\+Click' -and $hint.Text -match 'Alt\+Click' -and $hint.Text -match 'Esc') 'it teaches all three gestures'

'--- unrecognised machines: hidden by default, counted, never in the % ---'
# A machine whose hostname did not decode: no building, no room, no number.
$script:ExtraRollup = @{ 'MYSTERY-PC' = @{
    Machine='MYSTERY-PC'; Building=''; BuildingAbbr=''; Room=''; Type=''; Num=$null
    Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList)
    Sessions=1; Reimaged=0; PriorSessions=0; Sticks=@{'01'=$true} } }
$script:HideUnknownMachines = $true
Update-FleetRooms
ok ($script:MW.txtFleetTitle.Text -match '1 hidden \(unrecognised name\)') "hidden count is stated, not silent: '$($script:MW.txtFleetTitle.Text)'"
ok ($script:MW.txtFleetTitle.Text -match '45% done') 'a hidden machine does not move the % done'
$heads = @((& $allRoomCards) | ForEach-Object { $_.Child.Children[0].Text })
ok ($heads -notcontains 'Unrecognized names') 'the unrecognised card is not rendered'
$script:HideUnknownMachines = $false
Update-FleetRooms
$heads = @((& $allRoomCards) | ForEach-Object { $_.Child.Children[0].Text })
ok ($heads -contains 'Unrecognized names') 'unticking the setting brings it back'
ok ($script:MW.txtFleetTitle.Text -notmatch 'hidden') 'and the hidden note goes away'
$script:HideUnknownMachines = $true
$script:ExtraRollup = @{}
Update-FleetRooms

'--- search finds machines MISSING a program ---'
$script:MW.txtFleetSearch.Text = 'LabVIEW'
Update-FleetRooms
$w2 = (& $firstRoomCard).Child.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Select-Object -First 1
$lit = @($w2.Children | Where-Object { $_.Opacity -ge 0.9 }).Count
ok ($lit -eq 1) "only the 1 machine missing LabVIEW stays lit (got $lit)"
$script:MW.txtFleetSearch.Text = ''

'--- Assign tab renders ---'
Update-AssignRoomList
ok ($script:MW.pnlAsgRooms.Children.Count -ge 1) "room list rendered ($($script:MW.pnlAsgRooms.Children.Count))"
# Pick ENG 103 BY NAME, not by index: the room list is sorted by building abbr,
# so adding a building to the fixture would otherwise silently retarget every
# assertion below at a different room.
Load-AssignRoom -Entry @(@($script:AS.Rooms) | Where-Object { "$($_.Building)" -eq '55' -and "$($_.Room)" -eq '103' })[0]
ok ($script:AS.Count -eq 90) "room loaded with 90 machines (got $($script:AS.Count))"
ok ($script:AS.Segs.Count -eq 2) "existing 2 segments read back from the rules (got $($script:AS.Segs.Count))"
ok ($script:AS.Segs[0].Apps.Count -eq 19) "segment 1 has 19 programs (got $($script:AS.Segs[0].Apps.Count))"
ok ($script:AS.Segs[1].Apps.Count -eq 0)  "segment 2 has none (got $($script:AS.Segs[1].Apps.Count))"
ok ($script:MW.pnlAsgRuler.Children.Count -eq 90) "ruler has 90 cells (got $($script:MW.pnlAsgRuler.Children.Count))"
ok ($script:MW.pnlAsgSegs.Children.Count -eq 2) "2 segment rows (got $($script:MW.pnlAsgSegs.Children.Count))"
ok ($script:MW.pnlAsgApps.Children.Count -eq 21) "all 21 program checkboxes listed (got $($script:MW.pnlAsgApps.Children.Count))"
$ticked = @($script:MW.pnlAsgApps.Children | Where-Object { $_.IsChecked }).Count
ok ($ticked -eq 19) "19 boxes ticked for the selected segment (got $ticked)"

'--- splitting through the real UI path ---'
Split-AssignAt -N 30
ok ($script:AS.Segs.Count -eq 3) "split at #30 -> 3 segments (got $($script:AS.Segs.Count))"
ok ($script:MW.pnlAsgRuler.Children.Count -eq 90) 'ruler still covers 90 after split'
Split-AssignAt -N 70
Split-AssignAt -N 80
ok ($script:AS.Segs.Count -eq 5) "3 more splits -> 5 segments (got $($script:AS.Segs.Count))"
$cov=0; foreach($s in $script:AS.Segs){ $cov += ($s.To-$s.From+1) }
ok ($cov -eq 90) "still exactly 90 machines covered (got $cov)"
ok ($script:MW.txtAsgTitle.Text -match '5 segment') "title reports 5 segments: '$($script:MW.txtAsgTitle.Text)'"

'--- (none) and profile buttons ---'
$script:AS.Sel = 0
Set-AssignProfile -Which 'none'
ok ((Get-AssignSel).Apps.Count -eq 0) 'segment set to (none)'
Set-AssignProfile -Which 'ENG'
ok ((Get-AssignSel).Apps.Count -eq 19) 'segment refilled from the ENG profile'

'--- merge ---'
$before = $script:AS.Segs.Count
Merge-AssignSeg
ok ($script:AS.Segs.Count -eq ($before-1)) "merge removed one segment ($before -> $($script:AS.Segs.Count))"
$cov=0; foreach($s in $script:AS.Segs){ $cov += ($s.To-$s.From+1) }
ok ($cov -eq 90) 'merge kept full coverage'

'--- Coverage drill-down renders ---'
# LEVEL 1: buildings. Configured ones must sort ahead of unconfigured ones, and
# alphabetically within each group - that ordering IS the feature, so assert it
# rather than just counting tiles.
$script:CV.Level = 'buildings'
Update-CoverageMap
$blds = @(Get-CoverageBuildings)
ok ($blds.Count -eq 4) "building list built ($($blds.Count))"
# the exact example: ENG and HUM configured -> ENG then HUM (alphabetical), then the rest
# greyed out in alphabetical order.
ok ("$(@($blds | ForEach-Object { $_.Abbr }) -join ',')" -eq 'ENG,HUM,ARTS,MARK') `
   "building order is ENG,HUM,ARTS,MARK (got $(@($blds | ForEach-Object { $_.Abbr }) -join ','))"
# Unique abbrs stay bare; only a repeated one earns its code in the title.
ok ("$(@($blds | ForEach-Object { $_.Display }) -join ',')" -eq 'ENG,HUM,ARTS,MARK') `
   'unique abbreviations render without a code suffix'
$firstUn = [array]::IndexOf(@($blds | ForEach-Object { $_.Configured }), $false)
$lastCfg = -1
for ($i = 0; $i -lt $blds.Count; $i++) { if ($blds[$i].Configured) { $lastCfg = $i } }
ok ($firstUn -lt 0 -or $lastCfg -lt $firstUn) 'every configured building sorts before every unconfigured one'
$cfgNames = @($blds | Where-Object { $_.Configured } | ForEach-Object { "$($_.Abbr)".ToLowerInvariant() })
ok ("$($cfgNames -join ',')" -eq "$((@($cfgNames) | Sort-Object) -join ',')") 'configured group is alphabetical'
$unNames = @($blds | Where-Object { -not $_.Configured } | ForEach-Object { "$($_.Abbr)".ToLowerInvariant() })
ok ("$($unNames -join ',')" -eq "$((@($unNames) | Sort-Object) -join ',')") 'unconfigured group is alphabetical'
ok ($script:MW.pnlCover.Children.Count -ge 1) 'buildings panel rendered'
ok ("$($script:MW.btnCoverBack.Visibility)" -eq 'Collapsed') 'Back hidden at the top level'
ok ($script:MW.txtCoverTitle.Text -match 'building') "buildings title: '$($script:MW.txtCoverTitle.Text)'"

# A building with several codes (real: ENG is 55 AND 56) is ONE card carrying
# both codes - not two cards that look like a bug.
$dupB = [pscustomobject]@{
    buildings = [pscustomobject]@{ '55'=[pscustomobject]@{abbr='ENG'}; '56'=[pscustomobject]@{abbr='ENG'}
                                   '26'=[pscustomobject]@{abbr='ARTS'} }
    roomSizes = [pscustomobject]@{} }
$keepB = $script:BuildingsConfig
$script:BuildingsConfig = $dupB
$dup = @(Get-CoverageBuildings)
$dv  = @($dup | Where-Object { $_.Abbr -eq 'ENG' })
ok ($dv.Count -eq 1) "ENG renders as ONE card, not two (got $($dv.Count))"
ok ("$(@($dv[0].Codes) -join ',')" -eq '55,56') "carrying both codes (got $(@($dv[0].Codes) -join ','))"
ok ($dv[0].Display -eq 'ENG') 'titled by abbreviation alone - the code suffix is no longer needed'
ok ("$(@($dup | Where-Object { $_.Abbr -eq 'ARTS' } | ForEach-Object { @($_.Codes).Count }))" -eq '1') `
   'a single-code building still has exactly one code'
$script:BuildingsConfig = $keepB

# LEVEL 2: rooms of the first CONFIGURED building.
$cfg = @($blds | Where-Object { $_.Configured })[0]
ok ($null -ne $cfg) 'at least one configured building to drill into'
$script:CV.Level = 'rooms'; $script:CV.Building = "$($cfg.Code)"; $script:CV.Codes = @($cfg.Codes); $script:CV.Abbr = "$($cfg.Abbr)"
Update-CoverageMap
ok ($script:MW.pnlCover.Children.Count -ge 1) 'rooms panel rendered'
ok ("$($script:MW.btnCoverBack.Visibility)" -eq 'Visible') 'Back appears below the top level'

# LEVEL 3: one room's segments.
$room = @(Get-AssignRoomList | Where-Object { "$($_.Building)" -eq "$($cfg.Code)" })[0]
$script:CV.Abbr = "$($cfg.Abbr)"
ok ($null -ne $room) "a room exists in $($cfg.Abbr)"
$script:CV.Level = 'room'; $script:CV.Room = "$($room.Room)"; $script:CV.SeenMax = [int]$room.SeenMax; $script:CV.SegIdx = 0
Update-CoverageMap
$segs = @(Get-CoverageSegments -Building $room.Building -Room $room.Room -SeenMax $room.SeenMax)
ok ($segs.Count -ge 1) "room split into segments ($($segs.Count))"
ok ([bool]$segs[$segs.Count - 1].Tail) 'last segment is the open tail'
ok ((Get-CoverageSegLabel -Seg $segs[$segs.Count - 1]) -match ([string][char]0x221E)) 'tail label ends in the infinity sign'
# Every machine number is accounted for: segments are contiguous from 1 up.
$expect = 1; $contig = $true
foreach ($s in $segs) { if ($s.From -ne $expect) { $contig = $false }; if (-not $s.Tail) { $expect = $s.To + 1 } }
ok $contig 'segments are contiguous from #1 with no unexplained gaps'
# Ledger and Rail (2026-07-31): pnlCover is one full-width row per segment plus
# the legend, and the plate + rail + readout live in pnlCoverHead so they do not
# scroll away when a selected row expands.
ok ($script:MW.pnlCover.Children.Count -eq ($segs.Count + 1)) "ledger has one row per segment plus the legend (got $($script:MW.pnlCover.Children.Count) for $($segs.Count) segments)"
ok ("$($script:MW.pnlCoverHead.Visibility)" -eq 'Visible') 'the room head is shown at the room level'
ok ($script:MW.pnlCoverHead.Children.Count -eq 3) 'room head = plate + rail + hover readout'
$plate = $script:MW.pnlCoverHead.Children[0]
ok ($plate -is [System.Windows.Controls.Border]) 'plate is a Border'
ok ($plate.CornerRadius.TopRight -eq 14) 'plate uses the header radius 5,14,14,5'
$rail = $script:MW.pnlCoverHead.Children[1]
ok ($rail.Height -eq 26) 'rail is 26px tall'
ok ($rail.Child.ColumnDefinitions.Count -eq $segs.Count) "rail has one star column per segment (got $($rail.Child.ColumnDefinitions.Count))"
# Coverage is WIDTH: a segment twice as long must weigh twice as much.
$bounded = @($segs | Where-Object { -not $_.Tail })
if ($bounded.Count -ge 1) {
    $i0 = [array]::IndexOf($segs, $bounded[0])
    ok ($rail.Child.ColumnDefinitions[$i0].Width.Value -eq ($bounded[0].To - $bounded[0].From + 1)) 'a rail slice weighs exactly its machine count'
} else { ok $true 'no bounded segment to weight-check' }
ok ($script:MW.pnlCoverHead.Children[2].Text -match 'Point at the rail') 'readout starts in its rest state'
# Rows are Border, not Button+CardBtn - CardBtn never TemplateBound BorderBrush,
# so the selected card's ring has never rendered in any shipped build.
$row0 = $script:MW.pnlCover.Children[0]
ok ($row0 -is [System.Windows.Controls.Border]) 'ledger rows are Borders so the selection ring actually paints'
ok ($row0.BorderThickness.Left -eq 1 -and $null -ne $row0.BorderBrush) 'selected row carries a real border'
ok ($script:MW.txtCoverTitle.Text -match 'Click a row') "room title is the standing instruction: '$($script:MW.txtCoverTitle.Text)'"
# Three states, ONE hue. Nothing here may be green, amber or red.
foreach ($s in $segs) {
    $st = Get-CoverageSegState -Seg $s
    ok ($st -in @('written','inherited','empty')) "segment $(Get-CoverageSegLabel -Seg $s) resolves to a known state ($st)"
}

# Install order must survive the render - sorting it would destroy the
# engineered ordering the whole install depends on.
$withApps = @($segs | Where-Object { $_.Apps.Count -gt 1 })
if ($withApps.Count -gt 0) {
    $r0 = @(Get-AssignRoomRules -Building $room.Building -Room $room.Room)[0]
    if ($r0 -and (Test-RuleHasApps -Rule $r0)) {
        $raw = @(Get-RuleApps -Rule $r0)
        $seg = @($segs | Where-Object { $_.Assigned })[0]
        ok ("$($seg.Apps -join ',')" -eq "$($raw -join ',')") 'segment app order matches the rule verbatim (never sorted)'
    } else { ok $true 'first rule uses a profile - order check not applicable' }
} else { ok $true 'no multi-app segment in this room to order-check' }

# Back walks up one level at a time and stops at the top.
Invoke-CoverageBack
ok ($script:CV.Level -eq 'rooms') 'Back: room -> rooms'
Invoke-CoverageBack
ok ($script:CV.Level -eq 'buildings') 'Back: rooms -> buildings'
Invoke-CoverageBack
ok ($script:CV.Level -eq 'buildings') 'Back at the top level is a no-op'

# Room cards come out in NUMERIC room order, not string order - "99" must
# precede "103", which a plain text sort gets backwards. A non-numeric room name
# in a RULE is dropped entirely (Get-AssignRoomList takes only rules naming one
# all-digits room), so ANNEX below is expected to be absent, not last.
$keepR = $script:RulesConfig
$script:RulesConfig = [pscustomobject]@{ rules = @(
    [pscustomobject]@{ building='55'; rooms='201'; types=''; machines='1-10'; apps=@() },
    [pscustomobject]@{ building='55'; rooms='99';  types=''; machines='1-10'; apps=@() },
    [pscustomobject]@{ building='55'; rooms='103'; types=''; machines='1-10'; apps=@() },
    [pscustomobject]@{ building='55'; rooms='ANNEX'; types=''; machines='1-10'; apps=@() }) }
$ordered = @(Get-AssignRoomList | Where-Object { "$($_.Building)" -eq '55' } | ForEach-Object { "$($_.Room)" })
ok ("$($ordered -join ',')" -eq '99,103,201') "rooms in numeric order (got $($ordered -join ','))"
ok ($ordered -notcontains 'ANNEX') 'a non-numeric room named by a rule is dropped, not sorted to the end'
$script:RulesConfig = $keepR

# Level-gated action buttons: exactly the right ones on each level, and never
# an action that makes no sense where you are standing.
# EVERY btnCover* in the XAML has to be bound and level-gated. Derived from the
# markup rather than hand-listed: a hand-list is exactly how btnCoverUnclaim
# shipped invisible - it was wired in the real script but missing from the
# harness bags, so screenshots showed a toolbar the app does not have.
$xamlBtns = @([regex]::Matches($m.Groups[1].Value, 'Name="(btnCover\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
ok ($xamlBtns.Count -ge 8) "found $($xamlBtns.Count) btnCover* buttons in the XAML"
foreach ($b in $xamlBtns) {
    ok ($null -ne $script:MW[$b]) "$b is bound into `$script:MW (harness list is not stale)"
}
$roomOnly = @('btnCoverSize','btnCoverSplit','btnCoverMerge','btnCoverAddProg','btnCoverRemProg','btnCoverUnclaim')
$want = @{ buildings = @('btnCoverAddBldg'); rooms = @('btnCoverAddRoom'); room = $roomOnly }
foreach ($lv in 'buildings','rooms','room') {
    $script:CV.Level = $lv
    Update-CoverageMap
    foreach ($b in ($xamlBtns | Where-Object { $_ -ne 'btnCoverBack' -and $_ -ne 'btnCoverRefresh' })) {
        $expect = $(if ($want[$lv] -contains $b) { 'Visible' } else { 'Collapsed' })
        ok ("$($script:MW[$b].Visibility)" -eq $expect) "$lv level: $b is $expect"
    }
}
$script:CV.Level = 'buildings'

# The old flat matrix is gone: no sideways program names anywhere.
$src = Get-Content $f -Raw
ok ($src -notmatch 'RotateTransform') 'no RotateTransform left in the source (sideways headers gone)'

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }

