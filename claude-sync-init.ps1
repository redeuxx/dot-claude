# Requires -Version 5.1
# claude-sync-init.ps1 — First-run setup: prompt for repo URL, clone, write config.
#
# USAGE:
#   .\claude-sync-init.ps1
#
# NOTE: You may need to allow script execution first:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

# CHECKS

Assert-GitAvailable

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "GitHub CLI (gh) is required but was not found on this machine."
    Write-Host ""
    Write-Host "Download it from: https://cli.github.com/"
    Write-Host ""
    Write-Host "After installing, run: gh auth login"
    exit 1
}

Assert-GhAuthenticated

# RE-INIT WARNING

$existing = Load-SyncConfig
if ($null -ne $existing) {
    Write-Host "Config already exists at $(Get-SyncConfigPath)."
    Write-Host "Re-running init will re-clone the repo and overwrite the current config."
    if (-not (Confirm-Prompt "Continue?")) {
        Write-Host "Aborted."
        exit 0
    }
}

# REPO URL

$repoUrl = ''
while ($repoUrl -eq '') {
    $repoUrl = (Read-Host "Enter the GitHub repo URL (e.g. https://github.com/user/repo.git)").Trim()
    if ($repoUrl -eq '') {
        Write-Host "Repo URL cannot be empty."
    }
}

# REPO SUBDIR

$rawSubdir  = (Read-Host "Subdirectory in repo to sync into (leave blank for root)").Trim()
$repoSubdir = if ($rawSubdir -ne '') { $rawSubdir.Trim('/\').Replace('\', '/') } else { '' }

# RESOLVE PATHS

$claudeDir = Get-ClaudeDir
$repoDir   = Get-RepoDir
$syncDir   = if ($repoSubdir -ne '') { Join-Path $repoDir $repoSubdir.Replace('/', '\') } else { $repoDir }
$syncRoot  = Split-Path $repoDir -Parent

Write-Host ""
Write-Host "Claude dir : $claudeDir"
Write-Host "Repo cache : $repoDir"
if ($repoSubdir -ne '') {
    Write-Host "Sync subdir: $repoSubdir"
}
Write-Host "Config     : $(Get-SyncConfigPath)"
Write-Host ""

# ENSURE SYNC ROOT EXISTS

if (-not (Test-Path $syncRoot)) {
    New-Item -ItemType Directory -Path $syncRoot -Force | Out-Null
}

# HANDLE EXISTING REPO DIR

if (Test-Path $repoDir) {
    Write-Host "Repo dir already exists: $repoDir"
    if (Confirm-Prompt "Delete and re-clone?") {
        Remove-Item $repoDir -Recurse -Force
    } else {
        Write-Host "Aborted."
        exit 1
    }
}

# CLONE

Write-Host "Cloning $repoUrl ..."
& git clone $repoUrl $repoDir
if ($LASTEXITCODE -ne 0) {
    Write-Error "git clone failed."
    exit 1
}

# INITIAL COMMIT HASH (null if empty repo)

$initialCommit = $null
try {
    $initialCommit = (& git -C $repoDir rev-parse HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) { $initialCommit = $null }
} catch {
    $initialCommit = $null
}

# CREATE .gitattributes IF REPO IS EMPTY (normalise line endings)

if ($null -eq $initialCommit) {
    $gitattributes = Join-Path $repoDir '.gitattributes'
    '* text=auto' | Set-Content $gitattributes -Encoding UTF8
    Write-Host "Created .gitattributes in empty repo (line-ending normalisation)."
}

# ENSURE SYNC SUBDIR EXISTS IN REPO

if ($repoSubdir -ne '' -and -not (Test-Path $syncDir)) {
    New-Item -ItemType Directory -Path $syncDir -Force | Out-Null
    Write-Host "Created sync subdirectory: $repoSubdir"
}

# WRITE CONFIG

$config = [PSCustomObject]@{
    repoUrl        = $repoUrl
    repoSubdir     = $repoSubdir
    repoDir        = $repoDir
    claudeDir      = $claudeDir
    lastSyncCommit = $initialCommit
    lastSyncTime   = $null
    exclusions     = @(
        '*.log'
        '.credentials.json'
        'cache'
        '.tmp'
        'ide'
        'backups'
        'debug'
        'downloads'
        'file-history'
        'mcp-needs-auth-cache.json'
        'plans'
        'policy-limits.json'
        'projects'
        'sessions'
        'shell-snapshots'
        'statsig'
        'telemetry'
        'settings.local.json'
        'todos'
    )
}
Save-SyncConfig $config

Write-Host ""
Write-Host "Init complete."
if ($null -eq $initialCommit) {
    Write-Host "The repo is empty. Run claude-sync-push.ps1 to upload your local .claude."
} else {
    Write-Host "Run claude-sync-pull.ps1 to download repo contents to your local .claude."
    Write-Host "Run claude-sync-push.ps1 to upload your local .claude to the repo."
}
