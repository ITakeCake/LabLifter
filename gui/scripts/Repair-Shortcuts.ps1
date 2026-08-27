# Repair-Shortcuts.ps1
# Reads apps.json to know WHAT to look for, then verifies and repairs
# Public Desktop shortcuts for every app that is actually installed.
# Room-aware: if a room is specified, only checks that room's apps.

param(
    [string]$RoomId
)

$desktopPath = 'C:\Users\Public\Desktop'
$configRoot  = Join-Path $PSScriptRoot '..\config'
$appsFile    = Join-Path $configRoot 'apps.json'
$roomsFile   = Join-Path $configRoot 'rooms.json'

# ---- Load config ----
if (-not (Test-Path $appsFile)) {
    Write-Host "[ERROR] Cannot find apps.json at: $appsFile" -ForegroundColor Red
    Write-Host 'Press any key to close...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

$appsConfig  = Get-Content $appsFile  -Raw | ConvertFrom-Json
$roomsConfig = if (Test-Path $roomsFile) { Get-Content $roomsFile -Raw | ConvertFrom-Json } else { $null }

# ---- Determine which apps to check ----
$appIds = @()
if ($RoomId -and $roomsConfig) {
    $room = $roomsConfig.rooms.$RoomId
    if ($room) {
        $appIds = @($room.apps)
        Write-Host "Room profile: $($room.displayName) ($($appIds.Count) apps)" -ForegroundColor Cyan
    }
}

if ($appIds.Count -eq 0) {
    # No room specified or room not found -- check all apps in catalog
    $appIds = @($appsConfig.apps.PSObject.Properties.Name)
    if ($RoomId) {
        Write-Host "Room '$RoomId' not found in rooms.json -- checking all $($appIds.Count) apps" -ForegroundColor Yellow
    } else {
        Write-Host "No room specified -- checking all $($appIds.Count) apps in catalog" -ForegroundColor Cyan
    }
}

# ---- Build search roots for fallback scanning ----
$globalSearchRoots = @(
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    "$env:SystemDrive\Xilinx"
    "$env:SystemDrive\ANSYS Inc"
) | Where-Object { Test-Path $_ -PathType Container }

# ---- Scan existing shortcuts once ----
$existingShortcuts = Get-ChildItem -Path $desktopPath -Filter '*.lnk' -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- Verifying & Repairing Desktop Shortcuts ---' -ForegroundColor Cyan
Write-Host "Target: $desktopPath"
Write-Host ''

$created  = 0
$ok       = 0
$skipped  = 0
$failed   = 0

foreach ($appId in $appIds) {
    $appDef = $appsConfig.apps.$appId
    if (-not $appDef) {
        Write-Host "  [SKIP]    $appId - not in apps.json" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $displayName = $appDef.displayName
    $detect      = $appDef.detect
    # The icon's name can differ from the card title (apps.json "shortcutName").
    # LabVIEW: card says "... + ELVIS III", desktop must read the product name.
    $wantName    = if ($appDef.shortcutName) { [string]$appDef.shortcutName } else { $displayName }
    $strictName  = [bool]$appDef.shortcutName

    # Check if a shortcut already exists (match on EITHER name, or app ID) -
    # matching the old name too is what lets a rename be detected instead of
    # silently leaving the stale icon in place.
    $foundAll = @($existingShortcuts | Where-Object {
        $_.BaseName -match [regex]::Escape($wantName) -or
        $_.BaseName -match [regex]::Escape($displayName) -or
        $_.BaseName -match [regex]::Escape($appId)
    })
    $foundShortcut = $foundAll | Select-Object -First 1

    if ($foundShortcut) {
        # Strict cards must carry EXACTLY the configured name (and only one
        # icon). Anything else gets swept and recreated below.
        $nameOk = (-not $strictName) -or
                  (($foundAll.Count -eq 1) -and ($foundAll[0].BaseName -ceq $wantName))
        if ($nameOk) {
            Write-Host "  [OK]      $wantName - $($foundShortcut.Name)" -ForegroundColor Green
            $ok++
            continue
        }
        Write-Host "  [RENAME]  $($foundShortcut.BaseName) -> $wantName" -ForegroundColor Yellow
        foreach ($stale in $foundAll) {
            Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
        }
        # fall through to the create block, which writes the correct name
    }

    # No shortcut exists. Is the app even installed? Check known paths first.
    $exePath = $null

    # Phase 1: known paths from detect config
    if ($detect.paths) {
        foreach ($p in $detect.paths) {
            if ($detect.method -eq 'path' -and (Test-Path $p -PathType Leaf)) {
                $exePath = $p
                break
            }
            if ($detect.method -eq 'folder' -and (Test-Path $p -PathType Container)) {
                # Folder exists but we need an exe for the shortcut.
                # If searchExe is defined, search inside this folder.
                if ($detect.searchExe) {
                    $found = Get-ChildItem -Path $p -Filter $detect.searchExe -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($found) { $exePath = $found.FullName; break }
                }
            }
        }
    }

    # Phase 2: broader search if searchExe is set and we still have nothing
    if (-not $exePath -and $detect.searchExe) {
        foreach ($root in $globalSearchRoots) {
            $found = Get-ChildItem -Path $root -Filter $detect.searchExe -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { $exePath = $found.FullName; break }
        }
    }

    if (-not $exePath) {
        Write-Host "  [SKIP]    $wantName - app not installed (no shortcut needed)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # App is installed but has no shortcut (or had a wrongly-named one) -- create it
    try {
        $shell    = New-Object -ComObject WScript.Shell
        $lnkPath  = Join-Path $desktopPath "$wantName.lnk"
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath  = $exePath
        $shortcut.Description = "Launch $wantName"
        # Set working directory to the exe's folder
        $shortcut.WorkingDirectory = Split-Path $exePath -Parent
        $shortcut.Save()
        Write-Host "  [CREATED] $wantName -> $exePath" -ForegroundColor Green
        $created++
    } catch {
        Write-Host "  [FAILED]  $wantName - $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

# ---- Summary ----
Write-Host ''
Write-Host '--- Summary ---' -ForegroundColor Cyan
Write-Host "  OK:      $ok"
Write-Host "  Created: $created"
Write-Host "  Skipped: $skipped (not installed or not in catalog)"
Write-Host "  Failed:  $failed"

Write-Host ''
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
