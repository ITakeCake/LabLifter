# Config lint: schema + cross-reference checks over the REAL config files.
# Nothing in the app validates apps.json field shape today - a typo'd install
# method or a detect rule missing its paths only surfaces as E20/E10 on a lab
# machine, when Blake is not there. This suite fails on the master instead.
#
#   1. apps.json     - every card has the fields the engine actually consumes,
#                      per install/detect method; requires ids exist, no cycles;
#                      regex fields compile
#   2. rooms.json    - every profile app id exists; no duplicates in a set
#   3. buildings.json- 2-3 digit codes, no prefix collisions (decoder safety)
#   4. rules         - the app's own Test-RulesSane, run as a test for once
#   5. reachability  - every rule wins for a hostname in its own range
#                      (decode -> resolve round-trip through the REAL engine)
#   6. enum drift    - the lint's method lists still match the source switches
#
# READ-ONLY: loads config, never writes it. No sandbox needed.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

$f = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$src = Get-Content $f -Raw
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
$want = @('Test-RulesSane','Test-RuleHasApps','Get-RuleApps','ConvertFrom-MachineToken',
          'ConvertFrom-LabHostname','Resolve-DeployRule','Test-NumToken')
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$missing = @($want | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) { "NOT FOUND in source: $($missing -join ', ')"; exit 1 }
function Write-LabLog { param($Event, $Data) }

$pass = 0; $fail = 0
function ok($cond, $msg) { if ($cond) { $script:pass++; "  ok    $msg" } else { $script:fail++; "  FAIL  $msg" } }

# ---- the real config, loaded exactly as startup does ----
$script:AppsConfig      = Get-Content (Join-Path $LabRoot 'config\apps.json') -Raw | ConvertFrom-Json
$script:RoomsConfig     = Get-Content (Join-Path $LabRoot 'config\rooms.json') -Raw | ConvertFrom-Json
$script:BuildingsConfig = Get-Content (Join-Path $LabRoot 'config\buildings.json') -Raw | ConvertFrom-Json
$script:RulesConfig     = Get-Content (Join-Path $LabRoot 'config\deployment-rules.json') -Raw | ConvertFrom-Json

$apps     = $script:AppsConfig.apps
$appIds   = @($apps.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
$DETECT_METHODS  = @('path','folder','registry','appx','filematch','envpath')   # switch at Test-AppInstalled
$INSTALL_METHODS = @('winget','copy','exe','msi','msix','psadt')  # E20 switch in Start-SingleInstall

'=== 1. apps.json card schema (what the engine actually consumes) ==='
ok ($appIds.Count -ge 40) "catalog has a sane card count ($($appIds.Count))"

$bad = @{}   # category -> list of offending "id (why)" strings
function flag($cat, $what) { if (-not $bad[$cat]) { $bad[$cat] = @() } $bad[$cat] += $what }

foreach ($id in $appIds) {
    $a = $apps.$id
    if (-not "$($a.displayName)".Trim()) { flag 'displayName' $id }

    $d = $a.detect
    if (-not $d)                                { flag 'detect' "$id (missing block)" }
    elseif ($DETECT_METHODS -notcontains "$($d.method)") { flag 'detect' "$id (method '$($d.method)')" }
    else {
        switch ("$($d.method)") {
            'path'     { if (@($d.paths | Where-Object { "$_".Trim() }).Count -eq 0) { flag 'detect' "$id (path: no paths)" } }
            'folder'   { if (@($d.paths | Where-Object { "$_".Trim() }).Count -eq 0) { flag 'detect' "$id (folder: no paths)" } }
            'registry' { if (-not "$($d.key)".Trim() -or -not "$($d.value)".Trim())  { flag 'detect' "$id (registry: key/value)" } }
            'appx'     { if (-not "$($d.packageName)".Trim())                        { flag 'detect' "$id (appx: packageName)" } }
            'envpath'  { if (-not "$($d.exe)".Trim())                                { flag 'detect' "$id (envpath: exe)" } }
        }
        if ($d.pathMustMatch) { try { [void][regex]::new("$($d.pathMustMatch)") } catch { flag 'regex' "$id (detect.pathMustMatch)" } }
    }

    $i = $a.install
    if (-not $i)                                 { flag 'install' "$id (missing block)" }
    elseif ($INSTALL_METHODS -notcontains "$($i.method)") { flag 'install' "$id (method '$($i.method)')" }
    else {
        switch ("$($i.method)") {
            'winget' { if (-not "$($i.id)".Trim())        { flag 'install' "$id (winget: no id)" } }
            'copy'   { if (-not "$($i.sourceSub)".Trim() -or -not "$($i.destination)".Trim()) { flag 'install' "$id (copy: sourceSub/destination)" } }
            'psadt'  { if (-not "$($i.package)".Trim())   { flag 'install' "$id (psadt: no package)" } }
            default  { if (-not "$($i.sourceSub)".Trim()) { flag 'install' "$id ($($i.method): no sourceSub)" } }
        }
        foreach ($req in @($i.requires)) {
            if ($req -and -not $apps.$req) { flag 'requires' "$id -> '$req'" }
        }
        if ($i.fallback) {
            if ($INSTALL_METHODS -notcontains "$($i.fallback.method)") { flag 'fallback' "$id (method '$($i.fallback.method)')" }
            if ("$($i.fallback.method)" -ne 'winget' -and -not "$($i.fallback.sourceSub)".Trim()) { flag 'fallback' "$id (no sourceSub)" }
        }
    }

    if ($a.shortcutMatch) { try { [void][regex]::new("$($a.shortcutMatch)") } catch { flag 'regex' "$id (shortcutMatch)" } }
    if ($null -ne $a.quietTasks) {   # @($null) unrolls to one $null entry - the very trap test-collections documents
        foreach ($qt in @($a.quietTasks)) { if (-not "$qt".Trim()) { flag 'quietTasks' "$id (blank entry)" } }
    }
}

# requires must never form a loop: the dependency chain in Start-SingleInstall
# re-queues the parent, so A->B->A would ping-pong forever on a lab machine.
foreach ($id in $appIds) {
    $seen = @{}; $stack = New-Object System.Collections.Stack; $stack.Push($id)
    while ($stack.Count) {
        $cur = $stack.Pop()
        if ($seen[$cur]) { flag 'reqCycle' "$id (revisits $cur)"; break }
        $seen[$cur] = $true
        foreach ($req in @($apps.$cur.install.requires)) { if ($req -and $apps.$req) { $stack.Push($req) } }
    }
}

foreach ($cat in 'displayName','detect','install','requires','fallback','regex','quietTasks','reqCycle') {
    $label = switch ($cat) {
        'displayName' { 'every card has a displayName' }
        'detect'      { 'every detect block is complete for its method' }
        'install'     { 'every install block is complete for its method' }
        'requires'    { 'every requires id exists in the catalog' }
        'fallback'    { 'every fallback block is complete' }
        'regex'       { 'every regex field compiles' }
        'quietTasks'  { 'no blank quietTasks entries' }
        'reqCycle'    { 'no requires cycles (the dep chain would ping-pong)' }
    }
    ok (-not $bad[$cat]) "$label$(if ($bad[$cat]) { ' -- ' + ($bad[$cat] -join '; ') })"
}

'=== 2. rooms.json package sets ==='
$profiles = @($script:RoomsConfig.rooms.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
ok ($profiles.Count -ge 1) "package sets present ($($profiles -join ', '))"
$badRoom = @(); $dupRoom = @()
foreach ($p in $profiles) {
    $list = @($script:RoomsConfig.rooms.$p.apps)
    foreach ($aId in $list) { if ($aId -and -not $apps.$aId) { $badRoom += "$p -> '$aId'" } }
    $dupes = @($list | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($g in $dupes) { $dupRoom += "$p lists '$($g.Name)' $($g.Count)x" }
}
ok (-not $badRoom.Count) "every package-set app exists in the catalog$(if ($badRoom.Count) { ' -- ' + ($badRoom -join '; ') })"
ok (-not $dupRoom.Count) "no duplicates inside a set (order IS install order)$(if ($dupRoom.Count) { ' -- ' + ($dupRoom -join '; ') })"

'=== 3. buildings.json decoder safety ==='
$codes = @($script:BuildingsConfig.buildings.PSObject.Properties.Name)
ok ($codes.Count -ge 1) "building codes present ($($codes.Count))"
$badCode = @($codes | Where-Object { $_ -notmatch '^\d{2,3}$' })
ok (-not $badCode.Count) "every code is 2-3 digits$(if ($badCode.Count) { ' -- ' + ($badCode -join ', ') })"
# a 2-digit code that prefixes a 3-digit one makes hostnames ambiguous - the
# decoder tries longest-first, so '5' vs '55' would silently mis-split rooms
$clash = @()
foreach ($c in $codes) { foreach ($c2 in $codes) {
    if ($c -ne $c2 -and $c2.StartsWith($c)) { $clash += "$c prefixes $c2" }
} }
ok (-not $clash.Count) "no code is a prefix of another$(if ($clash.Count) { ' -- ' + ($clash -join '; ') })"
$noAbbr = @($codes | Where-Object { -not "$($script:BuildingsConfig.buildings.$_.abbr)".Trim() })
ok (-not $noAbbr.Count) "every building has an abbr$(if ($noAbbr.Count) { ' -- ' + ($noAbbr -join ', ') })"

'=== 4. deployment rules: the app''s own validator, run as a test ==='
$sane = Test-RulesSane -Rules @($script:RulesConfig.rules)
ok $sane.Ok "Test-RulesSane is clean on the real rules$(if (-not $sane.Ok) { '' })"
if (-not $sane.Ok) { foreach ($p in $sane.Problems) { "        problem: $p" } }
$badTok = @()
foreach ($r in @($script:RulesConfig.rules)) {
    foreach ($fld in 'machines','rooms') {
        if ("$($r.$fld)".Trim()) {
            try { [void](ConvertFrom-MachineToken -Token "$($r.$fld)" -Max 9999) } catch { $badTok += "'$($r.$fld)' ($fld)" }
        }
    }
    if (-not $script:BuildingsConfig.buildings.("$($r.building)")) { $badTok += "unknown building '$($r.building)'" }
}
ok (-not $badTok.Count) "every rule's tokens parse and its building exists$(if ($badTok.Count) { ' -- ' + ($badTok -join '; ') })"

'=== 5. reachability: each rule wins for its own coordinates ==='
# Build a campus-convention hostname inside the rule's own range, decode it
# with the real decoder, resolve it with the real resolver, and demand the
# SAME rule wins. A rule that cannot win for its own coordinates is dead
# config - exactly the mistake first-match-wins makes easy.
$ri = 0
foreach ($r in @($script:RulesConfig.rules)) {
    $ri++
    $room = if ("$($r.rooms)".Trim()) { (ConvertFrom-MachineToken -Token "$($r.rooms)" -Max 9999).From } else { 101 }
    $mach = if ("$($r.machines)".Trim()) { (ConvertFrom-MachineToken -Token "$($r.machines)" -Max 9999).From } else { 2 }
    $type = if ("$($r.types)".Trim()) { ("$($r.types)" -split ',')[0].Trim().ToUpper() }
            else { $tc = @($script:BuildingsConfig.typeCodes.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
                   if ($tc.Count) { $tc[0] } else { 'CART' } }
    $host2 = '{0}{1:000}{2}34-{3:00}' -f $r.building, [int]$room, $type, [int]$mach
    $dec = ConvertFrom-LabHostname -Hostname $host2
    $win = Resolve-DeployRule -Decode $dec
    ok ($dec.Matched -and $dec.Building -eq "$($r.building)") "rule $ri coordinates decode ($host2 -> bldg $($dec.Building), room $($dec.Room), #$($dec.Machine))"
    ok ($null -ne $win -and ([object]::ReferenceEquals($win, $r) -or $win -eq $r)) "rule $ri wins for its own coordinates$(if ($win -and -not ([object]::ReferenceEquals($win, $r))) { ' -- SHADOWED by an earlier rule' } elseif (-not $win) { ' -- NO rule matched' })"
    if ($win) {
        $resolved = Get-RuleApps -Rule $win
        if ($null -ne $resolved) {
            ok (@($resolved).Count -eq @(@($win.apps) | Where-Object { $_ -and $apps.$_ }).Count) "rule $ri inline apps all survive catalog filtering ($(@($resolved).Count) of $(@($win.apps).Count))"
        }
    }
}

'=== 6. enum drift: lint lists still match the source switches ==='
# If a new method lands in the code, this suite must learn it, not silently
# skip it. Read the ACTUAL switch labels out of the AST and demand set
# equality with the lists used above.
$labelSets = @()
foreach ($sw in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)) {
    $labels = @($sw.Clauses | ForEach-Object { $_.Item1 } |
        Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } |
        ForEach-Object { $_.Value })
    if ($labels.Count) { $labelSets += ,$labels }
}
# several switches key on install method (Start-SingleInstall, uninstall,
# the card's method label); the E20 one carries every method - demand that
# SOME switch matches the lint list exactly.
$exp = (@($INSTALL_METHODS) | Sort-Object) -join ','
$instHit = @($labelSets | Where-Object { ((@($_) | Sort-Object) -join ',') -eq $exp })
ok ($instHit.Count -ge 1) "a switch in the source carries exactly the lint's install methods ($exp)"
$detSw = @($labelSets | Where-Object { $_ -contains 'appx' -and $_ -contains 'registry' -and $_ -contains 'folder' })
ok ($detSw.Count -ge 1) "found the detect-method switch in the source ($($detSw.Count) candidate(s))"
if ($detSw.Count) {
    $got = (@($detSw[0]) | Sort-Object) -join ','
    $exp = (@($DETECT_METHODS) | Sort-Object) -join ','
    ok ($got -eq $exp) "detect-method switch labels match the lint list ($got)"
}

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
