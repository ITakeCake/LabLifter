# Source-level wiring audit (check-verify style: reads the source, runs nothing).
#
#   1. Every FindName('X') literal in the source resolves to a Name="X" that
#      actually exists - a renamed/deleted XAML control otherwise comes back
#      $null and crashes at click time, on a lab machine, with Blake not there.
#   2. Every Button in the MAIN window XAML has a handler wired somewhere.
#   3. Every CheckBox/ComboBox is wired OR consciously allowlisted as a
#      read-on-demand dialog input (a flow reads .IsChecked/.SelectedItem when
#      its button fires). New controls fail loudly until wired or listed.
#   4. The Enter-to-run text boxes keep their KeyDown handlers.
#
# Wiring styles this understands (all in use today):
#   $btnX.Add_Click(...)                      Deploy-tab style, var = control name
#   $window.FindName('btnX').Add_Click(...)   Initialize-MasterTabs style
#   $script:MW.ctl.Add_KeyDown(...)           MW-bag style
#   $var = $window.FindName('ctl') ... $var.Add_Click   local-var rename
#   Enable-NumericBoxes -Names @('txtX',...)  helper-attached KeyDown
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$src = Get-Content (Join-Path $LabRoot 'Deploy-LabGUI.ps1') -Raw

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }

# ---- collect every declared control name (all XAML here-strings) ----
$declared = @{}
foreach ($m in [regex]::Matches($src, '(?:x:)?Name="(\w+)"')) { $declared[$m.Groups[1].Value] = $true }

# ---- collect the wired set ----
$wired = @{}
foreach ($m in [regex]::Matches($src, '\$(\w+)\.Add_\w+\('))                { $wired[$m.Groups[1].Value] = $true }
foreach ($m in [regex]::Matches($src, "FindName\('(\w+)'\)\.Add_\w+\("))    { $wired[$m.Groups[1].Value] = $true }
foreach ($m in [regex]::Matches($src, 'MW\.(\w+)\.Add_\w+\('))              { $wired[$m.Groups[1].Value] = $true }
# local-var rename: $var = $window.FindName('ctl') ... later $var.Add_*
foreach ($m in [regex]::Matches($src, "\`$(\w+)\s*=\s*\`$window\.FindName\('(\w+)'\)")) {
    if ($wired[$m.Groups[1].Value]) { $wired[$m.Groups[2].Value] = $true }
}
# helper-attached numeric gating
foreach ($m in [regex]::Matches($src, 'Enable-NumericBoxes\s+-Names\s+@\(([^)]*)\)')) {
    foreach ($n in [regex]::Matches($m.Groups[1].Value, "'(\w+)'")) { $wired[$n.Groups[1].Value] = $true }
}

'=== 1. every literal FindName target exists in a XAML block ==='
$dangling = @()
foreach ($m in [regex]::Matches($src, "FindName\('(\w+)'\)")) {
    $n = $m.Groups[1].Value
    if (-not $declared[$n]) { $dangling += $n }
}
$dangling = @($dangling | Sort-Object -Unique)
ok ($declared.Count -gt 100) "control-name harvest looks sane ($($declared.Count) names declared)"
ok (-not $dangling.Count) "no FindName call aims at a name missing from the XAML$(if ($dangling.Count) { ' -- ' + ($dangling -join ', ') })"

'=== 2/3. main-window interactive controls are wired or allowlisted ==='
# Inputs a flow reads when its OWN button fires; they never need handlers.
# ADD A NAME HERE ONLY when the reading flow exists - this list is the record
# of every "unwired on purpose" decision.
$readOnDemand = @{
    cmbAsgNewBldg  = 'read by Add-AssignRoomFlow'
    cmbAsgProfile  = 'read by btnAsgApply handler'
    cmbRoomDigits  = 'read by Add-BuildingFlow'
    cmbType01      = 'read by Add-TypeFlow'
    cmbRuleProfile = 'read by Add-RuleFlow'
    cmbRuleBldg    = 'read by Add-RuleFlow'
    cmbNewStick    = 'read by Invoke-StickInitFlow'
    cmbCapRequires = 'read by Invoke-CaptureFlow'
    chkCapOpen     = 'read by Invoke-CaptureFlow'
    chkCapAsk      = 'read by Invoke-CaptureFlow'
    chkCapLast     = 'read by Invoke-CaptureFlow'
    chkCapOffload  = 'read by Invoke-CaptureFlow'
}

$m = [regex]::Match($src, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
ok $m.Success 'main-window XAML block found'
$mainXaml = $m.Groups[1].Value
$ctrls = @([regex]::Matches($mainXaml, '<(Button|CheckBox|ComboBox)\b[^>]*?\bName="(\w+)"') |
    ForEach-Object { [pscustomobject]@{ Kind = $_.Groups[1].Value; Name = $_.Groups[2].Value } })
$buttons = @($ctrls | Where-Object { $_.Kind -eq 'Button' })
ok ($buttons.Count -ge 30) "button harvest looks sane ($($buttons.Count) buttons)"

$unwiredBtn = @($buttons | Where-Object { -not $wired[$_.Name] } | ForEach-Object { $_.Name })
ok (-not $unwiredBtn.Count) "every main-window Button has a handler$(if ($unwiredBtn.Count) { ' -- UNWIRED: ' + ($unwiredBtn -join ', ') })"

$others = @($ctrls | Where-Object { $_.Kind -ne 'Button' })
$unaccounted = @($others | Where-Object { -not $wired[$_.Name] -and -not $readOnDemand.ContainsKey($_.Name) } | ForEach-Object { "$($_.Kind) $($_.Name)" })
ok (-not $unaccounted.Count) "every CheckBox/ComboBox is wired or allowlisted$(if ($unaccounted.Count) { ' -- NEW+UNWIRED: ' + ($unaccounted -join ', ') })"
# and the allowlist itself must not go stale
$staleAllow = @($readOnDemand.Keys | Where-Object { -not $declared[$_] })
ok (-not $staleAllow.Count) "allowlist entries all still exist in the XAML$(if ($staleAllow.Count) { ' -- ' + ($staleAllow -join ', ') })"

'=== 4. Enter-to-run boxes keep their KeyDown handlers ==='
foreach ($n in 'txtFleetSearch', 'txtDryHost', 'txtAsgSplitAt') {
    ok ([bool]$wired[$n]) "$n has a KeyDown handler"
}

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
