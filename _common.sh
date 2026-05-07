#!/usr/bin/env bash
# _common.sh — Shared functions for claude-sync scripts.
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

# EXCLUSION MATCHING

is_excluded() {
    local rel_path="$1"
    shift
    # Remaining args are exclusion patterns.
    local pattern seg
    for pattern in "$@"; do
        if [[ "$pattern" == */* ]]; then
            # Pattern contains slash — match against full path.
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
    shift 2
    # Remaining args are exclusion patterns.

    [[ -d "$claude_dir" ]] || return 0

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$claude_dir/"}"
        is_excluded "$rel_path" "$@" && continue
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
    shift 2

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$repo_dir/"}"
        [[ "$rel_path" == .git || "$rel_path" == .git/* ]] && continue
        is_excluded "$rel_path" "$@" && continue
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
    shift 2

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$repo_dir/"}"
        [[ "$rel_path" == .git || "$rel_path" == .git/* ]] && continue
        is_excluded "$rel_path" "$@" && continue
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
    shift 2

    while IFS= read -r -d '' full_path; do
        local rel_path="${full_path#"$claude_dir/"}"
        is_excluded "$rel_path" "$@" && continue
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
    shift 4
    # Remaining args are exclusion patterns.

    local subdir_prefix=""
    if [[ "$sync_dir" != "$repo_dir" ]]; then
        subdir_prefix="${sync_dir#"$repo_dir/"}"
        subdir_prefix="${subdir_prefix%/}/"
    fi

    # Inner subshell so the EXIT trap is always scoped here, even if called directly.
    (
        trap 'git -C "$repo_dir" checkout -- . 2>/dev/null || true' EXIT

        copy_claude_to_repo "$claude_dir" "$sync_dir" "$@" > /dev/null

        local -a changed=()
        local line

        local diff_out
        diff_out=$(git -C "$repo_dir" diff --name-only "$commit_hash" 2>/dev/null) || true
        while IFS= read -r line; do
            [[ -n "$line" ]] && changed+=("$line")
        done <<< "$diff_out"

        local untracked_out
        untracked_out=$(git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null) || true
        while IFS= read -r line; do
            [[ -n "$line" ]] && changed+=("$line")
        done <<< "$untracked_out"

        # Also detect files deleted locally (present at commit but missing in .claude).
        local at_commit_out
        at_commit_out=$(git -C "$repo_dir" ls-tree -r --name-only "$commit_hash" 2>/dev/null) || true
        local repo_rel claude_rel
        while IFS= read -r repo_rel; do
            [[ -z "$repo_rel" ]] && continue
            is_excluded "$repo_rel" "$@" && continue

            claude_rel="$repo_rel"
            if [[ -n "$subdir_prefix" && "$repo_rel" == "$subdir_prefix"* ]]; then
                claude_rel="${repo_rel#"$subdir_prefix"}"
            fi

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

# Prints file paths changed on the remote since commit_hash, one per line.
get_remote_changed_files() {
    local repo_dir="$1"
    local commit_hash="${2:-}"

    [[ -z "$commit_hash" ]] && return 0

    local remote_head
    remote_head=$(git -C "$repo_dir" rev-parse FETCH_HEAD 2>/dev/null) || return 0
    remote_head="${remote_head// /}"
    [[ "$remote_head" == "$commit_hash" ]] && return 0

    git -C "$repo_dir" diff --name-only "$commit_hash" "$remote_head" 2>/dev/null || true
}

# Sets globals (all prefixed _CS_):
#   _CS_HAS_CONFLICT   — "true" or "false"
#   _CS_LOCAL_CHANGED  — array of locally changed file paths
#   _CS_REMOTE_CHANGED — array of remotely changed file paths
#   _CS_CONFLICT_FILES — array of files changed in both
test_conflict_exists() {
    local claude_dir="$1"
    local repo_dir="$2"
    local sync_dir="$3"
    local commit_hash="$4"
    shift 4

    _CS_LOCAL_CHANGED=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && _CS_LOCAL_CHANGED+=("$line")
    done < <(get_local_changed_files "$claude_dir" "$repo_dir" "$sync_dir" "$commit_hash" "$@")

    _CS_REMOTE_CHANGED=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && _CS_REMOTE_CHANGED+=("$line")
    done < <(get_remote_changed_files "$repo_dir" "$commit_hash")

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
            # Unknown or no /etc/os-release — show all three.
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

# Prints "local" or "remote" to stdout. All prompts go to /dev/tty.
select_conflict_winner() {
    printf '\n' >/dev/tty
    printf 'CONFLICT: The following files changed both locally and remotely:\n' >/dev/tty
    local f
    for f in "$@"; do
        printf '  %s\n' "$f" >/dev/tty
    done
    printf '\n' >/dev/tty
    while true; do
        local response
        read -r -p "Which version wins? [L]ocal / [R]emote " response </dev/tty
        if [[ "$response" =~ ^[Ll] ]]; then
            echo "local"
            return 0
        fi
        if [[ "$response" =~ ^[Rr] ]]; then
            echo "remote"
            return 0
        fi
        printf 'Please enter L or R.\n' >/dev/tty
    done
}
