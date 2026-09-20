# RB's Auto App Updater

A Windows PowerShell utility that checks installed applications with WinGet, presents the available updates, and upgrades each package individually. Failed packages are classified and skipped so the remaining applications can continue.

## Features

- Desktop shortcut with no UAC prompt during normal app updates
- Live package-level progress and elapsed time
- Human-readable WinGet error explanations
- Automatic non-elevated retry for per-user installers
- Clear security-blocked, manual-update, restart, and application-in-use statuses
- Detailed logs in `%LOCALAPPDATA%\WingetUpdater`
- Automatic updater self-check before the WinGet application chart
- SHA-256 verification before an updater release is installed

## Install

1. Download `AutoAppUpdater.ps1`.
2. Right-click it and select **Run with PowerShell**.
3. Approve the one-time administrator prompt.
4. Use the **App Auto Updater** shortcut created on the desktop.

The setup installs protected worker scripts under:

```text
%ProgramFiles%\RB App Auto Updater
```

## Self-update behavior

Whenever the desktop shortcut starts, it checks `version.json` from this repository.

If a newer version is available, the updater:

1. Starts the protected self-update task.
2. Shows live download and installation progress.
3. Downloads only `AutoAppUpdater.ps1` from this repository.
4. Verifies its SHA-256 hash against `version.json`.
5. Installs the updated launcher and workers.
6. Restarts the refreshed launcher with the update check skipped once.
7. Continues with the normal WinGet update chart and confirmation prompt.

If GitHub cannot be reached or verification fails, the installed updater is retained and normal application-update checking continues.

## Publishing an updater version

Update the version near the beginning of `AutoAppUpdater.ps1`:

```powershell
$UpdaterVersion = [version]"2.2.0"
```

Then calculate its SHA-256 hash:

```powershell
(Get-FileHash .\AutoAppUpdater.ps1 -Algorithm SHA256).Hash.ToLower()
```

Update `version.json` with the matching version and hash in the same pull request. Do not publish a manifest hash that does not match the exact script bytes on the default branch.

> The hash protects against incomplete or mismatched downloads. Because the script and manifest are hosted in the same repository, repository access must remain protected with strong GitHub account security and branch controls.
