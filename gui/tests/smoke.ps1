# REAL smoke test: runs the actual Deploy-LabGUI.ps1 startup path end to end -
# config load, room detection, master tab binding, watchdog arming, UI scale - then
# screenshots the live window and closes it. Everything up to now has verified
# pieces in isolation; this is the whole thing actually starting.
#
# The copy lives IN the LabDeploy folder so $PSScriptRoot resolves to the real
# config/logs paths. Its name is not in Promote-ToStaging's allow-list, so it
# can never reach a stick, and it is deleted afterwards.
# Paths are DERIVED, never hard-coded: this suite has to run from a USB stick,
# a second PC, or a clone under any username. $LabRoot is the LabDeploy folder
# this tests\ directory sits in.
$LabRoot = Split-Path $PSScriptRoot -Parent
$ErrorActionPreference = 'Stop'
$dir  = $LabRoot
$real = Join-Path $dir 'Deploy-LabGUI.ps1'
$copy = Join-Path $dir '_smoketest_temp.ps1'
$shot = (Join-Path $env:TEMP 'labdeploy-smoke.png')
$log  = (Join-Path $env:TEMP 'labdeploy-smoke.txt')
foreach ($p in $shot, $log) { if (Test-Path $p) { Remove-Item $p -Force } }

$src = Get-Content $real -Raw
$tail = '$window.ShowDialog() | Out-Null'
if (-not $src.Contains($tail)) { throw 'could not find the ShowDialog line to substitute' }

$inject = @'
# --- SMOKE TEST HOOK (injected; not part of the real script) ---
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class SmkW32 {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out SmkR r);
}
public struct SmkR { public int L,T,Rt,B; }
"@
$smokeLog = (Join-Path $env:TEMP 'labdeploy-smoke.txt')
$window.Add_ContentRendered({
    $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{
        try {
            Start-Sleep -Milliseconds 3500   # let the scan + index build tick
            $lines = @()
            $lines += "master            : $($script:IsMaster)"
            $lines += "admin          : $($script:IsAdmin)"
            $lines += "room detected  : $script:CurrentRoom"
            $lines += "cards built    : $($script:Cards.Count)"
            $lines += "scan queue left: $($script:scanQueue.Count)"
            $lines += "MW bound       : $($script:MW.Bound)"
            $lines += "removable      : $($script:RunningFromRemovable)  (watchdog armed: $($null -ne $script:driveWatchTimer))"
            $lines += "ui scale       : $($script:UiScale)"
            $lines += "window         : $([int]$window.Width) x $([int]$window.Height)"
            $lines += "status text    : $($txtStatus.Text)"
            $lines += "summary text   : $($txtSummary.Text)"
            $tabs = @(); foreach ($t in $window.FindName('tabMain').Items) { if ($t.Visibility -eq 'Visible') { $tabs += "$($t.Header)" } }
            $lines += "visible tabs   : $($tabs -join ' | ')"
            $lines += "drive banner   : $($window.FindName('brdDriveGone').Visibility)"
            $lines | Set-Content $smokeLog -Encoding UTF8

            $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
            $r = New-Object SmkR
            [void][SmkW32]::GetWindowRect($h, [ref]$r)
            $bmp = New-Object System.Drawing.Bitmap(($r.Rt-$r.L), ($r.B-$r.T))
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $dc = $g.GetHdc(); [void][SmkW32]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc); $g.Dispose()
            $bmp.Save((Join-Path $env:TEMP 'labdeploy-smoke.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        } catch {
            "SMOKE HOOK FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Set-Content $smokeLog -Encoding UTF8
        }
        $script:ForceClose = $true
        $window.Close()
    }) | Out-Null
})
$window.ShowDialog() | Out-Null
'@

($src -replace [regex]::Escape($tail), [System.Text.RegularExpressions.Regex]::Escape($inject).Replace('\','\\')) | Out-Null
# plain string replace - regex escaping of a 40-line block is a trap
$out = $src.Substring(0, $src.LastIndexOf($tail)) + $inject
Set-Content -LiteralPath $copy -Value $out -Encoding UTF8
"smoke copy written ($([math]::Round((Get-Item $copy).Length/1KB)) KB)"

$p = Start-Process powershell.exe -Verb RunAs -PassThru -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$copy`"")
$null = $p.WaitForExit(120000)
"exited: $($p.HasExited)"
if (Test-Path $copy) { Remove-Item $copy -Force }
'--- smoke result ---'
if (Test-Path $log) { Get-Content $log } else { 'NO RESULT FILE - startup threw before the window rendered' }
"screenshot: $(Test-Path $shot)"
