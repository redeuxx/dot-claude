# Requires -Version 5.1
# claude-sync-push.ps1 — Copy local ~/.claude to repo, commit, and push to GitHub.
#
# USAGE:
#   .\claude-sync-push.ps1
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

# CHECK .CLAUDE EXISTS

if (-not (Test-Path $claudeDir)) {
    Write-Error ".claude directory not found at $claudeDir"
    exit 1
}

# CHECK IF REMOTE IS AHEAD

Write-Host "Fetching remote status..."
try {
    Invoke-Git $repoDir @('fetch', 'origin') | Out-Null
    $remoteHead = Get-RemoteHeadCommit $repoDir

    if ($null -ne $lastSync -and $remoteHead -ne $lastSync) {
        Write-Host ""
        Write-Host "WARNING: Remote has new commits since your last sync."
        Write-Host "Run claude-sync-pull.ps1 first to avoid overwriting remote changes."
        Write-Host ""
        if (-not (Confirm-Prompt "Push anyway?")) {
            Write-Host "Aborted."
            exit 0
        }
    }
} catch {
    Write-Host "Could not reach remote. Proceeding with local commit only (no push)."
    $remoteHead = $null
}

# STAGE FILES

Write-Host "Copying $claudeDir to repo..."
$copied  = Copy-ClaudeToRepo     $claudeDir $syncDir $exclusions
$deleted = Remove-StaleRepoFiles $syncDir   $claudeDir $exclusions

if ($copied.Count -gt 0 -or $deleted.Count -gt 0) {
    Write-Host "  Staged   : $($copied.Count) file(s)"
    Write-Host "  Removed  : $($deleted.Count) stale file(s)"
}

# CHECK FOR ACTUAL GIT CHANGES

$status = Invoke-Git $repoDir @('status', '--porcelain')
if ($status -eq '') {
    Write-Host "Nothing to commit — local .claude already matches the repo."
    exit 0
}

# COMMIT

Invoke-Git $repoDir @('add', '-A') | Out-Null
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Invoke-Git $repoDir @('commit', '-m', "sync: $timestamp from $env:COMPUTERNAME") | Out-Null
Write-Host "Committed."

# PUSH

Write-Host "Pushing to remote..."
$pushed = $false
try {
    Invoke-Git $repoDir @('push', 'origin') | Out-Null
    $pushed = $true
} catch {
    # First push to empty repo needs --set-upstream
    $branch = (Invoke-Git $repoDir @('branch', '--show-current')).Trim()
    if ($branch -eq '') { $branch = 'main' }
    try {
        Invoke-Git $repoDir @('push', '--set-upstream', 'origin', $branch) | Out-Null
        $pushed = $true
    } catch {
        Write-Error "Push failed: $_"
        exit 1
    }
}

# UPDATE CONFIG

$config.lastSyncCommit = Get-RepoCurrentCommit $repoDir
$config.lastSyncTime   = (Get-Date -Format 'o')
Save-SyncConfig $config

Write-Host "Push complete."
