$ErrorActionPreference = "Stop"

$BaseUrl = "https://raw.githubusercontent.com/RileyBeenders/RB-s-Auto-App-Updater/main"
$Manifest = Invoke-RestMethod "$BaseUrl/version.json"

$TemporaryScript = Join-Path $env:TEMP "RB-App-Auto-Updater.ps1"

try {
    Write-Host "Downloading RB's App Auto Updater..." -ForegroundColor Cyan

    Invoke-WebRequest `
        -Uri "$BaseUrl/$($Manifest.script)" `
        -OutFile $TemporaryScript `
        -UseBasicParsing

    $ActualHash = (
        Get-FileHash $TemporaryScript -Algorithm SHA256
    ).Hash.ToLower()

    $ExpectedHash = ([string]$Manifest.sha256).ToLower()

    if ($ActualHash -ne $ExpectedHash) {
        throw "Security check failed: downloaded script hash does not match version.json."
    }

    Write-Host "Download verified. Starting installation..." -ForegroundColor Green

    $Process = Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$TemporaryScript`"" `
        -Wait `
        -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "Installation exited with code $($Process.ExitCode)."
    }
}
finally {
    Remove-Item $TemporaryScript -Force -ErrorAction SilentlyContinue
}