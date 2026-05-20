#!/usr/bin/env bash
# claude-sync-status.sh — Show what differs between local ~/.claude and the remote repo.
# Read-only: makes no changes to files or config.
#
# USAGE:
#   bash claude-sync-status.sh [--verbose|-v]
#
# OPTIONS:
#   --verbose, -v  List each changed file instead of just the count.

set -euo pipefail
source "$(dirname "$0")/_common.sh"

# PARSE ARGS

verbose=false
for arg in "$@"; do
    [[ "$arg" == --verbose || "$arg" == -v ]] && verbose=true
done

# LOAD CONFIG

if ! config=$(load_sync_config 2>/dev/null); then
    echo "Not initialized. Run claude-sync-init.sh first."
    exit 0
fi

claude_dir=$(jq -r '.claudeDir'             <<< "$config")
repo_dir=$(jq -r   '.repoDir'              <<< "$config")
repo_subdir=$(jq -r '.repoSubdir // ""'     <<< "$config")
last_sync=$(jq -r   '.lastSyncCommit // ""' <<< "$config")
last_time=$(jq -r   '.lastSyncTime // ""'   <<< "$config")
repo_url=$(jq -r    '.repoUrl'             <<< "$config")

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

# FETCH REMOTE (best-effort — offline is fine, done before header so we can show machine name)

fetch_ok=false
if invoke_git "$repo_dir" fetch origin --quiet > /dev/null 2>&1; then
    fetch_ok=true
fi

# SUMMARY HEADER

pushed_by=""
if [[ "$fetch_ok" == true ]]; then
    remote_msg=$(git -C "$repo_dir" log -1 --format="%s" FETCH_HEAD 2>/dev/null || true)
    if [[ "$remote_msg" =~ [[:space:]]from[[:space:]]([^[:space:]]+)$ ]]; then
        pushed_by="${BASH_REMATCH[1]}"
    fi
fi

echo ""
echo "Repo       : $repo_url"
[[ -n "$repo_subdir" ]] && echo "Subdir     : $repo_subdir"
if [[ -n "$last_time" ]]; then
    echo "Last sync  : $last_time"
else
    echo "Last sync  : never"
fi
if [[ -n "$last_sync" ]]; then
    echo "Commit     : $last_sync"
else
    echo "Commit     : none"
fi
[[ -n "$pushed_by" ]] && echo "Pushed by  : $pushed_by"
echo ""

if [[ "$fetch_ok" == false ]]; then
    echo "[WARNING] Could not reach remote. Showing local status only."
    echo ""
fi

# REMOTE STATUS

remote_changed=()
if [[ "$fetch_ok" == true ]]; then
    if [[ -z "$last_sync" ]]; then
        echo "Remote : no baseline sync yet — cannot compare"
    else
        while IFS= read -r line; do
            [[ -n "$line" ]] && remote_changed+=("$line")
        done < <(get_remote_changed_files "$repo_dir" "$last_sync" 2>/dev/null || true)

        if [[ ${#remote_changed[@]} -eq 0 ]]; then
            echo "Remote : nothing to pull"
        else
            echo "Remote : ${#remote_changed[@]} file(s) changed -> run ./claude-sync-pull.sh"
            if [[ "$verbose" == true ]]; then
                for f in "${remote_changed[@]}"; do echo "  [remote] $f"; done
            fi
        fi
    fi
fi

# LOCAL STATUS

local_changed=()
if [[ -z "$last_sync" ]]; then
    echo "Local  : no baseline sync yet — cannot compare"
elif [[ ! -d "$claude_dir" ]]; then
    echo "Local  : .claude directory not found at $claude_dir"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && local_changed+=("$line")
    done < <(get_local_changed_files "$claude_dir" "$repo_dir" "$sync_dir" "$last_sync" "${exclusions[@]+"${exclusions[@]}"}" 2>/dev/null || true)

    if [[ ${#local_changed[@]} -eq 0 ]]; then
        echo "Local  : nothing to push"
    else
        echo "Local  : ${#local_changed[@]} file(s) changed -> run ./claude-sync-push.sh"
        if [[ "$verbose" == true ]]; then
            for f in "${local_changed[@]}"; do echo "  [local] $f"; done
        fi
    fi
fi

# CONFLICT SUMMARY

has_conflicts=false
if [[ ${#local_changed[@]} -gt 0 && ${#remote_changed[@]} -gt 0 ]]; then
    conflicts=()
    for lf in "${local_changed[@]}"; do
        for rf in "${remote_changed[@]}"; do
            [[ "$lf" == "$rf" ]] && { conflicts+=("$lf"); break; }
        done
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        has_conflicts=true
        echo ""
        echo "CONFLICTS (${#conflicts[@]} file(s) changed in both local and remote):"
        if [[ "$verbose" == true ]]; then
            for f in "${conflicts[@]}"; do echo "  [CONFLICT] $f"; done
        fi
    fi
fi

if [[ "$verbose" == false ]]; then
    echo "Tip: run with --verbose to list changed files."
fi
echo ""

# ACTION PROMPTS

script_dir="$(dirname "$0")"

if [[ "$has_conflicts" == true ]]; then
    echo "Both local and remote have changes. You must choose one direction."
    echo "  [1] Pull from remote (overwrites your local changes)"
    echo "  [2] Push to remote   (overwrites remote with your local changes)"
    echo "  [3] Do nothing (default)"
    read -r -p "Choice [3]: " choice
    case "${choice:-3}" in
        1) bash "$script_dir/claude-sync-pull.sh" ;;
        2) bash "$script_dir/claude-sync-push.sh" ;;
        *) echo "No action taken." ;;
    esac
elif [[ ${#remote_changed[@]} -gt 0 && ${#local_changed[@]} -gt 0 ]]; then
    echo "Remote and local both have changes (no file conflicts)."
    echo "  [1] Pull from remote first, then push local changes"
    echo "  [2] Pull only"
    echo "  [3] Push only"
    echo "  [4] Do nothing (default)"
    read -r -p "Choice [4]: " choice
    case "${choice:-4}" in
        1) bash "$script_dir/claude-sync-pull.sh" && bash "$script_dir/claude-sync-push.sh" ;;
        2) bash "$script_dir/claude-sync-pull.sh" ;;
        3) bash "$script_dir/claude-sync-push.sh" ;;
        *) echo "No action taken." ;;
    esac
elif [[ ${#remote_changed[@]} -gt 0 ]]; then
    read -r -p "Pull ${#remote_changed[@]} remote change(s) now? [y/N]: " answer
    [[ "${answer:-N}" =~ ^[Yy] ]] && bash "$script_dir/claude-sync-pull.sh"
elif [[ ${#local_changed[@]} -gt 0 ]]; then
    read -r -p "Push ${#local_changed[@]} local change(s) now? [y/N]: " answer
    [[ "${answer:-N}" =~ ^[Yy] ]] && bash "$script_dir/claude-sync-push.sh"
fi
