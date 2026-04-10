# Requires -Version 5.1
# claude-sync-pull.ps1 — Fetch remote repo and sync contents into local ~/.claude.
#
# USAGE:
#   .\claude-sync-pull.ps1
#
# NOTE: You may need to allow script execution first:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

# LOAD CONFIG

$config = Load-SyncConfig
if ($null -eq $config) {
    Write-Error "Not initialized. Run claude-sync-init.ps1 first."
    exit 1
}

$claudeDir  = $config.claudeDir
$repoDir    = $config.repoDir
$syncDir    = if ($config.repoSubdir) { Join-Path $repoDir $config.repoSubdir.Replace('/', '\') } else { $repoDir }
$exclusions = @($config.exclusions)
$lastSync   = $config.lastSyncCommit

Assert-GitAvailable

# FETCH

Write-Host "Fetching from remote..."
Invoke-Git $repoDir @('fetch', 'origin')

# CHECK IF REMOTE HAS ANYTHING NEW

$remoteHead = $null
try {
    $remoteHead = Get-RemoteHeadCommit $repoDir
} catch {
    Write-Error "Could not determine remote HEAD. The repo may be empty or unreachable."
    exit 1
}

if ($remoteHead -eq $lastSync) {
    Write-Host "Already up to date."
    exit 0
}

# CONFLICT DETECTION

$winner = 'remote'  # default: remote wins unless user overrides

if ($null -ne $lastSync -and (Test-Path $claudeDir)) {
    Write-Host "Checking for conflicts..."
    $conflictInfo = Test-ConflictExists $claudeDir $repoDir $syncDir $lastSync $exclusions

    if ($conflictInfo.HasConflict) {
        $winner = Select-ConflictWinner $conflictInfo.ConflictFiles
        if ($winner -eq 'local') {
            Write-Host ""
            Write-Host "Keeping local changes. Run claude-sync-push.ps1 to upload them."
            exit 0
        }
        Write-Host "Remote wins. Proceeding with pull..."
    } elseif ($conflictInfo.LocalChanged.Count -gt 0) {
        Write-Host ""
        Write-Host "You have local changes that have not been pushed:"
        foreach ($f in $conflictInfo.LocalChanged) {
            Write-Host "  $f"
        }
        Write-Host ""
        if (-not (Confirm-Prompt "Pull anyway? (local changes will be overwritten)")) {
            Write-Host "Aborted. Run claude-sync-push.ps1 to upload your local changes first."
            exit 0
        }
    }
}

# OVERWRITE PROTECTION (first sync or user hasn't been asked yet)

if (Test-Path $claudeDir) {
    if ($null -eq $lastSync) {
        # First sync: .claude exists but we have no baseline — be extra careful
        Write-Host ""
        Write-Host "WARNING: $claudeDir already exists and no previous sync baseline was found."
        if (-not (Confirm-Prompt "Overwrite files in $claudeDir with repo contents?")) {
            Write-Host "Aborted."
            exit 0
        }
    }
} else {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

# MERGE REPO TO REMOTE HEAD

try {
    Invoke-Git $repoDir @('merge', '--ff-only', 'FETCH_HEAD') | Out-Null
} catch {
    # Fast-forward failed (diverged history) — reset hard since user chose remote
    Write-Host "Fast-forward merge not possible; resetting to remote HEAD..."
    Invoke-Git $repoDir @('reset', '--hard', 'FETCH_HEAD') | Out-Null
}

# COPY REPO -> .CLAUDE

$copied  = Copy-RepoToClaude       $syncDir $claudeDir $exclusions
$deleted = Remove-StaleClaudeFiles $claudeDir $syncDir $exclusions

Write-Host "Pulled   : $($copied.Count) file(s) to $claudeDir."
if ($deleted.Count -gt 0) {
    Write-Host "Removed  : $($deleted.Count) stale file(s) from $claudeDir."
}

# UPDATE CONFIG

$config.lastSyncCommit = $remoteHead
$config.lastSyncTime   = (Get-Date -Format 'o')
Save-SyncConfig $config

Write-Host "Pull complete."
