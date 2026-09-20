# RB's App Auto Updater - Friendly Error Handling Edition
#
# Save this file as:
#   Setup-AppAutoUpdater.ps1
#
# Then right-click the .ps1 file and choose "Run with PowerShell".
# Run this setup again whenever you want to reinstall or update the updater.

param(
    [switch]$SelfUpdate
)

# ============================================================
# App Auto Updater v2 - One-Time Setup
# ============================================================

$ErrorActionPreference = "Stop"

$UpdaterVersion = [version]"2.1.1"
$RepositoryRawBase = "https://raw.githubusercontent.com/RileyBeenders/RB-s-Auto-App-Updater/main"
$VersionManifestUrl = "$RepositoryRawBase/version.json"
$UpdaterScriptUrl = "$RepositoryRawBase/AutoAppUpdater.ps1"
$ShortcutIconUrl = "$RepositoryRawBase/icon.png"

# ------------------------------------------------------------
# Elevate this setup script once
# ------------------------------------------------------------

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$PrincipalCheck = New-Object Security.Principal.WindowsPrincipal($Identity)

if (-not $PrincipalCheck.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Host "Administrator permission is required for initial setup."

    $SelfUpdateArgument = if ($SelfUpdate) { " -SelfUpdate" } else { "" }

    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$SelfUpdateArgument" `
        -Verb RunAs

    exit
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$TaskName = "WinGet Silent Upgrade"
$SelfUpdateTaskName = "RB App Auto Updater Self Update"

$AppFolder     = Join-Path $env:LOCALAPPDATA "WingetUpdater"
$LauncherPath  = Join-Path $AppFolder "WingetUpdater.ps1"
$DesktopPath   = [Environment]::GetFolderPath("Desktop")
$ShortcutPath  = Join-Path $DesktopPath "App Auto Updater.lnk"
$IconPath      = Join-Path $AppFolder "AppAutoUpdater.ico"

# The elevated worker is stored in Program Files. Standard,
# non-elevated processes cannot modify it without UAC approval.
$InstallFolder = Join-Path $env:ProgramFiles "RB App Auto Updater"
$WorkerPath    = Join-Path $InstallFolder "WingetUpdaterWorker.ps1"
$SelfUpdateBootstrapPath = Join-Path $InstallFolder "WingetUpdaterSelfUpdate.ps1"
$VersionFile = Join-Path $AppFolder "updater-version.txt"

# ------------------------------------------------------------
# Make sure WinGet exists
# ------------------------------------------------------------

try {
    $WingetPath = (Get-Command winget.exe -ErrorAction Stop).Source
}
catch {
    Write-Host "ERROR: winget.exe could not be found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Found WinGet:"
Write-Host $WingetPath
Write-Host ""

# ------------------------------------------------------------
# Create required directories
# ------------------------------------------------------------

New-Item -ItemType Directory -Path $AppFolder -Force | Out-Null
New-Item -ItemType Directory -Path $InstallFolder -Force | Out-Null

Set-Content `
    -Path $VersionFile `
    -Value $UpdaterVersion.ToString() `
    -Encoding ASCII

# ============================================================
# CREATE USER-FACING LAUNCHER
# ============================================================

$LauncherScript = @'
param(
    [switch]$SkipUpdateCheck
)

$Host.UI.RawUI.WindowTitle = "App Auto Updater"

Clear-Host

$TaskName = "WinGet Silent Upgrade"
$SelfUpdateTaskName = "RB App Auto Updater Self Update"
$AppFolder = Join-Path $env:LOCALAPPDATA "WingetUpdater"
$LauncherPath = Join-Path $AppFolder "WingetUpdater.ps1"
$InstalledUpdaterVersion = [version]"__UPDATER_VERSION__"
$VersionManifestUrl = "__VERSION_MANIFEST_URL__"

$StatusFile   = Join-Path $AppFolder "status.log"
$ResultFile   = Join-Path $AppFolder "worker-result.json"
$DoneFile     = Join-Path $AppFolder "done.flag"
$DetailLog    = Join-Path $AppFolder "winget-details.log"
$ProgressFile = Join-Path $AppFolder "progress.json"
$SelfUpdateProgressFile = Join-Path $AppFolder "self-update-progress.json"
$SelfUpdateDoneFile = Join-Path $AppFolder "self-update-done.json"

function Write-ColoredStatusLine {
    param([string]$Line)

    if ($Line -match '\[OK\]') {
        Write-Host $Line -ForegroundColor Green
    }
    elseif ($Line -match '\[RETRY AS USER\]') {
        Write-Host $Line -ForegroundColor Cyan
    }
    elseif ($Line -match '\[SECURITY BLOCKED\]') {
        Write-Host $Line -ForegroundColor Red
    }
    elseif ($Line -match '\[MANUAL UPDATE\]') {
        Write-Host $Line -ForegroundColor Yellow
    }
    elseif ($Line -match '\[CLOSE APP\]') {
        Write-Host $Line -ForegroundColor Yellow
    }
    elseif ($Line -match '\[RESTART REQUIRED\]') {
        Write-Host $Line -ForegroundColor Yellow
    }
    elseif ($Line -match '\[NO ACTION\]') {
        Write-Host $Line -ForegroundColor DarkGray
    }
    elseif ($Line -match '\[FAILED\]' -or $Line -match '\[ERROR\]') {
        Write-Host $Line -ForegroundColor Red
    }
    else {
        Write-Host $Line
    }
}

Write-Host "==========================================" -ForegroundColor Blue
Write-Host "          RB's App Auto Updater" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Blue
Write-Host "  Version: 2.1.1" -ForegroundColor White
Write-Host "  Notes:" -ForegroundColor White
Write-Host "    - Testing to see if updates work correctly." -ForegroundColor Gray
Write-Host ""

# ------------------------------------------------------------
# Check for an updater release before scanning applications
# ------------------------------------------------------------

if (-not $SkipUpdateCheck) {
    try {
        Write-Host "Checking for updater updates..." -ForegroundColor Cyan

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $ManifestResponse = Invoke-WebRequest `
            -Uri $VersionManifestUrl `
            -UseBasicParsing `
            -Headers @{ "User-Agent" = "RB-App-Auto-Updater" } `
            -TimeoutSec 15

        $RemoteManifest = $ManifestResponse.Content | ConvertFrom-Json
        $RemoteVersion = [version]$RemoteManifest.version

        if ($RemoteVersion -gt $InstalledUpdaterVersion) {
            Write-Host "Updater version $RemoteVersion is available." -ForegroundColor Green
            Write-Host "Installing the updater update before checking applications..." -ForegroundColor Green
            Write-Host ""

            Remove-Item $SelfUpdateProgressFile -Force -ErrorAction SilentlyContinue
            Remove-Item $SelfUpdateDoneFile -Force -ErrorAction SilentlyContinue

            Start-ScheduledTask -TaskName $SelfUpdateTaskName -ErrorAction Stop

            $SelfUpdateStarted = Get-Date
            $SelfUpdateTimeout = New-TimeSpan -Minutes 15

            while (-not (Test-Path $SelfUpdateDoneFile)) {
                if (Test-Path $SelfUpdateProgressFile) {
                    try {
                        $UpdateProgress = Get-Content $SelfUpdateProgressFile -Raw -ErrorAction Stop |
                            ConvertFrom-Json -ErrorAction Stop

                        $UpdatePercent = [int]$UpdateProgress.Percent

                        if ($UpdatePercent -lt 0) {
                            $UpdatePercent = 0
                        }
                        elseif ($UpdatePercent -gt 100) {
                            $UpdatePercent = 100
                        }

                        Write-Progress `
                            -Activity "Updating RB's App Auto Updater..." `
                            -Status ([string]$UpdateProgress.Message) `
                            -PercentComplete $UpdatePercent
                    }
                    catch {
                        # The elevated updater may be replacing the JSON file.
                    }
                }

                if (((Get-Date) - $SelfUpdateStarted) -gt $SelfUpdateTimeout) {
                    throw "The updater update exceeded the 15-minute timeout."
                }

                try {
                    $SelfUpdateTaskState = (
                        Get-ScheduledTask -TaskName $SelfUpdateTaskName -ErrorAction Stop
                    ).State

                    if (
                        $SelfUpdateTaskState -ne "Running" -and
                        ((Get-Date) - $SelfUpdateStarted).TotalSeconds -gt 5 -and
                        -not (Test-Path $SelfUpdateDoneFile)
                    ) {
                        throw "The self-update task stopped before reporting a result."
                    }
                }
                catch {
                    if ($_.Exception.Message -eq "The self-update task stopped before reporting a result.") {
                        throw
                    }
                }

                Start-Sleep -Milliseconds 350
            }

            Write-Progress -Activity "Updating RB's App Auto Updater..." -Completed

            $SelfUpdateResult = Get-Content $SelfUpdateDoneFile -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop

            if (-not [bool]$SelfUpdateResult.Success) {
                throw "Updater update failed: $($SelfUpdateResult.Error)"
            }

            Write-Host "Updater successfully updated to version $RemoteVersion." -ForegroundColor Green
            Write-Host "Continuing with the refreshed updater..." -ForegroundColor Green
            Write-Host ""

            Start-Process powershell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`" -SkipUpdateCheck"

            exit
        }
        else {
            Write-Host "Updater is current (version $InstalledUpdaterVersion)." -ForegroundColor DarkGray
            Write-Host ""
        }
    }
    catch {
        Write-Progress -Activity "Updating RB's App Auto Updater..." -Completed
        Write-Host "Updater update check could not be completed." -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow
        Write-Host "Continuing with installed version $InstalledUpdaterVersion." -ForegroundColor Yellow
        Write-Host ""
    }
}

try {
    $Winget = (Get-Command winget.exe -ErrorAction Stop).Source
}
catch {
    Write-Host "WinGet could not be found." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

# ------------------------------------------------------------
# Show available updates
# ------------------------------------------------------------

Write-Host "Checking for available updates..." -ForegroundColor Green
Write-Host ""

& $Winget list `
    --upgrade-available `
    --accept-source-agreements

Write-Host ""
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""

$Response = Read-Host "Install ALL available updates? [Y/N]"

if ($Response -notmatch '^(Y|YES)$') {
    Write-Host ""
    Write-Host "Update cancelled." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    exit
}

# ------------------------------------------------------------
# Do not start a second copy while one is already running
# ------------------------------------------------------------

try {
    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    if ($ExistingTask.State -eq "Running") {
        Write-Host ""
        Write-Host "The updater is already running." -ForegroundColor Yellow
        Read-Host "Press Enter to close"
        exit
    }
}
catch {
    Write-Host ""
    Write-Host "The updater task could not be found." -ForegroundColor Red
    Write-Host "Run the one-time setup script again." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

# ------------------------------------------------------------
# Clear previous run information
# ------------------------------------------------------------

Remove-Item $StatusFile   -Force -ErrorAction SilentlyContinue
Remove-Item $ResultFile   -Force -ErrorAction SilentlyContinue
Remove-Item $DoneFile     -Force -ErrorAction SilentlyContinue
Remove-Item $DetailLog    -Force -ErrorAction SilentlyContinue
Remove-Item $ProgressFile -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==========================================" -ForegroundColor Blue
Write-Host "           Updating Applications" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""
Write-Host "Starting elevated silent update..." -ForegroundColor Green
Write-Host ""
Write-Host "Any package that fails will be skipped." -ForegroundColor DarkGray
Write-Host "The updater will continue with the remaining applications." -ForegroundColor DarkGray
Write-Host ""

# ------------------------------------------------------------
# Start elevated scheduled task
# ------------------------------------------------------------

try {
    Start-ScheduledTask -TaskName $TaskName
}
catch {
    Write-Host "Failed to start update task:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

# ------------------------------------------------------------
# Monitor live status from hidden elevated task
# ------------------------------------------------------------

$DisplayedLines = 0
$StartTime = Get-Date
$Timeout = New-TimeSpan -Hours 4
$TaskObservedRunning = $false
$UnexpectedStop = $false

while (-not (Test-Path $DoneFile)) {

    # Show current package, queue progress, and elapsed time.
    if (Test-Path $ProgressFile) {
        try {
            $Progress = Get-Content $ProgressFile -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop

            $Current = [int]$Progress.Current
            $Total   = [int]$Progress.Total
            $Name    = [string]$Progress.Name
            $Started = [datetime]$Progress.Started

            if ($Total -gt 0) {
                $Elapsed = (Get-Date) - $Started
                $ElapsedText = "{0:hh\:mm\:ss}" -f $Elapsed
                $Percent = [math]::Floor((($Current - 1) / $Total) * 100)

                Write-Progress `
                    -Activity "Updating applications..." `
                    -Status "[$Current/$Total] $Name  |  Current app elapsed: $ElapsedText" `
                    -PercentComplete $Percent
            }
        }
        catch {
            # The worker may be replacing the JSON file at this instant.
        }
    }

    # Print newly appended worker messages.
    if (Test-Path $StatusFile) {
        try {
            $Lines = @(Get-Content $StatusFile -ErrorAction Stop)

            if ($Lines.Count -gt $DisplayedLines) {
                for ($i = $DisplayedLines; $i -lt $Lines.Count; $i++) {
                    $Line = $Lines[$i]

                    Write-ColoredStatusLine -Line $Line
                }

                $DisplayedLines = $Lines.Count
            }
        }
        catch {
            # The worker may have the file open very briefly.
        }
    }

    # Detect a task that stopped without producing its completion flag.
    try {
        $TaskState = (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State

        if ($TaskState -eq "Running") {
            $TaskObservedRunning = $true
        }
        elseif ($TaskObservedRunning -and ((Get-Date) - $StartTime).TotalSeconds -gt 2) {
            $UnexpectedStop = $true
            break
        }
    }
    catch {
        # Status and timeout handling below still protect the launcher.
    }

    if (((Get-Date) - $StartTime) -gt $Timeout) {
        Write-Host ""
        Write-Host "[ERROR] Update task exceeded the 4-hour timeout." -ForegroundColor Red
        break
    }

    Start-Sleep -Milliseconds 500
}

Write-Progress -Activity "Updating applications..." -Completed

if ($UnexpectedStop -and -not (Test-Path $DoneFile)) {
    Write-Host ""
    Write-Host "[ERROR] The update task stopped unexpectedly." -ForegroundColor Red
    Write-Host "Check the detailed log shown below." -ForegroundColor Red
}

# ------------------------------------------------------------
# Flush any last status messages
# ------------------------------------------------------------

Start-Sleep -Milliseconds 500

if (Test-Path $StatusFile) {
    $Lines = @(Get-Content $StatusFile -ErrorAction SilentlyContinue)

    if ($Lines.Count -gt $DisplayedLines) {
        for ($i = $DisplayedLines; $i -lt $Lines.Count; $i++) {
            $Line = $Lines[$i]

            Write-ColoredStatusLine -Line $Line
        }
    }
}

# ------------------------------------------------------------
# Load structured worker results
# ------------------------------------------------------------

$WorkerResult = $null

if (Test-Path $ResultFile) {
    try {
        $WorkerResult = Get-Content $ResultFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "[ERROR] The worker result file could not be read." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
else {
    Write-Host "[ERROR] No worker result file was generated." -ForegroundColor Red
}

# ------------------------------------------------------------
# Retry elevation-prohibited packages in this normal user process
# ------------------------------------------------------------

$UserRetrySucceeded = @()
$UserRetryFailed = @()

if ($null -ne $WorkerResult) {
    $RetryPackages = @(
        $WorkerResult.RetryAsUser |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.Id) }
    )

    if ($RetryPackages.Count -gt 0) {
        $LauncherIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $LauncherPrincipal = New-Object Security.Principal.WindowsPrincipal($LauncherIdentity)
        $LauncherIsAdmin = $LauncherPrincipal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Blue
        Write-Host "        Retrying Per-User Applications" -ForegroundColor White
        Write-Host "==========================================" -ForegroundColor Blue
        Write-Host ""

        if ($LauncherIsAdmin) {
            $Message = "The launcher itself is elevated, so per-user retries cannot run safely. Close this window and open App Auto Updater normally from the desktop."
            $UserRetryFailed += $Message
            Write-Host "[FAILED] $Message" -ForegroundColor Red
        }
        else {
            $RetryNumber = 0

            foreach ($RetryPackage in $RetryPackages) {
                $RetryNumber++
                $RetryName = [string]$RetryPackage.Name

                if ([string]::IsNullOrWhiteSpace($RetryName)) {
                    $RetryName = [string]$RetryPackage.Id
                }

                $RetryPercent = [math]::Floor((($RetryNumber - 1) / $RetryPackages.Count) * 100)

                Write-Progress `
                    -Activity "Retrying per-user applications..." `
                    -Status "[$RetryNumber/$($RetryPackages.Count)] $RetryName" `
                    -PercentComplete $RetryPercent

                Write-Host "[$RetryNumber/$($RetryPackages.Count)] Retrying $RetryName without administrator elevation..." -ForegroundColor Cyan

                Add-Content -Path $DetailLog -Value "" -Encoding UTF8
                Add-Content -Path $DetailLog -Value "============================================================" -Encoding UTF8
                Add-Content -Path $DetailLog -Value "Non-elevated retry: $RetryName [$($RetryPackage.Id)]" -Encoding UTF8
                Add-Content -Path $DetailLog -Value "============================================================" -Encoding UTF8

                $RetryArguments = @(
                    "upgrade"
                    "--id"
                    [string]$RetryPackage.Id
                    "--exact"
                    "--silent"
                    "--disable-interactivity"
                    "--accept-package-agreements"
                    "--accept-source-agreements"
                )

                if (-not [string]::IsNullOrWhiteSpace($RetryPackage.Source)) {
                    $RetryArguments += @("--source", [string]$RetryPackage.Source)
                }

                try {
                    & $Winget @RetryArguments 2>&1 |
                        ForEach-Object {
                            $OutputLine = [string]$_
                            Add-Content -Path $DetailLog -Value $OutputLine -Encoding UTF8

                            if (
                                $OutputLine -match '^Found ' -or
                                $OutputLine -match 'Downloading' -or
                                $OutputLine -match 'Successfully verified' -or
                                $OutputLine -match 'Starting package install' -or
                                $OutputLine -match 'Successfully installed' -or
                                $OutputLine -match 'Successfully upgraded'
                            ) {
                                Write-Host "    $OutputLine"
                            }
                        }

                    $RetryExitCode = $LASTEXITCODE

                    Add-Content -Path $DetailLog -Value "WinGet exit code: $RetryExitCode" -Encoding UTF8

                    if ($RetryExitCode -eq 0) {
                        $UserRetrySucceeded += "$RetryName [$($RetryPackage.Id)]"
                        Write-Host "[OK] $RetryName" -ForegroundColor Green
                    }
                    else {
                        switch ($RetryExitCode) {
                            -1978335215 {
                                $Reason = "Security blocked: the downloaded installer hash does not match the trusted WinGet manifest. Do not bypass the hash check."
                            }
                            -1978335090 {
                                $Reason = "Manual update required: the new release uses a different installer technology. Use the application's own updater or current vendor installer."
                            }
                            { $_ -in @(-1978334975, -1978334973, -1978334959) } {
                                $Reason = "The application or one of its files is in use. Close it and anything using it, then re-run this updater once it is closed."
                            }
                            -1978335212 {
                                $Reason = "WinGet could no longer find the package. Run 'winget source update' and re-run this updater."
                            }
                            default {
                                $Reason = "The non-elevated retry failed. Review the detailed WinGet log."
                            }
                        }

                        $FailureText = "$RetryName [$($RetryPackage.Id)] - $Reason (WinGet exit code $RetryExitCode)"
                        $UserRetryFailed += $FailureText
                        Write-Host "[FAILED] $FailureText" -ForegroundColor Red
                    }
                }
                catch {
                    $FailureText = "$RetryName [$($RetryPackage.Id)] - $($_.Exception.Message)"
                    $UserRetryFailed += $FailureText
                    Write-Host "[FAILED] $FailureText" -ForegroundColor Red
                    Add-Content -Path $DetailLog -Value "Exception: $($_.Exception.Message)" -Encoding UTF8
                }

                Write-Host ""
            }

            Write-Progress -Activity "Retrying per-user applications..." -Completed
        }
    }
}

# ------------------------------------------------------------
# Display final actionable summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "==========================================" -ForegroundColor Blue
Write-Host "              Update Summary" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Blue
Write-Host ""

if ($null -ne $WorkerResult) {
    $Succeeded = @($WorkerResult.Succeeded | Where-Object { $_ }) + @($UserRetrySucceeded)
    $SecurityBlocked = @($WorkerResult.SecurityBlocked | Where-Object { $_ })
    $ManualRequired = @($WorkerResult.ManualRequired | Where-Object { $_ })
    $InUse = @($WorkerResult.InUse | Where-Object { $_ })
    $RestartRequired = @($WorkerResult.RestartRequired | Where-Object { $_ })
    $NoActionRequired = @($WorkerResult.NoActionRequired | Where-Object { $_ })
    $OtherFailed = @($WorkerResult.OtherFailed | Where-Object { $_ }) + @($UserRetryFailed)

    $NeedsAttention = `
        $SecurityBlocked.Count + `
        $ManualRequired.Count + `
        $InUse.Count + `
        $RestartRequired.Count + `
        $OtherFailed.Count

    Write-Host "Succeeded: $($Succeeded.Count)" -ForegroundColor Green
    Write-Host "Needs attention: $NeedsAttention" -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($WorkerResult.FatalError)) {
        Write-Host ""
        Write-Host "FATAL ERROR:" -ForegroundColor Red
        Write-Host $WorkerResult.FatalError -ForegroundColor Red
    }

    if ($Succeeded.Count -gt 0) {
        Write-Host ""
        Write-Host "Successful updates:" -ForegroundColor Green
        foreach ($Item in $Succeeded) {
            Write-Host "  [OK] $Item" -ForegroundColor Green
        }
    }

    if ($SecurityBlocked.Count -gt 0) {
        Write-Host ""
        Write-Host "Security blocked:" -ForegroundColor Red
        foreach ($Item in $SecurityBlocked) {
            Write-Host "  [SECURITY BLOCKED] $Item" -ForegroundColor Red
        }
    }

    if ($ManualRequired.Count -gt 0) {
        Write-Host ""
        Write-Host "Manual update required:" -ForegroundColor Yellow
        foreach ($Item in $ManualRequired) {
            Write-Host "  [MANUAL UPDATE] $Item" -ForegroundColor Yellow
        }
    }

    if ($InUse.Count -gt 0) {
        Write-Host ""
        Write-Host "Applications that must be closed:" -ForegroundColor Yellow
        foreach ($Item in $InUse) {
            Write-Host "  [CLOSE APP] $Item" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Close these applications and anything using them, then re-run this updater once they are closed." -ForegroundColor Yellow
    }

    if ($RestartRequired.Count -gt 0) {
        Write-Host ""
        Write-Host "Restart required:" -ForegroundColor Yellow
        foreach ($Item in $RestartRequired) {
            Write-Host "  [RESTART REQUIRED] $Item" -ForegroundColor Yellow
        }
    }

    if ($OtherFailed.Count -gt 0) {
        Write-Host ""
        Write-Host "Other failures:" -ForegroundColor Red
        foreach ($Item in $OtherFailed) {
            Write-Host "  [FAILED] $Item" -ForegroundColor Red
        }
    }

    if ($NoActionRequired.Count -gt 0) {
        Write-Host ""
        Write-Host "No action required:" -ForegroundColor DarkGray
        foreach ($Item in $NoActionRequired) {
            Write-Host "  [NO ACTION] $Item" -ForegroundColor DarkGray
        }
    }

    if (
        $Succeeded.Count -eq 0 -and
        $NeedsAttention -eq 0 -and
        $NoActionRequired.Count -eq 0 -and
        [string]::IsNullOrWhiteSpace($WorkerResult.FatalError)
    ) {
        Write-Host "No updates were required."
    }
}

Write-Host ""
Write-Host "Detailed WinGet log:" -ForegroundColor DarkGray
Write-Host $DetailLog -ForegroundColor DarkGray
Write-Host ""

Read-Host "Press Enter to close"
exit
'@

$LauncherScript = $LauncherScript.Replace(
    "__UPDATER_VERSION__",
    $UpdaterVersion.ToString()
)

$LauncherScript = $LauncherScript.Replace(
    "__VERSION_MANIFEST_URL__",
    $VersionManifestUrl
)

Set-Content `
    -Path $LauncherPath `
    -Value $LauncherScript `
    -Encoding UTF8

# ============================================================
# CREATE ELEVATED UPDATE WORKER
# ============================================================

$WorkerScript = @'
$ErrorActionPreference = "Continue"

$Winget = '__WINGET_PATH__'
$AppFolder = Join-Path $env:LOCALAPPDATA "WingetUpdater"

$StatusFile   = Join-Path $AppFolder "status.log"
$ResultFile   = Join-Path $AppFolder "worker-result.json"
$DoneFile     = Join-Path $AppFolder "done.flag"
$DetailLog    = Join-Path $AppFolder "winget-details.log"
$ProgressFile = Join-Path $AppFolder "progress.json"

$Succeeded       = @()
$SecurityBlocked = @()
$ManualRequired  = @()
$InUse           = @()
$RestartRequired = @()
$NoActionRequired = @()
$OtherFailed     = @()
$RetryAsUser     = @()
$FatalError      = $null

function Write-Status {
    param([string]$Message)

    Add-Content -Path $StatusFile -Value $Message -Encoding UTF8
}

function Write-Detail {
    param([string]$Message)

    Add-Content -Path $DetailLog -Value $Message -Encoding UTF8
}

function Set-PackageProgress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Name
    )

    $ProgressInfo = [PSCustomObject]@{
        Current = $Current
        Total   = $Total
        Name    = $Name
        Started = (Get-Date).ToString("o")
    }

    $ProgressInfo |
        ConvertTo-Json -Compress |
        Set-Content -Path $ProgressFile -Encoding UTF8
}

function Get-FriendlyFailure {
    param([int]$ExitCode)

    switch ($ExitCode) {
        -1978335215 {
            return [PSCustomObject]@{
                Category = "SecurityBlocked"
                Description = "The downloaded installer hash does not match the trusted WinGet manifest."
                Action = "Do not bypass the hash check. Use the vendor updater or wait for the WinGet manifest to be corrected."
            }
        }
        -1978335187 {
            return [PSCustomObject]@{
                Category = "SecurityBlocked"
                Description = "The installer failed WinGet's security validation."
                Action = "Do not force the installation. Use the vendor updater or investigate the package source."
            }
        }
        -1978335186 {
            return [PSCustomObject]@{
                Category = "SecurityBlocked"
                Description = "The downloaded size does not match the trusted manifest."
                Action = "Do not bypass validation. Retry later or use the vendor updater."
            }
        }
        -1978335138 {
            return [PSCustomObject]@{
                Category = "SecurityBlocked"
                Description = "The server certificate did not match WinGet's expected value."
                Action = "Do not bypass certificate validation. Check the network or retry later."
            }
        }
        -1978335136 {
            return [PSCustomObject]@{
                Category = "SecurityBlocked"
                Description = "The downloaded archive failed its malware scan."
                Action = "Do not force the installation. Use the vendor updater only after verifying the download."
            }
        }
        -1978335090 {
            return [PSCustomObject]@{
                Category = "ManualRequired"
                Description = "The available update uses a different installer technology than the installed version."
                Action = "Use the application's own updater or the current installer from its vendor."
            }
        }
        -1978335152 {
            return [PSCustomObject]@{
                Category = "ManualRequired"
                Description = "WinGet cannot determine whether the available version is newer."
                Action = "Check the installed version and update through the vendor if needed."
            }
        }
        -1978335128 {
            return [PSCustomObject]@{
                Category = "ManualRequired"
                Description = "A WinGet pin is preventing this package from being upgraded."
                Action = "Review or remove the package pin before updating."
            }
        }
        -1978334956 {
            return [PSCustomObject]@{
                Category = "ManualRequired"
                Description = "The installer does not support upgrading the existing package."
                Action = "Use the vendor updater or reinstall the current release manually."
            }
        }
        -1978334975 {
            return [PSCustomObject]@{
                Category = "InUse"
                Description = "The application is currently running."
                Action = "Close it and anything using it, then re-run this updater once it is closed."
            }
        }
        -1978334973 {
            return [PSCustomObject]@{
                Category = "InUse"
                Description = "One or more application files are currently in use."
                Action = "Close the application and anything using its files, then re-run this updater once it is closed."
            }
        }
        -1978334959 {
            return [PSCustomObject]@{
                Category = "InUse"
                Description = "The application is currently being used by another application."
                Action = "Close both applications, then re-run this updater once they are closed."
            }
        }
        -1978335146 {
            return [PSCustomObject]@{
                Category = "RetryAsUser"
                Description = "The installer cannot run with administrator elevation."
                Action = "Retry automatically from the normal, non-elevated launcher."
            }
        }
        -1978335107 {
            return [PSCustomObject]@{
                Category = "RetryAsUser"
                Description = "This per-user package cannot be changed from an administrator context."
                Action = "Retry automatically from the normal, non-elevated launcher."
            }
        }
        -1978334967 {
            return [PSCustomObject]@{
                Category = "RestartRequired"
                Description = "A restart is required to finish this installation."
                Action = "Restart Windows, then run the updater again."
            }
        }
        -1978334966 {
            return [PSCustomObject]@{
                Category = "RestartRequired"
                Description = "Windows must be restarted before this package can be installed."
                Action = "Restart Windows, then run the updater again."
            }
        }
        -1978335189 {
            return [PSCustomObject]@{
                Category = "NoActionRequired"
                Description = "No applicable update remains for this package."
                Action = "The application may have updated itself after the initial scan."
            }
        }
        -1978335153 {
            return [PSCustomObject]@{
                Category = "NoActionRequired"
                Description = "The available package is not newer than the installed version."
                Action = "No update is required."
            }
        }
        -1978335135 {
            return [PSCustomObject]@{
                Category = "NoActionRequired"
                Description = "The package is already installed."
                Action = "No update is required."
            }
        }
        -1978334963 {
            return [PSCustomObject]@{
                Category = "NoActionRequired"
                Description = "Another version of this application is already installed."
                Action = "Confirm the installed version; no automatic action was taken."
            }
        }
        -1978334962 {
            return [PSCustomObject]@{
                Category = "NoActionRequired"
                Description = "A newer version is already installed."
                Action = "No update is required."
            }
        }
        -1978335212 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "WinGet could no longer find this package in the selected source."
                Action = "Run 'winget source update' and re-run this updater."
            }
        }
        -1978335216 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "No installer is applicable to this computer."
                Action = "Check the package architecture, Windows version, and vendor installer."
            }
        }
        -1978335224 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "The installer download failed."
                Action = "Check the network connection and re-run this updater."
            }
        }
        -1978335098 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "WinGet downloaded an empty installer file."
                Action = "Check the network connection or retry later."
            }
        }
        -1978335123 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "A required service is busy or unavailable."
                Action = "Wait briefly and re-run this updater."
            }
        }
        -1978334974 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "Another installation is already in progress."
                Action = "Allow it to finish, then re-run this updater."
            }
        }
        -1978334972 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "A required dependency is missing."
                Action = "Review the detailed log and install the missing dependency."
            }
        }
        -1978334971 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "There is insufficient free disk space."
                Action = "Free disk space, then re-run this updater."
            }
        }
        -1978334969 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "The installer could not access the network."
                Action = "Check the network connection and re-run this updater."
            }
        }
        -1978334960 {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "One or more package dependencies failed to install."
                Action = "Review the detailed log and resolve the dependency failure."
            }
        }
        default {
            return [PSCustomObject]@{
                Category = "OtherFailed"
                Description = "WinGet returned an unclassified error."
                Action = "Review the detailed WinGet log for the installer-specific message."
            }
        }
    }
}

try {
    New-Item -ItemType Directory -Path $AppFolder -Force | Out-Null

    Write-Status "Scanning WinGet for available upgrades..."

    Write-Detail "============================================================"
    Write-Detail "RB's App Auto Updater"
    Write-Detail "Started: $(Get-Date)"
    Write-Detail "============================================================"
    Write-Detail ""

    # Out-String with a wide width prevents long package IDs from
    # being truncated by the hidden PowerShell host.
    $UpgradeText = & $Winget list `
        --upgrade-available `
        --accept-source-agreements `
        --disable-interactivity 2>&1 |
        Out-String -Width 4096

    $ListExitCode = $LASTEXITCODE
    $UpgradeOutput = @($UpgradeText -split "`r?`n")

    Write-Detail "WinGet upgrade list:"
    Write-Detail ""

    foreach ($Line in $UpgradeOutput) {
        Write-Detail ([string]$Line)
    }

    Write-Detail ""

    # --------------------------------------------------------
    # Find WinGet table header
    # --------------------------------------------------------

    $HeaderIndex = -1

    for ($i = 0; $i -lt $UpgradeOutput.Count; $i++) {
        $Line = [string]$UpgradeOutput[$i]

        if ($Line -match '^\s*Name\s+Id\s+Version\s+Available') {
            $HeaderIndex = $i
            break
        }
    }

    if ($HeaderIndex -lt 0) {
        if ($ListExitCode -eq 0) {
            Write-Status "No available application updates were found."
        }
        else {
            throw "WinGet could not retrieve the available upgrade list. Exit code: $ListExitCode"
        }
    }
    else {
        # ----------------------------------------------------
        # Determine table column locations
        # ----------------------------------------------------

        $Header = [string]$UpgradeOutput[$HeaderIndex]

        $IdStart        = $Header.IndexOf("Id")
        $VersionStart   = $Header.IndexOf("Version")
        $AvailableStart = $Header.IndexOf("Available")
        $SourceStart    = $Header.IndexOf("Source")

        if (
            $IdStart -lt 0 -or
            $VersionStart -lt 0 -or
            $AvailableStart -lt 0
        ) {
            throw "Unable to determine WinGet table columns."
        }

        $SeparatorIndex = -1

        for ($i = $HeaderIndex + 1; $i -lt $UpgradeOutput.Count; $i++) {
            $Line = [string]$UpgradeOutput[$i]

            if ($Line -match '^\s*-{2,}') {
                $SeparatorIndex = $i
                break
            }
        }

        if ($SeparatorIndex -lt 0) {
            throw "Unable to locate WinGet table separator."
        }

        # ----------------------------------------------------
        # Parse upgrade rows
        # ----------------------------------------------------

        $Packages = @()

        for ($i = $SeparatorIndex + 1; $i -lt $UpgradeOutput.Count; $i++) {
            $Line = [string]$UpgradeOutput[$i]

            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            if ($Line -match '^\s*\d+\s+upgrades?\s+available') {
                break
            }

            if ($Line.Length -le $VersionStart) {
                continue
            }

            $NameLength = [Math]::Min($IdStart, $Line.Length)
            $Name = $Line.Substring(0, $NameLength).Trim()

            if ($Line.Length -gt $IdStart) {
                $IdEnd = [Math]::Min($VersionStart, $Line.Length)
                $IdLength = $IdEnd - $IdStart

                if ($IdLength -gt 0) {
                    $PackageId = $Line.Substring($IdStart, $IdLength).Trim()
                }
                else {
                    $PackageId = ""
                }
            }
            else {
                $PackageId = ""
            }

            $Source = ""

            if ($SourceStart -ge 0 -and $Line.Length -gt $SourceStart) {
                $Source = $Line.Substring($SourceStart).Trim()
            }

            if ([string]::IsNullOrWhiteSpace($PackageId)) {
                continue
            }

            if ($PackageId -eq "Id") {
                continue
            }

            if ($PackageId.Contains("...") -or $PackageId.Contains("…")) {
                $Message = "$Name [$PackageId] - package ID was truncated by WinGet"
                $OtherFailed += "$Message. Review the detailed log or update this application manually."
                Write-Status "[FAILED] $Message"
                continue
            }

            $Packages += [PSCustomObject]@{
                Name   = $Name
                Id     = $PackageId
                Source = $Source
            }
        }

        $Packages = @($Packages | Sort-Object Id -Unique)

        if ($Packages.Count -eq 0) {
            Write-Status "No available application updates were found."
        }
        else {
            Write-Status ""
            Write-Status "Found $($Packages.Count) available update(s)."
            Write-Status ""

            # ==================================================
            # UPDATE EACH PACKAGE INDIVIDUALLY
            # ==================================================

            $Current = 0

            foreach ($Package in $Packages) {
                $Current++

                $DisplayName = $Package.Name

                if ([string]::IsNullOrWhiteSpace($DisplayName)) {
                    $DisplayName = $Package.Id
                }

                Set-PackageProgress `
                    -Current $Current `
                    -Total $Packages.Count `
                    -Name $DisplayName

                Write-Status "[$Current/$($Packages.Count)] Updating $DisplayName..."
                Write-Detail ""
                Write-Detail "============================================================"
                Write-Detail "Updating: $DisplayName"
                Write-Detail "ID:       $($Package.Id)"
                Write-Detail "Source:   $($Package.Source)"
                Write-Detail "============================================================"

                $Arguments = @(
                    "upgrade"
                    "--id"
                    $Package.Id
                    "--exact"
                    "--silent"
                    "--disable-interactivity"
                    "--accept-package-agreements"
                    "--accept-source-agreements"
                )

                if (-not [string]::IsNullOrWhiteSpace($Package.Source)) {
                    $Arguments += @("--source", $Package.Source)
                }

                try {
                    # Stream WinGet output line-by-line. Full output goes to
                    # the detail log; useful milestones reach the launcher.
                    & $Winget @Arguments 2>&1 |
                        ForEach-Object {
                            $OutputLine = [string]$_
                            Write-Detail $OutputLine

                            if (
                                $OutputLine -match '^Found ' -or
                                $OutputLine -match 'Downloading' -or
                                $OutputLine -match 'Successfully verified' -or
                                $OutputLine -match 'Installer hash' -or
                                $OutputLine -match 'Starting package install' -or
                                $OutputLine -match 'Successfully installed' -or
                                $OutputLine -match 'Successfully upgraded'
                            ) {
                                Write-Status "    $OutputLine"
                            }
                        }

                    $ExitCode = $LASTEXITCODE

                    Write-Detail ""
                    Write-Detail "WinGet exit code: $ExitCode"

                    if ($ExitCode -eq 0) {
                        $Succeeded += "$DisplayName [$($Package.Id)]"
                        Write-Status "[OK] $DisplayName"
                    }
                    else {
                        $FailureInfo = Get-FriendlyFailure -ExitCode $ExitCode
                        $FailureMessage = "$DisplayName [$($Package.Id)] - $($FailureInfo.Description) $($FailureInfo.Action) (WinGet exit code $ExitCode)"

                        switch ($FailureInfo.Category) {
                            "SecurityBlocked" {
                                $SecurityBlocked += $FailureMessage
                                Write-Status "[SECURITY BLOCKED] $FailureMessage"
                            }
                            "ManualRequired" {
                                $ManualRequired += $FailureMessage
                                Write-Status "[MANUAL UPDATE] $FailureMessage"
                            }
                            "InUse" {
                                $InUse += $FailureMessage
                                Write-Status "[CLOSE APP] $FailureMessage"
                            }
                            "RestartRequired" {
                                $RestartRequired += $FailureMessage
                                Write-Status "[RESTART REQUIRED] $FailureMessage"
                            }
                            "NoActionRequired" {
                                $NoActionRequired += $FailureMessage
                                Write-Status "[NO ACTION] $FailureMessage"
                            }
                            "RetryAsUser" {
                                $RetryAsUser += [PSCustomObject]@{
                                    Name = $DisplayName
                                    Id = $Package.Id
                                    Source = $Package.Source
                                    ElevatedExitCode = $ExitCode
                                }

                                Write-Status "[RETRY AS USER] $DisplayName - $($FailureInfo.Description)"
                            }
                            default {
                                $OtherFailed += $FailureMessage
                                Write-Status "[FAILED] $FailureMessage"
                            }
                        }
                    }
                }
                catch {
                    $FailureMessage = "$DisplayName [$($Package.Id)] - $($_.Exception.Message)"
                    $OtherFailed += $FailureMessage
                    Write-Status "[FAILED] $FailureMessage"
                    Write-Detail ""
                    Write-Detail "Exception:"
                    Write-Detail $_.Exception.Message
                }
            }
        }
    }
}
catch {
    $FatalError = $_.Exception.Message
    Write-Status "[ERROR] $FatalError"
    Write-Detail ""
    Write-Detail "FATAL ERROR:"
    Write-Detail $FatalError
}
finally {
    # ============================================================
    # Write structured results for the non-elevated launcher
    # ============================================================

    $WorkerResult = [PSCustomObject]@{
        Completed = (Get-Date).ToString("o")
        FatalError = $FatalError
        Succeeded = @($Succeeded)
        SecurityBlocked = @($SecurityBlocked)
        ManualRequired = @($ManualRequired)
        InUse = @($InUse)
        RestartRequired = @($RestartRequired)
        NoActionRequired = @($NoActionRequired)
        OtherFailed = @($OtherFailed)
        RetryAsUser = @($RetryAsUser)
    }

    $WorkerResult |
        ConvertTo-Json -Depth 6 |
        Set-Content -Path $ResultFile -Encoding UTF8

    Write-Detail ""
    Write-Detail "============================================================"
    Write-Detail "Finished: $(Get-Date)"
    Write-Detail "Succeeded: $($Succeeded.Count)"
    Write-Detail "Security blocked: $($SecurityBlocked.Count)"
    Write-Detail "Manual update required: $($ManualRequired.Count)"
    Write-Detail "Applications in use: $($InUse.Count)"
    Write-Detail "Restart required: $($RestartRequired.Count)"
    Write-Detail "No action required: $($NoActionRequired.Count)"
    Write-Detail "Other failures: $($OtherFailed.Count)"
    Write-Detail "Queued for non-elevated retry: $($RetryAsUser.Count)"
    Write-Detail "============================================================"

    Set-Content -Path $DoneFile -Value "DONE" -Encoding ASCII
}

if ($FatalError) {
    exit 1
}

exit 0
'@

# Insert the exact WinGet path found during setup.
$SafeWingetPath = $WingetPath.Replace("'", "''")
$WorkerScript = $WorkerScript.Replace("__WINGET_PATH__", $SafeWingetPath)

Set-Content `
    -Path $WorkerPath `
    -Value $WorkerScript `
    -Encoding UTF8

# ============================================================
# CREATE PROTECTED SELF-UPDATE BOOTSTRAP
# ============================================================

$SelfUpdateBootstrap = @'
$ErrorActionPreference = "Stop"

$VersionManifestUrl = "__VERSION_MANIFEST_URL__"
$UpdaterScriptUrl = "__UPDATER_SCRIPT_URL__"

$AppFolder = Join-Path $env:LOCALAPPDATA "WingetUpdater"
$InstallFolder = Join-Path $env:ProgramFiles "RB App Auto Updater"
$StagingFolder = Join-Path $InstallFolder "UpdateStaging"
$DownloadedScript = Join-Path $StagingFolder "AutoAppUpdater.ps1"

$ProgressFile = Join-Path $AppFolder "self-update-progress.json"
$DoneFile = Join-Path $AppFolder "self-update-done.json"

function Write-SelfUpdateProgress {
    param(
        [int]$Percent,
        [string]$Message,
        [long]$BytesDownloaded = 0,
        [long]$TotalBytes = 0
    )

    [PSCustomObject]@{
        Percent = $Percent
        Message = $Message
        BytesDownloaded = $BytesDownloaded
        TotalBytes = $TotalBytes
        Updated = (Get-Date).ToString("o")
    } |
        ConvertTo-Json -Compress |
        Set-Content -Path $ProgressFile -Encoding UTF8
}

function Download-FileWithProgress {
    param(
        [string]$Uri,
        [string]$Destination,
        [string]$Version
    )

    $Request = [System.Net.HttpWebRequest]::Create($Uri)
    $Request.UserAgent = "RB-App-Auto-Updater"
    $Request.AllowAutoRedirect = $true
    $Request.Timeout = 60000
    $Request.ReadWriteTimeout = 60000

    $Response = $Request.GetResponse()
    $InputStream = $Response.GetResponseStream()
    $OutputStream = [System.IO.File]::Create($Destination)

    try {
        $TotalBytes = [long]$Response.ContentLength
        $DownloadedBytes = [long]0
        $Buffer = New-Object byte[] 65536

        while (($BytesRead = $InputStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $OutputStream.Write($Buffer, 0, $BytesRead)
            $DownloadedBytes += $BytesRead

            if ($TotalBytes -gt 0) {
                $DownloadPercent = [math]::Floor(($DownloadedBytes / $TotalBytes) * 85)
            }
            else {
                $DownloadPercent = 25
            }

            $DownloadedMB = [math]::Round($DownloadedBytes / 1MB, 2)

            if ($TotalBytes -gt 0) {
                $TotalMB = [math]::Round($TotalBytes / 1MB, 2)
                $Message = "Downloading updater $Version - $DownloadedMB MB of $TotalMB MB"
            }
            else {
                $Message = "Downloading updater $Version - $DownloadedMB MB"
            }

            Write-SelfUpdateProgress `
                -Percent ([Math]::Max(5, [Math]::Min(90, $DownloadPercent + 5))) `
                -Message $Message `
                -BytesDownloaded $DownloadedBytes `
                -TotalBytes $TotalBytes
        }
    }
    finally {
        $OutputStream.Dispose()
        $InputStream.Dispose()
        $Response.Dispose()
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Path $AppFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $StagingFolder -Force | Out-Null

    Remove-Item $DoneFile -Force -ErrorAction SilentlyContinue
    Remove-Item $DownloadedScript -Force -ErrorAction SilentlyContinue

    Write-SelfUpdateProgress -Percent 2 -Message "Checking the latest updater version..."

    $ManifestResponse = Invoke-WebRequest `
        -Uri $VersionManifestUrl `
        -UseBasicParsing `
        -Headers @{ "User-Agent" = "RB-App-Auto-Updater" } `
        -TimeoutSec 30

    $Manifest = $ManifestResponse.Content | ConvertFrom-Json
    $RemoteVersion = [version]$Manifest.version
    $ExpectedHash = ([string]$Manifest.sha256).Trim().ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        throw "The update manifest does not contain a SHA-256 hash."
    }

    Download-FileWithProgress `
        -Uri $UpdaterScriptUrl `
        -Destination $DownloadedScript `
        -Version $RemoteVersion.ToString()

    Write-SelfUpdateProgress -Percent 92 -Message "Verifying the downloaded updater..."

    $ActualHash = (Get-FileHash -Path $DownloadedScript -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($ActualHash -ne $ExpectedHash) {
        throw "Security verification failed: the downloaded updater hash does not match version.json."
    }

    Write-SelfUpdateProgress -Percent 96 -Message "Installing updater $RemoteVersion..."

    $PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $SetupArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$DownloadedScript`" -SelfUpdate"

    $SetupProcess = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $SetupArguments `
        -Wait `
        -PassThru

    if ($SetupProcess.ExitCode -ne 0) {
        throw "The downloaded setup script returned exit code $($SetupProcess.ExitCode)."
    }

    Write-SelfUpdateProgress -Percent 100 -Message "Updater $RemoteVersion installed successfully."

    [PSCustomObject]@{
        Success = $true
        Version = $RemoteVersion.ToString()
        Error = $null
    } |
        ConvertTo-Json -Compress |
        Set-Content -Path $DoneFile -Encoding UTF8
}
catch {
    [PSCustomObject]@{
        Success = $false
        Version = $null
        Error = $_.Exception.Message
    } |
        ConvertTo-Json -Compress |
        Set-Content -Path $DoneFile -Encoding UTF8

    exit 1
}

exit 0
'@

$SelfUpdateBootstrap = $SelfUpdateBootstrap.Replace(
    "__VERSION_MANIFEST_URL__",
    $VersionManifestUrl
)

$SelfUpdateBootstrap = $SelfUpdateBootstrap.Replace(
    "__UPDATER_SCRIPT_URL__",
    $UpdaterScriptUrl
)

Set-Content `
    -Path $SelfUpdateBootstrapPath `
    -Value $SelfUpdateBootstrap `
    -Encoding UTF8

# ============================================================
# CREATE ELEVATED SCHEDULED TASK
# ============================================================

$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TaskArguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkerPath`""

$Action = New-ScheduledTaskAction `
    -Execute $PowerShellExe `
    -Argument $TaskArguments

$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$Principal = New-ScheduledTaskPrincipal `
    -UserId $CurrentUser `
    -LogonType Interactive `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Principal $Principal `
    -Settings $Settings `
    -Description "Runs WinGet upgrades individually and silently with elevated privileges. Failed packages are skipped." `
    -Force | Out-Null

# Do not replace the self-update task while that same task is
# actively installing an update. Its protected script path stays fixed.
if (-not $SelfUpdate) {
    $SelfUpdateTaskArguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfUpdateBootstrapPath`""

    $SelfUpdateAction = New-ScheduledTaskAction `
        -Execute $PowerShellExe `
        -Argument $SelfUpdateTaskArguments

    $SelfUpdateSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $SelfUpdateTaskName `
        -Action $SelfUpdateAction `
        -Principal $Principal `
        -Settings $SelfUpdateSettings `
        -Description "Downloads verified updater releases from RileyBeenders/RB-s-Auto-App-Updater and installs them." `
        -Force | Out-Null
}

# ============================================================
# BUILD SHORTCUT ICON
# ============================================================

# Shortcuts cannot use a PNG directly, so icon.png from the
# repository is downloaded and packed into a multi-size .ico.
# If anything fails, the shortcut falls back to the PowerShell icon.

$ShortcutIconLocation = "$PowerShellExe,0"
$IconSourcePath = Join-Path $env:TEMP "RB-App-Auto-Updater-icon.png"

try {
    Write-Host "Downloading shortcut icon..." -ForegroundColor Cyan

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest `
        -Uri $ShortcutIconUrl `
        -OutFile $IconSourcePath `
        -UseBasicParsing `
        -Headers @{ "User-Agent" = "RB-App-Auto-Updater" } `
        -TimeoutSec 15

    Add-Type -AssemblyName System.Drawing

    $SourceImage = [System.Drawing.Image]::FromFile($IconSourcePath)

    try {
        # Each entry is stored as PNG data, which Windows Vista and
        # later accept inside .ico files. Largest size goes first.
        $IconSizes = @(256, 128, 64, 48, 32, 24, 16)
        $IconFrames = New-Object System.Collections.Generic.List[byte[]]

        foreach ($Size in $IconSizes) {
            $Frame = New-Object System.Drawing.Bitmap $Size, $Size
            $Graphics = [System.Drawing.Graphics]::FromImage($Frame)

            try {
                $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $Graphics.Clear([System.Drawing.Color]::Transparent)
                $Graphics.DrawImage($SourceImage, 0, 0, $Size, $Size)

                $FrameStream = New-Object System.IO.MemoryStream
                $Frame.Save($FrameStream, [System.Drawing.Imaging.ImageFormat]::Png)
                $IconFrames.Add($FrameStream.ToArray())
                $FrameStream.Dispose()
            }
            finally {
                $Graphics.Dispose()
                $Frame.Dispose()
            }
        }
    }
    finally {
        $SourceImage.Dispose()
    }

    $IconStream = New-Object System.IO.MemoryStream
    $IconWriter = New-Object System.IO.BinaryWriter $IconStream

    # ICONDIR header: reserved, type (1 = icon), image count
    $IconWriter.Write([uint16]0)
    $IconWriter.Write([uint16]1)
    $IconWriter.Write([uint16]$IconFrames.Count)

    $DataOffset = 6 + (16 * $IconFrames.Count)

    for ($Index = 0; $Index -lt $IconFrames.Count; $Index++) {
        $Size = $IconSizes[$Index]
        $SizeByte = if ($Size -ge 256) { [byte]0 } else { [byte]$Size }

        # ICONDIRENTRY: width, height, palette, reserved,
        # planes, bit depth, data length, data offset
        $IconWriter.Write($SizeByte)
        $IconWriter.Write($SizeByte)
        $IconWriter.Write([byte]0)
        $IconWriter.Write([byte]0)
        $IconWriter.Write([uint16]1)
        $IconWriter.Write([uint16]32)
        $IconWriter.Write([uint32]$IconFrames[$Index].Length)
        $IconWriter.Write([uint32]$DataOffset)

        $DataOffset += $IconFrames[$Index].Length
    }

    foreach ($FrameBytes in $IconFrames) {
        $IconWriter.Write($FrameBytes)
    }

    $IconWriter.Flush()
    [System.IO.File]::WriteAllBytes($IconPath, $IconStream.ToArray())
    $IconWriter.Dispose()
    $IconStream.Dispose()

    $ShortcutIconLocation = "$IconPath,0"
}
catch {
    Write-Host "Could not prepare the custom shortcut icon: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "The shortcut will use the default PowerShell icon." -ForegroundColor Yellow
}
finally {
    Remove-Item $IconSourcePath -Force -ErrorAction SilentlyContinue
}

# ============================================================
# CREATE DESKTOP SHORTCUT
# ============================================================

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)

$Shortcut.TargetPath = $PowerShellExe
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""
$Shortcut.WorkingDirectory = $AppFolder
$Shortcut.IconLocation = $ShortcutIconLocation
$Shortcut.Save()

# ============================================================
# COMPLETE
# ============================================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " Setup complete." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Desktop shortcut created:"
Write-Host "  $ShortcutPath"
Write-Host ""
Write-Host "Scheduled task created:"
Write-Host "  $TaskName"
Write-Host "  $SelfUpdateTaskName"
Write-Host ""
Write-Host "Installed worker:"
Write-Host "  $WorkerPath"
Write-Host ""
Write-Host "Behavior:"
Write-Host "  - Checks GitHub for updater updates before scanning apps"
Write-Host "  - Shows live updater download and installation progress"
Write-Host "  - Verifies the downloaded updater with SHA-256"
Write-Host "  - Continues automatically in the refreshed updater"
Write-Host "  - Updates are processed one at a time"
Write-Host "  - Current package and queue progress are displayed"
Write-Host "  - Current-package elapsed time updates live"
Write-Host "  - Useful WinGet milestones are streamed to the launcher"
Write-Host "  - WinGet error codes are translated into readable actions"
Write-Host "  - Per-user installers are retried without elevation"
Write-Host "  - Hash and security validation failures are clearly blocked"
Write-Host "  - Installer-technology changes are marked for manual update"
Write-Host "  - In-use apps tell the user to close them and rerun the updater"
Write-Host "  - Failed updates are classified and skipped safely"
Write-Host "  - Remaining updates continue"
Write-Host "  - A final actionable summary is displayed"
Write-Host "  - Detailed WinGet output is logged"
Write-Host "  - No UAC prompt is required during normal use"
Write-Host ""

if ($SelfUpdate) {
    exit 0
}

Read-Host "Press Enter to close"
