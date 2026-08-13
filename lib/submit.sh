#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena submit RUN_ID [--state-root PATH]

Require a clean committed writer checkpoint, create a detached Cursor review snapshot,
and respawn the reviewer pane when the tmux session is running.
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

[[ -n "$run_id" ]] || arena_die 'submit requires RUN_ID'
arena_validate_run_id "$run_id"
arena_require_command git
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
[[ "$ARENA_MANIFEST_RUN_ID" == "$run_id" ]] || arena_die 'run id differs from manifest'
arena_assert_clean_worktree "$ARENA_MANIFEST_WRITER_WORKTREE"

# A project-owned Cursor policy cannot be safely merged with the generated gate
# policy: permission arrays have provider-specific layering semantics. Refuse
# before creating a detached snapshot instead of weakening either policy.
for policy_path in .cursor/cli.json .agent-arena-gate; do
    if git -C "$ARENA_MANIFEST_WRITER_WORKTREE" ls-files --error-unmatch -- "$policy_path" >/dev/null 2>&1; then
        arena_die "submitted checkpoint tracks $policy_path; Agent Arena cannot safely layer its local Cursor gate policy"
    fi
done

writer_head="$(git -C "$ARENA_MANIFEST_WRITER_WORKTREE" rev-parse HEAD)"
[[ "$writer_head" != "$ARENA_MANIFEST_BASE_SHA" ]] || \
    arena_die 'writer checkpoint has no commit beyond the recorded base'
git -C "$ARENA_MANIFEST_WRITER_WORKTREE" merge-base --is-ancestor \
    "$ARENA_MANIFEST_BASE_SHA" "$writer_head" || \
    arena_die 'writer checkpoint does not descend from the recorded base'

short_sha="$(arena_short_sha "$writer_head")"
review_worktree="${ARENA_MANIFEST_WORKTREE_ROOT}/$(arena_repo_id "$ARENA_MANIFEST_REPOSITORY")/${run_id}/review-${short_sha}"
if [[ -e "$review_worktree" || -L "$review_worktree" ]]; then
    arena_assert_worktree "$review_worktree"
    [[ "$(git -C "$review_worktree" rev-parse HEAD)" == "$writer_head" ]] || \
        arena_die 'existing review worktree does not match submitted checkpoint'
    [[ -f "${run_dir}/review.tsv" ]] || \
        arena_die 'existing review worktree has no verified review manifest'
    arena_read_review_manifest "$run_dir"
    [[ "$ARENA_REVIEW_HEAD" == "$writer_head" ]] || \
        arena_die 'existing review manifest does not match submitted checkpoint'
    arena_same_directory "$ARENA_REVIEW_WORKTREE" "$review_worktree" || \
        arena_die 'existing review manifest does not match review worktree'
    arena_review_snapshot_is_intact "$review_worktree" "$writer_head" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" || \
        arena_die 'existing review snapshot is not an intact submitted checkpoint'
else
    arena_make_private_dir "$(dirname "$review_worktree")"
    # A manually deleted review snapshot stays registered in the Git worktree
    # list and blocks re-creation. Prune only the stale registry entry; this
    # never deletes worktree data.
    if [[ ! -e "$review_worktree" && ! -L "$review_worktree" ]] && \
        git -C "$ARENA_MANIFEST_REPOSITORY" worktree list --porcelain | \
            grep -Fqx "worktree ${review_worktree}"; then
        git -C "$ARENA_MANIFEST_REPOSITORY" worktree prune
    fi
    git -C "$ARENA_MANIFEST_REPOSITORY" worktree add --detach "$review_worktree" "$writer_head"
    arena_assert_clean_worktree "$review_worktree"
    arena_prepare_cursor_gate_policy "$review_worktree"
    arena_review_snapshot_is_intact "$review_worktree" "$writer_head" \
        "$ARENA_CURSOR_POLICY_HASH" "$ARENA_GATE_WRAPPER_HASH" || \
        arena_die 'review snapshot changed while installing Cursor gate policy'
    arena_write_review_manifest "$run_dir" "$writer_head" "$review_worktree" \
        "$ARENA_CURSOR_POLICY_HASH" "$ARENA_GATE_WRAPPER_HASH"
    # The previous checkpoint's validation/decision pointers no longer describe
    # this submission; the per-SHA archives remain for the audit trail.
    rm -f "${run_dir}/validation.md" "${run_dir}/decision.md"
fi

refresh_live_session_environment() {
    local environment_name
    local environment_value

    # v0.1 sessions lack the generic writer fields that current pane.sh
    # requires. Refresh them here as well as in start: a writer may submit its
    # next checkpoint directly from an already-running legacy Pi pane.
    export ARENA_SOURCE_ROOT="$source_root"
    export ARENA_COMMAND="${ARENA_COMMAND:-${source_root}/bin/agent-arena}"
    export ARENA_REPOSITORY="$ARENA_MANIFEST_REPOSITORY"
    export ARENA_RUN_ID="$run_id"
    export ARENA_RUN_DIR="$run_dir"
    export ARENA_STATE_ROOT="$(arena_state_root)"
    export ARENA_WRITER_WORKTREE="$ARENA_MANIFEST_WRITER_WORKTREE"
    export ARENA_WRITER_SESSION_DIR="$ARENA_MANIFEST_WRITER_SESSION_DIR"
    export ARENA_REVIEW_WORKTREE="$review_worktree"
    export ARENA_SESSION_NAME="$ARENA_MANIFEST_SESSION_NAME"
    export ARENA_PROFILE="$ARENA_MANIFEST_PROFILE"
    export ARENA_WRITER_ADAPTER="$ARENA_MANIFEST_WRITER_ADAPTER"
    export ARENA_WRITER_LABEL="$ARENA_MANIFEST_WRITER_LABEL"
    export ARENA_TEST_MODE="${ARENA_TEST_MODE:-0}"
    export ARENA_PI_BIN="${ARENA_PI_BIN:-pi}"
    export ARENA_CODEX_BIN="${ARENA_CODEX_BIN:-codex}"
    export ARENA_OPENCODE_BIN="${ARENA_OPENCODE_BIN:-opencode}"
    export ARENA_GEMINI_BIN="${ARENA_GEMINI_BIN:-gemini}"
    export ARENA_CURSOR_BIN="${ARENA_CURSOR_BIN:-agent}"
    arena_make_private_dir "$ARENA_WRITER_SESSION_DIR"

    for environment_name in \
        ARENA_SOURCE_ROOT ARENA_COMMAND ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR \
        ARENA_STATE_ROOT ARENA_WRITER_WORKTREE ARENA_WRITER_SESSION_DIR \
        ARENA_REVIEW_WORKTREE ARENA_SESSION_NAME ARENA_PROFILE \
        ARENA_WRITER_ADAPTER ARENA_WRITER_LABEL ARENA_TEST_MODE ARENA_PI_BIN \
        ARENA_CODEX_BIN ARENA_OPENCODE_BIN ARENA_GEMINI_BIN ARENA_CURSOR_BIN; do
        environment_value="${!environment_name}"
        tmux set-environment -t "=${ARENA_MANIFEST_SESSION_NAME}" \
            "$environment_name" "$environment_value"
    done
}

if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=${ARENA_MANIFEST_SESSION_NAME}" 2>/dev/null; then
    refresh_live_session_environment
    # The reviewer pane refresh is best effort: the checkpoint is already
    # recorded and immutable, so an unavailable pane must not fail the submit.
    if reviewer_pane="$(arena_find_live_pane "$ARENA_MANIFEST_SESSION_NAME" reviewer reviewer-agent 2>/dev/null)"; then
        printf -v respawn_command 'exec %q reviewer' "${source_root}/lib/pane.sh"
        tmux respawn-pane -k -t "$reviewer_pane" "$respawn_command"
    else
        arena_note 'reviewer pane is unavailable; checkpoint recorded without a Cursor pane respawn'
    fi
fi

arena_note "submitted ${ARENA_MANIFEST_WRITER_LABEL} checkpoint: $writer_head"
arena_note "Cursor review snapshot: $review_worktree"
arena_note 'Cursor must run the validation gate before approving the checkpoint'
