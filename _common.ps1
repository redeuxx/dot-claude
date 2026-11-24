# Requires -Version 5.1
# _common.ps1 - Shared functions for claude-sync scripts.
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

# SYNC FILTER
# A file syncs only if its .claude-relative path matches an include pattern and
# no exclusion. Include patterns are globs matched against the full relative
# path (forward slashes, `*` spans directories), e.g. 'CLAUDE.md', 'skills/*'.

$script:DefaultIncludes = @(
    'CLAUDE.md'
    'skills/*'
    'statusline.ps1'
)

# Managed by Claude Code itself; never synced regardless of config.
$script:BuiltInExclusions = @(
    'skills/synced/*'
    'skills/.trash/*'
)

function Get-SyncFilter {
    param([Parameter(Mandatory)][PSCustomObject]$Config)
    $includes = if ($Config.PSObject.Properties.Name -contains 'includes' -and $null -ne $Config.includes) {
        @($Config.includes)
    } else {
        $script:DefaultIncludes
    }
    $exclusions = @($script:BuiltInExclusions) + @($Config.exclusions | Where-Object { $_ })
    return @{ Includes = @($includes); Exclusions = @($exclusions) }
}

function Test-IsIncluded {
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Includes
    )
    foreach ($pattern in $Includes) {
        if ($RelPath -like $pattern) { return $true }
    }
    return $false
}

function Test-IsSynced {
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][hashtable]$Filter
    )
    # Never touch git metadata, even if an include pattern would match it
    if ($RelPath -eq '.git' -or $RelPath.StartsWith('.git/')) { return $false }
    if (-not (Test-IsIncluded $RelPath $Filter.Includes)) { return $false }
    return -not (Test-IsExcluded $RelPath $Filter.Exclusions)
}

# Maps a repo-relative path to a .claude-relative path, or $null if the path
# lies outside the sync subdirectory.
function ConvertTo-ClaudeRelPath {
    param(
        [Parameter(Mandatory)][string]$RepoRel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubdirPrefix
    )
    if ($SubdirPrefix -eq '') { return $RepoRel }
    if ($RepoRel.StartsWith($SubdirPrefix)) { return $RepoRel.Substring($SubdirPrefix.Length) }
    return $null
}

function Get-SubdirPrefix {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir
    )
    if ($SyncDir -eq $RepoDir) { return '' }
    return $SyncDir.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/') + '/'
}

function Test-IsExcluded {
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Exclusions
    )
    # $RelPath is always forward-slash separated, e.g. "cache/somefile.txt"
    $segments = $RelPath -split '/'
    foreach ($pattern in $Exclusions) {
        if ($pattern -like '*/*') {
            # Pattern contains a slash - match against full path
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
        [Parameter(Mandatory)][hashtable]$Filter
    )
    $copied = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $ClaudeDir)) { return $copied.ToArray() }

    Get-ChildItem -Path $ClaudeDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($ClaudeDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not (Test-IsSynced $relPath $Filter)) { return }

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
        [Parameter(Mandatory)][hashtable]$Filter
    )
    $copied = [System.Collections.Generic.List[string]]::new()

    # Test-IsSynced rejects .git and anything outside the include list
    Get-ChildItem -Path $RepoDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not (Test-IsSynced $relPath $Filter)) { return }

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
        [Parameter(Mandatory)][hashtable]$Filter
    )
    $deleted = [System.Collections.Generic.List[string]]::new()

    Get-ChildItem -Path $RepoDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($RepoDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not (Test-IsSynced $relPath $Filter)) { return }

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
        [Parameter(Mandatory)][hashtable]$Filter
    )
    $deleted = [System.Collections.Generic.List[string]]::new()

    Get-ChildItem -Path $ClaudeDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        $relPath  = $fullPath.Substring($ClaudeDir.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not (Test-IsSynced $relPath $Filter)) { return }

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
        [Parameter(Mandatory)][hashtable]$Filter
    )
    # Prefix to strip when mapping repo-relative paths back to .claude-relative paths
    $subdirPrefix = Get-SubdirPrefix $RepoDir $SyncDir

    # Runs git keeping stdout only. Windows PowerShell 5.1 would otherwise turn
    # harmless stderr (CRLF warnings, "Updated N paths") into terminating errors.
    $git = { $ErrorActionPreference = 'Continue'; & git @args 2>$null }

    # Copy .claude into the repo working tree, ask git what changed vs CommitHash,
    # then restore the working tree. This lets git handle binary files correctly.
    try {
        Copy-ClaudeToRepo $ClaudeDir $SyncDir $Filter | Out-Null

        $diffOutput = & $git -C $RepoDir diff --name-only $CommitHash
        if ($LASTEXITCODE -ne 0) {
            throw "git diff failed"
        }
        # Also include untracked files (new files not yet committed)
        $untrackedOutput = & $git -C $RepoDir ls-files --others --exclude-standard
        $changed = @(
            @($diffOutput) + @($untrackedOutput) | Where-Object {
                if (-not $_) { return $false }
                $claudeRel = ConvertTo-ClaudeRelPath $_ $subdirPrefix
                $null -ne $claudeRel -and (Test-IsSynced $claudeRel $Filter)
            }
        )

        # Also detect files deleted locally (present in repo at CommitHash but not in .claude)
        $atCommit = & $git -C $RepoDir ls-tree -r --name-only $CommitHash
        if ($LASTEXITCODE -eq 0) {
            foreach ($repoRel in ($atCommit -split "`n" | Where-Object { $_ -ne '' })) {
                $claudeRel = ConvertTo-ClaudeRelPath $repoRel $subdirPrefix
                if ($null -eq $claudeRel -or -not (Test-IsSynced $claudeRel $Filter)) { continue }
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
        # Always restore the repo working tree, including removing the untracked
        # copies, so a later push's `git add -A` cannot pick them up
        & $git -C $RepoDir checkout -- . | Out-Null
        & $git -C $RepoDir clean -fdq -e /.gitattributes -- $SyncDir | Out-Null
    }
}

function Get-RemoteChangedFiles {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][AllowNull()][string]$CommitHash,
        [Parameter(Mandatory)][hashtable]$Filter
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
    $subdirPrefix = Get-SubdirPrefix $RepoDir $SyncDir
    return $diffOutput -split "`n" | Where-Object {
        if (-not $_) { return $false }
        $claudeRel = ConvertTo-ClaudeRelPath $_ $subdirPrefix
        $null -ne $claudeRel -and (Test-IsSynced $claudeRel $Filter)
    }
}

function Test-ConflictExists {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][string]$CommitHash,
        [Parameter(Mandatory)][hashtable]$Filter
    )
    $localChanged  = @(Get-LocalChangedFiles  $ClaudeDir $RepoDir $SyncDir $CommitHash $Filter)
    $remoteChanged = @(Get-RemoteChangedFiles $RepoDir $SyncDir $CommitHash $Filter)
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
    # Windows PowerShell 5.1 turns any native stderr (fetch progress, CRLF
    # warnings) into a terminating error under Stop. git reports failure
    # through its exit code, so judge by that and keep stderr as plain text.
    $ErrorActionPreference = 'Continue'
    $output = & git -C $RepoDir @Arguments 2>&1 | ForEach-Object { "$_" }
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

# Prints the remote (-) vs local (+) diff of one repo-relative file. The local
# copy is placed in the repo working tree so .gitattributes normalization applies,
# then the working tree is restored.
function Show-ConflictDiff {
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir,
        [Parameter(Mandatory)][string]$RepoRel
    )
    # Windows PowerShell 5.1 turns redirected native stderr into terminating
    # errors under Stop; expected git noise (e.g. checkout of an untracked path
    # during cleanup) must not abort the pull
    $ErrorActionPreference = 'Continue'
    $claudeRel = ConvertTo-ClaudeRelPath $RepoRel (Get-SubdirPrefix $RepoDir $SyncDir)
    $localFull = Join-Path $ClaudeDir ($claudeRel.Replace('/', '\'))
    $repoFull  = Join-Path $RepoDir ($RepoRel.Replace('/', '\'))
    # git writes UTF-8; decode it as such so non-ASCII text is not garbled
    $oldEncoding = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
        if (Test-Path -LiteralPath $localFull) {
            New-Item -ItemType Directory -Force -Path (Split-Path $repoFull) | Out-Null
            Copy-Item -LiteralPath $localFull -Destination $repoFull -Force
            # Intent-to-add so a file that is new on both sides still shows in the diff
            & git -C $RepoDir -c core.safecrlf=false add -N -- $RepoRel 2>&1 | Out-Null
        } elseif (Test-Path -LiteralPath $repoFull) {
            Remove-Item -LiteralPath $repoFull -Force
        }
        Write-Host ""
        Write-Host "Diff of ${RepoRel} (- remote, + local):"
        # Out-Host keeps git's output out of the caller's return value
        & git -C $RepoDir -c core.safecrlf=false --no-pager diff --color=always FETCH_HEAD -- $RepoRel 2>&1 | Out-Host
    } finally {
        & git -C $RepoDir reset -q -- $RepoRel 2>&1 | Out-Null
        & git -C $RepoDir checkout -- $RepoRel 2>&1 | Out-Null
        & git -C $RepoDir clean -fq -- $RepoRel 2>&1 | Out-Null
        try { [Console]::OutputEncoding = $oldEncoding } catch { }
    }
}

function Select-ConflictWinner {
    param(
        [Parameter(Mandatory)][string[]]$ConflictFiles,
        [Parameter(Mandatory)][string]$ClaudeDir,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$SyncDir
    )
    Write-Host ""
    Write-Host "CONFLICT: The following files changed both locally and remotely:"
    for ($i = 0; $i -lt $ConflictFiles.Count; $i++) {
        Write-Host "  [$($i + 1)] $($ConflictFiles[$i])"
    }
    Write-Host ""
    while ($true) {
        $response = Read-Host "Which version wins? [L]ocal / [R]emote / [D]iff"
        if ($response -match '^[Ll]') { return 'local' }
        if ($response -match '^[Rr]') { return 'remote' }
        if ($response -match '^[Dd]') {
            $pick = '1'
            if ($ConflictFiles.Count -gt 1) {
                $pick = Read-Host "Diff which file? [1-$($ConflictFiles.Count)]"
            }
            $n = 0
            if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $ConflictFiles.Count) {
                Show-ConflictDiff $ClaudeDir $RepoDir $SyncDir $ConflictFiles[$n - 1]
            } else {
                Write-Host "Please enter a number from 1 to $($ConflictFiles.Count)."
            }
            Write-Host ""
            continue
        }
        Write-Host "Please enter L, R or D."
    }
}

# SCRIPT UPDATE CHECK

# Tells the user when the scripts' own git checkout is behind its upstream.
# Notify only, never auto-update. Silent when git is missing, the scripts are
# not a git checkout, there is no upstream, or the fetch fails or takes over
# 5 seconds (offline, dropped packets), so it can never block a sync.
function Show-ScriptUpdateNotice {
    param([Parameter(Mandatory)][string]$ScriptDir)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $names = 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE', 'GIT_SSH_COMMAND'
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        # Only check a checkout that actually tracks these scripts
        & git -C $ScriptDir ls-files --error-unmatch _common.ps1 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return }
        # Never prompt for credentials, passphrases or host keys just for an update check
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE     = 'never'
        $configSsh = & git -C $ScriptDir config core.sshCommand 2>$null
        if (-not $saved['GIT_SSH_COMMAND'] -and -not $configSsh) {
            $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=5'
        }
        # Hard 5 second cap, since git has no connect timeout of its own.
        # ponytail: Kill() stops git.exe only; a stuck child helper exits on its own timeout
        $p = Start-Process git -ArgumentList "-C `"$ScriptDir`" fetch --quiet" -WindowStyle Hidden -PassThru
        $null = $p.Handle  # 5.1 needs the handle cached to read ExitCode later
        if (-not $p.WaitForExit(5000)) {
            try { $p.Kill() } catch { }
            return
        }
        if ($p.ExitCode -ne 0) { return }
        $counts = (& git -C $ScriptDir rev-list --left-right --count 'HEAD...@{upstream}' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $counts -notmatch '^(\d+)\s+(\d+)$') { return }
        $ahead  = [int]$Matches[1]
        $behind = [int]$Matches[2]
        if ($behind -eq 0) { return }
        if ($ahead -gt 0) {
            Write-Host "Script updates available: $behind new commit(s) upstream, but your checkout also has $ahead local commit(s)."
            Write-Host "  Merge or rebase in `"$ScriptDir`" to update."
        } else {
            Write-Host "Script updates available: $behind new commit(s) upstream. To update, run:"
            Write-Host "  git -C `"$ScriptDir`" pull --ff-only"
        }
        Write-Host ""
    } catch {
        return
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}
