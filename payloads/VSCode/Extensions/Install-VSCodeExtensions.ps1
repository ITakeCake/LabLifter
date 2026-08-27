<#
    Install-VSCodeExtensions.ps1 - the CSE extension set for ENG 5105.

    THE PROBLEM THIS SOLVES (the guide names it and then shrugs):
      "VS Code extensions are user-scoped by default. For shared lab devices,
       deploy through Intune/GPO/login script if every user must receive them
       automatically."
    Running `code --install-extension ms-python.python` while imaging installs
    it for the IMAGING TECH and nobody else. Every student logs into a fresh
    profile with an empty VS Code - which looks exactly like the step was never
    done. This is the same per-user trap the Excel Analysis ToolPak card
    documents, and it gets the same answer: write the DEFAULT USER PROFILE,
    the template Windows copies for every new account.

    VS Code's per-user extensions live in %USERPROFILE%\.vscode\extensions, so
    seeding C:\Users\Default\.vscode\extensions gives every future student the
    set on first launch. We do not hand-copy folders into it - we point the
    real VS Code CLI at it with --extensions-dir, so the folder layout and the
    extensions.json manifest are written by VS Code itself and stay valid when
    VS Code changes that layout.

    OFFLINE BY DESIGN. It installs from .vsix files staged next to this script,
    never from the marketplace. Two reasons: (1) campus HTTPS interception has
    already broken one network-dependent installer on this fleet (see the PuTTY
    card's winget certificate note), and (2) a machine imaged in September gets
    the same extension versions as one imaged in August. scripts\Get-5105Sources.ps1
    downloads the .vsix files on the bench.

    IDEMPOTENT. --force reinstalls cleanly; re-running is safe.

    EXIT 0 only when every staged .vsix is present in the Default profile
    afterwards, verified by `code --list-extensions`. The HKLM marker the card
    detects is written LAST, so a green card means verified, not attempted.
#>
[CmdletBinding()]
param(
    [string]$DefaultExt = 'C:\Users\Default\.vscode\extensions'
)

$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$markerKey = 'HKLM:\SOFTWARE\LabDeploy\VSCodeExtensions'

function Write-Step { param([string]$m) Write-Host "[VS Code ext] $m" }

try {
    # ---- VS Code must be installed first ---------------------------------
    $code = @(
        'C:\Program Files\Microsoft VS Code\bin\code.cmd',
        'C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $code) { Write-Step 'FAILED: VS Code is not installed (bin\code.cmd not found).'; exit 1 }
    Write-Step "using $code"

    # ---- the payload ------------------------------------------------------
    $vsix = @(Get-ChildItem -LiteralPath $here -Filter '*.vsix' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($vsix.Count -eq 0) {
        Write-Step "FAILED: no .vsix files staged in $here - run scripts\Get-5105Sources.ps1 on the bench first."
        exit 1
    }
    Write-Step "$($vsix.Count) extension package(s) staged"

    if (-not (Test-Path -LiteralPath $DefaultExt)) {
        New-Item -ItemType Directory -Path $DefaultExt -Force | Out-Null
    }

    # A throwaway user-data-dir keeps VS Code from writing state into the
    # imaging tech's own profile while we drive its CLI.
    $udd = Join-Path $env:TEMP ('labdeploy_vscode_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $udd -Force | Out-Null

    try {
        foreach ($v in $vsix) {
            Write-Step "installing $($v.Name)"
            # cmd /c because code.cmd is a batch wrapper; 2>&1 so vendor stderr
            # lands in the same transcript instead of tripping PowerShell.
            $out = & cmd.exe /c "`"$code`" --install-extension `"$($v.FullName)`" --force --extensions-dir `"$DefaultExt`" --user-data-dir `"$udd`"" 2>&1
            $out | ForEach-Object { Write-Host "    $_" }
        }

        # ---- verify by asking VS Code what it now sees --------------------
        $listed = @(& cmd.exe /c "`"$code`" --list-extensions --extensions-dir `"$DefaultExt`" --user-data-dir `"$udd`"" 2>&1 |
                    ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '\s' })
        Write-Step "Default profile now reports $($listed.Count): $($listed -join ', ')"

        # Every staged package must show up. The vsix filename is
        # <publisher>.<name>-<version>.vsix, so strip the trailing -version.
        $missing = @()
        foreach ($v in $vsix) {
            $id = [regex]::Replace([IO.Path]::GetFileNameWithoutExtension($v.Name), '-\d+(\.\d+)*(-.*)?$', '')
            if ($listed -notcontains $id) { $missing += $id }
        }
        if ($missing.Count -gt 0) {
            Write-Step "FAILED: not present after install -> $($missing -join ', ')"
            exit 1
        }
    }
    finally {
        Remove-Item -LiteralPath $udd -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- marker LAST ------------------------------------------------------
    if (-not (Test-Path -LiteralPath $markerKey)) { New-Item -Path $markerKey -Force | Out-Null }
    New-ItemProperty -Path $markerKey -Name 'Configured' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $markerKey -Name 'Extensions' -Value (($vsix | ForEach-Object { $_.Name }) -join '; ') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $markerKey -Name 'ConfiguredOn' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force | Out-Null
    Write-Step 'done - marker written'
    exit 0
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)"
    exit 1
}
