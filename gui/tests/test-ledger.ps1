# Assignment-ledger invariants: start-at 0/1, high-water (freed numbers never
# auto-reused), swap stays in-room, retired machines excluded. Functions are
# AST-extracted from the GUI, never dot-sourced whole.
$ErrorActionPreference = 'Stop'
$LabRoot = Split-Path $PSScriptRoot -Parent
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $LabRoot 'Deploy-LabGUI.ps1'), [ref]$tok, [ref]$err)
if ($err.Count) { Write-Host 'FAIL  GUI does not parse'; exit 1 }
foreach ($name in 'Get-LedgerRoomMachines', 'Get-LedgerNextNumber', 'Set-LedgerMachine', 'Invoke-LedgerSwap') {
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL  $name not found"; exit 1 }
    Invoke-Expression $fn.Extent.Text
}

$fail = 0
function ok([bool]$Cond, [string]$Msg) { if ($Cond) { Write-Host "  ok    $Msg" } else { Write-Host "  FAIL  $Msg"; $script:fail++ } }

function New-Ledger([int]$StartAt) {
    [pscustomobject]@{
        rooms    = [pscustomobject]@{ 'ARTS-101' = [pscustomobject]@{ numbered = $true; startAt = $StartAt; mode = 'firstseen'; high = ($StartAt - 1) } }
        machines = [pscustomobject]@{}
    }
}

# ---- start at 1 --------------------------------------------------------------
$script:AssignLedger = New-Ledger 1
ok ((Get-LedgerNextNumber -Room 'ARTS-101') -eq 1) 'empty room starting at 1 hands out #1'
Set-LedgerMachine -MachineName 'PC-ALPHA' -Room 'ARTS-101' -Num (Get-LedgerNextNumber -Room 'ARTS-101')
Set-LedgerMachine -MachineName 'PC-BRAVO' -Room 'ARTS-101' -Num (Get-LedgerNextNumber -Room 'ARTS-101')
ok ((Get-LedgerNextNumber -Room 'ARTS-101') -eq 3) 'two assignments -> next is #3'

# ---- start at 0 --------------------------------------------------------------
$script:AssignLedger = New-Ledger 0
ok ((Get-LedgerNextNumber -Room 'ARTS-101') -eq 0) 'empty room starting at 0 hands out #0'

# ---- freed numbers never auto-reused (high-water survives unassign) ----------
$script:AssignLedger = New-Ledger 1
foreach ($m in 'PC-A', 'PC-B', 'PC-C') { Set-LedgerMachine -MachineName $m -Room 'ARTS-101' -Num (Get-LedgerNextNumber -Room 'ARTS-101') }
$script:AssignLedger.machines.PSObject.Properties.Remove('PC-C')   # unassign #3
ok ((Get-LedgerNextNumber -Room 'ARTS-101') -eq 4) 'unassigned #3 stays vacant - next machine gets #4'

# ---- swap --------------------------------------------------------------------
$a = $script:AssignLedger.machines.'PC-A'.num; $b = $script:AssignLedger.machines.'PC-B'.num
ok (Invoke-LedgerSwap -MachineA 'PC-A' -MachineB 'PC-B') 'swap succeeds inside one room'
ok ($script:AssignLedger.machines.'PC-A'.num -eq $b -and $script:AssignLedger.machines.'PC-B'.num -eq $a) 'numbers actually traded places'

# ---- cross-room swap refused -------------------------------------------------
$script:AssignLedger.rooms | Add-Member -NotePropertyName 'ARTS-102' -NotePropertyValue ([pscustomobject]@{ numbered = $true; startAt = 1; mode = 'manual'; high = 0 })
Set-LedgerMachine -MachineName 'PC-Z' -Room 'ARTS-102' -Num 1
ok (-not (Invoke-LedgerSwap -MachineA 'PC-A' -MachineB 'PC-Z')) 'swap across rooms is refused'

# ---- retired machines excluded ----------------------------------------------
$script:AssignLedger.machines.'PC-A'.retired = $true
$active = @(Get-LedgerRoomMachines -Room 'ARTS-101')
ok (@($active | Where-Object { $_.MachineName -eq 'PC-A' }).Count -eq 0) 'retired machine hidden from the room list'
ok ((Get-LedgerNextNumber -Room 'ARTS-101') -eq 4) 'retired machine number stays vacant too'

# ---- unnumbered rooms: assignment without numbers ----------------------------
Set-LedgerMachine -MachineName 'PC-NONUM' -Room 'ARTS-101' -Num $null
$got = @(Get-LedgerRoomMachines -Room 'ARTS-101' | Where-Object { $_.MachineName -eq 'PC-NONUM' })
ok ($got.Count -eq 1 -and $null -eq $got[0].Num) 'unnumbered machine carried with no number'

# ---- optional config file sanity --------------------------------------------
$ledFile = Join-Path $LabRoot 'config\machine-assignments.json'
if (Test-Path $ledFile) {
    try {
        $led = Get-Content $ledFile -Raw | ConvertFrom-Json
        $dupes = @()
        foreach ($rp in $led.rooms.PSObject.Properties) {
            $nums = @{}
            foreach ($mp in $led.machines.PSObject.Properties) {
                $v = $mp.Value
                if ("$($v.room)" -ne $rp.Name -or $v.retired -or $null -eq $v.num) { continue }
                if ($nums["$($v.num)"]) { $dupes += "$($rp.Name) #$($v.num)" } else { $nums["$($v.num)"] = $true }
            }
        }
        ok (-not $dupes.Count) "machine-assignments.json: no duplicate active numbers$(if ($dupes) { ' -- ' + ($dupes -join '; ') })"
    } catch { ok $false "machine-assignments.json parses ($($_.Exception.Message))" }
} else {
    ok $true 'machine-assignments.json absent (optional) - nothing to validate'
}

Write-Host ''
if ($fail) { Write-Host "FAIL $fail"; exit 1 } else { Write-Host 'PASS 11   FAIL 0'; exit 0 }
