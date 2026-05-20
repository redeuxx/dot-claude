# Requires -Version 5.1
# claude-sync-status.ps1 — Show what differs between local ~/.claude and the remote repo.
# Read-only: makes no changes to files or config.
#
# USAGE:
#   .\claude-sync-status.ps1 [-Verbose]
#
# OPTIONS:
#   -Verbose  List each changed file instead of just the count.
#
# NOTE: You may need to allow script execution first:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

# LOAD CONFIG

$config = Load-SyncConfig
if ($null -eq $config) {
    Write-Host "Not initialized. Run claude-sync-init.ps1 first."
    exit 0
}

$claudeDir  = $config.claudeDir
$repoDir    = $config.repoDir
$syncDir    = if ($config.repoSubdir) { Join-Path $repoDir $config.repoSubdir.Replace('/', '\') } else { $repoDir }
$exclusions = @($config.exclusions)
$lastSync   = $config.lastSyncCommit
$lastTime   = $config.lastSyncTime

Assert-GitAvailable

# FETCH REMOTE (best-effort — offline is fine, done before header so we can show machine name)

$fetchOk = $false
try {
    Invoke-Git $repoDir @('fetch', 'origin', '--quiet') | Out-Null
    $fetchOk = $true
} catch {}

# SUMMARY HEADER

$pushedBy = $null
if ($fetchOk) {
    try {
        $remoteMsg = Invoke-Git $repoDir @('log', '-1', '--format=%s', 'FETCH_HEAD')
        if ($remoteMsg -match '\bfrom\s+(\S+)') {
            $pushedBy = $Matches[1]
        }
    } catch {}
}

Write-Host ""
Write-Host "Repo       : $($config.repoUrl)"
if ($config.repoSubdir) {
    Write-Host "Subdir     : $($config.repoSubdir)"
}
if ($null -ne $lastTime -and $lastTime -ne '') {
    Write-Host "Last sync  : $lastTime"
} else {
    Write-Host "Last sync  : never"
}
if ($null -ne $lastSync -and $lastSync -ne '') {
    Write-Host "Commit     : $lastSync"
} else {
    Write-Host "Commit     : none"
}
if ($null -ne $pushedBy) {
    Write-Host "Pushed by  : $pushedBy"
}
Write-Host ""

if (-not $fetchOk) {
    Write-Host "[WARNING] Could not reach remote. Showing local status only."
    Write-Host ""
}

# REMOTE STATUS

$remoteChanged = @()
if ($fetchOk) {
    if ($null -eq $lastSync -or $lastSync -eq '') {
        Write-Host "Remote : no baseline sync yet — cannot compare"
    } else {
        try {
            $remoteChanged = @(Get-RemoteChangedFiles $repoDir $lastSync)
            if ($remoteChanged.Count -eq 0) {
                Write-Host "Remote : nothing to pull"
            } else {
                Write-Host "Remote : $($remoteChanged.Count) file(s) changed -> run .\claude-sync-pull.ps1"
                if ($Verbose) {
                    foreach ($f in $remoteChanged) { Write-Host "  [remote] $f" }
                }
            }
        } catch {
            Write-Host "Remote : could not determine (error: $_)"
        }
    }
}

# LOCAL STATUS

$localChanged = @()
if ($null -eq $lastSync -or $lastSync -eq '') {
    Write-Host "Local  : no baseline sync yet — cannot compare"
} elseif (-not (Test-Path $claudeDir)) {
    Write-Host "Local  : .claude directory not found at $claudeDir"
} else {
    try {
        $localChanged = @(Get-LocalChangedFiles $claudeDir $repoDir $syncDir $lastSync $exclusions)
        if ($localChanged.Count -eq 0) {
            Write-Host "Local  : nothing to push"
        } else {
            Write-Host "Local  : $($localChanged.Count) file(s) changed -> run .\claude-sync-push.ps1"
            if ($Verbose) {
                foreach ($f in $localChanged) { Write-Host "  [local] $f" }
            }
        }
    } catch {
        Write-Host "Local  : could not determine (error: $_)"
    }
}

# CONFLICT SUMMARY

$hasConflicts = $false
if ($localChanged.Count -gt 0 -and $remoteChanged.Count -gt 0) {
    $conflicts = $localChanged | Where-Object { $remoteChanged -contains $_ }
    if ($conflicts.Count -gt 0) {
        $hasConflicts = $true
        Write-Host ""
        Write-Host "CONFLICTS ($($conflicts.Count) file(s) changed in both local and remote):"
        if ($Verbose) {
            foreach ($f in $conflicts) { Write-Host "  [CONFLICT] $f" }
        }
    }
}

if (-not $Verbose) {
    Write-Host "Tip: run with -Verbose to list changed files."
}
Write-Host ""

# ACTION PROMPTS

if ($hasConflicts) {
    Write-Host "Both local and remote have changes. You must choose one direction."
    Write-Host "  [1] Pull from remote (overwrites your local changes)"
    Write-Host "  [2] Push to remote   (overwrites remote with your local changes)"
    Write-Host "  [3] Do nothing"
    $choice = Read-Host "Choice"
    switch ($choice.Trim()) {
        '1' { & "$PSScriptRoot\claude-sync-pull.ps1" }
        '2' { & "$PSScriptRoot\claude-sync-push.ps1" }
        default { Write-Host "No action taken." }
    }
} elseif ($remoteChanged.Count -gt 0 -and $localChanged.Count -gt 0) {
    # Non-conflicting changes on both sides - pull first is the safe order
    Write-Host "Remote and local both have changes (no file conflicts)."
    Write-Host "  [1] Pull from remote first, then push local changes"
    Write-Host "  [2] Pull only"
    Write-Host "  [3] Push only"
    Write-Host "  [4] Do nothing"
    $choice = Read-Host "Choice"
    switch ($choice.Trim()) {
        '1' {
            & "$PSScriptRoot\claude-sync-pull.ps1"
            & "$PSScriptRoot\claude-sync-push.ps1"
        }
        '2' { & "$PSScriptRoot\claude-sync-pull.ps1" }
        '3' { & "$PSScriptRoot\claude-sync-push.ps1" }
        default { Write-Host "No action taken." }
    }
} elseif ($remoteChanged.Count -gt 0) {
    $answer = Read-Host "Pull $($remoteChanged.Count) remote change(s) now? [y/N]"
    if ($answer.Trim() -match '^[Yy]') {
        & "$PSScriptRoot\claude-sync-pull.ps1"
    }
} elseif ($localChanged.Count -gt 0) {
    $answer = Read-Host "Push $($localChanged.Count) local change(s) now? [y/N]"
    if ($answer.Trim() -match '^[Yy]') {
        & "$PSScriptRoot\claude-sync-push.ps1"
    }
}
