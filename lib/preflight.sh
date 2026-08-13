#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

for variable_name in ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR ARENA_WRITER_WORKTREE ARENA_SESSION_NAME; do
    [[ -n "${!variable_name:-}" ]] || arena_die "missing environment variable $variable_name"
done

arena_read_manifest "$ARENA_RUN_DIR"
[[ "$ARENA_MANIFEST_RUN_ID" == "$ARENA_RUN_ID" ]] || arena_die 'run id differs from manifest'
arena_same_directory "$ARENA_MANIFEST_REPOSITORY" "$ARENA_REPOSITORY" || \
    arena_die 'repository differs from manifest'
arena_same_directory "$ARENA_MANIFEST_WRITER_WORKTREE" "$ARENA_WRITER_WORKTREE" || \
    arena_die 'writer worktree differs from manifest'
[[ "$ARENA_MANIFEST_SESSION_NAME" == "$ARENA_SESSION_NAME" ]] || \
    arena_die 'session differs from manifest'
arena_assert_worktree "$ARENA_WRITER_WORKTREE"
[[ "$(git -C "$ARENA_WRITER_WORKTREE" branch --show-current)" == "$ARENA_MANIFEST_BRANCH" ]] || \
    arena_die 'writer worktree is not on its recorded branch'

declared_review_worktree="${ARENA_REVIEW_WORKTREE:-}"
if [[ -n "$declared_review_worktree" ]]; then
    arena_read_review_manifest "$ARENA_RUN_DIR"
    arena_same_directory "$ARENA_REVIEW_WORKTREE" "$declared_review_worktree" || \
        arena_die 'review worktree differs from review manifest'
    arena_assert_worktree "$ARENA_REVIEW_WORKTREE"
    arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" || \
        arena_die 'review snapshot is not an intact submitted checkpoint'
fi

case "${ARENA_LOG_PANES:-0}" in
    0|1) ;;
    *) arena_die 'ARENA_LOG_PANES must be 0 or 1' ;;
esac

arena_note "preflight passed for run $ARENA_RUN_ID"
