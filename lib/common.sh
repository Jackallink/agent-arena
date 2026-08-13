#!/usr/bin/env bash

common_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=profile.sh
source "${common_dir}/profile.sh"
unset common_dir

if [[ "${ARENA_TRACE:-0}" == 1 ]]; then
    set -x
fi

arena_die() {
    printf 'agent-arena: %s\n' "$*" >&2
    exit 1
}

arena_note() {
    printf 'agent-arena: %s\n' "$*"
}

arena_require_command() {
    command -v "$1" >/dev/null 2>&1 || arena_die "required command not found: $1"
}

arena_abs_dir() {
    CDPATH='' cd -- "$1" && pwd -P
}

arena_normalize_path() {
    local path="$1"
    local ancestor
    local component
    local suffix=''

    [[ -n "$path" ]] || arena_die 'path must not be empty'
    ancestor="$path"
    while [[ ! -e "$ancestor" && ! -L "$ancestor" ]]; do
        component="$(basename -- "$ancestor")"
        suffix="/${component}${suffix}"
        ancestor="$(dirname -- "$ancestor")"
        [[ "$ancestor" != "$component" ]] || arena_die "cannot normalize path: $path"
    done
    [[ -d "$ancestor" ]] || arena_die "path ancestor is not a directory: $ancestor"
    ancestor="$(arena_abs_dir "$ancestor")"
    printf '%s%s\n' "$ancestor" "$suffix"
}

arena_same_directory() {
    [[ "$(arena_abs_dir "$1")" == "$(arena_abs_dir "$2")" ]]
}

arena_reject_control_characters() {
    if [[ "$1" =~ [[:cntrl:]] ]]; then
        arena_die 'value contains a control character'
    fi
}

arena_validate_text() {
    local value="$1"
    local field_name="$2"
    local limit="$3"

    [[ -n "$value" ]] || arena_die "$field_name must not be empty"
    [[ "${#value}" -le "$limit" ]] || arena_die "$field_name exceeds ${limit} characters"
    arena_reject_control_characters "$value"
}

arena_validate_relay_message() {
    arena_validate_text "$1" 'relay message' 1000
}

arena_validate_run_id() {
    local run_id="$1"

    [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || \
        arena_die "invalid run id '$run_id'; use letters, digits, dot, underscore, or hyphen"
    git check-ref-format --branch "agent-arena/pi/${run_id}" >/dev/null 2>&1 || \
        arena_die "run id '$run_id' cannot form a safe Git branch name"
}

arena_state_root() {
    if [[ -n "${ARENA_STATE_ROOT:-}" ]]; then
        arena_normalize_path "$ARENA_STATE_ROOT"
    else
        arena_normalize_path "${XDG_STATE_HOME:-${HOME}/.local/state}/agent-arena"
    fi
}

arena_worktree_root() {
    if [[ -n "${ARENA_WORKTREE_ROOT:-}" ]]; then
        arena_normalize_path "$ARENA_WORKTREE_ROOT"
    else
        arena_normalize_path "${XDG_DATA_HOME:-${HOME}/.local/share}/agent-arena/worktrees"
    fi
}

arena_make_private_dir() {
    if [[ -e "$1" || -L "$1" ]]; then
        [[ -d "$1" && ! -L "$1" ]] || arena_die "private directory is unsafe: $1"
    else
        mkdir -p "$1"
    fi
    chmod 700 "$1"
}

arena_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 16)}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 16)}'
    else
        printf '%s' "$1" | cksum | awk '{print $1}'
    fi
}

arena_sha256_text() {
    local value="$1"

    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print $1}'
    else
        arena_die 'SHA-256 utility is required for provider session identifiers'
    fi
}

arena_uuid_v4_from_text() {
    local digest

    digest="$(arena_sha256_text "$1")"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || \
        arena_die 'could not derive a SHA-256 provider session identifier'
    printf '%s-%s-4%s-8%s-%s\n' "${digest:0:8}" "${digest:8:4}" \
        "${digest:12:3}" "${digest:15:3}" "${digest:18:12}"
}

arena_file_hash() {
    local path="$1"

    [[ -f "$path" && ! -L "$path" ]] || return 1
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        printf '%s\n' 'agent-arena: SHA-256 utility is required for review-policy integrity' >&2
        return 1
    fi
}

arena_file_mode() {
    local path="$1"
    local mode

    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
        mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    fi
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    printf '%s\n' "$mode"
}

arena_repo_id() {
    local repository="$1"
    local stem

    stem="$(basename "$repository" | tr -cs 'A-Za-z0-9._-' '-')"
    stem="${stem#-}"
    stem="${stem%-}"
    [[ -n "$stem" ]] || stem='repository'
    stem="${stem:0:48}"
    printf '%s-%s' "$stem" "$(arena_hash "$repository")"
}

arena_assert_worktree() {
    local worktree="$1"

    [[ -d "$worktree" ]] || arena_die "worktree does not exist: $worktree"
    worktree="$(arena_abs_dir "$worktree")"
    git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
        arena_die "not a Git worktree: $worktree"
    [[ "$(git -C "$worktree" rev-parse --show-toplevel)" == "$worktree" ]] || \
        arena_die "worktree must be its Git top-level directory: $worktree"
}

arena_assert_clean_worktree() {
    local worktree="$1"
    local status

    arena_assert_worktree "$worktree"
    status="$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)"
    [[ -z "$status" ]] || arena_die "worktree is dirty: $worktree"
}

arena_short_sha() {
    printf '%s' "${1:0:12}"
}

arena_validate_review_declared_path() {
    local path="$1"
    local field_name="$2"

    [[ -n "$path" ]] || arena_die "$field_name must not be empty"
    [[ "$path" != /* ]] || \
        arena_die "$field_name must be relative to the review snapshot: $path"
    if [[ "$path" == .. || "$path" == ../* || "$path" == */.. || "$path" == */../* ]]; then
        arena_die "$field_name may not contain '..' path components: $path"
    fi
    arena_reject_control_characters "$path"
}

arena_review_snapshot_is_intact() {
    local worktree="$1"
    local expected_head="$2"
    local expected_policy_hash="${3:-}"
    local expected_gate_hash="${4:-}"
    local gate_policy_path="${5:-.cursor/cli.json}"
    local gate_wrapper_path="${6:-.agent-arena-gate}"
    local policy_file policy_parent gate_wrapper wrapper_parent actual_head worktree_status
    local policy_status_entry wrapper_status_entry status_entry path policy_mode gate_mode

    if [[ ! -d "$worktree" ]]; then
        printf 'review snapshot is missing: %s\n' "$worktree" >&2
        return 1
    fi
    if ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'review snapshot is not a Git worktree: %s\n' "$worktree" >&2
        return 1
    fi
    actual_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)" || {
        printf 'review snapshot has no readable HEAD: %s\n' "$worktree" >&2
        return 1
    }
    if [[ "$actual_head" != "$expected_head" ]]; then
        printf 'review snapshot HEAD changed: expected %s, got %s\n' \
            "$expected_head" "$actual_head" >&2
        return 1
    fi
    worktree_status="$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)"
    if [[ -z "$expected_policy_hash" && -z "$expected_gate_hash" ]]; then
        if [[ -n "$worktree_status" ]]; then
            printf 'review snapshot is dirty: %s\n' "$worktree" >&2
            return 1
        fi
        return 0
    fi
    if [[ -z "$expected_policy_hash" || -z "$expected_gate_hash" ]]; then
        printf 'review snapshot is missing generated policy integrity data\n' >&2
        return 1
    fi

    policy_file="${worktree}/${gate_policy_path}"
    gate_wrapper="${worktree}/${gate_wrapper_path}"
    policy_parent="$worktree"
    wrapper_parent="$worktree"
    if [[ "$(dirname "$gate_policy_path")" != '.' ]]; then
        policy_parent="${worktree}/$(dirname "$gate_policy_path")"
    fi
    if [[ "$(dirname "$gate_wrapper_path")" != '.' ]]; then
        wrapper_parent="${worktree}/$(dirname "$gate_wrapper_path")"
    fi
    policy_status_entry="?? ${gate_policy_path}"
    wrapper_status_entry="?? ${gate_wrapper_path}"
    if [[ -L "$policy_parent" || -L "$policy_file" || -L "$wrapper_parent" || -L "$gate_wrapper" ]]; then
        printf 'review snapshot generated policy path is a symbolic link\n' >&2
        return 1
    fi
    if [[ ! -d "$policy_parent" || ! -f "$policy_file" || ! -d "$wrapper_parent" || ! -f "$gate_wrapper" ]]; then
        printf 'review snapshot generated policy files are missing\n' >&2
        return 1
    fi
    policy_mode="$(arena_file_mode "$policy_file")" || return 1
    gate_mode="$(arena_file_mode "$gate_wrapper")" || return 1
    if [[ "$policy_mode" != 600 || "$gate_mode" != 700 ]]; then
        printf 'review snapshot generated policy permissions changed\n' >&2
        return 1
    fi
    if [[ "$(arena_file_hash "$policy_file")" != "$expected_policy_hash" ]]; then
        printf 'review snapshot gate policy changed: %s\n' "$policy_file" >&2
        return 1
    fi
    if [[ "$(arena_file_hash "$gate_wrapper")" != "$expected_gate_hash" ]]; then
        printf 'review snapshot gate wrapper changed: %s\n' "$gate_wrapper" >&2
        return 1
    fi
    while IFS= read -r status_entry; do
        [[ -n "$status_entry" ]] || continue
        case "$status_entry" in
            "$policy_status_entry"|"$wrapper_status_entry") ;;
            *)
                printf 'review snapshot has unexpected change: %s\n' "$status_entry" >&2
                return 1
                ;;
        esac
    done <<<"$worktree_status"
    for status_entry in "$policy_status_entry" "$wrapper_status_entry"; do
        path="${status_entry#?? }"
        # A project may already ignore its own gate-policy or dot-file state.
        # Do not alter shared Git excludes; the manifest hashes above still bind
        # Arena's two generated files, while normal status catches every other
        # change.
        if git -C "$worktree" check-ignore -q -- "$path"; then
            continue
        fi
        if ! grep -Fqx "$status_entry" <<<"$worktree_status"; then
            printf 'review snapshot is missing generated local file: %s\n' "$status_entry" >&2
            return 1
        fi
    done
}

arena_find_run_dir() {
    local run_id="$1"
    local runs_root
    local matches
    local match_count
    local inherited_run_dir

    arena_validate_run_id "$run_id"
    if [[ -n "${ARENA_RUN_DIR:-}" ]]; then
        inherited_run_dir="$(arena_abs_dir "$ARENA_RUN_DIR")" || \
            arena_die "inherited run directory does not exist: $ARENA_RUN_DIR"
        arena_read_manifest "$inherited_run_dir"
        [[ "$ARENA_MANIFEST_RUN_ID" == "$run_id" ]] || \
            arena_die "inherited run directory belongs to $ARENA_MANIFEST_RUN_ID, not $run_id"
        printf '%s\n' "$inherited_run_dir"
        return
    fi
    runs_root="$(arena_state_root)/runs"
    [[ -d "$runs_root" ]] || arena_die "no run state exists under: $runs_root"
    matches="$(find "$runs_root" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv \
        -path "*/${run_id}/manifest.tsv" 2>/dev/null || true)"
    match_count="$(printf '%s\n' "$matches" | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$match_count" == 1 ]] || \
        arena_die "could not identify one run state for $run_id; pass --state-root if needed"
    dirname "$matches"
}

arena_write_manifest() {
    local run_dir="$1"
    local run_id="$2"
    local repository="$3"
    local base_sha="$4"
    local writer_worktree="$5"
    local branch="$6"
    local session_name="$7"
    local tool_root="$8"
    local worktree_root="$9"
    local project_config="${10}"
    local profile="${11}"
    local writer_adapter="${12}"
    local writer_label="${13}"
    local writer_session_dir="${14}"
    local gate_adapter="${15}"
    local tmp_file value

    for value in "$run_id" "$repository" "$base_sha" "$writer_worktree" "$branch" \
        "$session_name" "$tool_root" "$worktree_root" "$project_config" "$profile" \
        "$writer_adapter" "$writer_label" "$writer_session_dir" "$gate_adapter"; do
        arena_reject_control_characters "$value"
        [[ -n "$value" ]] || arena_die 'run manifest value must not be empty'
    done
    arena_profile_resolve "$profile"
    [[ "$ARENA_PROFILE_WRITER_ADAPTER" == "$writer_adapter" ]] || \
        arena_die 'writer adapter does not match the selected profile'
    [[ "$ARENA_PROFILE_WRITER_LABEL" == "$writer_label" ]] || \
        arena_die 'writer label does not match the selected profile'
    [[ "$ARENA_PROFILE_GATE_ADAPTER" == "$gate_adapter" ]] || \
        arena_die 'gate adapter does not match the selected profile'
    [[ "$branch" == "$(arena_profile_branch "$writer_adapter" "$run_id")" ]] || \
        arena_die 'writer branch does not match the selected profile'
    writer_session_dir="$(arena_normalize_path "$writer_session_dir")"
    run_dir="$(arena_normalize_path "$run_dir")"
    [[ "$writer_session_dir" == "${run_dir}/writer-session" ]] || \
        arena_die 'writer session directory must be the private generic session directory'

    tmp_file="$(mktemp "${run_dir}/.manifest.XXXXXX")"
    {
        printf 'run_id\t%s\n' "$run_id"
        printf 'repository\t%s\n' "$repository"
        printf 'base_sha\t%s\n' "$base_sha"
        printf 'writer_worktree\t%s\n' "$writer_worktree"
        printf 'branch\t%s\n' "$branch"
        printf 'session_name\t%s\n' "$session_name"
        printf 'tool_root\t%s\n' "$tool_root"
        printf 'worktree_root\t%s\n' "$worktree_root"
        printf 'project_config\t%s\n' "$project_config"
        printf 'profile\t%s\n' "$profile"
        printf 'writer_adapter\t%s\n' "$writer_adapter"
        printf 'writer_label\t%s\n' "$writer_label"
        printf 'writer_session_dir\t%s\n' "$writer_session_dir"
        printf 'gate_adapter\t%s\n' "$gate_adapter"
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/manifest.tsv"
}

arena_read_manifest() {
    local run_dir="$1"
    local manifest="${run_dir}/manifest.tsv"
    local key value

    [[ -f "$manifest" ]] || arena_die "missing run manifest: $manifest"
    ARENA_MANIFEST_RUN_ID=''
    ARENA_MANIFEST_REPOSITORY=''
    ARENA_MANIFEST_BASE_SHA=''
    ARENA_MANIFEST_WRITER_WORKTREE=''
    ARENA_MANIFEST_BRANCH=''
    ARENA_MANIFEST_SESSION_NAME=''
    ARENA_MANIFEST_TOOL_ROOT=''
    ARENA_MANIFEST_WORKTREE_ROOT=''
    ARENA_MANIFEST_PROJECT_CONFIG=''
    ARENA_MANIFEST_PROFILE=''
    ARENA_MANIFEST_WRITER_ADAPTER=''
    ARENA_MANIFEST_WRITER_LABEL=''
    ARENA_MANIFEST_WRITER_SESSION_DIR=''
    ARENA_MANIFEST_GATE_ADAPTER=''
    ARENA_MANIFEST_LEGACY_PROFILE=0
    local profile_field_count=0

    while IFS=$'\t' read -r key value; do
        case "$key" in
            run_id) ARENA_MANIFEST_RUN_ID="$value" ;;
            repository) ARENA_MANIFEST_REPOSITORY="$value" ;;
            base_sha) ARENA_MANIFEST_BASE_SHA="$value" ;;
            writer_worktree) ARENA_MANIFEST_WRITER_WORKTREE="$value" ;;
            branch) ARENA_MANIFEST_BRANCH="$value" ;;
            session_name) ARENA_MANIFEST_SESSION_NAME="$value" ;;
            tool_root) ARENA_MANIFEST_TOOL_ROOT="$value" ;;
            worktree_root) ARENA_MANIFEST_WORKTREE_ROOT="$value" ;;
            project_config) ARENA_MANIFEST_PROJECT_CONFIG="$value" ;;
            profile)
                ARENA_MANIFEST_PROFILE="$value"
                profile_field_count=$((profile_field_count + 1))
                ;;
            writer_adapter)
                ARENA_MANIFEST_WRITER_ADAPTER="$value"
                profile_field_count=$((profile_field_count + 1))
                ;;
            writer_label)
                ARENA_MANIFEST_WRITER_LABEL="$value"
                profile_field_count=$((profile_field_count + 1))
                ;;
            writer_session_dir)
                ARENA_MANIFEST_WRITER_SESSION_DIR="$value"
                profile_field_count=$((profile_field_count + 1))
                ;;
            gate_adapter) ARENA_MANIFEST_GATE_ADAPTER="$value" ;;
            *) arena_die "unknown manifest key '$key' in $manifest" ;;
        esac
    done <"$manifest"

    for value in "$ARENA_MANIFEST_RUN_ID" "$ARENA_MANIFEST_REPOSITORY" \
        "$ARENA_MANIFEST_BASE_SHA" "$ARENA_MANIFEST_WRITER_WORKTREE" \
        "$ARENA_MANIFEST_BRANCH" "$ARENA_MANIFEST_SESSION_NAME" \
        "$ARENA_MANIFEST_TOOL_ROOT" "$ARENA_MANIFEST_WORKTREE_ROOT" \
        "$ARENA_MANIFEST_PROJECT_CONFIG"; do
        [[ -n "$value" ]] || arena_die "incomplete run manifest: $manifest"
        arena_reject_control_characters "$value"
    done
    arena_validate_run_id "$ARENA_MANIFEST_RUN_ID"

    case "$profile_field_count" in
        0)
            # v0.1 manifests are Pi-only. Preserve them so an interrupted older
            # run can be resumed safely rather than silently changing writers.
            ARENA_MANIFEST_PROFILE='pi-cursor'
            ARENA_MANIFEST_WRITER_ADAPTER='pi'
            ARENA_MANIFEST_WRITER_LABEL='Pi'
            ARENA_MANIFEST_WRITER_SESSION_DIR="${run_dir}/pi-session"
            ARENA_MANIFEST_LEGACY_PROFILE=1
            ;;
        4) ;;
        *) arena_die "incomplete writer profile in run manifest: $manifest" ;;
    esac
    [[ -n "$ARENA_MANIFEST_GATE_ADAPTER" ]] || ARENA_MANIFEST_GATE_ADAPTER='cursor'
    arena_gate_resolve "$ARENA_MANIFEST_GATE_ADAPTER"

    for value in "$ARENA_MANIFEST_PROFILE" "$ARENA_MANIFEST_WRITER_ADAPTER" \
        "$ARENA_MANIFEST_WRITER_LABEL" "$ARENA_MANIFEST_WRITER_SESSION_DIR"; do
        [[ -n "$value" ]] || arena_die "incomplete writer profile in run manifest: $manifest"
        arena_reject_control_characters "$value"
    done
    arena_profile_resolve "$ARENA_MANIFEST_PROFILE"
    [[ "$ARENA_PROFILE_WRITER_ADAPTER" == "$ARENA_MANIFEST_WRITER_ADAPTER" ]] || \
        arena_die "writer adapter does not match profile in $manifest"
    [[ "$ARENA_PROFILE_WRITER_LABEL" == "$ARENA_MANIFEST_WRITER_LABEL" ]] || \
        arena_die "writer label does not match profile in $manifest"
    [[ "$ARENA_MANIFEST_BRANCH" == \
        "$(arena_profile_branch "$ARENA_MANIFEST_WRITER_ADAPTER" "$ARENA_MANIFEST_RUN_ID")" ]] || \
        arena_die "writer branch does not match profile in $manifest"
    ARENA_MANIFEST_WRITER_SESSION_DIR="$(arena_normalize_path "$ARENA_MANIFEST_WRITER_SESSION_DIR")"
    run_dir="$(arena_normalize_path "$run_dir")"
    if [[ "$ARENA_MANIFEST_LEGACY_PROFILE" == 1 ]]; then
        [[ "$ARENA_MANIFEST_WRITER_SESSION_DIR" == "${run_dir}/pi-session" ]] || \
            arena_die "legacy writer session directory is invalid: $manifest"
    else
        [[ "$ARENA_MANIFEST_WRITER_SESSION_DIR" == "${run_dir}/writer-session" ]] || \
            arena_die "writer session directory is invalid: $manifest"
    fi
}

arena_write_review_manifest() {
    local run_dir="$1"
    local review_head="$2"
    local review_worktree="$3"
    local gate_adapter="$4"
    local gate_policy_path="$5"
    local cursor_policy_hash="$6"
    local gate_wrapper_hash="$7"
    local gate_wrapper_path="$8"
    local tmp_file value

    for value in "$review_head" "$review_worktree" "$gate_adapter" "$gate_policy_path" \
        "$cursor_policy_hash" "$gate_wrapper_hash" "$gate_wrapper_path"; do
        [[ -n "$value" ]] || arena_die 'review manifest value must not be empty'
        arena_reject_control_characters "$value"
    done
    [[ "$cursor_policy_hash" =~ ^[0-9a-fA-F]{64}$ && "$gate_wrapper_hash" =~ ^[0-9a-fA-F]{64}$ ]] || \
        arena_die 'review manifest policy hashes must be SHA-256 values'
    arena_validate_review_declared_path "$gate_policy_path" 'gate policy path'
    arena_validate_review_declared_path "$gate_wrapper_path" 'gate wrapper path'
    tmp_file="$(mktemp "${run_dir}/.review.XXXXXX")"
    {
        printf 'review_head\t%s\n' "$review_head"
        printf 'review_worktree\t%s\n' "$review_worktree"
        printf 'gate_adapter\t%s\n' "$gate_adapter"
        printf 'gate_policy_path\t%s\n' "$gate_policy_path"
        printf 'gate_wrapper_path\t%s\n' "$gate_wrapper_path"
        printf 'cursor_policy_hash\t%s\n' "$cursor_policy_hash"
        printf 'gate_wrapper_hash\t%s\n' "$gate_wrapper_hash"
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/review.tsv"
}

arena_read_review_manifest() {
    local run_dir="$1"
    local manifest="${run_dir}/review.tsv"
    local key value

    [[ -f "$manifest" ]] || arena_die "no submitted review exists for this run"
    ARENA_REVIEW_HEAD=''
    ARENA_REVIEW_WORKTREE=''
    ARENA_REVIEW_GATE_ADAPTER=''
    ARENA_REVIEW_GATE_POLICY_PATH=''
    ARENA_REVIEW_GATE_WRAPPER_PATH=''
    ARENA_REVIEW_CURSOR_POLICY_HASH=''
    ARENA_REVIEW_GATE_WRAPPER_HASH=''
    while IFS=$'\t' read -r key value; do
        case "$key" in
            review_head) ARENA_REVIEW_HEAD="$value" ;;
            review_worktree) ARENA_REVIEW_WORKTREE="$value" ;;
            gate_adapter) ARENA_REVIEW_GATE_ADAPTER="$value" ;;
            gate_policy_path) ARENA_REVIEW_GATE_POLICY_PATH="$value" ;;
            gate_wrapper_path) ARENA_REVIEW_GATE_WRAPPER_PATH="$value" ;;
            cursor_policy_hash) ARENA_REVIEW_CURSOR_POLICY_HASH="$value" ;;
            gate_wrapper_hash) ARENA_REVIEW_GATE_WRAPPER_HASH="$value" ;;
            *) arena_die "unknown review manifest key '$key' in $manifest" ;;
        esac
    done <"$manifest"
    [[ -n "$ARENA_REVIEW_HEAD" && -n "$ARENA_REVIEW_WORKTREE" && \
        -n "$ARENA_REVIEW_CURSOR_POLICY_HASH" && -n "$ARENA_REVIEW_GATE_WRAPPER_HASH" ]] || \
        arena_die "incomplete review manifest: $manifest"
    # v0.2-era review manifests predate the gate_adapter, gate_policy_path, and
    # gate_wrapper_path columns; mirror the run-manifest read and default them
    # to the Cursor gate adapter and its .cursor/cli.json policy
    [[ -n "$ARENA_REVIEW_GATE_ADAPTER" ]] || ARENA_REVIEW_GATE_ADAPTER='cursor'
    [[ -n "$ARENA_REVIEW_GATE_POLICY_PATH" ]] || ARENA_REVIEW_GATE_POLICY_PATH='.cursor/cli.json'
    [[ -n "$ARENA_REVIEW_GATE_WRAPPER_PATH" ]] || ARENA_REVIEW_GATE_WRAPPER_PATH='.agent-arena-gate'
    arena_validate_review_declared_path "$ARENA_REVIEW_GATE_POLICY_PATH" 'gate policy path'
    arena_validate_review_declared_path "$ARENA_REVIEW_GATE_WRAPPER_PATH" 'gate wrapper path'
    arena_gate_resolve "$ARENA_REVIEW_GATE_ADAPTER"
    [[ "$ARENA_REVIEW_GATE_ADAPTER" == "$ARENA_MANIFEST_GATE_ADAPTER" ]] || \
        arena_die 'review gate adapter differs from the run manifest'
    arena_reject_control_characters "$ARENA_REVIEW_HEAD"
    arena_reject_control_characters "$ARENA_REVIEW_WORKTREE"
    arena_reject_control_characters "$ARENA_REVIEW_GATE_ADAPTER"
    arena_reject_control_characters "$ARENA_REVIEW_GATE_POLICY_PATH"
    arena_reject_control_characters "$ARENA_REVIEW_GATE_WRAPPER_PATH"
    arena_reject_control_characters "$ARENA_REVIEW_CURSOR_POLICY_HASH"
    arena_reject_control_characters "$ARENA_REVIEW_GATE_WRAPPER_HASH"
    [[ "$ARENA_REVIEW_CURSOR_POLICY_HASH" =~ ^[0-9a-fA-F]{64}$ && \
        "$ARENA_REVIEW_GATE_WRAPPER_HASH" =~ ^[0-9a-fA-F]{64}$ ]] || \
        arena_die "invalid review manifest policy hashes: $manifest"
}

arena_prepare_gate_policy() {
    local review_worktree="$1"
    local gate_adapter="$2"
    local adapter="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/adapters/gate-${gate_adapter}.sh"
    local binding_pattern=$'^(policy|wrapper)\t[^\t]+\t[0-9a-fA-F]{64}$'
    local bindings binding_line binding_key binding_path binding_hash
    local gate_policy_path='' gate_policy_hash='' gate_wrapper_path='' gate_wrapper_hash=''

    arena_assert_worktree "$review_worktree"
    [[ -x "$adapter" ]] || arena_die "gate adapter is missing: $adapter"
    bindings="$("$adapter" policy "$review_worktree")" || \
        arena_die "gate adapter $gate_adapter failed to generate its policy"
    while IFS= read -r binding_line; do
        [[ -n "$binding_line" ]] || continue
        if [[ ! "$binding_line" =~ $binding_pattern ]]; then
            arena_die 'gate adapter printed a malformed policy binding line'
        fi
        IFS=$'\t' read -r binding_key binding_path binding_hash <<<"$binding_line"
        case "$binding_key" in
            policy)
                [[ -z "$gate_policy_path" && -z "$gate_policy_hash" ]] || \
                    arena_die 'gate adapter printed duplicate policy binding lines'
                gate_policy_path="$binding_path"
                gate_policy_hash="$binding_hash"
                ;;
            wrapper)
                [[ -z "$gate_wrapper_path" && -z "$gate_wrapper_hash" ]] || \
                    arena_die 'gate adapter printed duplicate wrapper binding lines'
                gate_wrapper_path="$binding_path"
                gate_wrapper_hash="$binding_hash"
                ;;
        esac
    done <<<"$bindings"
    [[ -n "$gate_policy_path" && -n "$gate_policy_hash" && \
        -n "$gate_wrapper_path" && -n "$gate_wrapper_hash" ]] || \
        arena_die 'gate adapter printed an incomplete policy binding manifest'
    arena_validate_review_declared_path "$gate_policy_path" 'gate policy path'
    arena_validate_review_declared_path "$gate_wrapper_path" 'gate wrapper path'
    ARENA_GATE_POLICY_PATH="$gate_policy_path"
    ARENA_GATE_POLICY_HASH="$gate_policy_hash"
    ARENA_GATE_WRAPPER_PATH="$gate_wrapper_path"
    ARENA_GATE_WRAPPER_HASH="$gate_wrapper_hash"
}

arena_pane_format() {
    printf '%s' $'#{session_name}\t#{pane_id}\t#{@agent_arena_role}\t#{@agent_arena_mode}\t#{pane_dead}\t#{pane_input_off}\t#{pane_in_mode}\t#{pane_synchronized}'
}

arena_find_live_pane() {
    local session_name="$1"
    local role="$2"
    local expected_mode="$3"
    local candidates count

    candidates="$(
        tmux list-panes -s -t "=${session_name}" -F "$(arena_pane_format)" |
            awk -F $'\t' -v session="$session_name" -v role="$role" -v mode="$expected_mode" \
                '$1 == session && $3 == role && $4 == mode && $5 == "0" && $6 == "0" && $7 == "0" && $8 == "0" { print $2 }'
    )"
    count="$(printf '%s\n' "$candidates" | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$count" == 1 ]] || arena_die \
        "$role pane is unavailable or ambiguous; relay only targets one live, input-enabled agent pane"
    printf '%s\n' "$candidates"
}
