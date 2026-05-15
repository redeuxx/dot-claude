# Requires -Version 5.1
# _common.ps1 — Shared functions for claude-sync scripts.
# Dot-source this file at the top of each script:
#   . "$PSScriptRoot\_common.ps1"

$ErrorActionPreference = 'Stop'

# CONFIG

function Get-SyncConfigPath {
    return Join-Path $env:USERPROFILE '.claude-sync\config.json'
}

function Load-SyncConfig {
    $path = Get-SyncConfigPath
    if (-not (Test-Path $path)) {
        return $null
    }
    $raw = Get-Content $path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Save-SyncConfig {
    param([Parameter(Mandatory)][PSCustomObject]$Config)
    $path = Get-SyncConfigPath
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
}

# PATH RESOLUTION

function Get-ClaudeDir {
    return Join-Path $env:USERPROFILE '.claude'
}

function Get-RepoDir {
    return Join-Path $env:USERPROFILE '.claude-sync\repo'
}

# EXCLUSION MATCHING

function Test-IsExcluded {
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    # $RelPath is always forward-slash separated, e.g. "cache/somefile.txt"
    $segments = $RelPath -split '/'
    foreach ($pattern in $Exclusions) {
        if ($pattern -like '*/*') {
            # Pattern contains a slash — match against full path
            if ($RelPath -like $pattern) { return $true }
        } else {
            # Match against each path segment individually
            foreach ($seg in $segments) {
                if ($seg -like $pattern) { return $true }
            }
        }
    }
    return $false
}

# FILE SYNC

function Copy-ClaudeToRepo {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    $copied = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $ClaudeDir)) { return $copied.ToArray() }

    Get-ChildItem -Path $ClaudeDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($ClaudeDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-IsExcluded $relPath $Exclusions) { return }

        $dest = Join-Path $RepoDir ($relPath.Replace('/', '\'))
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item $fullPath $dest -Force
        $copied.Add($relPath)
    }
    return $copied.ToArray()
}

function Copy-RepoToClaude {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    $copied = [System.Collections.Generic.List[string]]::new()

    # Skip .git directory entirely
    Get-ChildItem -Path $RepoDir -Recurse -File | Where-Object {
        $_.FullName -notmatch [regex]::Escape((Join-Path $RepoDir '.git'))
    } | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-IsExcluded $relPath $Exclusions) { return }

        $dest = Join-Path $ClaudeDir ($relPath.Replace('/', '\'))
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item $fullPath $dest -Force
        $copied.Add($relPath)
    }
    return $copied.ToArray()
}

function Remove-StaleRepoFiles {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    $deleted = [System.Collections.Generic.List[string]]::new()

    Get-ChildItem -Path $RepoDir -Recurse -File | Where-Object {
        $_.FullName -notmatch [regex]::Escape((Join-Path $RepoDir '.git'))
    } | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-IsExcluded $relPath $Exclusions) { return }

        $source = Join-Path $ClaudeDir ($relPath.Replace('/', '\'))
        if (-not (Test-Path $source)) {
            Remove-Item $fullPath -Force
            $deleted.Add($relPath)
        }
    }
    return $deleted.ToArray()
}

function Remove-StaleClaudeFiles {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    $deleted = [System.Collections.Generic.List[string]]::new()

    Get-ChildItem -Path $ClaudeDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($ClaudeDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-IsExcluded $relPath $Exclusions) { return }

        $repoFile = Join-Path $SyncDir ($relPath.Replace('/', '\'))
        if (-not (Test-Path $repoFile)) {
            Remove-Item $fullPath -Force
            $deleted.Add($relPath)
        }
    }
    return $deleted.ToArray()
}

# CONFLICT DETECTION

function Get-LocalChangedFiles {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][string]$CommitHash,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    # Prefix to strip when mapping repo-relative paths back to .claude-relative paths
    $subdirPrefix = ''
    if ($SyncDir -ne $RepoDir) {
        $subdirPrefix = $SyncDir.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/') + '/'
    }

    # Copy .claude into the repo working tree, ask git what changed vs CommitHash,
    # then restore the working tree. This lets git handle binary files correctly.
    try {
        Copy-ClaudeToRepo $ClaudeDir $SyncDir $Exclusions | Out-Null

        $diffOutput = & git -C $RepoDir diff --name-only $CommitHash 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "git diff failed"
        }
        # Also include untracked files (new files not yet committed)
        $untrackedOutput = & git -C $RepoDir ls-files --others --exclude-standard 2>$null
        $changed = @(
            ($diffOutput     | Where-Object { $_ -ne '' })
            ($untrackedOutput | Where-Object { $_ -ne '' })
        )

        # Also detect files deleted locally (present in repo at CommitHash but not in .claude)
        $atCommit = & git -C $RepoDir ls-tree -r --name-only $CommitHash 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($repoRel in ($atCommit -split "`n" | Where-Object { $_ -ne '' })) {
                if (Test-IsExcluded $repoRel $Exclusions) { continue }
                # Strip subdir prefix to get .claude-relative path
                $claudeRel = if ($subdirPrefix -ne '' -and $repoRel.StartsWith($subdirPrefix)) {
                    $repoRel.Substring($subdirPrefix.Length)
                } else { $repoRel }
                $localFull = Join-Path $ClaudeDir ($claudeRel.Replace('/', '\'))
                if (-not (Test-Path $localFull)) {
                    if ($changed -notcontains $repoRel) {
                        $changed += $repoRel
                    }
                }
            }
        }
        return $changed
    } finally {
        # Always restore the repo working tree
        & git -C $RepoDir checkout -- . 2>&1 | Out-Null
    }
}

function Get-RemoteChangedFiles {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][AllowNull()][string]$CommitHash
    )
    if ($null -eq $CommitHash -or $CommitHash -eq '') {
        return @()
    }
    $remoteHead = & git -C $RepoDir rev-parse FETCH_HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    $remoteHead = $remoteHead.Trim()
    if ($remoteHead -eq $CommitHash) { return @() }

    $diffOutput = & git -C $RepoDir diff --name-only $CommitHash $remoteHead 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    return $diffOutput -split "`n" | Where-Object { $_ -ne '' }
}

function Test-ConflictExists {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][string]$CommitHash,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    $localChanged  = Get-LocalChangedFiles  $ClaudeDir $RepoDir $SyncDir $CommitHash $Exclusions
    $remoteChanged = Get-RemoteChangedFiles $RepoDir $CommitHash
    $conflictFiles = $localChanged | Where-Object { $remoteChanged -contains $_ }

    return @{
        HasConflict    = ($conflictFiles.Count -gt 0)
        LocalChanged   = $localChanged
        RemoteChanged  = $remoteChanged
        ConflictFiles  = $conflictFiles
    }
}

# GIT HELPERS

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & git -C $RepoDir @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$output"
    }
    return ($output | Out-String).Trim()
}

function Get-RepoCurrentCommit {
    param([Parameter(Mandatory)][string]$RepoDir)
    return Invoke-Git $RepoDir @('rev-parse', 'HEAD')
}

function Get-RemoteHeadCommit {
    param([Parameter(Mandatory)][string]$RepoDir)
    return (Invoke-Git $RepoDir @('rev-parse', 'FETCH_HEAD')).Trim()
}

# PREREQUISITE CHECKS

function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not installed or not on PATH. Install Git for Windows: https://git-scm.com/"
    }
}

function Assert-GhAvailable {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is not installed or not on PATH. Install from: https://cli.github.com/"
    }
}

function Assert-GhAuthenticated {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run: gh auth login"
    }
}

# USER PROMPTS

function Confirm-Prompt {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$Default = $false
    )
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $response = Read-Host "$Message $hint"
    if ($response -eq '') { return $Default }
    return $response -match '^[Yy]'
}

function Select-ConflictWinner {
    param([Parameter(Mandatory)][string[]]$ConflictFiles)
    Write-Host ""
    Write-Host "CONFLICT: The following files changed both locally and remotely:"
    foreach ($f in $ConflictFiles) {
        Write-Host "  $f"
    }
    Write-Host ""
    while ($true) {
        $response = Read-Host "Which version wins? [L]ocal / [R]emote"
        if ($response -match '^[Ll]') { return 'local' }
        if ($response -match '^[Rr]') { return 'remote' }
        Write-Host "Please enter L or R."
    }
}
