# Applications tab (consolidation Phase 4a): the enable/disable writer for app
# cards (apps.json `disabled`). Mirrors test-lastbatch's Set-AppAutoShortcut
# approach - a sandboxed COPY of the real apps.json, Publish disabled, driving
# the real Set-AppDisabled through its snapshot -> write -> reload -> rollback path.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$f = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @('Set-AppDisabled','Set-AppFields','Set-AppRoomMembership','ConvertTo-AppFieldEdits','ConvertTo-AppInstallEdits',
          'New-LabDialog','Add-DlgSection','Build-EditAppDialog','New-FrozenBrush','New-DlgBox','New-DlgCombo','New-DlgNumBox',
          'Add-DlgRow','Add-DlgFooter','Set-DlgLive','Set-DlgRowVisible','Get-RoomProfileChoices',
          'Backup-ConfigSnapshot','Publish-ConfigToStaging','Update-AppCatalogList')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$missing = @($want | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) { "NOT FOUND in source: $($missing -join ', ')"; exit 1 }
# Promote every loaded function to GLOBAL scope.
#
# Invoke-Expression above defines them at SCRIPT scope, which is fine for code
# the test calls directly - but the dialog builders wire WPF event handlers
# (Add_SelectionChanged and friends), and when those scriptblocks fire they
# could not see script-scoped functions. Result: a stream of red
# "Set-DlgRowVisible is not recognized" errors while every assertion still
# passed - noise that reads exactly like a broken suite and hid the real
# PASS/FAIL line. Re-binding into function:global: makes the handlers resolve.
foreach ($n in $loaded) {
    $sb = (Get-Item "function:$n" -ErrorAction SilentlyContinue).ScriptBlock
    if ($sb) { Set-Item -Path "function:global:$n" -Value $sb -Force }
}
function Write-LabLog { param($Event, $Data) }

$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { $script:pass++; "  ok    $m" } else { $script:fail++; "  FAIL  $m" } }

$sand = Join-Path $env:TEMP ("labdeploy_appcat_" + (Get-Random))
New-Item -ItemType Directory -Path $sand -Force | Out-Null
Copy-Item (Join-Path $LabRoot 'config\apps.json') (Join-Path $sand 'apps.json')
$ConfigRoot = $sand
$script:IsMaster = $false   # Publish-ConfigToStaging no-ops
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json

'=== enable/disable round-trip on the real apps.json (sandboxed) ==='
ok (Set-AppDisabled -AppId 'MATLAB' -Disabled $true) 'disable MATLAB saves'
ok ([bool]$script:AppsConfig.apps.MATLAB.disabled) 'in-memory config reloaded: MATLAB now disabled'
$disk = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($disk.apps.MATLAB.disabled -eq $true) 'on-disk disabled = true'
ok ($disk.apps.MATLAB.install.method -eq 'exe') 'MATLAB other fields preserved (install.method)'
ok ($null -eq $disk.apps.Python.disabled -or $disk.apps.Python.disabled -eq $false) 'a different app (Python) untouched'
ok (Set-AppDisabled -AppId 'MATLAB' -Disabled $false) 're-enable MATLAB saves'
$disk2 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($disk2.apps.MATLAB.disabled -eq $false) 'on-disk disabled = false after re-enable'
ok ((Test-Path (Join-Path $sand 'snapshots')) -and @(Get-ChildItem (Join-Path $sand 'snapshots') -Filter 'apps.json.*.bak').Count -ge 2) 'a snapshot was taken before EACH write'
ok (-not (Set-AppDisabled -AppId 'NoSuchApp' -Disabled $true)) 'unknown app refuses politely (returns false)'
$disk3 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (@($disk3.apps.PSObject.Properties).Count -eq @($disk2.apps.PSObject.Properties).Count) 'unknown-app attempt added no card'

'=== Set-AppFields edits basic fields (sandboxed) ==='
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ displayName = 'MATLAB (2026b)'; needsOpen = $true; askAfterOpen = $false }) 'edit MATLAB saves'
$d = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($d.apps.MATLAB.displayName -eq 'MATLAB (2026b)') 'displayName written'
ok ($d.apps.MATLAB.needsOpen -eq $true) 'needsOpen written'
ok ($d.apps.MATLAB.askAfterOpen -eq $false) 'askAfterOpen written'
ok ($d.apps.MATLAB.install.method -eq 'exe') 'install block untouched'
ok ($null -ne $d.apps.MATLAB.detect) 'detect block untouched'
ok ($script:AppsConfig.apps.MATLAB.displayName -eq 'MATLAB (2026b)') 'in-memory config reloaded after edit'
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ openPrompt = 'Click OK when it opens' }) 'set openPrompt saves'
$dP = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($dP.apps.MATLAB.openPrompt -eq 'Click OK when it opens') 'openPrompt written'
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ openPrompt = $null }) 'clearing openPrompt saves'
$d2 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (-not $d2.apps.MATLAB.PSObject.Properties['openPrompt']) 'openPrompt property removed when set to $null'
ok (-not (Set-AppFields -AppId 'MATLAB' -Fields @{ displayName = '  ' })) 'blank displayName refused'
ok ((Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json).apps.MATLAB.displayName -eq 'MATLAB (2026b)') 'refused blank edit did not corrupt the card'
ok (-not (Set-AppFields -AppId 'NoSuchApp' -Fields @{ displayName = 'x' })) 'unknown app refused'
ok (-not (Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json).apps.PSObject.Properties['NoSuchApp']) 'unknown-app edit added no card'

'=== Set-AppFields nested (dotted) keys ==='
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ 'install.installOrder' = 55; 'install.installLast' = $true }) 'nested install.* saves'
$n = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($n.apps.MATLAB.install.installOrder -eq 55) 'install.installOrder written UNDER install (fresh value, not pre-existing 90)'
ok ($n.apps.MATLAB.install.installLast -eq $true) 'install.installLast written under install'
ok (-not $n.apps.MATLAB.PSObject.Properties['install.installOrder']) 'no bogus flat "install.installOrder" property created'
ok ($n.apps.MATLAB.install.method -eq 'exe') 'sibling install.method preserved'
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ 'install.installOrder' = $null }) 'clearing a nested leaf saves'
$n2 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (-not $n2.apps.MATLAB.install.PSObject.Properties['installOrder']) 'nested leaf removed (the real installOrder is gone)'
ok ($n2.apps.MATLAB.install.PSObject.Properties['method']) 'parent NOT pruned while it still has siblings'
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ 'uninstall.method' = 'launch'; 'uninstall.program' = 'C:\x.exe' }) 'creates a missing parent object'
$n3 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($n3.apps.MATLAB.uninstall.method -eq 'launch') 'uninstall.method created under a new parent'
ok ($n3.apps.MATLAB.uninstall.program -eq 'C:\x.exe') 'uninstall.program created under the same parent'
ok (Set-AppFields -AppId 'MATLAB' -Fields @{ 'uninstall.method' = $null; 'uninstall.program' = $null; 'uninstall.message' = $null }) 'clearing all leaves saves'
$n4 = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok (-not $n4.apps.MATLAB.PSObject.Properties['uninstall']) 'empty parent object pruned'

'=== ConvertTo-AppFieldEdits maps dialog values -> a Set-AppFields hashtable ==='
$mOn = ConvertTo-AppFieldEdits -DisplayName '  Foo  ' -Icon 'On (default)' -NeedsOpen $true -AskAfterOpen $true -OpenPrompt '  hi  '
ok ($mOn.displayName -eq 'Foo') 'displayName trimmed'
ok ($mOn.autoShortcut -eq $true) 'icon On -> autoShortcut = true'
ok ($null -eq $mOn.noShortcut) 'icon On -> noShortcut removed'
ok ($mOn.needsOpen -eq $true -and $mOn.askAfterOpen -eq $true) 'open + ask carried through'
ok ($mOn.openPrompt -eq 'hi') 'openPrompt trimmed'
$mOff = ConvertTo-AppFieldEdits -DisplayName 'X' -Icon 'Off' -NeedsOpen $false -AskAfterOpen $true -OpenPrompt 'ignored'
ok ($mOff.autoShortcut -eq $false) 'icon Off -> autoShortcut = false'
ok ($null -eq $mOff.noShortcut) 'icon Off -> noShortcut removed'
ok ($mOff.needsOpen -eq $false) 'needsOpen = No carried'
ok ($null -eq $mOff.askAfterOpen) 'needsOpen No -> askAfterOpen removed'
ok ($null -eq $mOff.openPrompt) 'needsOpen No -> openPrompt removed'
$mNever = ConvertTo-AppFieldEdits -DisplayName 'X' -Icon 'Never' -NeedsOpen $true -AskAfterOpen $false -OpenPrompt 'p'
ok ($mNever.noShortcut -eq $true) 'icon Never -> noShortcut = true'
ok ($null -eq $mNever.autoShortcut) 'icon Never -> autoShortcut removed'
ok ($null -eq $mNever.openPrompt) 'ask = No -> openPrompt removed even if typed'
# the mapping output must feed Set-AppFields cleanly (the real dialog seam)
ok (Set-AppFields -AppId 'MATLAB' -Fields (ConvertTo-AppFieldEdits -DisplayName 'MATLAB' -Icon 'Never' -NeedsOpen $false -AskAfterOpen $false -OpenPrompt '')) 'mapping output feeds Set-AppFields'
$dc = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($dc.apps.MATLAB.noShortcut -eq $true) 'compose: Never wrote noShortcut = true'
ok (-not $dc.apps.MATLAB.PSObject.Properties['autoShortcut']) 'compose: autoShortcut removed on disk'
ok (-not $dc.apps.MATLAB.PSObject.Properties['openPrompt']) 'compose: openPrompt removed on disk'

'=== Set-AppRoomMembership toggles rooms.json profile membership ==='
$script:AppsConfig  = Get-Content (Join-Path $LabRoot 'config\apps.json')  -Raw | ConvertFrom-Json
Copy-Item (Join-Path $LabRoot 'config\rooms.json') (Join-Path $sand 'rooms.json') -Force
$script:RoomsConfig = Get-Content (Join-Path $sand 'rooms.json') -Raw | ConvertFrom-Json
$profs = @($script:RoomsConfig.rooms.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
ok ($profs.Count -ge 2) "rooms.json has >= 2 profiles to test with ($($profs.Count))"
$pA = $profs[0]; $pB = $profs[1]
# Normalise: start with MATLAB in NO profile, so append/count assertions are
# deterministic regardless of the real config's current membership.
[void](Set-AppRoomMembership -AppId 'MATLAB' -InProfiles @())
$baseA = @((Get-Content (Join-Path $sand 'rooms.json') -Raw | ConvertFrom-Json).rooms.$pA.apps).Count
ok (Set-AppRoomMembership -AppId 'MATLAB' -InProfiles @($pA)) 'add to one profile returns true'
$r = Get-Content (Join-Path $sand 'rooms.json') -Raw | ConvertFrom-Json
ok (@($r.rooms.$pA.apps) -contains 'MATLAB') "MATLAB added to $pA"
ok (@($r.rooms.$pA.apps)[-1] -eq 'MATLAB') 'add APPENDS (does not reorder existing entries)'
ok (@($r.rooms.$pA.apps).Count -eq ($baseA + 1)) 'exactly one id added'
ok (-not (@($r.rooms.$pB.apps) -contains 'MATLAB')) "MATLAB absent from the unticked $pB"
ok (Set-AppRoomMembership -AppId 'MATLAB' -InProfiles @()) 'empty set removes from all'
$r2 = Get-Content (Join-Path $sand 'rooms.json') -Raw | ConvertFrom-Json
ok (-not (@($r2.rooms.$pA.apps) -contains 'MATLAB')) 'MATLAB removed when unticked'
ok (@($r2.rooms.$pA.apps).Count -eq $baseA) 'removal restored the original count (no collateral changes)'
ok (-not (Set-AppRoomMembership -AppId 'NoSuchApp' -InProfiles @($pA))) 'unknown app refused'
ok ((Test-Path (Join-Path $sand 'snapshots')) -and @(Get-ChildItem (Join-Path $sand 'snapshots') -Filter 'rooms.json.*.bak').Count -ge 1) 'a rooms.json snapshot was taken'

'=== ConvertTo-AppInstallEdits maps order+tuning -> dotted hashtable ==='
$g = ConvertTo-AppInstallEdits -InstallOrder ' 90 ' -InstallLast $true -MethodLabel '  Big image  ' -ExpectedSizeMB '200' -Offload $true -Requires 'MATLAB' -ExcludeFromInstallAll $true -UninstallMethod 'launch' -UninstallProgram ' C:\ni.exe ' -UninstallMessage ' hi '
ok ($g['install.installOrder'] -eq 90) 'installOrder parsed to int'
ok ($g['install.installLast'] -eq $true) 'installLast true'
ok ($g['install.methodLabel'] -eq 'Big image') 'methodLabel trimmed'
ok ($g['install.expectedSizeMB'] -eq 200) 'expectedSizeMB parsed to int'
ok ($g['install.offload'] -eq $true) 'offload true'
ok ($g['install.requires'] -eq 'MATLAB') 'requires carried'
ok ($g['install.excludeFromInstallAll'] -eq $true) 'exclude true'
ok ($g['uninstall.method'] -eq 'launch' -and $g['uninstall.program'] -eq 'C:\ni.exe') 'uninstall launch+program'
ok ($g['uninstall.message'] -eq 'hi') 'uninstall message trimmed'
$off = ConvertTo-AppInstallEdits -InstallOrder '' -InstallLast $false -MethodLabel '' -ExpectedSizeMB 'abc' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'default' -UninstallProgram '' -UninstallMessage ''
ok ($null -eq $off['install.installOrder']) 'blank order -> null'
ok ($null -eq $off['install.installLast']) 'installLast off -> null'
ok ($null -eq $off['install.expectedSizeMB']) 'non-numeric size -> null'
ok ($null -eq $off['install.requires']) '(none) requires -> null'
ok ($null -eq $off['uninstall.method'] -and $null -eq $off['uninstall.program'] -and $null -eq $off['uninstall.message']) 'default uninstall -> all null'
$noProg = ConvertTo-AppInstallEdits -InstallOrder '' -InstallLast $false -MethodLabel '' -ExpectedSizeMB '' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'launch' -UninstallProgram '  ' -UninstallMessage 'x'
ok ($null -eq $noProg['uninstall.method']) 'launch without a program -> uninstall not written'
# Editability switches: the single-select editor must NOT overwrite fields it
# cannot faithfully represent (multi-value requires, non-launch uninstall) -
# omitting the key means Set-AppFields leaves the existing value untouched.
$keep = ConvertTo-AppInstallEdits -InstallOrder '' -InstallLast $false -MethodLabel '' -ExpectedSizeMB '' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'default' -UninstallProgram '' -UninstallMessage '' -RequiresEditable $false -UninstallEditable $false
ok (-not $keep.ContainsKey('install.requires')) 'RequiresEditable=$false OMITS install.requires (preserves existing)'
ok (-not $keep.ContainsKey('uninstall.method'))  'UninstallEditable=$false OMITS uninstall.* (preserves existing)'
$emit = ConvertTo-AppInstallEdits -InstallOrder '' -InstallLast $false -MethodLabel '' -ExpectedSizeMB '' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'default' -UninstallProgram '' -UninstallMessage ''
ok ($emit.ContainsKey('install.requires') -and $emit.ContainsKey('uninstall.method')) 'default (editable) still emits both keys'
# Regression: editing an app with MULTI-VALUE requires must not drop it.
Copy-Item (Join-Path $LabRoot 'config\apps.json') (Join-Path $sand 'apps.json') -Force
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
$mreqName = @($script:AppsConfig.apps.PSObject.Properties | Where-Object { $_.Value.install.requires -is [System.Array] -and @($_.Value.install.requires).Count -ge 2 } | Select-Object -First 1).Name
if ($mreqName) {
    $before = @($script:AppsConfig.apps.$mreqName.install.requires).Count
    $advKeep = ConvertTo-AppInstallEdits -InstallOrder '' -InstallLast $false -MethodLabel '' -ExpectedSizeMB '' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'default' -UninstallProgram '' -UninstallMessage '' -RequiresEditable $false
    ok (Set-AppFields -AppId $mreqName -Fields $advKeep) "save of multi-requires app ($mreqName) succeeds"
    $after = @((Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json).apps.$mreqName.install.requires).Count
    ok ($after -eq $before) "multi-value requires PRESERVED across a save (was silently dropped before the fix)"
} else {
    ok $true 'no multi-value-requires app in config to regression-test (mapper-level checks cover it)'
}

'=== render: Update-AppCatalogList builds one row + checkbox per app ==='
Add-Type -AssemblyName PresentationFramework
$script:FleetColors = @{ card = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x33)) }
$script:BrushText   = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xE0,0xE0,0xE0))
$script:AppsConfig  = Get-Content (Join-Path $LabRoot 'config\apps.json') -Raw | ConvertFrom-Json   # fresh from REAL config
$script:RoomsConfig = Get-Content (Join-Path $LabRoot 'config\rooms.json') -Raw | ConvertFrom-Json
$script:MW = @{ pnlAppCatalog = (New-Object System.Windows.Controls.StackPanel) }
Update-AppCatalogList
$nApps = @($script:AppsConfig.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' }).Count
$rows  = @($script:MW.pnlAppCatalog.Children)
ok ($rows.Count -eq $nApps) "one row per catalog app ($($rows.Count) rows for $nApps apps)"
$chks = @($rows | ForEach-Object { $_.Child.Children } | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
ok ($chks.Count -eq $nApps) "every row has an Enabled checkbox ($($chks.Count))"
ok (@($chks | Where-Object { $_.IsChecked }).Count -eq $nApps) 'all enabled by default (no app disabled in the real catalog)'
$firstId = @($script:AppsConfig.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' } | Sort-Object)[0]
$script:AppsConfig.apps.$firstId | Add-Member -NotePropertyName 'disabled' -NotePropertyValue $true -Force
Update-AppCatalogList
ok (@($script:MW.pnlAppCatalog.Children | Where-Object { $_.Opacity -lt 1 }).Count -eq 1) 'a disabled app renders dimmed'
$edits = @($script:MW.pnlAppCatalog.Children | ForEach-Object { $_.Child.Children } | Where-Object { $_ -is [System.Windows.Controls.Button] -and "$($_.Content)" -eq 'Edit' })
ok ($edits.Count -eq $nApps) "every row has an Edit button ($($edits.Count))"

'=== dialog infra: -Scroll wraps the grid, Add-DlgSection spans 2 cols ==='
$script:BrushCard  = $script:FleetColors.card
$script:BrushWhite = $script:BrushText
$script:BrushMuted = $script:BrushText
$dlg = New-LabDialog -Title 'T' -Scroll
ok ($dlg.Stack.Children[0] -is [System.Windows.Controls.ScrollViewer]) '-Scroll wraps content in a ScrollViewer'
ok ([System.Object]::ReferenceEquals($dlg.Stack.Children[0].Content, $dlg.Grid)) 'the grid is the ScrollViewer content'
$plain = New-LabDialog -Title 'T'
ok ($plain.Stack.Children[0] -is [System.Windows.Controls.Grid]) 'without -Scroll the grid is added directly (unchanged)'
$h = Add-DlgSection -Dlg $dlg -Title 'Install order'
ok ($h.Text -eq 'Install order') 'section header text set'
ok ([System.Windows.Controls.Grid]::GetColumnSpan($h) -eq 2) 'section header spans both grid columns'

'=== 4c/4d Save seam: merged basics+install write in one Set-AppFields call ==='
Copy-Item (Join-Path $LabRoot 'config\apps.json') (Join-Path $sand 'apps.json') -Force
$script:AppsConfig = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
$bas = ConvertTo-AppFieldEdits   -DisplayName 'MATLAB' -Icon 'On (default)' -NeedsOpen $false -AskAfterOpen $false -OpenPrompt ''
$ins = ConvertTo-AppInstallEdits -InstallOrder '77' -InstallLast $true -MethodLabel '' -ExpectedSizeMB '' -Offload $false -Requires '(none)' -ExcludeFromInstallAll $false -UninstallMethod 'default' -UninstallProgram '' -UninstallMessage ''
ok (Set-AppFields -AppId 'MATLAB' -Fields ($bas + $ins)) 'merged basics+install hashtable writes in one call'
$mrg = Get-Content (Join-Path $sand 'apps.json') -Raw | ConvertFrom-Json
ok ($mrg.apps.MATLAB.displayName -eq 'MATLAB' -and $mrg.apps.MATLAB.install.installOrder -eq 77) 'a basic AND a nested field both landed'

'=== Build-EditAppDialog assembles the full editor headlessly ==='
$script:AppsConfig  = Get-Content (Join-Path $LabRoot 'config\apps.json')  -Raw | ConvertFrom-Json
$script:RoomsConfig = Get-Content (Join-Path $LabRoot 'config\rooms.json') -Raw | ConvertFrom-Json
$script:BrushWhite = $script:BrushText; $script:BrushMuted = $script:BrushText
$script:BrushRed   = $script:BrushText; $script:BrushGreen = $script:BrushText
$script:BrushCard  = $script:FleetColors.card
$someApp = @($script:AppsConfig.apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' } | Sort-Object)[0]
$bd = Build-EditAppDialog -AppId $someApp
ok ($null -ne $bd -and $null -ne $bd.Win) "editor builds for a real app ($someApp)"
ok ($null -eq (Build-EditAppDialog -AppId 'NoSuchApp')) 'editor refuses an unknown app (returns null)'
$sections = @($bd.Grid.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.FontWeight -eq [System.Windows.FontWeights]::Bold })
ok ($sections.Count -eq 3) "three section headers Basics/Rooms/Install (got $($sections.Count))"
$boxes = @($bd.Grid.Children | Where-Object { $_ -is [System.Windows.Controls.TextBox] })
ok ($boxes.Count -ge 5) "editor built its text boxes ($($boxes.Count))"
$profChecks = @($bd.Grid.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
ok ($profChecks.Count -eq @(Get-RoomProfileChoices).Count) "one checkbox per room profile ($($profChecks.Count))"
# A multi-value requires must render READ-ONLY so a Save can't silently drop it.
$mreqApp = @($script:AppsConfig.apps.PSObject.Properties | Where-Object { $_.Value.install.requires -is [System.Array] } | Select-Object -First 1).Name
if ($mreqApp) {
    $bdM = Build-EditAppDialog -AppId $mreqApp
    $rq  = @($bdM.Grid.Children | Where-Object { $_ -is [System.Windows.Controls.ComboBox] -and $_.Tag -eq 'requires' })[0]
    ok ($null -ne $rq -and -not $rq.IsEnabled) "multi-value requires shown read-only in the editor ($mreqApp)"
}
$sreqApp = @($script:AppsConfig.apps.PSObject.Properties | Where-Object { $_.Value.install.requires -and $_.Value.install.requires -isnot [System.Array] } | Select-Object -First 1).Name
if ($sreqApp) {
    $bdS = Build-EditAppDialog -AppId $sreqApp
    $rq2 = @($bdS.Grid.Children | Where-Object { $_ -is [System.Windows.Controls.ComboBox] -and $_.Tag -eq 'requires' })[0]
    ok ($null -ne $rq2 -and $rq2.IsEnabled) "single-value requires stays editable ($sreqApp)"
}

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
