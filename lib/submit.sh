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

# The state file is authoritative for the transition commit below. Source
# state.sh here: the priority precheck needs its lock and intent helpers.
ARENA_CALLER=submit source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" submit

# Serialize the evidence + state commit; released before the best-effort
# pane respawn and notes. Every exit path (arena_die, state conflict,
# guard refusal) releases the lock; exit "$status" preserves the real
# exit code (a plain EXIT trap body would mask it under Bash 3.2).
submit_lock_held=0
arena_submit_cleanup() {
    local status=$?

    if [[ "$submit_lock_held" == 1 ]] && arena_lock_is_held "${run_dir}/.run-lock" && \
        [[ "$(arena_lock_owner_token "${run_dir}/.run-lock")" == "submit-$$" ]]; then
        arena_lock_release "${run_dir}/.run-lock" "submit-$$"
    fi
    exit "$status"
}
trap arena_submit_cleanup EXIT
arena_lock_acquire "${run_dir}/.run-lock" "submit-$$"
submit_lock_held=1

# Legacy run: project inside the lock BEFORE the evidence phase can change
# review.tsv (an L6 intake projection requires no evidence). Residue (5)
# and conflict (2) abort here under errexit.
legacy_projected=0
if [[ ! -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_project_legacy "$run_dir"
    legacy_projected=1
fi

arena_assert_clean_worktree "$ARENA_MANIFEST_WRITER_WORKTREE"

# A project-owned gate policy cannot be safely merged with the generated gate
# policy: permission arrays have provider-specific layering semantics. Refuse
# before creating a detached snapshot instead of weakening either policy.
while IFS=$'\t' read -r key value; do
    [[ "$key" == policy_path || "$key" == wrapper_path ]] || continue
    if git -C "$ARENA_MANIFEST_WRITER_WORKTREE" ls-files --error-unmatch -- "$value" >/dev/null 2>&1; then
        arena_die "submitted checkpoint tracks $value; Agent Arena cannot safely layer its local gate policy"
    fi
done < <(arena_gate_policy_paths "$ARENA_MANIFEST_GATE_ADAPTER")

writer_head="$(git -C "$ARENA_MANIFEST_WRITER_WORKTREE" rev-parse HEAD)"
[[ "$writer_head" != "$ARENA_MANIFEST_BASE_SHA" ]] || \
    arena_die 'writer checkpoint has no commit beyond the recorded base'
git -C "$ARENA_MANIFEST_WRITER_WORKTREE" merge-base --is-ancestor \
    "$ARENA_MANIFEST_BASE_SHA" "$writer_head" || \
    arena_die 'writer checkpoint does not descend from the recorded base'

# Classify the transition BEFORE the evidence phase: an illegal submit must
# fail closed (exit 2) without rewriting review.tsv or deleting the
# validation/decision pointers. run-state.tsv remains the atomic commit
# point; it is only written after the evidence is on disk.
submit_case=''
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if arena_source_submitted_reviewer && [[ "$ARENA_STATE_CHECKPOINT_SHA" == "$writer_head" ]]; then
        submit_case='retry' # T3: same-SHA idempotent retry — zero-write
    elif arena_source_intake_or_decided_writer && [[ -z "$ARENA_STATE_CHECKPOINT_SHA" || "$ARENA_STATE_CHECKPOINT_SHA" != "$writer_head" ]]; then
        submit_case='new-sha' # T2: intake or decided writer submits a new SHA
    elif [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer ]] && \
        { [[ "$ARENA_STATE_REASON_CODE" == changes_requested || "$ARENA_STATE_REASON_CODE" == human_changes_requested ]]; } && \
        [[ "$ARENA_STATE_CHECKPOINT_SHA" == "$writer_head" ]]; then
        arena_state_die 'writer must submit a new SHA'
    else
        arena_state_die "illegal submit from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    fi
elif [[ "$legacy_projected" == 1 ]]; then
    if [[ "$ARENA_PROJECTED_PHASE" == submitted && "$ARENA_PROJECTED_CS" == "$writer_head" ]]; then
        submit_case='legacy-resubmit' # L-T3: resubmit of the already-submitted SHA
    elif [[ "$ARENA_PROJECTED_PHASE" == intake ]]; then
        submit_case='legacy-first' # L6: a legacy run with no evidence
    else
        arena_state_die "legacy projection ${ARENA_PROJECTED_PHASE}/${ARENA_PROJECTED_PARTY}/${ARENA_PROJECTED_REASON} does not admit this submit"
    fi
fi

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
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
        "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH" || \
        arena_die 'existing review snapshot is not an intact submitted checkpoint'
else
    # The tracked-policy loop above runs arena_gate_policy_paths inside a
    # process substitution, which swallows its missing-adapter die. Re-check
    # here so a vanished gate adapter fails submit before any snapshot exists.
    adapter_check="${source_root}/adapters/gate-${ARENA_MANIFEST_GATE_ADAPTER}.sh"
    [[ -x "$adapter_check" ]] || arena_die "gate adapter is missing: $adapter_check"
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
    arena_prepare_gate_policy "$review_worktree" "$ARENA_MANIFEST_GATE_ADAPTER"
    arena_review_snapshot_is_intact "$review_worktree" "$writer_head" \
        "$ARENA_GATE_POLICY_HASH" "$ARENA_GATE_WRAPPER_HASH" "$ARENA_GATE_POLICY_PATH" \
        "$ARENA_GATE_WRAPPER_PATH" || \
        arena_die 'review snapshot changed while installing gate policy'
    arena_write_review_manifest "$run_dir" "$writer_head" "$review_worktree" \
        "$ARENA_MANIFEST_GATE_ADAPTER" "$ARENA_GATE_POLICY_PATH" \
        "$ARENA_GATE_POLICY_HASH" "$ARENA_GATE_WRAPPER_HASH" "$ARENA_GATE_WRAPPER_PATH"
    # The previous checkpoint's validation/decision pointers no longer describe
    # this submission; the per-SHA archives remain for the audit trail.
    rm -f "${run_dir}/validation.md" "${run_dir}/decision.md"
fi

# Commit the transition: evidence is on disk first; run-state.tsv is the
# atomic commit point. The submit case was classified above, before the
# evidence phase could mutate anything.
case "$submit_case" in
    retry)
        : # T3: same-SHA idempotent retry — zero-write, evidence verified above
        ;;
    new-sha)
        arena_state_transition "$run_dir" arena_source_intake_or_decided_writer \
            true \
            arena_state_delta_submit_new_sha \
            submit
        ;;
    legacy-resubmit)
        # L-T3: legacy first migration for the already-submitted SHA.
        # Materialize v1 with the L5 projection; evidence stays as verified.
        arena_state_defaults
        ARENA_STATE_PHASE='submitted'
        ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
        ARENA_STATE_REASON_CODE='review_pending'
        ARENA_STATE_CHECKPOINT_SHA="$writer_head"
        ARENA_STATE_CHECKPOINT_ROUND='unknown'
        ARENA_STATE_WAITING_SINCE="$(date +%s)"
        ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
        ARENA_STATE_LAST_TRANSITION_ACTOR='writer'
        ARENA_STATE_LAST_TRANSITION_ACTION='submit'
        arena_state_write "$run_dir"
        ;;
    legacy-first)
        # L6: a legacy run with no evidence admits a first submission.
        arena_state_defaults
        ARENA_STATE_PHASE='submitted'
        ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
        ARENA_STATE_REASON_CODE='review_pending'
        ARENA_STATE_CHECKPOINT_SHA="$writer_head"
        ARENA_STATE_CHECKPOINT_ROUND='1'
        ARENA_STATE_WAITING_SINCE="$(date +%s)"
        ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
        ARENA_STATE_LAST_TRANSITION_ACTOR='writer'
        ARENA_STATE_LAST_TRANSITION_ACTION='submit'
        arena_state_write "$run_dir"
        ;;
    *)
        arena_state_die 'internal error: submit transition case not classified'
        ;;
esac

arena_lock_release "${run_dir}/.run-lock" "submit-$$"
submit_lock_held=0

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
    export ARENA_GATE_ADAPTER="$ARENA_MANIFEST_GATE_ADAPTER"
    export ARENA_TEST_MODE="${ARENA_TEST_MODE:-0}"
    export ARENA_PI_BIN="${ARENA_PI_BIN:-pi}"
    export ARENA_CODEX_BIN="${ARENA_CODEX_BIN:-codex}"
    export ARENA_OPENCODE_BIN="${ARENA_OPENCODE_BIN:-opencode}"
    export ARENA_AGY_BIN="${ARENA_AGY_BIN:-agy}"
    export ARENA_CURSOR_BIN="${ARENA_CURSOR_BIN:-agent}"
    arena_make_private_dir "$ARENA_WRITER_SESSION_DIR"

    for environment_name in \
        ARENA_SOURCE_ROOT ARENA_COMMAND ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR \
        ARENA_STATE_ROOT ARENA_WRITER_WORKTREE ARENA_WRITER_SESSION_DIR \
        ARENA_REVIEW_WORKTREE ARENA_SESSION_NAME ARENA_PROFILE \
        ARENA_WRITER_ADAPTER ARENA_WRITER_LABEL ARENA_GATE_ADAPTER ARENA_TEST_MODE ARENA_PI_BIN \
        ARENA_CODEX_BIN ARENA_OPENCODE_BIN ARENA_AGY_BIN ARENA_CURSOR_BIN; do
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
