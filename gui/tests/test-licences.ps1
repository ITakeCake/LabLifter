# Vendor licence codes live OUTSIDE apps.json (2026-08-18).
#
# Real ADInstruments site-licence codes used to sit inline in config\apps.json -
# in LtLabStation's msiexec arguments and in every LabChart registration.byRoom
# entry. That meant each commit published them and each clone carried them. They
# now live in config\licences.json (gitignored, but still mirrored onto sticks)
# and apps.json carries {{TOKEN}} placeholders.
#
# The failure this suite mainly defends: a stick that never received
# licences.json must FAIL LOUDLY. If an unresolved token were quietly stripped,
# msiexec would get 'LICENCE=' with no code and install an UNLICENSED product
# that detects green and only misbehaves when a class opens it.
#
# Functions are lifted out of Deploy-LabGUI.ps1 by AST; the GUI never runs.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'

$pass = 0; $fail = 0
function ok($cond, $msg) {
    if ($cond) { $script:pass++; Write-Host "PASS  $msg" }
    else       { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
}

$guiPath = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tok, [ref]$errs)
ok ($errs.Count -eq 0) "Deploy-LabGUI.ps1 parses ($($errs.Count) errors)"

$want = @('Import-Licences','Expand-LicenceTokens','Test-LicenceTokenUnresolved','Get-LicenceMissingMessage')
$loaded = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -notcontains $fn.Name) { continue }
    Set-Item -Path "function:script:$($fn.Name)" -Value $fn.Body.GetScriptBlock() -Force
    $loaded += $fn.Name
}
foreach ($w in $want) { ok ($loaded -contains $w) "lifted $w out of the GUI" }

function script:Write-LabLog { param($Event, $Data) $script:LogEvents += @{ Event = $Event; Data = $Data } }
$script:LogEvents = @()

# ---- sandbox: a fake licences.json under %TEMP%, never the real config -------
$sand = Join-Path $env:TEMP "labdeploy-licence-test-$PID"
New-Item -ItemType Directory -Force $sand | Out-Null
$fake = Join-Path $sand 'licences.json'
@'
{
  "_note": "documentation keys starting with _ must be ignored",
  "GOOD_CODE": "AAAA-BBBB-CCCC",
  "BLANK_CODE": ""
}
'@ | Set-Content $fake -Encoding UTF8

$script:LicenceFile  = $fake
$script:LicenceCache = $null

Write-Host "`n--- resolving ---"
$map = Import-Licences
ok ($map.ContainsKey('GOOD_CODE')) 'a real key is loaded'
ok (-not $map.ContainsKey('_note')) 'documentation keys (_note) are not treated as licences'
ok ((Expand-LicenceTokens 'LICENCE={{GOOD_CODE}}') -eq 'LICENCE=AAAA-BBBB-CCCC') 'a token is replaced with its code'
ok ((Expand-LicenceTokens 'a {{GOOD_CODE}} b {{GOOD_CODE}} c') -eq 'a AAAA-BBBB-CCCC b AAAA-BBBB-CCCC c') 'every occurrence is replaced, not just the first'
ok ((Expand-LicenceTokens '/qn /norestart') -eq '/qn /norestart') 'text with no token is returned untouched'
ok ((Expand-LicenceTokens '') -eq '') 'empty input is safe'
# [string]$Text coerces $null to '' at the parameter binder, so the contract is
# "returns empty and does not throw", not "returns null".
ok ((Expand-LicenceTokens $null) -eq '') 'null input is coerced to empty and does not throw'

Write-Host "`n--- the loud-failure contract ---"
# THE point of the suite: unknown tokens survive so the install gate can see them.
$unknown = Expand-LicenceTokens 'LICENCE={{NO_SUCH_KEY}}'
ok ($unknown -eq 'LICENCE={{NO_SUCH_KEY}}') 'an UNKNOWN token is left intact, never stripped'
ok (Test-LicenceTokenUnresolved $unknown) 'and Test-LicenceTokenUnresolved sees it'
# A key present but empty is the same hazard as a missing one.
$blank = Expand-LicenceTokens 'LICENCE={{BLANK_CODE}}'
ok ($blank -eq 'LICENCE={{BLANK_CODE}}') 'a key present but EMPTY is treated as missing, not as a blank code'
ok (Test-LicenceTokenUnresolved $blank) 'and it too is reported unresolved'
ok (-not (Test-LicenceTokenUnresolved 'LICENCE=AAAA-BBBB-CCCC')) 'a fully resolved string reports nothing outstanding'

$msg = Get-LicenceMissingMessage -Text 'LICENCE={{NO_SUCH_KEY}}' -AppId 'SomeApp'
ok ($msg -match 'E73')          'the message carries the E73 code'
ok ($msg -match 'NO_SUCH_KEY')  'and NAMES the token, so the fix is obvious'
ok ($msg -match 'SomeApp')      'and names the app'
ok ($msg -match 'NOTHING was installed') 'and states that nothing was installed'

Write-Host "`n--- a stick with no licences.json at all ---"
$script:LicenceFile  = Join-Path $sand 'does-not-exist.json'
$script:LicenceCache = $null
$m2 = Import-Licences
ok ($m2.Count -eq 0) 'a missing file loads as empty rather than throwing'
$still = Expand-LicenceTokens 'LICENCE={{GOOD_CODE}}'
ok (Test-LicenceTokenUnresolved $still) 'so every token stays unresolved and the gate fires'

Write-Host "`n--- the REAL config: no key may sit inline in apps.json ---"
$appsText = Get-Content (Join-Path $LabRoot 'config\apps.json') -Raw
# Any XXXX-XXXX-XXXX shaped literal inside a LICENCE= argument is a leak.
$inline = [regex]::Matches($appsText, 'LICENCE=([A-Z0-9]{4}-[A-Z0-9]{4}[A-Z0-9-]*)')
ok ($inline.Count -eq 0) "no literal code sits in a LICENCE= argument (found $($inline.Count))"
ok ($appsText -match '\{\{LTLABSTATION_CODE\}\}') 'LtLabStation uses a token instead'
ok ($appsText -match '\{\{LABCHART_SCI_CODE\}\}') 'LabChart uses a token instead'

# The committed template must exist, or a fresh clone has no idea the file is needed.
ok (Test-Path (Join-Path $LabRoot 'config\licences.example.json')) 'the committed licences.example.json template exists'
# ...and the real one must be ignored by git.
Push-Location $LabRoot
$ignored = (& git check-ignore config/licences.json 2>$null)
Pop-Location
ok ($ignored) 'config/licences.json is gitignored, so it cannot be committed'

Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
