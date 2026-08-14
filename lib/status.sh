#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena status RUN_ID [--state-root PATH]

Show the run manifest plus the latest submitted checkpoint, validation report, and
decision record. This command makes no changes.
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

[[ -n "$run_id" ]] || arena_die 'status requires RUN_ID'
arena_validate_run_id "$run_id"
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
# The state file is the authority for status (Task 1: read+validate only;
# the one-sentence diagnosis lands in a later task). Corruption fails
# closed here before any output.
source "${source_root}/lib/state.sh"
arena_state_read "$run_dir"

printf 'Run: %s\n' "$ARENA_MANIFEST_RUN_ID"
printf 'Repository: %s\n' "$ARENA_MANIFEST_REPOSITORY"
printf 'Base: %s\n' "$ARENA_MANIFEST_BASE_SHA"
printf 'Profile: %s\n' "$ARENA_MANIFEST_PROFILE"
printf 'Writer adapter: %s\n' "$ARENA_MANIFEST_WRITER_ADAPTER"
printf 'Gate: %s\n' "$ARENA_MANIFEST_GATE_ADAPTER"
printf 'Writer: %s\n' "$ARENA_MANIFEST_WRITER_LABEL"
printf 'Writer worktree: %s\n' "$ARENA_MANIFEST_WRITER_WORKTREE"
printf 'Branch: %s\n' "$ARENA_MANIFEST_BRANCH"
printf 'Tmux session: %s\n' "$ARENA_MANIFEST_SESSION_NAME"
printf 'State: %s\n' "$run_dir"
integrity_status=0
if [[ -f "${run_dir}/review.tsv" ]]; then
    arena_read_review_manifest "$run_dir"
    printf 'Review HEAD: %s\n' "$ARENA_REVIEW_HEAD"
    printf 'Review worktree: %s\n' "$ARENA_REVIEW_WORKTREE"
    if arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
        "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
        printf 'Integrity: OK\n'
    else
        printf 'Integrity: FAILED (review snapshot is missing, dirty, or tampered)\n'
        integrity_status=1
    fi
    expected_short="$(arena_short_sha "$ARENA_REVIEW_HEAD")"
    if [[ -f "${run_dir}/validation.md" ]]; then
        pointer="$(<"${run_dir}/validation.md")"
        if [[ "$pointer" == "Latest validation report: validation-${expected_short}.md" ]]; then
            printf 'Validation: %s\n' "$pointer"
        else
            printf 'Validation: not run for current checkpoint\n'
        fi
    else
        printf 'Validation: not run\n'
    fi
    if [[ -f "${run_dir}/decision.md" ]]; then
        if grep -Fqx "Review HEAD: ${ARENA_REVIEW_HEAD}" "${run_dir}/decision.md"; then
            printf 'Decision: %s\n' "${run_dir}/decision.md"
        else
            printf 'Decision: not recorded for current checkpoint\n'
        fi
    else
        printf 'Decision: not recorded\n'
    fi
else
    printf 'Review: no checkpoint submitted\n'
    printf 'Validation: not run\n'
    printf 'Decision: not recorded\n'
fi
exit "$integrity_status"
