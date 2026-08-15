#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..."

Raise a stuck run to human responsibility. Allowed only from
responsible_party=reviewer with phase submitted or validated. Idempotent in
the blocked/human/reviewer_unreachable state.

Options:
  --reason-code CODE     v1 supports only reviewer_unreachable
  --reason TEXT          Why the run is being escalated (required)
  --state-root PATH      Private run-state root override
  -h, --help             Show this help
EOF
}

run_id=''
reason_code=''
reason=''
actor='human'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason-code)
            [[ $# -ge 2 ]] || arena_die '--reason-code requires a value'
            reason_code="$2"
            shift 2
            ;;
        --reason)
            [[ $# -ge 2 ]] || arena_die '--reason requires a value'
            reason="$2"
            shift 2
            ;;
        --actor)
            [[ $# -ge 2 ]] || arena_die '--actor requires a value'
            case "$2" in
                human|system) ;;
                *) arena_die "invalid --actor: $2 (legal values: human, system)" ;;
            esac
            actor="$2"
            shift 2
            ;;
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a value'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*) arena_die "unknown option: $1" ;;
        *)
            [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'
            run_id="$1"
            shift
            ;;
    esac
done
[[ -n "$run_id" && -n "$reason_code" && -n "$reason" ]] || \
    arena_die 'escalate requires RUN_ID, --reason-code, and --reason'
[[ "$reason_code" == reviewer_unreachable ]] || \
    arena_die 'v1 escalate supports only --reason-code reviewer_unreachable'
arena_validate_run_id "$run_id"
arena_validate_text "$reason" 'reason' 256

run_dir="$(arena_find_run_dir "$run_id")"

# Source state.sh after manifest resolution: the priority precheck needs its
# lock and intent helpers.
source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" escalate

# Serialize the projection + state commit. Every exit path (arena_die,
# state conflict, guard refusal) releases the lock; exit "$status"
# preserves the real exit code (a plain EXIT trap body would mask it
# under Bash 3.2).
lock_path="${run_dir}/.run-lock"
escalate_lock_held=0
arena_escalate_cleanup() {
    local status=$?

    if [[ "$escalate_lock_held" == 1 ]] && arena_lock_is_held "$lock_path" && \
        [[ "$(arena_lock_owner_token "$lock_path")" == "escalate-$$" ]]; then
        arena_lock_release "$lock_path" "escalate-$$"
    fi
    exit "$status"
}
trap arena_escalate_cleanup EXIT
arena_lock_acquire "$lock_path" "escalate-$$"
escalate_lock_held=1

if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    # Idempotence: already blocked/human/reviewer_unreachable is a zero-write
    # success, never a waiting_since reset.
    if [[ "$ARENA_STATE_RUN_STATUS" == blocked && \
        "$ARENA_STATE_RESPONSIBLE_PARTY" == human && \
        "$ARENA_STATE_REASON_CODE" == reviewer_unreachable ]]; then
        arena_lock_release "$lock_path" "escalate-$$"
        escalate_lock_held=0
        arena_note 'already escalated'
        exit 0
    fi
    { [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && \
        ( "$ARENA_STATE_PHASE" == submitted || "$ARENA_STATE_PHASE" == validated ) ]]; } || \
        arena_state_die "illegal transition from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    ARENA_STATE_RUN_STATUS='blocked'
    ARENA_STATE_RESPONSIBLE_PARTY='human'
    ARENA_STATE_REASON_CODE='reviewer_unreachable'
    ARENA_STATE_REASON_DETAIL="$reason"
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR="$actor"
    ARENA_STATE_LAST_TRANSITION_ACTION='escalate'
    arena_state_write "$run_dir"
else
    # Legacy run: project inside the lock, migrate to v1, and apply T9 in
    # the same commit when the projection satisfies the T9 guard (a legacy
    # SUBMITTED/VALIDATED run with a dead reviewer is therefore a legal
    # first migration via escalate). Conflicts (2) and foreign residue (5)
    # keep their codes.
    projection_status=0
    arena_state_project_legacy "$run_dir" || projection_status=$?
    [[ "$projection_status" == 0 ]] || exit "$projection_status"
    { [[ "$ARENA_PROJECTED_PARTY" == reviewer && \
        ( "$ARENA_PROJECTED_PHASE" == submitted || "$ARENA_PROJECTED_PHASE" == validated ) ]]; } || \
        arena_state_die "legacy projection ${ARENA_PROJECTED_PHASE}/${ARENA_PROJECTED_PARTY}/${ARENA_PROJECTED_REASON} does not admit escalate"
    arena_state_defaults
    ARENA_STATE_RUN_STATUS='blocked'
    ARENA_STATE_PHASE="$ARENA_PROJECTED_PHASE"
    ARENA_STATE_RESPONSIBLE_PARTY='human'
    ARENA_STATE_REASON_CODE='reviewer_unreachable'
    ARENA_STATE_REASON_DETAIL="$reason"
    ARENA_STATE_CHECKPOINT_SHA="$ARENA_PROJECTED_CS"
    ARENA_STATE_CHECKPOINT_ROUND='unknown'
    ARENA_STATE_VERDICT="$ARENA_PROJECTED_VERDICT"
    ARENA_STATE_VALIDATION_RESULT="$ARENA_PROJECTED_VR"
    ARENA_STATE_VALIDATION_DIGEST="$ARENA_PROJECTED_VD"
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR="$actor"
    ARENA_STATE_LAST_TRANSITION_ACTION='escalate'
    arena_state_write "$run_dir"
fi
arena_lock_release "$lock_path" "escalate-$$"
escalate_lock_held=0
arena_note 'escalated to human; release with: agent-arena resolve '"$run_id"' --action recover --reason "..."'
