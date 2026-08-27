# Ledger view: does the WPF actually BUILD?
#
# A parse check proves the PowerShell is syntactically valid. It does not prove
# that Grid.SetColumn is given a real column, that a Border gets one child and
# not two, or that a brush is constructed with the right argument types - all of
# which throw only when the object is created. This suite creates the controls
# for real, on an STA thread, with no window ever shown.
#
# Functions are lifted out of Deploy-LabGUI.ps1 by AST, the same way
# test-appcatalog.ps1 does it - the GUI is not executed.
#
# READ-ONLY. Builds objects in memory; touches no config, no registry, no stick.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

# WPF needs STA. Re-launch ourselves once if the host gave us MTA.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $me = $MyInvocation.MyCommand.Path
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $me
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

# ---- lift the render functions out of the GUI -------------------------------
$guiPath = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tok, [ref]$errs)
ok ($errs.Count -eq 0) "Deploy-LabGUI.ps1 parses ($($errs.Count) errors)"

$want = @('New-LedgerBrush','Add-LedgerColumns','New-StickLedgerHeader','New-StickLedgerRow','Get-PayloadManifest')
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$loaded = @()
foreach ($fn in $funcs) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
foreach ($w in $want) { ok ($loaded -contains $w) "lifted $w out of the GUI" }

# LedgerCols is module state the functions depend on - mirror it from source so
# a change to the column set breaks this test rather than the running app.
$colsAst = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    "$($n.Left)" -match 'LedgerCols' }, $true)
ok ($colsAst.Count -ge 1) 'found the LedgerCols definition in source'
if ($colsAst.Count) { $script:LedgerCols = & ([scriptblock]::Create($colsAst[0].Right.Extent.Text)) }
ok (@($script:LedgerCols).Count -ge 5) "LedgerCols has $(@($script:LedgerCols).Count) columns"

Write-Host "`n--- brushes ---"
$b = New-LedgerBrush 0x26 0x9E 0x58
ok ($b -is [System.Windows.Media.SolidColorBrush]) 'New-LedgerBrush returns a SolidColorBrush'
ok ($b.Color.G -eq 0x9E) 'the colour channels land where they are put'

Write-Host "`n--- header ---"
$hdr = New-StickLedgerHeader
ok ($hdr -is [System.Windows.Controls.Border]) 'header builds as a Border'
ok ($hdr.Child -is [System.Windows.Controls.Grid]) 'header holds a Grid'
ok ($hdr.Child.ColumnDefinitions.Count -eq @($script:LedgerCols).Count) "header has one column per LedgerCols entry"
ok ($hdr.Child.Children.Count -eq @($script:LedgerCols).Count) 'header has one TextBlock per column'

Write-Host "`n--- rows, one per state ---"
function New-Slot($n, $state, $label, $cap) {
    [pscustomobject]@{ Slot=$n; State=$state; Label=$label; CapacityGB=$cap
                       DriveId='x'; LastSeen='2026-08-07 09:00:00'; LastSynced='2026-08-07 09:00:00'
                       ManifestSig='abc'; Scope=$null; RetiredOn=$null; PriorOccupants=@() }
}
$cases = @(
    @{ N='active/in sync'; Slot=(New-Slot 7 'ACTIVE' 'LabDeploy-07' 233.1); Live=[pscustomobject]@{Letter='D';FreeGB=170}; Kind='good'; Frac=0.28 },
    @{ N='active/offline'; Slot=(New-Slot 5 'ACTIVE' 'LabDeploy-05' 16);    Live=$null;                                   Kind='warn'; Frac=-1  },
    @{ N='tombstone';      Slot=(New-Slot 10 'TOMBSTONE' $null 32);         Live=$null;                                   Kind='tomb'; Frac=-1  },
    @{ N='free slot';      Slot=(New-Slot 3 'FREE' $null 0);                Live=$null;                                   Kind='idle'; Frac=-1  },
    @{ N='over capacity';  Slot=(New-Slot 11 'ACTIVE' 'LabDeploy-11' 8);    Live=[pscustomobject]@{Letter='J';FreeGB=0};   Kind='warn'; Frac=1.15 }
)
foreach ($c in $cases) {
    $built = $null; $threw = $null
    try {
        $built = New-StickLedgerRow -SlotInfo $c.Slot -Live $c.Live -ServesText 'SCI2 142 / 143 / 145' `
                    -StatusText 'test' -StatusKind $c.Kind -CapText '10 / 32 GB' -UsedFrac $c.Frac
    } catch { $threw = $_.Exception.Message }
    ok ($null -eq $threw) "$($c.N): builds without throwing$(if($threw){" - $threw"})"
    if ($threw) { continue }
    ok ($built.Row -is [System.Windows.Controls.Border]) "$($c.N): row is a Border"
    ok ($built.Button -is [System.Windows.Controls.Button]) "$($c.N): row exposes its action button"
    ok ([int]$built.Button.Tag -eq [int]$c.Slot.Slot) "$($c.N): button carries the slot number"
    # the stripe + content grid, and the content grid's column count
    $outer = $built.Row.Child
    ok ($outer -is [System.Windows.Controls.Grid]) "$($c.N): row wraps a Grid"
    ok ($outer.Children.Count -eq 2) "$($c.N): stripe + content, exactly two children"
    $content = $outer.Children[1]
    ok ($content.ColumnDefinitions.Count -eq @($script:LedgerCols).Count) "$($c.N): content grid matches the header's column count"
    # EVERY cell must be inside the grid it is placed in - a SetColumn past the
    # end silently renders the cell in the last column, overlapping its neighbour
    $bad = @()
    foreach ($ch in $content.Children) {
        $ci = [System.Windows.Controls.Grid]::GetColumn($ch)
        if ($ci -lt 0 -or $ci -ge $content.ColumnDefinitions.Count) { $bad += $ci }
    }
    ok ($bad.Count -eq 0) "$($c.N): every cell sits in a real column"
}

Write-Host "`n--- sync affordance (regression 2026-08-12) ---"
# THE UNSYNCABLE-FLEET BUG. The first ledger shipped rows with only 'Edit...':
# no Update button, and nothing registered in $script:StickRows, so every sync
# path - the per-stick click, the queue painter, and 'Update ALL Known Sticks'
# (which refuses outright on an empty row table) - was dead while the sticks
# sat right there. A LIVE row must expose SyncButton/Bar/Status; a dead slot
# must not offer a sync it cannot run.
foreach ($c in $cases) {
    $b = New-StickLedgerRow -SlotInfo $c.Slot -Live $c.Live -ServesText 'x' -StatusText 'y' `
            -StatusKind $c.Kind -CapText 'z' -UsedFrac $c.Frac
    if ($c.Live -and $c.Kind -ne 'tomb') {
        ok ($b.SyncButton -is [System.Windows.Controls.Button]) "$($c.N): live row has an Update button"
        ok ("$($b.SyncButton.Tag)" -eq "$($c.Live.Letter)") "$($c.N): Update button carries the DRIVE LETTER, not the slot"
        ok ($b.Bar -is [System.Windows.Controls.ProgressBar]) "$($c.N): live row exposes its progress bar"
        ok ($b.Status -is [System.Windows.Controls.TextBlock]) "$($c.N): live row exposes its status text"
    } else {
        ok ($null -eq $b.SyncButton) "$($c.N): no Update button on a row with nothing to sync"
    }
}
# a stick whose label matched no slot renders with '#--', still syncable
$orphan = [pscustomobject]@{ Slot=0; Label='LABDEPLOY'; CapacityGB=57.8; DriveId='orph' }
$oLive  = [pscustomobject]@{ Letter='K'; FreeGB=12 }
$ob = New-StickLedgerRow -SlotInfo $orphan -Live $oLive -ServesText 'x' -StatusText 'no slot' `
        -StatusKind 'warn' -CapText 'z' -UsedFrac 0.7
ok ($ob.SyncButton -is [System.Windows.Controls.Button]) "unslotted live stick still gets an Update button"

Write-Host "`n--- a whole list, header + rows together ---"
$panel = New-Object System.Windows.Controls.StackPanel
$threw = $null
try {
    $panel.Children.Add((New-StickLedgerHeader)) | Out-Null
    foreach ($c in $cases) {
        $r = New-StickLedgerRow -SlotInfo $c.Slot -Live $c.Live -ServesText 'x' -StatusText 'y' `
                -StatusKind $c.Kind -CapText 'z' -UsedFrac $c.Frac
        $panel.Children.Add($r.Row) | Out-Null
    }
} catch { $threw = $_.Exception.Message }
ok ($null -eq $threw) "header and $(@($cases).Count) rows compose into one panel$(if($threw){" - $threw"})"
ok ($panel.Children.Count -eq (@($cases).Count + 1)) "panel holds the header plus every row"

# A control may only have one parent - adding a row twice is the classic WPF
# crash, and it must fail loudly rather than silently reparent.
$dup = $false
try { $panel.Children.Add($panel.Children[1]) | Out-Null } catch { $dup = $true }
ok $dup 'adding the same row twice is rejected by WPF (parent rules intact)'

Write-Host "`n--- scoped fingerprint (E74 false-alarm regression, 2026-08-12) ---"
# A scoped stick's expected manifest is staging MINUS its exclusions. The first
# ENG stick sync was byte-perfect against its scope and still failed the E74
# tripwire, because the comparison used the full-catalog staging fingerprint.
$fix = Join-Path $env:TEMP "ledger-manifest-fixture-$([guid]::NewGuid().ToString('N').Substring(0,6))"
try {
    $null = New-Item -ItemType Directory -Path "$fix\LabDeploy-InstallerSources\KeepMe" -Force
    $null = New-Item -ItemType Directory -Path "$fix\LabDeploy-InstallerSources\DropMe" -Force
    Set-Content "$fix\LabDeploy-InstallerSources\KeepMe\a.txt" 'kept'  -Encoding UTF8
    Set-Content "$fix\LabDeploy-InstallerSources\DropMe\b.txt" 'gone'  -Encoding UTF8
    $full   = Get-PayloadManifest $fix
    $scoped = Get-PayloadManifest $fix -ExcludeRel @('\LabDeploy-InstallerSources\DropMe\')
    ok ($full -ne $scoped) "excluding a folder changes the fingerprint"
    Remove-Item "$fix\LabDeploy-InstallerSources\DropMe" -Recurse -Force
    $after = Get-PayloadManifest $fix
    ok ($after -eq $scoped) "scoped staging fingerprint equals a stick that never got the excluded folder"
    ok ((Get-PayloadManifest $fix -ExcludeRel @()) -eq $after) "an empty exclusion list is a no-op"
} finally {
    Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n--- script-scope must never appear inside GetNewClosure ---"
# THE BUG THIS CATCHES, 2026-08-07. A scriptblock created with .GetNewClosure()
# gets its own session state, so:
#   READ : $script:ScopeCardUnits is NULL inside the closure even when the
#          enclosing function has just populated it. Get-ScopeSize then calls
#          .ContainsKey() on null -> "You cannot call a method on a null-valued
#          expression", which killed the Initialize picker twice.
#   WRITE: assigning $script:InitScopeResult inside the closure never reaches
#          the caller, so a completed pick came back as "cancelled".
# Anything a closure needs must be captured into a LOCAL first, and results
# carried in a hashtable (a reference type it can mutate in place).
$closures = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    "$($n.Member)" -eq 'GetNewClosure' }, $true)
ok ($closures.Count -gt 0) "found $($closures.Count) .GetNewClosure() site(s) to check"

$offenders = @()
foreach ($c in $closures) {
    $sb = $c.Expression
    if (-not ($sb -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
    $vars = $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    foreach ($v in $vars) {
        $p = "$($v.VariablePath)"
        # $script:Cards etc. are read-only lookups the old code already relies on
        # elsewhere; the ones that bite are the scope caches and any result slot.
        if ($p -match '^script:(Scope|InitScopeResult)') {
            $offenders += "L$($v.Extent.StartLineNumber): `$$p"
        }
    }
}
if ($offenders.Count) { $offenders | Select-Object -First 8 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red } }
ok ($offenders.Count -eq 0) "no closure reads or writes script-scoped Scope*/InitScopeResult vars ($($offenders.Count) found)"

# and prove the behaviour itself, so the reason is documented in a runnable form
$script:ClosureProbe = @{ x = 1 }
function Get-ClosureProbe { $sb = { $null -eq $script:ClosureProbe }.GetNewClosure(); return (& $sb) }
ok (Get-ClosureProbe) 'confirmed: script-scoped vars read as NULL inside a GetNewClosure block'

function Test-ClosureWrite {
    $ref = @{ Ok = $false }
    & ({ $ref.Ok = $true }.GetNewClosure())
    return $ref.Ok
}
ok (Test-ClosureWrite) 'confirmed: a captured hashtable IS mutable from inside a closure'

Write-Host ""
Write-Host "ledger render: $pass passed, $fail failed"
if ($fail) { exit 1 }
