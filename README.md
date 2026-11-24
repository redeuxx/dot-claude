# Claude Code Settings Sync

Sync your `~/.claude` directory across multiple machines via a private GitHub repo. Scripts are available for Windows (PowerShell) and Linux/macOS (Bash).

## Prerequisites

| Tool | Windows | Linux | macOS |
|---|---|---|---|
| Git | [git-scm.com](https://git-scm.com/) | `sudo apt install git` | `brew install git` |
| GitHub CLI | [cli.github.com](https://cli.github.com/) | [install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) | `brew install gh` |
| jq *(Bash only)* | n/a | `sudo apt install jq` | `brew install jq` |
| PowerShell 5.1+ *(Windows only)* | built-in | n/a | n/a |

After installing GitHub CLI, authenticate once:

```sh
gh auth login
```

On Windows you may also need to allow script execution:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If a required tool is missing, the scripts will print platform-specific install instructions and exit.

## First-Time Setup

Run this once per machine:

```powershell
# Windows
.\claude-sync-init.ps1
```

```bash
# Linux / macOS
bash claude-sync-init.sh
```

You will be prompted for:

- **Repo URL**: your private GitHub repo (e.g. `https://github.com/you/claude-settings.git`)
- **Subdirectory**: an optional path within the repo to sync into (e.g. `claude`). Leave blank to use the repo root.

The script clones the repo to `~/.claude-sync/repo/` and writes a local config to `~/.claude-sync/config.json`.

If the repo is brand new (empty), run push first. If it already has settings from another machine, run pull first.

Re-running init on a machine that is already configured will prompt before overwriting.

## Usage

### Download settings from GitHub

```powershell
# Windows
.\claude-sync-pull.ps1 [-Force]
```

```bash
# Linux / macOS
bash claude-sync-pull.sh [--force]
```

Fetches the latest commits and copies the synced files into `~/.claude`. Files in `~/.claude` that no longer exist in the repo are removed, making pull a true mirror. If both local and remote have changed the same file since the last sync, you will be asked which version wins.

Use `-Force` / `--force` to re-copy all files even when the remote commit matches the last sync (useful if files are missing from `~/.claude` without any new commits).

### Upload local settings to GitHub

```powershell
# Windows
.\claude-sync-push.ps1
```

```bash
# Linux / macOS
bash claude-sync-push.sh
```

Copies the synced files from `~/.claude` into the local repo clone, removes any repo files that no longer exist locally, commits with a timestamp and machine name, and pushes to GitHub. If the remote is ahead of your last sync, you will be warned before proceeding.

### Check what has changed

```powershell
# Windows
.\claude-sync-status.ps1 [-Verbose]
```

```bash
# Linux / macOS
bash claude-sync-status.sh [--verbose|-v]
```

Read-only. Reports whether there are local changes to push or remote changes to pull since the last sync, and highlights any conflicts. Makes no changes.

By default only counts are shown. Pass `-Verbose` / `--verbose` to list each changed file.

## File Layout

```
~/.claude-sync/
  config.json   # local config, never synced to GitHub
  repo/         # git clone of your settings repo (staging area)
```

The config is always local to each machine and is never uploaded. The `repo/` directory is purely a staging area; your settings live in `~/.claude`.

## What Gets Synced

Only an allowlist of paths is synced. Everything else in `~/.claude` (plugins, sessions, `settings.json`, `.claude.json`, caches and other machine-specific state) is never pushed, pulled or deleted. Defaults:

```
CLAUDE.md
skills/*
statusline.ps1
```

`skills/synced/` (skills synced from your claude.ai account) and `skills/.trash/` are always excluded, since Claude Code manages them on each machine.

To customize, edit `~/.claude-sync/config.json`:

- `includes`: glob patterns matched against the full path relative to `~/.claude` (`*` spans directories, e.g. `skills/*`). If the key is missing, the defaults above apply.
- `exclusions`: patterns removed from the included set. A pattern with a `/` matches the full path; one without matches any single path segment (e.g. `*.log`).

Files in the repo that fall outside the allowlist (e.g. left over from older versions of these scripts) are ignored, not deleted.

## Conflict Resolution

Conflicts are detected using the `lastSyncCommit` recorded after each successful push or pull. If a file changed both locally and on the remote since that commit, you are prompted:

```
CONFLICT: The following files changed both locally and remotely:
  [1] settings.json

Which version wins? [L]ocal / [R]emote / [D]iff:
```

Choosing **Diff** shows the remote (-) vs local (+) diff of a file (you pick the number when several conflict), then asks again.  
Choosing **Local** aborts the pull and leaves your files untouched. Run push to upload your version.  
Choosing **Remote** overwrites your local files with the repo version.

## Typical Workflow

**Setting up a new machine:**

```powershell
# Windows
.\claude-sync-init.ps1
.\claude-sync-pull.ps1
```

```bash
# Linux / macOS
bash claude-sync-init.sh
bash claude-sync-pull.sh
```

**After making local changes:**

```powershell
# Windows
.\claude-sync-push.ps1
```

```bash
# Linux / macOS
bash claude-sync-push.sh
```

**Before making changes (to get latest from another machine):**

```powershell
# Windows
.\claude-sync-pull.ps1
```

```bash
# Linux / macOS
bash claude-sync-pull.sh
```
