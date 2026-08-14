#!/usr/bin/env bash
set -euo pipefail

lock_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${lock_dir}/common.sh"

arena_lock_is_held() {
    local lock_path="$1"
    [[ -d "$lock_path" ]] || return 1
    [[ -f "${lock_path}/owner" ]] || return 1
    return 0
}

arena_lock_owner_token() {
    awk -F= '$1 == "token" { print $2 }' "$1/owner"
}

arena_lock_owner_pid() {
    awk -F= '$1 == "pid" { print $2 }' "$1/owner"
}

arena_lock_owner_alive() {
    local pid
    pid="$(arena_lock_owner_pid "$1")" || return 1
    kill -0 "$pid" 2>/dev/null
}

arena_lock_acquire() {
    local lock_path="$1"
    local token="$2"
    local owner_tmp grace_cutoff pid

    [[ -n "$token" ]] || arena_die 'lock token must not be empty'
    if ! mkdir "$lock_path" 2>/dev/null; then
        if arena_lock_is_held "$lock_path"; then
            if arena_lock_owner_alive "$lock_path"; then
                arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
            fi
            rm -rf "$lock_path"
            mkdir "$lock_path" 2>/dev/null || arena_die "cannot acquire lock: $lock_path"
        else
            # metadata-less window: grace rule
            grace_cutoff="$(($(date +%s) - 60))"
            if [[ "$(stat -f '%m' "$lock_path" 2>/dev/null || stat -c '%Y' "$lock_path" 2>/dev/null)" -lt "$grace_cutoff" ]]; then
                rm -rf "$lock_path"
                mkdir "$lock_path" 2>/dev/null || arena_die "cannot acquire lock: $lock_path"
            else
                printf 'transition in progress (lock without metadata): %s\n' "$lock_path" >&2
                exit 4
            fi
        fi
    fi
    owner_tmp="${lock_path}/owner.tmp.$$"
    {
        printf 'pid=%s\n' "$$"
        printf 'token=%s\n' "$token"
        printf 'created_at=%s\n' "$(date +%s)"
    } >"$owner_tmp"
    mv "$owner_tmp" "${lock_path}/owner"
}

arena_lock_release() {
    local lock_path="$1"
    local token="$2"

    if ! arena_lock_is_held "$lock_path"; then
        rm -rf "$lock_path"
        return 0
    fi
    [[ "$(arena_lock_owner_token "$lock_path")" == "$token" ]] || \
        arena_die 'lock release requires the owner token'
    rm -rf "$lock_path"
}
