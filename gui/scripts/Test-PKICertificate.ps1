# Test-PKICertificate.ps1
# Checks the local machine certificate store for a PKI cert matching the hostname.

$hostname = $env:COMPUTERNAME
Write-Host '--- Checking for PKI Certificate ---' -ForegroundColor Cyan
Write-Host "Searching for a certificate matching hostname: $hostname"

$certificate = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -match $hostname } |
    Select-Object -First 1

if ($certificate) {
    Write-Host '[SUCCESS] Found matching certificate!' -ForegroundColor Green
    Write-Host "  Subject: $($certificate.Subject)"
    Write-Host "  Issuer:  $($certificate.Issuer)"
    Write-Host "  Expires: $($certificate.NotAfter)"
} else {
    Write-Host '[FAILED] No PKI certificate with the hostname was found.' -ForegroundColor Red
    Write-Host 'This may be because the computer is not in the correct AD group or Group Policy has not yet run.' -ForegroundColor Yellow

    $choice = Read-Host -Prompt "Would you like to run 'gpupdate /force' now? [y/n]"
    if ($choice -match '^y') {
        Write-Host '  Running gpupdate /force... This may take a moment.'
        Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -Wait -NoNewWindow
        Write-Host '  gpupdate finished. Run this check again after a few minutes.' -ForegroundColor Green
    } else {
        Write-Host '  gpupdate skipped.'
    }
}

Write-Host ''
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
