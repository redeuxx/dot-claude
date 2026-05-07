#!/usr/bin/env bash
# claude-sync-init.sh — First-run setup: prompt for repo URL, clone, write config.
#
# USAGE:
#   bash claude-sync-init.sh

set -euo pipefail
source "$(dirname "$0")/_common.sh"

# CHECKS

assert_jq_available
assert_git_available

if ! command -v gh &>/dev/null; then
    echo "GitHub CLI (gh) is required but was not found on this machine."
    echo ""
    echo "Download it from: https://cli.github.com/"
    echo ""
    echo "After installing, run: gh auth login"
    exit 1
fi

assert_gh_authenticated

# RE-INIT WARNING

if load_sync_config > /dev/null 2>&1; then
    echo "Config already exists at $(get_sync_config_path)."
    echo "Re-running init will re-clone the repo and overwrite the current config."
    if ! confirm_prompt "Continue?"; then
        echo "Aborted."
        exit 0
    fi
fi

# REPO URL

repo_url=""
while [[ -z "$repo_url" ]]; do
    read -r -p "Enter the GitHub repo URL (e.g. https://github.com/user/repo.git): " repo_url </dev/tty
    repo_url="${repo_url## }"
    repo_url="${repo_url%% }"
    if [[ -z "$repo_url" ]]; then
        echo "Repo URL cannot be empty."
    fi
done

# REPO SUBDIR

read -r -p "Subdirectory in repo to sync into (leave blank for root): " raw_subdir </dev/tty
repo_subdir="${raw_subdir## }"
repo_subdir="${repo_subdir%% }"
repo_subdir="${repo_subdir#/}"
repo_subdir="${repo_subdir%/}"

# RESOLVE PATHS

claude_dir="$(get_claude_dir)"
repo_dir="$(get_repo_dir)"
if [[ -n "$repo_subdir" ]]; then
    sync_dir="$repo_dir/$repo_subdir"
else
    sync_dir="$repo_dir"
fi
sync_root="$(dirname "$repo_dir")"

echo ""
echo "Claude dir : $claude_dir"
echo "Repo cache : $repo_dir"
[[ -n "$repo_subdir" ]] && echo "Sync subdir: $repo_subdir"
echo "Config     : $(get_sync_config_path)"
echo ""

# ENSURE SYNC ROOT EXISTS

mkdir -p "$sync_root"

# HANDLE EXISTING REPO DIR

if [[ -d "$repo_dir" ]]; then
    echo "Repo dir already exists: $repo_dir"
    if confirm_prompt "Delete and re-clone?"; then
        rm -rf "$repo_dir"
    else
        echo "Aborted."
        exit 1
    fi
fi

# CLONE

echo "Cloning $repo_url ..."
if ! git clone "$repo_url" "$repo_dir"; then
    echo "Error: git clone failed." >&2
    exit 1
fi

# INITIAL COMMIT HASH
# Always null — init clones but does not copy files to .claude, so there is
# no sync baseline yet. Pull will detect null and do a real first-time sync.

initial_commit="null"

# CREATE .gitattributes IF REPO IS EMPTY (normalise line endings)

if [[ "$initial_commit" == "null" ]]; then
    printf '* text=auto\n' > "$repo_dir/.gitattributes"
    echo "Created .gitattributes in empty repo (line-ending normalisation)."
fi

# ENSURE SYNC SUBDIR EXISTS IN REPO

if [[ -n "$repo_subdir" && ! -d "$sync_dir" ]]; then
    mkdir -p "$sync_dir"
    echo "Created sync subdirectory: $repo_subdir"
fi

# WRITE CONFIG

config=$(jq -n \
    --arg repoUrl    "$repo_url" \
    --arg repoSubdir "$repo_subdir" \
    --arg repoDir    "$repo_dir" \
    --arg claudeDir  "$claude_dir" \
    '{
        repoUrl:        $repoUrl,
        repoSubdir:     $repoSubdir,
        repoDir:        $repoDir,
        claudeDir:      $claudeDir,
        lastSyncCommit: null,
        lastSyncTime:   null,
        exclusions: [
            "*.log",
            ".credentials.json",
            "cache",
            ".tmp",
            "ide",
            "backups",
            "debug",
            "downloads",
            "file-history",
            "mcp-needs-auth-cache.json",
            "plans",
            "policy-limits.json",
            "projects",
            "sessions",
            "shell-snapshots",
            "statsig",
            "telemetry",
            "settings.local.json",
            "todos",
            "plugins"
        ]
    }')

save_sync_config "$config"

echo ""
echo "Init complete."
if [[ "$initial_commit" == "null" ]]; then
    echo "The repo is empty. Run claude-sync-push.sh to upload your local .claude."
else
    echo "Run claude-sync-pull.sh to download repo contents to your local .claude."
    echo "Run claude-sync-push.sh to upload your local .claude to the repo."
fi
