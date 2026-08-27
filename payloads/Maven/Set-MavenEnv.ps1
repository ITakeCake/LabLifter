<#
    Set-MavenEnv.ps1 - post-install step for the Maven card (ENG 5105).

    WHY A SCRIPT AND NOT JUST A COPY CARD
    Apache ships Maven as a plain binary .zip. There is no installer, so the
    copy card puts the tree on disk and nothing else - and a Maven that is on
    disk but not on PATH fails the guide's own verification step (`mvn -version`)
    while looking perfectly installed. This script is the other half of the
    install: the two machine-wide environment variables the guide asks for.

        MAVEN_HOME = C:\Program Files\Apache\Maven
        PATH      += %MAVEN_HOME%\bin

    WHY IT WRITES THE REGISTRY DIRECTLY RATHER THAN USING setx OR
    [Environment]::SetEnvironmentVariable:
      * setx TRUNCATES the value it writes at 1024 characters. A lab image's
        system PATH is routinely longer than that (MATLAB, LabVIEW, Python,
        Git, Go, VS Code all append). Using setx here would silently amputate
        the end of PATH on a fully-loaded machine and break the tools that
        were installed before Maven - a catastrophic, near-invisible failure.
      * [Environment]::SetEnvironmentVariable(...,'Machine') reads the value
        EXPANDED and writes it back as a plain REG_SZ. The system PATH is a
        REG_EXPAND_SZ full of %SystemRoot%-style references; round-tripping it
        that way bakes today's expansions in permanently.
    Reading with DoNotExpandEnvironmentNames and writing with the value's
    original RegistryValueKind avoids both. This is the standard safe form.

    IDEMPOTENT: re-running is a no-op. The marker file the card detects is
    written LAST and only after both writes are read back and verified, so a
    green Maven card means verified, not attempted (same rule as the Excel
    Analysis ToolPak card).

    EXIT CODES: 0 = both variables set and verified. 1 = something failed; the
    marker is not written and LabDeploy reports the post-install step as
    incomplete while still counting Maven itself as installed (which it is -
    the files are on disk).
#>
[CmdletBinding()]
param(
    [string]$MavenHome = 'C:\Program Files\Apache\Maven'
)

$ErrorActionPreference = 'Stop'
$envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$marker = Join-Path $MavenHome '.labdeploy-env'

function Write-Step { param([string]$m) Write-Host "[Maven env] $m" }

try {
    # ---- sanity: the copy card must have landed first -------------------
    $mvn = Join-Path $MavenHome 'bin\mvn.cmd'
    if (-not (Test-Path -LiteralPath $mvn)) {
        Write-Step "FAILED: $mvn not found - the Maven files were not copied."
        exit 1
    }

    # ---- MAVEN_HOME -----------------------------------------------------
    $cur = (Get-ItemProperty -Path $envKey -Name 'MAVEN_HOME' -ErrorAction SilentlyContinue).MAVEN_HOME
    if ($cur -ne $MavenHome) {
        Set-ItemProperty -Path $envKey -Name 'MAVEN_HOME' -Value $MavenHome -Type String
        Write-Step "MAVEN_HOME = $MavenHome"
    } else {
        Write-Step "MAVEN_HOME already correct"
    }

    # ---- PATH (unexpanded, kind-preserving) -----------------------------
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $sub  = $hklm.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    if (-not $sub) { Write-Step 'FAILED: cannot open the machine Environment key for write (admin?)'; exit 1 }
    try {
        $kind    = $sub.GetValueKind('Path')
        $rawPath = [string]$sub.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $want    = '%MAVEN_HOME%\bin'
        # Match either the literal we add or an already-expanded equivalent, so
        # a machine someone fixed by hand is not given a second copy.
        $parts   = @($rawPath -split ';' | Where-Object { $_ -ne '' })
        $already = $parts | Where-Object {
            $_.TrimEnd('\') -ieq $want.TrimEnd('\') -or
            $_.TrimEnd('\') -ieq (Join-Path $MavenHome 'bin').TrimEnd('\')
        }
        if ($already) {
            Write-Step 'PATH already contains the Maven bin folder'
        } else {
            $new = ($rawPath.TrimEnd(';') + ';' + $want)
            $sub.SetValue('Path', $new, $kind)
            Write-Step "PATH += $want  (kind preserved: $kind, length $($rawPath.Length) -> $($new.Length))"
        }
    } finally { $sub.Close() }

    # ---- verify by reading back -----------------------------------------
    $mh = (Get-ItemProperty -Path $envKey -Name 'MAVEN_HOME' -ErrorAction SilentlyContinue).MAVEN_HOME
    $sub2 = $hklm.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    $pv = [string]$sub2.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $sub2.Close()
    $pathOk = ($pv -split ';' | Where-Object {
        $_.TrimEnd('\') -ieq '%MAVEN_HOME%\bin' -or $_.TrimEnd('\') -ieq (Join-Path $MavenHome 'bin').TrimEnd('\')
    }).Count -gt 0
    if ($mh -ne $MavenHome -or -not $pathOk) {
        Write-Step "FAILED verification: MAVEN_HOME='$mh' pathOk=$pathOk"
        exit 1
    }

    # ---- JAVA_HOME is Maven's own prerequisite (advisory only) -----------
    # The OpenJDK 21 MSI sets this via ADDLOCAL=...,FeatureJavaHome. If it is
    # missing, `mvn -version` will fail with "JAVA_HOME not found" even though
    # this script did its job - so say so loudly rather than failing Maven.
    $jh = (Get-ItemProperty -Path $envKey -Name 'JAVA_HOME' -ErrorAction SilentlyContinue).JAVA_HOME
    if ($jh) { Write-Step "JAVA_HOME = $jh (OK)" }
    else     { Write-Step 'WARNING: JAVA_HOME is not set machine-wide. Install the OpenJDK 21 card, then re-run this step. mvn will not start without it.' }

    # ---- tell running processes the environment changed ------------------
    # Purely cosmetic (a new logon picks it up regardless) but it means an
    # already-open cmd/Explorer on the bench sees mvn without a reboot.
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
        $r = [UIntPtr]::Zero
        [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
    } catch { }

    # ---- marker LAST, only after verification -----------------------------
    "MAVEN_HOME=$MavenHome`r`nPATH+=%MAVEN_HOME%\bin`r`nset by LabDeploy Set-MavenEnv.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n" |
        Out-File -LiteralPath $marker -Encoding ASCII -Force
    Write-Step "done - marker written to $marker"
    exit 0
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)"
    exit 1
}
