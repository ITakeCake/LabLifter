# Parse-WingetSearchOutput: the pure text->rows half of the ADD FROM WINGET
# suggestion box. Extracted from the GUI by AST (never dot-source the whole
# 20k-line app just to test one function).
$ErrorActionPreference = 'Stop'
$LabRoot = Split-Path $PSScriptRoot -Parent
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $LabRoot 'Deploy-LabGUI.ps1'), [ref]$tok, [ref]$err)
if ($err.Count) { Write-Host "FAIL  GUI does not parse"; exit 1 }
$fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Parse-WingetSearchOutput' }, $true) | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL  Parse-WingetSearchOutput not found'; exit 1 }
Invoke-Expression $fn.Extent.Text

$fail = 0
function ok([bool]$Cond, [string]$Msg) { if ($Cond) { Write-Host "  ok    $Msg" } else { Write-Host "  FAIL  $Msg"; $script:fail++ } }

$ell = [string][char]0x2026   # the ellipsis winget uses when it truncates a column

# realistic winget search output: preamble noise, fixed-width header, dashes,
# rows - including one whose Id was truncated (must be dropped, not saved)
$sample = @(
    '   -',
    '   \',
    'Name                           Id                         Version      Match          Source',
    '---------------------------------------------------------------------------------------------',
    'Google Chrome                  Google.Chrome              139.0.7258   Moniker: chrome winget',
    'Chrome Remote Desktop Host     Google.ChromeRemoteDesktop 138.0.1      Tag: chrome    winget',
    ("Chrome Canary Preview          Google.ChromeCan$ell         140.0        Tag: chrome    winget"),
    ''
)
$rows = @(Parse-WingetSearchOutput -Lines $sample)
ok ($rows.Count -eq 2) "truncated-Id row dropped, 2 of 3 rows kept (got $($rows.Count))"
ok ($rows[0].Name -eq 'Google Chrome') "name parsed ('$($rows[0].Name)')"
ok ($rows[0].Id -eq 'Google.Chrome') "id parsed ('$($rows[0].Id)')"
ok ($rows[0].Version -eq '139.0.7258') "version parsed ('$($rows[0].Version)')"
ok ($rows[1].Id -eq 'Google.ChromeRemoteDesktop') 'second row id intact'

# no header at all (winget error text, no internet) -> empty, never throws
$rows2 = @(Parse-WingetSearchOutput -Lines @('No package found matching input criteria.'))
ok ($rows2.Count -eq 0) 'headerless output yields zero rows, no throw'

# empty input
$rows3 = @(Parse-WingetSearchOutput -Lines @())
ok ($rows3.Count -eq 0) 'empty input yields zero rows'

Write-Host ''
if ($fail) { Write-Host "FAIL $fail"; exit 1 } else { Write-Host 'PASS 7   FAIL 0'; exit 0 }
