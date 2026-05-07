#!/usr/bin/env bash
# claude-sync-push.sh — Copy local ~/.claude to repo, commit, and push to GitHub.
#
# USAGE:
#   bash claude-sync-push.sh

set -euo pipefail
source "$(dirname "$0")/_common.sh"

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

# CHECK .CLAUDE EXISTS

if [[ ! -d "$claude_dir" ]]; then
    echo "Error: .claude directory not found at $claude_dir" >&2
    exit 1
fi

# CHECK IF REMOTE IS AHEAD

echo "Fetching remote status..."
remote_head=""
if invoke_git "$repo_dir" fetch origin > /dev/null 2>&1; then
    if remote_head=$(get_remote_head_commit "$repo_dir" 2>/dev/null); then
        remote_head="${remote_head// /}"
        if [[ -n "$last_sync" && "$remote_head" != "$last_sync" ]]; then
            echo ""
            echo "WARNING: Remote has new commits since your last sync."
            echo "Run claude-sync-pull.sh first to avoid overwriting remote changes."
            echo ""
            if ! confirm_prompt "Push anyway?"; then
                echo "Aborted."
                exit 0
            fi
        fi
    fi
else
    echo "Could not reach remote. Proceeding with local commit only (no push)."
    remote_head=""
fi

# STAGE FILES

echo "Copying $claude_dir to repo..."
copied=()
while IFS= read -r line; do
    [[ -n "$line" ]] && copied+=("$line")
done < <(copy_claude_to_repo "$claude_dir" "$sync_dir" "${exclusions[@]+"${exclusions[@]}"}")

deleted=()
while IFS= read -r line; do
    [[ -n "$line" ]] && deleted+=("$line")
done < <(remove_stale_repo_files "$sync_dir" "$claude_dir" "${exclusions[@]+"${exclusions[@]}"}")

if [[ ${#copied[@]} -gt 0 || ${#deleted[@]} -gt 0 ]]; then
    echo "  Staged   : ${#copied[@]} file(s)"
    echo "  Removed  : ${#deleted[@]} stale file(s)"
fi

# CHECK FOR ACTUAL GIT CHANGES

status=$(invoke_git "$repo_dir" status --porcelain)
if [[ -z "$status" ]]; then
    echo "Nothing to commit — local .claude already matches the repo."
    exit 0
fi

# COMMIT

invoke_git "$repo_dir" add -A > /dev/null
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
invoke_git "$repo_dir" commit -m "sync: $timestamp from $(hostname)" > /dev/null
echo "Committed."

# PUSH

echo "Pushing to remote..."
if ! invoke_git "$repo_dir" push origin > /dev/null 2>&1; then
    # First push to an empty repo needs --set-upstream.
    branch=$(invoke_git "$repo_dir" branch --show-current)
    branch="${branch// /}"
    [[ -z "$branch" ]] && branch="main"
    if ! invoke_git "$repo_dir" push --set-upstream origin "$branch" > /dev/null; then
        echo "Error: Push failed." >&2
        exit 1
    fi
fi

# UPDATE CONFIG

new_commit=$(get_repo_current_commit "$repo_dir")
now=$(date '+%Y-%m-%dT%H:%M:%S%z')
config=$(jq --arg commit "$new_commit" --arg time "$now" \
    '.lastSyncCommit = $commit | .lastSyncTime = $time' <<< "$config")
save_sync_config "$config"

echo "Push complete."
