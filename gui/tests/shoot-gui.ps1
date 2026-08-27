# Launches the REAL window (not headless), drives it, and screenshots it.
# This is the visual verification that has been missing: every check so far
# proved the XAML parses and controls resolve, none proved it LOOKS right.
param([double]$Scale = 1.0, [int]$W = 0, [int]$H = 0, [string]$Tab = 'Deploy', [string]$Out,
      [string]$SubTab = '',   # nested Rooms & Rules sub-tab: Layout Designer / Manual Entry / Advanced / Backups
      [ValidateSet('buildings','rooms','room')][string]$CoverLevel = 'buildings',
      [string]$CoverBuilding = '', [string]$CoverRoom = '',
      [bool]$HideUnknown = $true,
      # -Fit exercises the REAL Update-UiFit (AST-extracted below, same as the
      # coverage/fleet renderers) against -W/-H, instead of a hand-picked
      # -Scale. Baseline is pinned to the XAML's own 920x745 so a screenshot at
      # -W 920 -H 745 comes out at exactly 1.0 and every other size is a true
      # ratio off it -- reproducible, unlike whatever size a live window had.
      [switch]$Fit)
# Paths are DERIVED, never hard-coded: this has to run from a USB stick, a
# second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  public struct R { public int L,T,Rt,B; }
}
'@

$src = Get-Content (Join-Path $LabRoot 'Deploy-LabGUI.ps1') -Raw
$m = [regex]::Match($src, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
[xml]$x = $m.Groups[1].Value
$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))

# populate just enough to look real
$win.FindName('txtHostname').Text = '10101LAB34-20'
$win.FindName('txtDecode').Text   = 'ENG 103 #20'
$win.FindName('txtDecode').Visibility = 'Visible'
$win.FindName('txtUser').Text     = 'student01'
$win.FindName('txtSummary').Text  = '17 / 19 installed'
$win.FindName('txtStatus').Text   = 'Ready'
$cmb = $win.FindName('cmbRoom'); [void]$cmb.Items.Add('ENG 103 #1-60 (assigned)'); $cmb.SelectedIndex = 0
$us = $win.FindName('cmbUiScale')
foreach ($s in 75,90,100,110,125,150,175,200) { [void]$us.Items.Add("$s%$(if($s -eq 100){'  (normal)'})") }
$us.SelectedIndex = 2

# a few realistic app cards on the Deploy tab - Rail rows, mirroring
# New-AppCard's chrome: 4px status spine / name+tag pill / detail / actions.
# Must track the real script's brushes - a mock that keeps an old swatch makes
# a recolour look untouched.
$pnl = $win.FindName('pnlApps')
$mkB = { param($r,$g,$b2) New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r,$g,$b2)) }
# Detail strings must match what Get-AppCardDetail actually renders (changed
# 2026-08-03 from raw detection output to one sentence). A fixture that keeps
# the old long path/searched-list makes the screenshot claim a UI that no longer
# ships - the same failure mode as keeping a stale brush.
$apps = @(@('NI LabVIEW 2021 SP1 (32-bit) + ELVIS III','Installed 2026-07-27 at 10:14 AM','ok','Offload Image Install','Reinstall',$true,$false),
          @('Xilinx Vivado','Installed 2026-07-26 at 4:38 PM','ok','Image Install','Reinstall',$true,$false),
          @('Rockwell CCW','INCOMPLETE - VS 2015 Shell missing. Click Install again.','warn','Silent EXE','Install',$false,$true),
          @('MATLAB','Installed 2026-07-30 at 9:02 AM','ok','Image Install','Reinstall',$true,$false),
          @('Ansys Electronics Desktop',"Not installed  $([char]0x00B7)  checked at 2:21 PM",'bad','Silent EXE','Install',$false,$false))
foreach ($a in $apps) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background      = & $mkB 0x23 0x23 0x23
    $b.BorderBrush     = & $mkB 0x2C 0x2C 0x32
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.CornerRadius    = [System.Windows.CornerRadius]::new(4,8,8,4)
    $b.Margin          = [System.Windows.Thickness]::new(0,0,0,7)
    $g = New-Object System.Windows.Controls.Grid
    foreach ($cw in @('4','*','A')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = switch ($cw) { '4' { [System.Windows.GridLength]::new(4) } '*' { [System.Windows.GridLength]::new(1,'Star') } default { [System.Windows.GridLength]::Auto } }
        $g.ColumnDefinitions.Add($cd)
    }
    $col = switch ($a[2]) { 'ok' { [System.Windows.Media.Color]::FromRgb(0x26,0x9E,0x58) }
                            'warn' { [System.Windows.Media.Color]::FromRgb(0xB8,0x87,0x25) }
                            default { [System.Windows.Media.Color]::FromRgb(0xAA,0x55,0x55) } }
    $sp2 = New-Object System.Windows.Shapes.Rectangle
    $sp2.Width = 4; $sp2.RadiusX = 2; $sp2.RadiusY = 2
    $sp2.Fill = New-Object System.Windows.Media.SolidColorBrush $col
    [System.Windows.Controls.Grid]::SetColumn($sp2, 0); $g.Children.Add($sp2) | Out-Null
    $mid = New-Object System.Windows.Controls.StackPanel
    $mid.VerticalAlignment = 'Center'
    $mid.Margin = [System.Windows.Thickness]::new(14,11,14,12)
    [System.Windows.Controls.Grid]::SetColumn($mid, 1)
    $nl = New-Object System.Windows.Controls.WrapPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $a[0]; $t1.FontSize = 13.5; $t1.FontWeight = 'SemiBold'
    $t1.Foreground = & $mkB 0xE0 0xE0 0xE0
    $t1.VerticalAlignment = 'Center'
    $nl.Children.Add($t1) | Out-Null
    $tg = New-Object System.Windows.Controls.Border
    $tg.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $tg.Padding = [System.Windows.Thickness]::new(7,2,7,2)
    $tg.Margin  = [System.Windows.Thickness]::new(8,0,0,0)
    $tg.VerticalAlignment = 'Center'
    $tg.Background = & $mkB 0x31 0x31 0x3A
    $tt = New-Object System.Windows.Controls.TextBlock
    $tt.Text = $a[3]; $tt.FontSize = 9.5; $tt.FontWeight = 'Bold'
    $tt.Foreground = & $mkB 0xA9 0xA9 0xB4
    $tg.Child = $tt; $nl.Children.Add($tg) | Out-Null
    $mid.Children.Add($nl) | Out-Null
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = $a[1]; $t2.FontSize = 11
    $t2.Margin = [System.Windows.Thickness]::new(0,3.5,0,0)
    $t2.Foreground = New-Object System.Windows.Media.SolidColorBrush $col
    $mid.Children.Add($t2) | Out-Null
    if ($a[6]) {   # exception chip demo: shortcut missing pill
        $ch = New-Object System.Windows.Controls.Border
        $ch.CornerRadius = [System.Windows.CornerRadius]::new(20)
        $ch.Padding = [System.Windows.Thickness]::new(10,4,10,4)
        $ch.Margin  = [System.Windows.Thickness]::new(0,8.5,0,0)
        $ch.HorizontalAlignment = 'Left'
        $ch.BorderThickness = [System.Windows.Thickness]::new(1)
        $ch.Background  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x1A,0xE0,0x52,0x52))
        $ch.BorderBrush = & $mkB 0x6E 0x2E 0x2E
        $ct = New-Object System.Windows.Controls.TextBlock
        $ct.Text = "$([char]0x2717) Shortcut missing $([char]0x00B7) fix"
        $ct.FontSize = 10; $ct.FontWeight = 'Bold'
        $ct.Foreground = & $mkB 0xE0 0x77 0x77
        $ch.Child = $ct
        $mid.Children.Add($ch) | Out-Null
    }
    $g.Children.Add($mid) | Out-Null
    $ap = New-Object System.Windows.Controls.StackPanel
    $ap.Orientation = 'Horizontal'; $ap.VerticalAlignment = 'Center'
    $ap.Margin = [System.Windows.Thickness]::new(0,0,12,0)
    [System.Windows.Controls.Grid]::SetColumn($ap, 2)
    $mkSB = { param($txt,$bg)
        $sb = New-Object System.Windows.Controls.Button
        $sb.Content = $txt; $sb.FontSize = 11.5; $sb.FontWeight = 'SemiBold'
        $sb.Padding = [System.Windows.Thickness]::new(12,6,12,6)
        $sb.Margin  = [System.Windows.Thickness]::new(0,0,6,0)
        $sb.Background = $bg
        try { $sb.Style = $win.FindResource('SmallBtn') } catch { $sb.Foreground = [System.Windows.Media.Brushes]::White }
        $sb }
    $pri = if ($a[4] -eq 'Install') { & $mkB 0x2E 0x4E 0xED } else { & $mkB 0x2A 0x5B 0x36 }
    $ap.Children.Add((& $mkSB $a[4] $pri)) | Out-Null
    if ($a[5]) { $ap.Children.Add((& $mkSB 'Uninstall' (& $mkB 0x6E 0x2E 0x2E))) | Out-Null }
    $more = & $mkSB "$([char]0x22EF)" (& $mkB 0x2A 0x2A 0x33)
    $more.FontSize = 13; $more.Padding = [System.Windows.Thickness]::new(11,4,11,6)
    $more.Margin = [System.Windows.Thickness]::new(0)
    $ap.Children.Add($more) | Out-Null
    $g.Children.Add($ap) | Out-Null
    $b.Child = $g
    $pnl.Children.Add($b) | Out-Null
}

# tabAssign retired from the strip (consolidation Phase 2) - not un-hidden here,
# to match the real master. `-Tab Assign` still works: the selection block below
# un-hides whatever tab you explicitly ask for, so the parked panel can still be shot.
foreach ($t in 'tabFleet','tabCover','tabSticks','tabAddApp') { $c = $win.FindName($t); if ($c) { $c.Visibility = 'Visible' } }

# Status Dock footer: master stick/fleet line (real Initialize-MasterTabs unhides
# it) + one chip of each state so a screenshot exercises the indicator dots.
$ss = $win.FindName('brdStickStatus'); if ($ss) { $ss.Visibility = 'Visible' }
$tss = $win.FindName('txtStickStatus')
if ($tss) {
    $tss.Text = '0 stick(s) here, 0 other USB drive(s), 12 away   -   fleet: 0 CURRENT / 12 STALE / 0 unknown'
    $tss.Foreground = & $mkB 0xD9 0xA5 0x21   # tracks Set-StickStatus's stale-amber
}
$dc = $win.FindName('dotCaffeine'); if ($dc) { $dc.Fill = & $mkB 0x4E 0xC7 0x49 }
$cc = $win.FindName('txtCaffeineChip'); if ($cc) { $cc.Text = 'Caffeine ON' }
$dw = $win.FindName('dotWinget'); if ($dw) { $dw.Fill = & $mkB 0x4E 0xC7 0x49 }
$cw = $win.FindName('txtWingetChip'); if ($cw) { $cw.Text = 'winget' }

# DEPLOYMENT TRACKER + LAYOUT DESIGNER are rendered by the REAL functions
# against the REAL config files, not mocks. A hand-built mock hid a stale title
# once already (it showed the pre-% wording after the % shipped), which is
# exactly the class of thing this harness exists to catch. The only synthetic
# part is the fleet ROLLUP - that data normally comes from merged stick logs.
$LD = $LabRoot
$tokC = $null; $errC = $null
$astC = [System.Management.Automation.Language.Parser]::ParseFile("$LD\Deploy-LabGUI.ps1", [ref]$tokC, [ref]$errC)
$wantC = @('Update-UiFit',
           'New-CoverageSegRow','New-CoverageRail','Resolve-CoverageInherited','Get-CoverageSegState',
           'Get-RoomTally','New-RoomBar','Get-FleetTileTip','New-FleetHint',
           'Get-FleetTileKey','Set-FleetTileRing','Update-FleetSelTitle',
           'Clear-FleetSelection','Add-FleetSelection','Invoke-FleetTileClick','Select-FleetRange',
           'Get-FleetMarkKey','Import-FleetMarks','Get-FleetMark','Update-FleetAutoFound',
           'Import-FleetWatermarks','Get-FleetWatermark',
           'Import-FleetYears','Get-FleetPageFor','New-FleetYearHeader','Test-FleetYearCutoff',
           'Get-FleetRestorableYears','ConvertTo-FleetDate',
           'New-HealthChip','Set-HealthChip','Update-HealthPill',
           'New-FrozenBrush','ConvertFrom-MachineToken','New-AppSet','Get-AssignRoomList',
           'Get-AssignRoomRules','Get-RoomMachineCount','Test-RuleHasApps','Get-RuleApps',
           'Get-CoverageBuildings','Get-CoverageSegments','Get-CoverageSegLabel','New-CoverageCard','Get-CVCodes',
           'New-CoverageWrap','New-CoverageNote','Show-CoverageBuildings','Show-CoverageRooms',
           'Show-CoverageRoom','Update-CoverageMap',
           'Update-FleetRooms','Get-FleetRoomGroups','Get-FleetRoomOrder','New-FleetTile','New-FleetRow',
           'Test-FleetMatch','Get-FleetMachineStatus','Test-AppCountsForFleetHealth','Get-FleetExpected','Test-AppNeedsOpenConfirm',
           'Resolve-DeployRule','Get-RuleLabel','Test-NumToken','Show-FleetMachineInspector','Update-AppCatalogList')
foreach ($d in $astC.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wantC -contains $d.Name) { Invoke-Expression $d.Extent.Text }
}
foreach ($p in @(@('AppsConfig','apps.json'), @('RoomsConfig','rooms.json'),
                 @('RulesConfig','deployment-rules.json'), @('BuildingsConfig','buildings.json'))) {
    Set-Variable -Name $p[0] -Scope Script -Value (Get-Content "$LD\config\$($p[1])" -Raw | ConvertFrom-Json)
}
# Synthetic rollup mirroring test-render's: a 90-machine ENG 103 with 44 seen,
# #1/#2 in error and #19 partial, plus one machine whose hostname never decoded
# so the hide-unrecognised setting has something to act on.
# The demo app set: the ENG profile if the config carries one, else any
# non-empty profile, else a slice of the catalog - the harness must render
# a populated fleet no matter how stripped-down the shipped starter config is.
$script:ENGAPPS = @($script:RoomsConfig.rooms.ENG.apps | Where-Object { $_ })
if (-not $script:ENGAPPS.Count) {
    foreach ($p in $script:RoomsConfig.rooms.PSObject.Properties) {
        if ($p.Name -notlike '_*' -and @($p.Value.apps | Where-Object { $_ }).Count) { $script:ENGAPPS = @($p.Value.apps | Where-Object { $_ }); break }
    }
}
if (-not $script:ENGAPPS.Count) {
    $script:ENGAPPS = @($script:AppsConfig.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' } | Select-Object -First 12)
}
function Get-FleetRollup {
    $r = @{}
    for ($n = 1; $n -le 44; $n++) {
        $inst = @{}
        foreach ($a in $script:ENGAPPS) { $inst[$a] = $true }
        $fail = New-Object System.Collections.ArrayList
        if ($n -le 2)  { [void]$fail.Add('RockwellCCW E26 @ 07-28 14:02') }
        if ($n -eq 19) { $inst.Remove(@($script:ENGAPPS)[0]); $inst.Remove(@($script:ENGAPPS)[1]) }
        $r["10101LAB34-$('{0:D2}' -f $n)"] = @{
            Machine = "10101LAB34-$('{0:D2}' -f $n)"; Building='55'; BuildingAbbr='ENG'; Room='103'; Type='LAB'
            Num = $n; Installed=$inst; Opened=@{}; Failures=$fail; LastSeen=(Get-Date '2026-07-28 14:02')
            Sessions=3; Reimaged=0; PriorSessions=0; Imaged='2026-07-11'; ImagedGen='2026-07-11'
            ImageFilePresent=$true; GpLast=(Get-Date '2026-07-27 09:00'); GpOk=$true
            CmLast=$null; CmOk=$false; CmDetail=''; Sticks=@{'01'=$true}; RecheckApps=@() }
    }
    $r['SPARE-LAPTOP-7'] = @{
        Machine='SPARE-LAPTOP-7'; Building=''; BuildingAbbr=''; Room=''; Type=''; Num=$null
        Installed=@{}; Opened=@{}; Failures=(New-Object System.Collections.ArrayList)
        Sessions=1; Reimaged=0; PriorSessions=0; Sticks=@{'01'=$true}; RecheckApps=@() }
    return $r
}
function Publish-FleetIssues { }
$script:BrushText   = New-FrozenBrush 0xE0 0xE0 0xE0
$script:BrushMuted  = New-FrozenBrush 0x78 0x78 0x78
$script:BrushCard   = New-FrozenBrush 0x2D 0x2D 0x32
$script:BrushIntent = New-FrozenBrush 0x6E 0x3F 0xA3
$script:BrushWhite  = New-FrozenBrush 0xFF 0xFF 0xFF
# Ledger and Rail chrome (2026-07-31). MUST track the real palette block: a
# missing brush is not a harmless null here - Border.Background goes transparent
# and TextBlock.Foreground falls back to its default BLACK, invisible on this
# ground. That is exactly how this harness reported a fully-built room header as
# a floating title with no plate, no spine and no stat line.
$script:BrushPlate     = New-FrozenBrush 0x1E 0x1E 0x1E
$script:BrushPlateEdge = New-FrozenBrush 0x3E 0x3E 0x44
$script:BrushPanelEdge = New-FrozenBrush 0x30 0x30 0x36
$script:BrushTrough    = New-FrozenBrush 0x1B 0x1B 0x20
$script:BrushRowSel    = New-FrozenBrush 0x23 0x23 0x29
$script:BrushMutedCool = New-FrozenBrush 0x8A 0x8A 0x95
$script:BrushLabel     = New-FrozenBrush 0x66 0x66 0x66
$script:BrushChipGray  = New-FrozenBrush 0x3A 0x3A 0x40
$script:BrushBtnGet    = New-FrozenBrush 0x2E 0x4E 0xED
$script:BrushBtnRed    = New-FrozenBrush 0x8B 0x2E 0x2E   # Delete Year
$script:FleetColors = @{
    green  = New-FrozenBrush 0x14 0x4A 0x28
    yellow = New-FrozenBrush 0x6E 0x58 0x14
    red    = New-FrozenBrush 0x6E 0x1E 0x1E
    grey   = New-FrozenBrush 0x3A 0x3A 0x40
    card   = New-FrozenBrush 0x2D 0x2D 0x33
    blue   = New-FrozenBrush 0x1E 0x3A 0x6E
    purple = New-FrozenBrush 0x4A 0x2E 0x6E
    orange = New-FrozenBrush 0x7A 0x3C 0x0A   # reported missing
}
# tile fills mirror the dashboard wall - keep in step with the real palette
$script:TileColors = @{
    green  = New-FrozenBrush 0x2E 0xA0 0x43
    yellow = New-FrozenBrush 0xD4 0xA0 0x17
    red    = New-FrozenBrush 0xE5 0x48 0x4D
    purple = New-FrozenBrush 0x89 0x57 0xE5
    orange = New-FrozenBrush 0xD9 0x73 0x0D
    blue   = New-FrozenBrush 0x3B 0x6F 0xB0
    grey   = New-FrozenBrush 0x3A 0x3A 0x40
}
$script:HideUnknownMachines = $HideUnknown
# Tile selection state - top-level in the real script, so the AST loader (which
# takes functions only) leaves it $null here and New-FleetTile throws.
$script:FleetSel   = @{ Items = @{}; Anchor = $null }
$script:FleetTiles = @{}
$script:FleetTitleBase = ''
# Tech marks: seeded in memory only (no MasterRoot here, so Save-FleetMarks is
# never reached) so a screenshot exercises every tile state including the blue
# "reported missing" and the mark notch.
$script:FleetMarks = @{
    '10101LAB34-06|2026-07-11' = @{ State = 'missing';  Ts = (Get-Date '2026-08-01'); By = 'master' }
    'room:ENG 103|47'           = @{ State = 'missing';  Ts = (Get-Date '2026-08-01'); By = 'master' }
    '10101LAB34-11|2026-07-11' = @{ State = 'override'; Ts = (Get-Date '2026-08-02'); By = 'master' }
    '10101LAB34-01|2026-07-11' = @{ State = 'verified'; Ts = (Get-Date '2026-08-03'); By = 'master' }
}
$script:FleetWatermarks = @{}
# Removed = the delete bin. A page in it enables the header's Restore Year
# button, so seeding one is what makes that button screenshot in its LIVE state.
$script:FleetYears = @{ Current = 2026
                        Pages   = @(@{ Label = 2026; Cutoff = $null; Created = ([datetime]'2025-09-02') })
                        Removed = @(@{ Label = 2025; Cutoff = ([datetime]'2024-12-10'); Created = ([datetime]'2024-12-10'); Removed = ([datetime]'2026-08-01 09:14') }) }
# New-CoverageCard resolves its style off $window, which is what the real script
# calls the window - alias it or every card silently loses its chrome.
$window = $win

# Health pill: REAL functions, mock states - one of each colour so a screenshot
# exercises the whole aggregate (ok, ok, warn, bad -> "2 issues" in red tone).
$script:HealthChips    = @{}
$script:HealthDotBrush = @{
    ok    = New-FrozenBrush 0x4E 0xC7 0x49
    warn  = New-FrozenBrush 0xD9 0xA5 0x21
    bad   = New-FrozenBrush 0xE0 0x52 0x52
    muted = New-FrozenBrush 0x55 0x55 0x5E
}
$script:HealthPillTone = @{
    bad  = @{ B = New-FrozenBrush 0x6E 0x2E 0x2E; T = New-FrozenBrush 0xE0 0x77 0x77 }
    warn = @{ B = New-FrozenBrush 0x6E 0x58 0x14; T = New-FrozenBrush 0xD9 0xA5 0x21 }
    ok   = @{ B = New-FrozenBrush 0x3A 0x3A 0x40; T = New-FrozenBrush 0x8A 0x8A 0x95 }
}
foreach ($k in 'Imaged','CM','PKI') { New-HealthChip -Key $k }   # GP chip retired 2026-08-12 - keep in step with the real chip list
Set-HealthChip -Key Imaged -Text 'Imaged: 2026-07-11 (19d ago)' -State ok -Tip 'C:\timestamp_Cart.txt'
Set-HealthChip -Key GP     -Text 'GP: 3d ago'                   -State ok
Set-HealthChip -Key CM     -Text 'CM: 2 actions'                -State warn
Set-HealthChip -Key PKI    -Text 'PKI: certificate missing'     -State bad
$script:MW = @{}
foreach ($n in 'pnlCover','pnlCoverHead','txtCoverTitle','btnCoverBack',
               'btnCoverAddBldg','btnCoverAddRoom','btnCoverSize','btnCoverSplit',
               'btnCoverMerge','btnCoverAddProg','btnCoverRemProg','btnCoverUnclaim',
               'pnlFleet','pnlFleetInsp','txtFleetTitle','txtFleetSearch','pnlAppCatalog') { $script:MW[$n] = $win.FindName($n) }
$chk = $win.FindName('chkHideUnknown'); if ($chk) { $chk.IsChecked = $HideUnknown }
foreach ($n in 'lblTrackerSettings','brdTrackerSettings') {
    $c = $win.FindName($n); if ($c) { $c.Visibility = 'Visible' }
}
Update-FleetRooms
$script:CV = @{ Level = $CoverLevel; Building = ''; Codes = @(); Abbr = ''; Room = ''; Type = ''; SeenMax = 0; SegIdx = 0 }
if ($CoverLevel -ne 'buildings') {
    $b = if ($CoverBuilding) { @(Get-CoverageBuildings | Where-Object { @($_.Codes) -contains $CoverBuilding })[0] }
         else { @(Get-CoverageBuildings | Where-Object { $_.Configured })[0] }
    # Display, not Abbr - that is what the real click handler stores, and a
    # screenshot that disagrees with the real app is worse than no screenshot.
    if ($b) { $script:CV.Building = "$($b.Code)"; $script:CV.Codes = @($b.Codes); $script:CV.Abbr = "$(if ($b.Display) { $b.Display } else { $b.Abbr })" }
    if ($CoverLevel -eq 'room') {
        $rm = if ($CoverRoom) { @(Get-AssignRoomList | Where-Object { "$($_.Building)" -eq $script:CV.Building -and "$($_.Room)" -eq $CoverRoom })[0] }
              else { @(Get-AssignRoomList | Where-Object { "$($_.Building)" -eq $script:CV.Building })[0] }
        if ($rm) { $script:CV.Room = "$($rm.Room)"; $script:CV.SeenMax = [int]$rm.SeenMax }
    }
}
Update-CoverageMap
Update-AppCatalogList

if ($W -gt 0) { $win.Width = $W }
if ($H -gt 0) { $win.Height = $H }
if ([math]::Abs($Scale - 1.0) -gt 0.001) {
    $win.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($Scale,$Scale)
}
# Fit mode reads ActualWidth/ActualHeight, which are still 0 until the window
# is laid out -- so it is armed here and actually applied in ContentRendered.
$script:UiFit = [bool]$Fit
$script:UiFitApplied = $null
$script:UiFitBase = @{ W = 920.0; H = 745.0 }
$script:UiFitMin = 0.55
$script:UiFitMax = 2.0
$tc = $win.FindName('tabMain')
# Select by CONTROL name first, headers second: headers are display-only and
# have been renamed (Fleet -> "Deployment Tracker", Coverage -> "Layout
# Designer"), and a header-only match made the documented `-Tab Fleet` shoot
# the Deploy tab without saying so. Old short names stay accepted.
$tabMap = @{ 'deploy'='tabDeploy'; 'fleet'='tabFleet'; 'deployment tracker'='tabFleet'; 'tracker'='tabFleet';
             'cover'='tabCover'; 'coverage'='tabCover'; 'layout designer'='tabCover'; 'layout'='tabCover';
             'assign'='tabAssign'; 'config'='tabConfig'; 'sticks'='tabSticks';
             'add app'='tabAddApp'; 'addapp'='tabAddApp'; 'applications'='tabAddApp'; 'apps'='tabAddApp'; 'settings'='tabSettings' }
$sel = $null
if ($tabMap.ContainsKey($Tab.ToLower())) { $sel = $win.FindName($tabMap[$Tab.ToLower()]) }
if (-not $sel) { foreach ($it in $tc.Items) { if ("$($it.Header)" -eq $Tab) { $sel = $it } } }
if ($sel) { $sel.Visibility = 'Visible'; $tc.SelectedItem = $sel }
else { Write-Host "  WARN: no tab matches '$Tab' -- shooting the default (Deploy) instead." }
# Rooms & Rules and Applications both hold nested tab strips. -SubTab selects
# by header inside whichever main tab was asked for, so its pane can be shot.
if ($SubTab) {
    $nest = if ($tabMap[$Tab.ToLower()] -eq 'tabAddApp') { $win.FindName('tabApps') } else { $win.FindName('tabRR') }
    if ($nest) {
        $subSel = $null
        foreach ($it in $nest.Items) { if ("$($it.Header)" -like "*$SubTab*") { $subSel = $it } }
        if ($subSel) { $nest.SelectedItem = $subSel }
        else { Write-Host "  WARN: no sub-tab matches '$SubTab'." }
    }
}
# The Status Dock's action row is Deploy's; the real app collapses it on the master
# tabs from a tabMain SelectionChanged handler, which this harness deliberately
# never runs (it loads XAML, it does not do startup wiring). Mirror it by hand
# or every master-tab screenshot shows an Install All Missing button that would not
# be there - exactly the class of lie a screenshot harness exists to prevent.
$pfa = $win.FindName('pnlFooterActions')
if ($pfa -and $tc.SelectedItem -ne $win.FindName('tabDeploy')) { $pfa.Visibility = 'Collapsed' }

$win.Add_ContentRendered({
    # Fit runs HERE, not in the capture callback below: that one ends in a
    # Start-Sleep, which blocks the UI thread, so a LayoutTransform set inside
    # it never gets a render pass and PrintWindow grabs the stale frame. Set it
    # in ContentRendered and the queued ApplicationIdle capture sees it drawn.
    if ($script:UiFit) {
        Update-UiFit
        Write-Host ("fit: {0}x{1} -> scale {2}" -f [int]$win.ActualWidth, [int]$win.ActualHeight, $script:UiFitApplied)
        $win.UpdateLayout()
    }
    $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{
        Start-Sleep -Milliseconds 400
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        $r = New-Object W32+R
        [void][W32]::GetWindowRect($h, [ref]$r)
        $bw = $r.Rt - $r.L; $bh = $r.B - $r.T
        $bmp = New-Object System.Drawing.Bitmap($bw, $bh)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $dc = $g.GetHdc()
        [void][W32]::PrintWindow($h, $dc, 2)
        $g.ReleaseHdc($dc); $g.Dispose()
        $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $win.Close()
    }) | Out-Null
})
[void]$win.ShowDialog()
"captured: $Out"
