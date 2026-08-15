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

arena_lock_mtime() {
    local path="$1" value
    value="$(stat -c '%Y' "$path" 2>/dev/null)" && [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    value="$(stat -f '%m' "$path" 2>/dev/null)" && [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    return 1
}

# Metadata-less grace rule (mkdir→owner window): a lock directory without an
# owner file and with mtime within 60 seconds is considered live (contenders
# exit 4); older than 60 seconds it is stale. An unreadable mtime fails
# closed as live, mirroring arena_lock_acquire.
arena_lock_metadata_less_fresh() {
    local lock_path="$1"
    local grace_cutoff mtime
    [[ -d "$lock_path" ]] || return 1
    arena_lock_is_held "$lock_path" && return 1
    mtime="$(arena_lock_mtime "$lock_path")" || return 0
    [[ -n "$mtime" && "$mtime" =~ ^[0-9]+$ ]] || return 0
    grace_cutoff="$(($(date +%s) - 60))"
    [[ "$mtime" -ge "$grace_cutoff" ]]
}

# Atomically reclaim a stale lock: rename to a tombstone (exactly one
# concurrent claimer wins the rename), remove the tombstone, then rebuild.
# A lost race or failed rebuild exits 4 (retry) and never continues into the
# critical section. Behavior-compatible for all v0.4 callers.
arena_lock_reclaim() {
    local lock_path="$1" token="$2"
    local tombstone
    tombstone="${lock_path}.reap.${token}.$$"
    if mv "$lock_path" "$tombstone" 2>/dev/null; then
        rm -rf "$tombstone"
        if ! mkdir "$lock_path" 2>/dev/null; then
            printf 'cannot reacquire lock (reclamation raced): %s\n' "$lock_path" >&2
            exit 4
        fi
        return 0
    fi
    return 1
}

arena_lock_acquire() {
    local lock_path="$1"
    local token="$2"
    local owner_tmp grace_cutoff pid mtime now

    [[ -n "$token" ]] || arena_die 'lock token must not be empty'
    if ! mkdir "$lock_path" 2>/dev/null; then
        if arena_lock_is_held "$lock_path"; then
            if arena_lock_owner_alive "$lock_path"; then
                arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
            fi
            arena_lock_reclaim "$lock_path" "$token" || exit 4
        else
            # metadata-less window: grace rule
            grace_cutoff="$(($(date +%s) - 60))"
            mtime="$(arena_lock_mtime "$lock_path")" || mtime=''
            if [[ -n "$mtime" && "$mtime" =~ ^[0-9]+$ && "$mtime" -lt "$grace_cutoff" ]]; then
                arena_lock_reclaim "$lock_path" "$token" || exit 4
            else
                printf 'transition in progress (lock without metadata): %s\n' "$lock_path" >&2
                exit 4
            fi
        fi
    fi
    now="$(date +%s)"
    owner_tmp="${lock_path}/owner.tmp.$$"
    {
        printf 'pid=%s\n' "$$"
        printf 'token=%s\n' "$token"
        printf 'created_at=%s\n' "$now"
        printf 'last_seen_at=%s\n' "$now"
    } >"$owner_tmp"
    mv "$owner_tmp" "${lock_path}/owner"
}

# Refresh last_seen_at in the owner metadata (autopilot long-lived locks only;
# v0.4 locks never call this). Token must match; a missing owner fails.
arena_lock_touch() {
    local lock_path="$1" token="$2"
    local owner now
    owner="${lock_path}/owner"
    [[ -f "$owner" ]] || return 1
    [[ "$(arena_lock_owner_token "$lock_path")" == "$token" ]] || return 1
    now="$(date +%s)"
    if grep -q '^last_seen_at=' "$owner"; then
        sed "s/^last_seen_at=.*/last_seen_at=${now}/" "$owner" >"${owner}.tmp.$$"
    else
        { cat "$owner"; printf 'last_seen_at=%s\n' "$now"; } >"${owner}.tmp.$$"
    fi
    mv "${owner}.tmp.$$" "$owner"
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
