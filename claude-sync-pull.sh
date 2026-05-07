#!/usr/bin/env bash
# claude-sync-pull.sh — Fetch remote repo and sync contents into local ~/.claude.
#
# USAGE:
#   bash claude-sync-pull.sh [--force]
#
# OPTIONS:
#   --force   Re-copy all files even if the remote commit matches the last sync.

set -euo pipefail
source "$(dirname "$0")/_common.sh"

# PARSE ARGS

force=false
for arg in "$@"; do
    [[ "$arg" == --force || "$arg" == -f ]] && force=true
done

# LOAD CONFIG

if ! config=$(load_sync_config 2>/dev/null); then
    echo "Error: Not initialized. Run claude-sync-init.sh first." >&2
    exit 1
fi

claude_dir=$(jq -r '.claudeDir'             <<< "$config")
repo_dir=$(jq -r   '.repoDir'              <<< "$config")
repo_subdir=$(jq -r '.repoSubdir // ""'     <<< "$config")
last_sync=$(jq -r   '.lastSyncCommit // ""' <<< "$config")

if [[ -n "$repo_subdir" ]]; then
    sync_dir="$repo_dir/$repo_subdir"
else
    sync_dir="$repo_dir"
fi

exclusions=()
while IFS= read -r line; do
    [[ -n "$line" ]] && exclusions+=("$line")
done < <(jq -r '.exclusions[]' <<< "$config")

assert_git_available
assert_jq_available

# FETCH

echo "Fetching from remote..."
invoke_git "$repo_dir" fetch origin > /dev/null

# CHECK IF REMOTE HAS ANYTHING NEW

if ! remote_head=$(get_remote_head_commit "$repo_dir" 2>/dev/null); then
    echo "Error: Could not determine remote HEAD. The repo may be empty or unreachable." >&2
    exit 1
fi
remote_head="${remote_head// /}"

if [[ "$remote_head" == "$last_sync" && "$force" == false ]]; then
    echo "Already up to date."
    exit 0
fi

# CONFLICT DETECTION

winner="remote"

if [[ -n "$last_sync" && -d "$claude_dir" ]]; then
    echo "Checking for conflicts..."
    test_conflict_exists "$claude_dir" "$repo_dir" "$sync_dir" "$last_sync" "${exclusions[@]+"${exclusions[@]}"}"

    if [[ "$_CS_HAS_CONFLICT" == true ]]; then
        winner=$(select_conflict_winner "${_CS_CONFLICT_FILES[@]+"${_CS_CONFLICT_FILES[@]}"}")
        if [[ "$winner" == local ]]; then
            echo ""
            echo "Keeping local changes. Run claude-sync-push.sh to upload them."
            exit 0
        fi
        echo "Remote wins. Proceeding with pull..."
    elif [[ ${#_CS_LOCAL_CHANGED[@]} -gt 0 ]]; then
        echo ""
        echo "You have local changes that have not been pushed:"
        local f
        for f in "${_CS_LOCAL_CHANGED[@]}"; do
            echo "  $f"
        done
        echo ""
        if ! confirm_prompt "Pull anyway? (local changes will be overwritten)"; then
            echo "Aborted. Run claude-sync-push.sh to upload your local changes first."
            exit 0
        fi
    fi
fi

# OVERWRITE PROTECTION (first sync or user hasn't been asked yet)

if [[ -d "$claude_dir" ]]; then
    if [[ -z "$last_sync" ]]; then
        echo ""
        echo "WARNING: $claude_dir already exists and no previous sync baseline was found."
        if ! confirm_prompt "Overwrite files in $claude_dir with repo contents?"; then
            echo "Aborted."
            exit 0
        fi
    fi
else
    mkdir -p "$claude_dir"
fi

# MERGE REPO TO REMOTE HEAD

if ! invoke_git "$repo_dir" merge --ff-only FETCH_HEAD > /dev/null 2>&1; then
    # Fast-forward failed (diverged history) — reset hard since user chose remote.
    echo "Fast-forward merge not possible; resetting to remote HEAD..."
    invoke_git "$repo_dir" reset --hard FETCH_HEAD > /dev/null
fi

# COPY REPO -> .CLAUDE

copied=()
while IFS= read -r line; do
    [[ -n "$line" ]] && copied+=("$line")
done < <(copy_repo_to_claude "$sync_dir" "$claude_dir" "${exclusions[@]+"${exclusions[@]}"}")

deleted=()
while IFS= read -r line; do
    [[ -n "$line" ]] && deleted+=("$line")
done < <(remove_stale_claude_files "$claude_dir" "$sync_dir" "${exclusions[@]+"${exclusions[@]}"}")

echo "Pulled   : ${#copied[@]} file(s) to $claude_dir."
if [[ ${#deleted[@]} -gt 0 ]]; then
    echo "Removed  : ${#deleted[@]} stale file(s) from $claude_dir."
fi

# UPDATE CONFIG

now=$(date '+%Y-%m-%dT%H:%M:%S%z')
config=$(jq --arg commit "$remote_head" --arg time "$now" \
    '.lastSyncCommit = $commit | .lastSyncTime = $time' <<< "$config")
save_sync_config "$config"

echo "Pull complete."
