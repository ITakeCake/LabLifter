# Offscreen render of the Applications "Edit app" pop-out to a PNG - the visual
# companion to test-appcatalog's headless construction test. shoot-gui.ps1 can
# only shoot the MAIN window; a modal dialog (ShowDialog blocks) needs this.
# Works because Show-EditAppDialog was split into Build-EditAppDialog (assembles
# + wires, no ShowDialog) + a thin shower - we build, uncap the scroll, and
# render the visual tree directly. Run under STA:
#   powershell -STA -File tests\shoot-dialog.ps1 -AppId MATLAB -Out out.png
param(
    [string]$AppId = 'MATLAB',
    [string]$Out   = '',
    [double]$Width  = 620
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$LabRoot = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = Join-Path $env:TEMP "labdeploy-editdialog-$AppId.png" }

# AST-load exactly the functions the dialog needs (no real startup).
$src = Join-Path $LabRoot 'Deploy-LabGUI.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tok, [ref]$err)
$want = 'New-LabDialog','New-FrozenBrush','New-DlgBox','New-DlgCombo','New-DlgNumBox','Add-DlgRow',
        'Add-DlgSection','Add-DlgFooter','Set-DlgLive','Set-DlgRowVisible','Get-RoomProfileChoices',
        'ConvertTo-AppFieldEdits','ConvertTo-AppInstallEdits','Set-AppFields','Set-AppRoomMembership','Build-EditAppDialog'
$loaded = @()
foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($want -contains $d.Name) { Invoke-Expression $d.Extent.Text; $loaded += $d.Name }
}
$missing = @($want | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) { "NOT FOUND in source: $($missing -join ', ')"; exit 1 }
function Write-LabLog { param($Event, $Data) }   # stub - no logging while rendering

$script:AppsConfig  = Get-Content (Join-Path $LabRoot 'config\apps.json')  -Raw | ConvertFrom-Json
$script:RoomsConfig = Get-Content (Join-Path $LabRoot 'config\rooms.json') -Raw | ConvertFrom-Json

# Approximate the app's dark theme brushes (this harness renders LAYOUT, not
# exact colour - the real brushes live in Deploy-LabGUI.ps1's startup block).
$mk = { param($r, $g, $b) $x = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($r, $g, $b)); $x.Freeze(); $x }
$script:BrushCard  = & $mk 0x2D 0x2D 0x33
$script:BrushWhite = & $mk 0xF0 0xF0 0xF0
$script:BrushText  = & $mk 0xE0 0xE0 0xE0
$script:BrushMuted = & $mk 0x9A 0x9A 0xA2
$script:BrushRed   = & $mk 0xE0 0x6C 0x6C
$script:BrushGreen = & $mk 0x5B 0xD6 0x8A

$dlg = Build-EditAppDialog -AppId $AppId
if (-not $dlg) { "No such app: $AppId"; exit 1 }

# The live dialog scrolls its field area at 460px; for a full-height screenshot
# lift that cap so every section is in one image.
$sv = $dlg.Stack.Children[0]
if ($sv -is [System.Windows.Controls.ScrollViewer]) { $sv.MaxHeight = 6000 }

$root = $dlg.Stack
$root.Background = $script:BrushCard
$innerW = $Width - 36        # dialog StackPanel has an 18px margin each side
$root.Measure([System.Windows.Size]::new($innerW, [double]::PositiveInfinity))
$h = [int][math]::Ceiling($root.DesiredSize.Height)
$root.Arrange([System.Windows.Rect]::new(0, 0, $innerW, $h))
$root.UpdateLayout()

$rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($innerW, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($root)
$enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$fs = [System.IO.File]::Create($Out); $enc.Save($fs); $fs.Close()
"captured $AppId editor ($innerW x $h) -> $Out"
