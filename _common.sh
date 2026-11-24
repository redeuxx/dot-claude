#!/usr/bin/env bash
# _common.sh - Shared functions for claude-sync scripts.
# Source this file at the top of each script:
#   source "$(dirname "$0")/_common.sh"

set -euo pipefail

# CONFIG

get_sync_config_path() {
    echo "$HOME/.claude-sync/config.json"
}

# Prints config JSON to stdout, returns 1 if not found.
load_sync_config() {
    local path
    path="$(get_sync_config_path)"
    [[ -f "$path" ]] || return 1
    cat "$path"
}

save_sync_config() {
    local config="$1"
    local path
    path="$(get_sync_config_path)"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$config" > "$path"
}

# PATH RESOLUTION

get_claude_dir() {
    echo "$HOME/.claude"
}

get_repo_dir() {
    echo "$HOME/.claude-sync/repo"
}

# SYNC FILTER
# A file syncs only if its .claude-relative path matches an include pattern and
# no exclusion. Include patterns are globs matched against the full relative
# path (`*` spans directories), e.g. 'CLAUDE.md', 'skills/*'.

DEFAULT_INCLUDES=(
    'CLAUDE.md'
    'skills/*'
    'statusline.ps1'
)

# Managed by Claude Code itself; never synced regardless of config.
BUILTIN_EXCLUSIONS=(
    'skills/synced/*'
    'skills/.trash/*'
)

# Sets globals _CS_INCLUDES and _CS_EXCLUSIONS from the config JSON in $1.
load_sync_filter() {
    local config="$1" line
    _CS_INCLUDES=()
    if jq -e 'has("includes") and .includes != null' <<< "$config" >/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && _CS_INCLUDES+=("$line")
        done < <(jq -r '.includes[]' <<< "$config")
    else
        _CS_INCLUDES=("${DEFAULT_INCLUDES[@]}")
    fi
    _CS_EXCLUSIONS=("${BUILTIN_EXCLUSIONS[@]}")
    while IFS= read -r line; do
        [[ -n "$line" ]] && _CS_EXCLUSIONS+=("$line")
    done < <(jq -r '.exclusions // [] | .[]' <<< "$config")
}

is_included() {
    local rel_path="$1" pattern
    for pattern in "${_CS_INCLUDES[@]+"${_CS_INCLUDES[@]}"}"; do
        # shellcheck disable=SC2254
        case "$rel_path" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Returns 0 if the .claude-relative path should be synced.
is_synced() {
    local rel_path="$1"
    # Never touch git metadata, even if an include pattern would match it.
    [[ "$rel_path" == .git || "$rel_path" == .git/* ]] && return 1
    is_included "$rel_path" || return 1
    ! is_excluded "$rel_path" "${_CS_EXCLUSIONS[@]+"${_CS_EXCLUSIONS[@]}"}"
}

# Prints the repo-relative path prefix of sync_dir ("" when syncing the repo root).
get_subdir_prefix() {
    local repo_dir="$1" sync_dir="$2" prefix
    [[ "$sync_dir" == "$repo_dir" ]] && return 0
    prefix="${sync_dir#"$repo_dir/"}"
    printf '%s/' "${prefix%/}"
}

# Prints the .claude-relative path for a repo-relative path; returns 1 if the
# path lies outside the sync subdirectory.
to_claude_rel() {
    local repo_rel="$1" prefix="$2"
    if [[ -z "$prefix" ]]; then
        printf '%s' "$repo_rel"
    elif [[ "$repo_rel" == "$prefix"* ]]; then
        printf '%s' "${repo_rel#"$prefix"}"
    else
        return 1
    fi
}

# Reads repo-relative paths on stdin, prints those whose .claude-relative path is synced.
filter_synced_repo_paths() {
    local prefix="$1" line claude_rel
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        claude_rel=$(to_claude_rel "$line" "$prefix") || continue
        is_synced "$claude_rel" && printf '%s\n' "$line"
    done
    return 0
}

is_excluded() {
    local rel_path="$1"
    shift
    # Remaining args are exclusion patterns.
    local pattern seg
    for pattern in "$@"; do
        if [[ "$pattern" == */* ]]; then
            # Pattern contains slash - match against full path.
            # shellcheck disable=SC2254
            case "$rel_path" in
                $pattern) return 0 ;;
            esac
        else
            # Match against each path segment individually.
            local -a segs
            IFS='/' read -ra segs <<< "$rel_path"
            for seg in "${segs[@]+"${segs[@]}"}"; do
                # shellcheck disable=SC2254
                case "$seg" in
                    $pattern) return 0 ;;
                esac
            done
        fi
    done
    return 1
}

# FILE SYNC

# Copies files from claude_dir to repo_dir, printing each relative path to stdout.
copy_claude_to_repo() {
    local claude_dir="$1"
    local repo_dir="$2"

    [[ -d "$claude_dir" ]] || return 0

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$claude_dir/"}"
        is_synced "$rel_path" || continue
        local dest="$repo_dir/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp -f "$full_path" "$dest"
        echo "$rel_path"
    done < <(find "$claude_dir" -type f -print0)
}

# Copies files from repo_dir to claude_dir, printing each relative path to stdout.
copy_repo_to_claude() {
    local repo_dir="$1"
    local claude_dir="$2"

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$repo_dir/"}"
        is_synced "$rel_path" || continue
        local dest="$claude_dir/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp -f "$full_path" "$dest"
        echo "$rel_path"
    done < <(find "$repo_dir" -type f -print0)
}

# Removes files in repo_dir that no longer exist in claude_dir, printing each path.
remove_stale_repo_files() {
    local repo_dir="$1"
    local claude_dir="$2"

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$repo_dir/"}"
        is_synced "$rel_path" || continue
        if [[ ! -f "$claude_dir/$rel_path" ]]; then
            rm -f "$full_path"
            echo "$rel_path"
        fi
    done < <(find "$repo_dir" -type f -print0)
}

# Removes files in claude_dir that no longer exist in sync_dir, printing each path.
remove_stale_claude_files() {
    local claude_dir="$1"
    local sync_dir="$2"

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$claude_dir/"}"
        is_synced "$rel_path" || continue
        if [[ ! -f "$sync_dir/$rel_path" ]]; then
            rm -f "$full_path"
            echo "$rel_path"
        fi
    done < <(find "$claude_dir" -type f -print0)
}

# CONFLICT DETECTION

# Prints changed file paths to stdout, one per line.
# Temporarily copies .claude into the repo working tree to let git detect changes,
# then always restores the working tree before returning.
get_local_changed_files() {
    local claude_dir="$1"
    local repo_dir="$2"
    local sync_dir="$3"
    local commit_hash="$4"

    local subdir_prefix
    subdir_prefix=$(get_subdir_prefix "$repo_dir" "$sync_dir")

    # Inner subshell so the EXIT trap is always scoped here, even if called directly.
    (
        # Restore the working tree, including removing untracked copies, so a
        # later push's `git add -A` cannot pick them up.
        trap 'git -C "$repo_dir" checkout -- . 2>/dev/null || true; git -C "$repo_dir" clean -fdq -e /.gitattributes -- "$sync_dir" 2>/dev/null || true' EXIT

        copy_claude_to_repo "$claude_dir" "$sync_dir" > /dev/null

        local -a changed=()
        local line

        local diff_out
        diff_out=$(git -C "$repo_dir" diff --name-only "$commit_hash" 2>/dev/null) || true
        local untracked_out
        untracked_out=$(git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null) || true
        while IFS= read -r line; do
            changed+=("$line")
        done < <(printf '%s\n%s\n' "$diff_out" "$untracked_out" | filter_synced_repo_paths "$subdir_prefix")

        # Also detect files deleted locally (present at commit but missing in .claude).
        local at_commit_out
        at_commit_out=$(git -C "$repo_dir" ls-tree -r --name-only "$commit_hash" 2>/dev/null) || true
        local repo_rel claude_rel
        while IFS= read -r repo_rel; do
            [[ -z "$repo_rel" ]] && continue
            claude_rel=$(to_claude_rel "$repo_rel" "$subdir_prefix") || continue
            is_synced "$claude_rel" || continue

            if [[ ! -f "$claude_dir/$claude_rel" ]]; then
                local found=0 c
                for c in "${changed[@]+"${changed[@]}"}"; do
                    [[ "$c" == "$repo_rel" ]] && { found=1; break; }
                done
                [[ $found -eq 0 ]] && changed+=("$repo_rel")
            fi
        done <<< "$at_commit_out"

        printf '%s\n' "${changed[@]+"${changed[@]}"}"
    )
}

# Prints synced file paths changed on the remote since commit_hash, one per line.
get_remote_changed_files() {
    local repo_dir="$1"
    local sync_dir="$2"
    local commit_hash="${3:-}"

    [[ -z "$commit_hash" ]] && return 0

    local remote_head
    remote_head=$(git -C "$repo_dir" rev-parse FETCH_HEAD 2>/dev/null) || return 0
    remote_head="${remote_head// /}"
    [[ "$remote_head" == "$commit_hash" ]] && return 0

    local diff_out
    diff_out=$(git -C "$repo_dir" diff --name-only "$commit_hash" "$remote_head" 2>/dev/null) || true
    printf '%s\n' "$diff_out" | filter_synced_repo_paths "$(get_subdir_prefix "$repo_dir" "$sync_dir")"
}

# Sets globals (all prefixed _CS_):
#   _CS_HAS_CONFLICT   - "true" or "false"
#   _CS_LOCAL_CHANGED  - array of locally changed file paths
#   _CS_REMOTE_CHANGED - array of remotely changed file paths
#   _CS_CONFLICT_FILES - array of files changed in both
test_conflict_exists() {
    local claude_dir="$1"
    local repo_dir="$2"
    local sync_dir="$3"
    local commit_hash="$4"

    _CS_LOCAL_CHANGED=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && _CS_LOCAL_CHANGED+=("$line")
    done < <(get_local_changed_files "$claude_dir" "$repo_dir" "$sync_dir" "$commit_hash")

    _CS_REMOTE_CHANGED=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && _CS_REMOTE_CHANGED+=("$line")
    done < <(get_remote_changed_files "$repo_dir" "$sync_dir" "$commit_hash")

    _CS_CONFLICT_FILES=()
    _CS_HAS_CONFLICT=false
    local lf rf
    for lf in "${_CS_LOCAL_CHANGED[@]+"${_CS_LOCAL_CHANGED[@]}"}"; do
        for rf in "${_CS_REMOTE_CHANGED[@]+"${_CS_REMOTE_CHANGED[@]}"}"; do
            if [[ "$lf" == "$rf" ]]; then
                _CS_CONFLICT_FILES+=("$lf")
                _CS_HAS_CONFLICT=true
                break
            fi
        done
    done
}

# GIT HELPERS

invoke_git() {
    local repo_dir="$1"
    shift
    local output
    if ! output=$(git -C "$repo_dir" "$@" 2>&1); then
        printf 'git %s failed:\n%s\n' "$*" "$output" >&2
        return 1
    fi
    echo "$output"
}

get_repo_current_commit() {
    local repo_dir="$1"
    invoke_git "$repo_dir" rev-parse HEAD
}

get_remote_head_commit() {
    local repo_dir="$1"
    invoke_git "$repo_dir" rev-parse FETCH_HEAD
}

# PREREQUISITE CHECKS

_install_hint() {
    local tool="$1"
    local os
    os="$(uname -s)"

    case "$tool" in
        git)
            echo "  Install git:" >&2
            if [[ "$os" == Darwin ]]; then
                echo "    macOS (Homebrew) : brew install git" >&2
                echo "    macOS (Xcode)    : xcode-select --install" >&2
            else
                _linux_pkg_hint "git" "git" "git"
            fi
            echo "    Download         : https://git-scm.com/downloads" >&2
            ;;
        gh)
            echo "  Install GitHub CLI (gh):" >&2
            if [[ "$os" == Darwin ]]; then
                echo "    macOS (Homebrew) : brew install gh" >&2
            else
                _linux_pkg_hint "gh" "gh" "github-cli"
                echo "    Linux (manual)   : https://github.com/cli/cli/blob/trunk/docs/install_linux.md" >&2
            fi
            echo "    Download         : https://cli.github.com/" >&2
            ;;
        jq)
            echo "  Install jq:" >&2
            if [[ "$os" == Darwin ]]; then
                echo "    macOS (Homebrew) : brew install jq" >&2
            else
                _linux_pkg_hint "jq" "jq" "jq"
            fi
            echo "    Download         : https://jqlang.github.io/jq/download/" >&2
            ;;
    esac
}

# Prints distro-appropriate package manager commands for a package.
# Args: apt_pkg dnf_pkg pacman_pkg
_linux_pkg_hint() {
    local apt_pkg="$1" dnf_pkg="$2" pacman_pkg="$3"
    # Detect distro from /etc/os-release if available.
    local distro_id=""
    if [[ -f /etc/os-release ]]; then
        distro_id=$(. /etc/os-release && echo "${ID_LIKE:-$ID}" | tr '[:upper:]' '[:lower:]')
    fi
    case "$distro_id" in
        *debian*|*ubuntu*)
            echo "    Debian/Ubuntu    : sudo apt install $apt_pkg" >&2 ;;
        *fedora*|*rhel*|*centos*)
            echo "    Fedora/RHEL      : sudo dnf install $dnf_pkg" >&2 ;;
        *arch*)
            echo "    Arch             : sudo pacman -S $pacman_pkg" >&2 ;;
        *)
            # Unknown or no /etc/os-release - show all three.
            echo "    Debian/Ubuntu    : sudo apt install $apt_pkg" >&2
            echo "    Fedora/RHEL      : sudo dnf install $dnf_pkg" >&2
            echo "    Arch             : sudo pacman -S $pacman_pkg" >&2
            ;;
    esac
}

assert_git_available() {
    if ! command -v git &>/dev/null; then
        echo "Error: git is not installed or not on PATH." >&2
        echo "" >&2
        _install_hint git
        exit 1
    fi
}

assert_gh_available() {
    if ! command -v gh &>/dev/null; then
        echo "Error: GitHub CLI (gh) is not installed or not on PATH." >&2
        echo "" >&2
        _install_hint gh
        exit 1
    fi
}

assert_gh_authenticated() {
    if ! gh auth status &>/dev/null 2>&1; then
        echo "Error: GitHub CLI is not authenticated. Run: gh auth login" >&2
        exit 1
    fi
}

assert_jq_available() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is not installed or not on PATH." >&2
        echo "" >&2
        _install_hint jq
        exit 1
    fi
}

# USER PROMPTS

# Returns 0 (true) or 1 (false). Always reads from /dev/tty.
confirm_prompt() {
    local message="$1"
    local default="${2:-false}"
    local hint response
    [[ "$default" == true ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$message $hint " response </dev/tty
    if [[ -z "$response" ]]; then
        [[ "$default" == true ]] && return 0 || return 1
    fi
    [[ "$response" =~ ^[Yy] ]]
}

# Prints the remote (-) vs local (+) diff of one repo-relative file to /dev/tty.
# The local copy is placed in the repo working tree so .gitattributes
# normalization applies, then the working tree is restored.
show_conflict_diff() {
    local claude_dir="$1" repo_dir="$2" sync_dir="$3" repo_rel="$4" claude_rel
    claude_rel=$(to_claude_rel "$repo_rel" "$(get_subdir_prefix "$repo_dir" "$sync_dir")") || return 0
    (
        trap 'git -C "$repo_dir" reset -q -- "$repo_rel" 2>/dev/null || true; git -C "$repo_dir" checkout -- "$repo_rel" 2>/dev/null || true; git -C "$repo_dir" clean -fq -- "$repo_rel" 2>/dev/null || true' EXIT
        if [[ -f "$claude_dir/$claude_rel" ]]; then
            mkdir -p "$(dirname "$repo_dir/$repo_rel")"
            cp "$claude_dir/$claude_rel" "$repo_dir/$repo_rel"
            # Intent-to-add so a file that is new on both sides still shows in the diff
            git -C "$repo_dir" -c core.safecrlf=false add -N -- "$repo_rel" 2>/dev/null || true
        else
            rm -f "$repo_dir/$repo_rel"
        fi
        printf '\nDiff of %s (- remote, + local):\n' "$repo_rel"
        git -C "$repo_dir" -c core.safecrlf=false diff --color=always FETCH_HEAD -- "$repo_rel" || true
    ) >/dev/tty
}

# Args: claude_dir repo_dir sync_dir conflict_file...
# Prints "local" or "remote" to stdout. All prompts go to /dev/tty.
select_conflict_winner() {
    local claude_dir="$1" repo_dir="$2" sync_dir="$3"
    shift 3
    printf '\n' >/dev/tty
    printf 'CONFLICT: The following files changed both locally and remotely:\n' >/dev/tty
    local i=1 f
    for f in "$@"; do
        printf '  [%d] %s\n' "$i" "$f" >/dev/tty
        i=$((i + 1))
    done
    printf '\n' >/dev/tty
    while true; do
        local response pick
        read -r -p "Which version wins? [L]ocal / [R]emote / [D]iff " response </dev/tty
        if [[ "$response" =~ ^[Ll] ]]; then
            echo "local"
            return 0
        fi
        if [[ "$response" =~ ^[Rr] ]]; then
            echo "remote"
            return 0
        fi
        if [[ "$response" =~ ^[Dd] ]]; then
            pick=1
            if [[ $# -gt 1 ]]; then
                read -r -p "Diff which file? [1-$#] " pick </dev/tty
            fi
            # No leading zero (bash would read it as octal), at most 4 digits (no overflow)
            if [[ "$pick" =~ ^[1-9][0-9]{0,3}$ ]] && (( pick <= $# )); then
                show_conflict_diff "$claude_dir" "$repo_dir" "$sync_dir" "${!pick}"
            else
                printf 'Please enter a number from 1 to %d.\n' "$#" >/dev/tty
            fi
            printf '\n' >/dev/tty
            continue
        fi
        printf 'Please enter L, R or D.\n' >/dev/tty
    done
}

# SCRIPT UPDATE CHECK

# Tells the user (on stderr) when the scripts' own git checkout is behind its
# upstream. Notify only, never auto-update. Silent when git is missing, the
# scripts are not a git checkout, there is no upstream, or the fetch fails or
# takes over 5 seconds (offline, dropped packets), so it can never block a sync.
show_script_update_notice() {
    local script_dir="$1" ssh_cmd pid i counts ahead behind
    command -v git &>/dev/null || return 0
    # Only check a checkout that actually tracks these scripts
    git -C "$script_dir" ls-files --error-unmatch _common.sh &>/dev/null || return 0
    # Never prompt for credentials, passphrases or host keys just for an update check
    ssh_cmd="${GIT_SSH_COMMAND:-}"
    if [[ -z "$ssh_cmd" ]] && ! git -C "$script_dir" config core.sshCommand &>/dev/null; then
        ssh_cmd='ssh -o BatchMode=yes -o ConnectTimeout=5'
    fi
    (
        export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
        if [[ -n "$ssh_cmd" ]]; then export GIT_SSH_COMMAND="$ssh_cmd"; fi
        exec git -C "$script_dir" fetch --quiet
    ) </dev/null &>/dev/null &
    pid=$!
    # Hard 5 second cap, since git has no connect timeout of its own (and
    # macOS has no timeout(1)).
    # ponytail: kills git only; a stuck child helper exits on its own timeout
    for ((i = 0; i < 50; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    wait "$pid" 2>/dev/null || return 0
    counts=$(git -C "$script_dir" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null) || return 0
    read -r ahead behind <<< "$counts" || return 0
    [[ "$ahead" =~ ^[0-9]+$ && "$behind" =~ ^[0-9]+$ ]] || return 0
    (( behind > 0 )) || return 0
    if (( ahead > 0 )); then
        printf 'Script updates available: %s new commit(s) upstream, but your checkout also has %s local commit(s).\n  Merge or rebase in "%s" to update.\n\n' \
            "$behind" "$ahead" "$script_dir" >&2
    else
        printf 'Script updates available: %s new commit(s) upstream. To update, run:\n  git -C "%s" pull --ff-only\n\n' \
            "$behind" "$script_dir" >&2
    fi
    return 0
}
