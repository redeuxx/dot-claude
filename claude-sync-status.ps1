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

# SUMMARY HEADER

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
Write-Host ""

# FETCH REMOTE (best-effort — offline is fine)

$fetchOk = $false
try {
    Invoke-Git $repoDir @('fetch', 'origin', '--quiet') | Out-Null
    $fetchOk = $true
} catch {
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
                Write-Host "Remote : up to date"
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
            Write-Host "Local  : up to date"
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

if ($localChanged.Count -gt 0 -and $remoteChanged.Count -gt 0) {
    $conflicts = $localChanged | Where-Object { $remoteChanged -contains $_ }
    if ($conflicts.Count -gt 0) {
        Write-Host ""
        Write-Host "CONFLICTS ($($conflicts.Count) file(s) changed in both local and remote):"
        if ($Verbose) {
            foreach ($f in $conflicts) { Write-Host "  [CONFLICT] $f" }
        }
        Write-Host ""
        Write-Host "Run claude-sync-pull.ps1 or claude-sync-push.ps1 to resolve."
    }
}

if (-not $Verbose) {
    Write-Host "Tip: run with -Verbose to list changed files."
}
Write-Host ""
