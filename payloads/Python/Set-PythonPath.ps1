<#
    Set-PythonPath.ps1 - the repair action behind the PythonPath card.

    THE FIELD REPORT (Blake, 2026-08-21):
      "It throws the correct version but the execution app alias is defaulting
       to a local version that isn't added to path"

    WHAT IS ACTUALLY HAPPENING
    Windows ships 0-byte App Execution Alias stubs for python.exe and
    python3.exe in  %LOCALAPPDATA%\Microsoft\WindowsApps , and that folder is on
    every user's USER path. Windows composes the effective PATH as
    SYSTEM entries first, then USER entries - so on a healthy machine the real
    interpreter wins and the stub is simply shadowed. Verified on the bench:

        where.exe python
          C:\Program Files\Python313\python.exe                          105816 bytes
          C:\Users\<u>\AppData\Local\Microsoft\WindowsApps\python.exe          0 bytes

    The stub only "wins" when the real Python is NOT on the SYSTEM path. So this
    is not an alias problem to be fought - it is a missing system PATH entry,
    and the alias is just what is left standing when the entry is absent.

    WHY THE ENTRY CAN BE MISSING EVEN THOUGH THE CARD WENT GREEN
    The card passes PrependPath=1, which is correct, but:
      * PrependPath is applied on a FRESH install. When the installer finds the
        same version already present it runs in modify/repair mode and does not
        re-apply the PATH options. The field logs show several Python runs that
        exited 0 in ~12s having consumed no disk at all - those were repairs,
        not installs, and a repair does not fix a PATH that was never set.
      * A pre-existing PER-USER Python (installed by a student or baked into an
        image) can also leave the machine with an interpreter that answers
        `python --version` correctly while nothing is on the system path.
    And crucially, DETECTION CANNOT SEE ANY OF THIS: the card's detect block
    only proves python.exe exists on disk. That is what the PythonPath card and
    its envpath detect method exist for: they read the real PATH every scan.

    WHAT THIS SCRIPT DOES NOT DO
    It does not delete or disable the App Execution Alias stubs. They are OS
    components, they are recreated per-user at profile creation, and the
    supported way to turn them off is a per-user Settings toggle that cannot be
    baked into an image. Fixing the system PATH makes them harmless, which is
    the smaller and more durable intervention.

    Registry is written directly rather than via setx or
    [Environment]::SetEnvironmentVariable, for the same two reasons spelled out
    in Maven\Set-MavenEnv.ps1: setx TRUNCATES PATH at 1024 characters (which on
    a loaded lab image would amputate the tools installed before Python), and
    SetEnvironmentVariable round-trips REG_EXPAND_SZ down to a plain REG_SZ,
    baking today's expansions in permanently.

    IDEMPOTENT. Re-running is a no-op. Values are read back and verified before
    this reports success, so the card greens only on a PATH that really works.

    EXIT 0 = both entries present on the system path and proven ahead of the
    WindowsApps stub. EXIT 1 = something failed; the PythonPath card stays RED
    and clicking Install re-runs just this step (seconds, no Python
    reinstall).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$envKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$envKeyPS   = "HKLM:\$envKeyPath"

function Write-Step { param([string]$m) Write-Host "[Python PATH] $m" }

try {
    # ---- 1. locate the MACHINE-WIDE interpreter --------------------------
    # Wildcarded on the version deliberately - the hardcoded-Python314 bug in
    # this card's own detect block is the reason. Newest wins.
    $py = @(Get-Item 'C:\Program Files\Python3*\python.exe' -ErrorAction SilentlyContinue) +
          @(Get-Item 'C:\Program Files (x86)\Python3*\python.exe' -ErrorAction SilentlyContinue) |
          Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $py) {
        # Say WHY, loudly: a per-user Python is the exact situation the field
        # report describes, and it is not something this step can repair -
        # a per-user install cannot be put on the system path for everyone.
        $userPy = @(Get-Item "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue) |
                  Select-Object -First 1
        if ($userPy) {
            Write-Step "FAILED: the only Python here is a PER-USER install at $($userPy.FullName)."
            Write-Step 'That cannot be added to the system PATH for other users. Uninstall it from'
            Write-Step 'Settings > Apps for THIS user, then re-run the Python card so the all-users'
            Write-Step 'installer performs a fresh install rather than a repair.'
        } else {
            Write-Step 'FAILED: no machine-wide Python found under Program Files.'
        }
        exit 1
    }
    $pyDir     = Split-Path $py.FullName -Parent
    $scriptsDir = Join-Path $pyDir 'Scripts'
    Write-Step "machine-wide Python: $($py.FullName)"

    # ---- 2. ensure both entries lead the SYSTEM path ---------------------
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $sub  = $hklm.OpenSubKey($envKeyPath, $true)
    if (-not $sub) { Write-Step 'FAILED: cannot open the machine Environment key for write (admin?)'; exit 1 }
    try {
        $kind = $sub.GetValueKind('Path')
        $raw  = [string]$sub.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
        $norm  = { param($s) ([string]$s).Trim().TrimEnd('\').ToLowerInvariant() }

        # python.org's own installer writes these WITH a trailing backslash; match
        # either form so a machine it already configured is not given duplicates.
        $want = @($pyDir, $scriptsDir)
        $have = @($parts | ForEach-Object { & $norm $_ })
        $missing = @($want | Where-Object { $have -notcontains (& $norm $_) })

        # WindowsApps in the SYSTEM path would defeat the system-before-user rule
        # this whole fix relies on, so check for it rather than assuming.
        $aliasIdx = -1
        for ($i = 0; $i -lt $parts.Count; $i++) { if ($parts[$i] -match '(?i)WindowsApps') { $aliasIdx = $i; break } }
        $pyIdx = -1
        for ($i = 0; $i -lt $parts.Count; $i++) { if ((& $norm $parts[$i]) -eq (& $norm $pyDir)) { $pyIdx = $i; break } }
        $needsReorder = ($aliasIdx -ge 0 -and $pyIdx -ge 0 -and $aliasIdx -lt $pyIdx)
        if ($aliasIdx -ge 0) { Write-Step "NOTE: WindowsApps is on the SYSTEM path at position $aliasIdx - unusual; ordering enforced below." }

        if ($missing.Count -eq 0 -and -not $needsReorder) {
            Write-Step 'system PATH already correct (both entries present, ahead of any alias)'
        } else {
            # Rebuild: drop our two entries wherever they were, then PREPEND them
            # in python.org's own order (Scripts first, then the root).
            $kept = @($parts | Where-Object { $w = & $norm $_; $w -ne (& $norm $pyDir) -and $w -ne (& $norm $scriptsDir) })
            $new  = (@("$scriptsDir\", "$pyDir\") + $kept) -join ';'
            $sub.SetValue('Path', $new, $kind)
            Write-Step "system PATH updated (kind preserved: $kind, length $($raw.Length) -> $($new.Length))"
            Write-Step "  prepended: $scriptsDir\  ;  $pyDir\"
        }
    } finally { $sub.Close() }

    # ---- 3. verify by reading back ---------------------------------------
    $sub2 = $hklm.OpenSubKey($envKeyPath, $false)
    $rawV = [string]$sub2.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $sub2.Close()
    $partsV = @($rawV -split ';' | Where-Object { $_ -ne '' })
    $normV  = @($partsV | ForEach-Object { ([string]$_).Trim().TrimEnd('\').ToLowerInvariant() })
    $okPy      = $normV -contains $pyDir.TrimEnd('\').ToLowerInvariant()
    $okScripts = $normV -contains $scriptsDir.TrimEnd('\').ToLowerInvariant()
    if (-not $okPy -or -not $okScripts) {
        Write-Step "FAILED verification: python=$okPy scripts=$okScripts"
        exit 1
    }
    Write-Step 'verified: both entries present on the system PATH'

    # ---- 4. report the alias stubs (informational, never fatal) -----------
    # Proof for the log that the stub is now shadowed rather than removed.
    $stub = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\python.exe'
    if (Test-Path -LiteralPath $stub) {
        $len = (Get-Item -LiteralPath $stub).Length
        Write-Step "App Execution Alias stub present ($len bytes) - harmless: it sits on the USER path, which Windows searches AFTER the system path."
    }

    # ---- 5. tell running processes the environment changed ----------------
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
        $r = [UIntPtr]::Zero
        [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
    } catch { }

    # ---- 6. done. NO marker file, deliberately: the PythonPath card's 'envpath'
    # detect method re-reads the real system PATH on every scan, so the card is
    # ground truth rather than a record of a past success. A marker would keep
    # claiming victory after someone edited PATH; this cannot.
    Write-Step 'done - Python is on the system PATH'
    Write-Step 'Check with a NEW console: where python   (Program Files must be listed first)'
    exit 0
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)"
    exit 1
}
