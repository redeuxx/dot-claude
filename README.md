# Claude Code Settings Sync

Sync your `~/.claude` directory across multiple machines via a private GitHub repo. Scripts are available for Windows (PowerShell) and Linux/macOS (Bash).

## Prerequisites

| Tool | Windows | Linux | macOS |
|---|---|---|---|
| Git | [git-scm.com](https://git-scm.com/) | `sudo apt install git` | `brew install git` |
| GitHub CLI | [cli.github.com](https://cli.github.com/) | [install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) | `brew install gh` |
| jq *(Bash only)* | — | `sudo apt install jq` | `brew install jq` |
| PowerShell 5.1+ *(Windows only)* | built-in | — | — |

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

- **Repo URL** — your private GitHub repo (e.g. `https://github.com/you/claude-settings.git`)
- **Subdirectory** — an optional path within the repo to sync into (e.g. `claude`). Leave blank to use the repo root.

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

Fetches the latest commits and copies repo contents into `~/.claude`. Files in `~/.claude` that no longer exist in the repo are removed, making pull a true mirror. If both local and remote have changed the same file since the last sync, you will be asked which version wins.

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

Copies `~/.claude` into the local repo clone, removes any repo files that no longer exist locally, commits with a timestamp and machine name, and pushes to GitHub. If the remote is ahead of your last sync, you will be warned before proceeding.

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
  config.json   # local config — never synced to GitHub
  repo/         # git clone of your settings repo (staging area)
```

The config is always local to each machine and is never uploaded. The `repo/` directory is purely a staging area — your settings live in `~/.claude`.

## Default Exclusions

The following are excluded from syncing by default (local/ephemeral data):

```
*.log  .credentials.json  cache  .tmp  ide  backups  debug  downloads
file-history  mcp-needs-auth-cache.json  plans  policy-limits.json
projects  sessions  shell-snapshots  statsig  telemetry  settings.local.json  todos  plugins
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
