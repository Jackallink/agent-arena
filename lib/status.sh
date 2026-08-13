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

printf 'Run: %s\n' "$ARENA_MANIFEST_RUN_ID"
printf 'Repository: %s\n' "$ARENA_MANIFEST_REPOSITORY"
printf 'Base: %s\n' "$ARENA_MANIFEST_BASE_SHA"
printf 'Writer worktree: %s\n' "$ARENA_MANIFEST_WRITER_WORKTREE"
printf 'Branch: %s\n' "$ARENA_MANIFEST_BRANCH"
printf 'Tmux session: %s\n' "$ARENA_MANIFEST_SESSION_NAME"
printf 'State: %s\n' "$run_dir"
if [[ -f "${run_dir}/review.tsv" ]]; then
    arena_read_review_manifest "$run_dir"
    printf 'Review HEAD: %s\n' "$ARENA_REVIEW_HEAD"
    printf 'Review worktree: %s\n' "$ARENA_REVIEW_WORKTREE"
else
    printf 'Review: no checkpoint submitted\n'
fi
if [[ -f "${run_dir}/validation.md" ]]; then
    printf 'Validation: %s\n' "$(<"${run_dir}/validation.md")"
else
    printf 'Validation: not run\n'
fi
if [[ -f "${run_dir}/decision.md" ]]; then
    printf 'Decision: %s\n' "${run_dir}/decision.md"
else
    printf 'Decision: not recorded\n'
fi
