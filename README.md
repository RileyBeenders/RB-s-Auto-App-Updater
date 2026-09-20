# RB's Auto App Updater

A Windows PowerShell utility that checks installed applications with WinGet, presents the available updates, and upgrades each package individually. Failed packages are classified and skipped so the remaining applications can continue.

## Features

- Desktop shortcut with a custom icon and no UAC prompt during normal app updates
- Live package-level progress and elapsed time
- Human-readable WinGet error explanations
- Automatic non-elevated retry for per-user installers
- Clear security-blocked, manual-update, restart, and application-in-use statuses
- Detailed logs in `%LOCALAPPDATA%\WingetUpdater`
- Automatic updater self-check before the WinGet application chart
- SHA-256 verification before an updater release is installed

## Install

Run this one-line command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/RileyBeenders/RB-s-Auto-App-Updater/main/install.ps1 | iex
```

`install.ps1` reads `version.json`, downloads the published `AutoAppUpdater.ps1`, verifies its SHA-256 hash against the manifest, and only then runs setup. Approve the one-time administrator prompt, then use the **App Auto Updater** shortcut created on the desktop.

The setup installs protected worker scripts under:

```text
%ProgramFiles%\RB App Auto Updater
```

## Shortcut icon

During setup, `icon.png` from this repository is downloaded and converted into a multi-size `.ico` at `%LOCALAPPDATA%\WingetUpdater\AppAutoUpdater.ico`, which the desktop shortcut uses. If the download or conversion fails, setup continues and the shortcut falls back to the standard PowerShell icon.

To change the icon, replace `icon.png` on `main` (a square PNG with transparency, 256x256 or larger is ideal). The icon is not covered by the `version.json` hash, so no version bump is needed for an icon-only change; it is picked up the next time setup or a self-update runs.

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

### 1. Update the script version

Change `$UpdaterVersion` near the beginning of `AutoAppUpdater.ps1`:

```powershell
$UpdaterVersion = [version]"2.1.2"
```

Finish every other script change before generating the hash. Any later change to the script will produce a different SHA-256 value.

### 2. Publish the updated script

Commit or upload `AutoAppUpdater.ps1` to `main`. Do not increase the version in `version.json` yet. Keeping the old manifest version temporarily prevents installed copies from downloading the script before its final hash is available.

This repository normalizes text files to LF line endings. Therefore, a hash calculated from a local Windows/CRLF copy may not match the file GitHub distributes.

### 3. Hash the file served by GitHub

Run the following in PowerShell after the updated script is visible on `main`.

> **Wait a few minutes after pushing.** `raw.githubusercontent.com` caches files for up to about five minutes, so hashing immediately after a push can return the *previous* version of the script. Confirm the download contains your change (for example, the new `$UpdaterVersion`) before trusting the hash.

```powershell
$url = "https://raw.githubusercontent.com/RileyBeenders/RB-s-Auto-App-Updater/main/AutoAppUpdater.ps1"
$temp = New-TemporaryFile
Invoke-WebRequest $url -OutFile $temp
(Get-FileHash $temp -Algorithm SHA256).Hash.ToLower()
Remove-Item $temp
```

Copy the entire 64-character result.

Alternatively, hash the committed file directly from git. This avoids the CDN cache entirely and always matches what GitHub will serve, because the repository stores the script with LF line endings:

```powershell
$t = New-TemporaryFile
cmd /c "git show HEAD:AutoAppUpdater.ps1 > `"$t`""
(Get-FileHash $t -Algorithm SHA256).Hash.ToLower()
Remove-Item $t
```

The `cmd /c` redirect is deliberate: piping `git show` through PowerShell rewrites the line endings and produces a different hash.

### 4. Update `version.json`

Set `version` to the same version used by `$UpdaterVersion`, paste the published script's hash into `sha256`, and update the publication date:

```json
{
  "version": "2.1.2",
  "script": "AutoAppUpdater.ps1",
  "sha256": "PASTE_THE_64_CHARACTER_HASH_HERE",
  "published": "2026-09-20"
}
```

The `script` value remains unchanged unless the PowerShell file is renamed.

### 5. Publish the manifest

Commit or upload `version.json` to `main`. Once the new manifest is visible, installed copies will detect the higher version, download the published script, verify its hash, install it, and continue with the normal WinGet workflow.

If the updater reports that verification failed and continues with the installed version, calculate the hash from the raw GitHub URL again and compare it with `version.json`.

> The hash protects against incomplete or mismatched downloads. Because the script and manifest are hosted in the same repository, repository access must remain protected with strong GitHub account security and branch controls.
