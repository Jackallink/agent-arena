#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/config.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena validate RUN_ID [--state-root PATH]

Run the submitted snapshot's project-defined validation script. Validation rejects a
dirty review snapshot before and after execution and records a report bound to its SHA.
EOF
}

run_id=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -* ) arena_die "unknown option: $1" ;;
        *)
            [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'
            run_id="$1"
            shift
            ;;
    esac
done

[[ -n "$run_id" ]] || arena_die 'validate requires RUN_ID'
arena_validate_run_id "$run_id"
arena_require_command git
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
arena_read_review_manifest "$run_dir"
arena_assert_worktree "$ARENA_REVIEW_WORKTREE"
review_head="$(git -C "$ARENA_REVIEW_WORKTREE" rev-parse HEAD)"
[[ "$review_head" == "$ARENA_REVIEW_HEAD" ]] || \
    arena_die 'review worktree HEAD differs from the submitted checkpoint'
arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
    "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
    "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH" || \
    arena_die 'review snapshot is not an intact submitted checkpoint'
arena_load_project_config "$ARENA_REVIEW_WORKTREE"
[[ -x "$ARENA_PROJECT_VALIDATION_PATH" ]] || \
    arena_die "project validation script is not executable: $ARENA_PROJECT_VALIDATION_PATH"

short_sha="$(arena_short_sha "$review_head")"
report="${run_dir}/validation-${short_sha}.md"
tmp_report="$(mktemp "${run_dir}/.validation.XXXXXX")"

run_gate() {
    printf '# Agent Arena Validation Report\n\n'
    printf 'Run: %s\n\n' "$run_id"
    printf 'Review HEAD: %s\n\n' "$review_head"
    printf 'Project: %s\n\n' "$ARENA_PROJECT_NAME"
    printf 'Command: %s\n\n' "$ARENA_PROJECT_VALIDATION_SCRIPT"
    printf '## Output\n\n'
    local gate_status

    if (
        cd "$ARENA_REVIEW_WORKTREE"
        "$ARENA_PROJECT_VALIDATION_PATH"
    ); then
        gate_status=0
    else
        gate_status=$?
    fi
    if ! arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
        "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
        printf '%s\n' 'Snapshot integrity check failed after validation.' >&2
        return 2
    fi
    return "$gate_status"
}

set +e
run_gate >"$tmp_report" 2>&1
validation_status=$?
set -e
if [[ "$validation_status" == 0 ]]; then
    printf '\nRESULT: PASS\n' >>"$tmp_report"
else
    printf '\nRESULT: FAIL\n' >>"$tmp_report"
fi
chmod 600 "$tmp_report"
if [[ -f "$report" && ! -L "$report" ]]; then
    # Preserve the previous report for the audit trail instead of overwriting
    # it; the decision gate still reads only the canonical report name.
    rotation_index=0
    rotated_report=''
    while :; do
        rotation_index=$((rotation_index + 1))
        rotated_report="${report%.md}.r${rotation_index}.md"
        [[ ! -e "$rotated_report" ]] && break
    done
    mv "$report" "$rotated_report"
    chmod 600 "$rotated_report"
fi
mv "$tmp_report" "$report"
printf 'Latest validation report: %s\n' "$(basename "$report")" >"${run_dir}/validation.md"
chmod 600 "${run_dir}/validation.md"
cat "$report"
exit "$validation_status"
