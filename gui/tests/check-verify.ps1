# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$f   = (Join-Path $LabRoot 'Deploy-LabGUI.ps1')
$src = Get-Content $f -Raw
$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { $script:pass++; "  ok    $m" } else { $script:fail++; "  FAIL  $m" } }

ok ($src.Contains('function Invoke-VerifyShortcuts'))  'sweep extracted into a function'
ok ($src.Contains('$r = Invoke-VerifyShortcuts'))      'Verify Shortcuts BUTTON delegates to it'
ok ($src.Contains('Invoke-VerifyShortcuts -Auto'))     'batch completion calls it with -Auto'

# exactly one implementation - the whole point of extracting it
$loops = @([regex]::Matches($src, [regex]::Escape('foreach ($card in $script:Cards.Values)'))).Count
ok ($loops -eq 1) "sweep loop exists exactly once (found $loops) - button and batch share it"

# the sweep must sit inside the SAME guard as the pre-existing batch log, so it
# adds no new firing points
$iLog   = $src.IndexOf('installall.finished')
$iClear = $src.IndexOf('$script:BatchQueued = @()   #')
$iSweep = $src.IndexOf('Invoke-VerifyShortcuts -Auto')
ok ($iLog -gt 0 -and $iClear -gt $iLog -and $iSweep -gt $iClear) `
   "order is: batch log -> clear BatchQueued -> sweep  ($iLog / $iClear / $iSweep)"
ok ($src.Contains('$script:BatchQueued = @()   #')) 'BatchQueued cleared BEFORE the sweep (a long sweep cannot double-report)'

# failures must not skip the sweep - installed apps still deserve their icons
$tail = $src.Substring($iSweep, 400)
ok ($src.Substring($iClear, ($iSweep - $iClear)) -notmatch 'if \(\$done\.Count') 'sweep is unconditional, not gated on a fully-successful batch'
ok ($src.Substring([math]::Max(0,$iSweep-300), 300) -match 'try \{') 'sweep is wrapped in try/catch so a shortcut error cannot swallow the batch summary'
ok ($tail -match 'Install All finished') 'status line reports installs AND shortcuts together'

# the -Auto switch only changes reporting, never behaviour
$fnStart = $src.IndexOf('function Invoke-VerifyShortcuts')
$fnBody  = $src.Substring($fnStart, 2200)
ok ($fnBody -match '\[switch\]\$Auto') '-Auto is a reporting flag on the function'
ok (($fnBody -split '\$Auto').Count - 1 -le 3) '-Auto is not used to branch the repair logic'
ok ($fnBody -match 'Test-AppAutoShortcut') 'still honours the per-card Desktop icon policy'
ok ($fnBody -match 'return @\{') 'returns counts so callers phrase their own message'

''
"PASS $pass   FAIL $fail"
if ($fail -gt 0) { exit 1 }
