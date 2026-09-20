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
$UpdaterVersion = [version]"2.2.0"
```

Finish every other script change before generating the hash. Any later change to the script will produce a different SHA-256 value.

### 2. Commit the updated script

Commit `AutoAppUpdater.ps1` locally, but do not push yet. The hash comes from the committed file, so the script and the updated manifest can be pushed together in step 5. Pushing the script alone with a stale `version.json` would cause installed copies to download it and fail verification.

### 3. Hash the committed script

Run the following one-liner in PowerShell from the repository folder:

```powershell
$t = New-TemporaryFile; cmd /c "git show HEAD:AutoAppUpdater.ps1 > `"$t`""; (Get-FileHash $t -Algorithm SHA256).Hash.ToLower(); Remove-Item $t
```

Copy the entire 64-character result.

This hashes the committed file exactly as GitHub will serve it, so it works before pushing and is not affected by CDN caching. The repository stores the script with LF line endings, and the `cmd /c` redirect is deliberate: piping `git show` through PowerShell rewrites the line endings and produces a different hash. For the same reason, do not hash the working-copy file directly on Windows.

### 4. Update `version.json`

Set `version` to the same version used by `$UpdaterVersion`, paste the published script's hash into `sha256`, and update the publication date:

```json
{
  "version": "2.2.0",
  "script": "AutoAppUpdater.ps1",
  "sha256": "PASTE_THE_64_CHARACTER_HASH_HERE",
  "published": "2026-09-20"
}
```

The `script` value remains unchanged unless the PowerShell file is renamed.

### 5. Publish the manifest

Commit `version.json` and push. Once the new manifest is visible, installed copies will detect the higher version, download the published script, verify its hash, install it, and continue with the normal WinGet workflow.

> **Wait a few minutes after pushing.** `raw.githubusercontent.com` caches each file for up to about five minutes, and the script and manifest expire independently. Until both have refreshed, installed copies and `install.ps1` will report that verification failed. Confirm the manifest has refreshed before testing:
>
> ```powershell
> (irm https://raw.githubusercontent.com/RileyBeenders/RB-s-Auto-App-Updater/main/version.json).sha256
> ```
>
> When this prints the hash from step 3, the release is live.

If the updater still reports that verification failed after the cache has refreshed, run the step 3 one-liner again and compare it with `version.json`.

> The hash protects against incomplete or mismatched downloads. Because the script and manifest are hosted in the same repository, repository access must remain protected with strong GitHub account security and branch controls.
