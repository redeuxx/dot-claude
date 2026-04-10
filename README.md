# Claude Code Settings Sync

Sync your `~/.claude` directory across multiple Windows machines via a private GitHub repo.

## Prerequisites

- [Git for Windows](https://git-scm.com/)
- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated via `gh auth login`
- PowerShell 5.1 or later

You may also need to allow script execution:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## First-Time Setup

Run this once per machine:

```powershell
.\claude-sync-init.ps1
```

You will be prompted for:

- **Repo URL** — your private GitHub repo (e.g. `https://github.com/you/claude-settings.git`)
- **Subdirectory** — an optional path within the repo to sync into (e.g. `claude`). Leave blank to use the repo root.

The script clones the repo to `~/.claude-sync/repo/` and writes a local config to `~/.claude-sync/config.json`.

If the repo is brand new (empty), run push first. If it already has settings from another machine, run pull first.

Re-running init on a machine that is already configured will prompt before overwriting.

## Usage

### Download settings from GitHub

```powershell
.\claude-sync-pull.ps1
```

Fetches the latest commits and copies repo contents into `~/.claude`. Files in `~/.claude` that no longer exist in the repo are removed, making pull a true mirror. If both local and remote have changed the same file since the last sync, you will be asked which version wins.

### Upload local settings to GitHub

```powershell
.\claude-sync-push.ps1
```

Copies `~/.claude` into the local repo clone, removes any repo files that no longer exist locally, commits with a timestamp and machine name, and pushes to GitHub. If the remote is ahead of your last sync, you will be warned before proceeding.

### Check what has changed

```powershell
.\claude-sync-status.ps1
```

Read-only. Shows which files differ between your local `~/.claude` and the remote repo since the last sync. Highlights any conflicts. Makes no changes.

## File Layout

```
~/.claude-sync/
  config.json   # local config — never synced to GitHub
  repo/         # git clone of your settings repo (staging area)
```

The config is always local to each machine and is never uploaded. The `repo/` directory is purely a staging area — your settings live in `~/.claude`.

## Default Exclusions

The following are excluded from syncing by default (local/ephemeral data):

```
*.log  .credentials.json  cache  .tmp  ide  backups  debug  downloads
file-history  mcp-needs-auth-cache.json  plans  policy-limits.json
projects  sessions  shell-snapshots  statsig  telemetry  settings.local.json  todos
```

To customize, edit the `exclusions` array in `~/.claude-sync/config.json`.

## Conflict Resolution

Conflicts are detected using the `lastSyncCommit` recorded after each successful push or pull. If a file changed both locally and on the remote since that commit, you are prompted:

```
CONFLICT: The following files changed both locally and remotely:
  settings.json

Which version wins? [L]ocal / [R]emote:
```

Choosing **Local** aborts the pull and leaves your files untouched. Run push to upload your version.  
Choosing **Remote** overwrites your local files with the repo version.

## Typical Workflow

**Setting up a new machine:**

```powershell
.\claude-sync-init.ps1   # enter repo URL and optional subdirectory
.\claude-sync-pull.ps1   # download your settings
```

**After making local changes:**

```powershell
.\claude-sync-push.ps1
```

**Before making changes (to get latest from another machine):**

```powershell
.\claude-sync-pull.ps1
```
