#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena resolve RUN_ID --action approve|reject|recover|cancel --reason "..."

Human disposition. Allowed only when responsible_party=human. reject/recover/
cancel require --reason. approve only after a reviewer APPROVE; recover only
after an operational escalation with a reachable reviewer pane; BLOCKED admits
only reject or cancel in v1.

Options:
  --action ACTION       approve, reject, recover, or cancel
  --reason TEXT         Why the run is being resolved (required except approve)
  --state-root PATH     Private run-state root override
  -h, --help            Show this help
EOF
}

run_id=''
action=''
reason=''
actor='human'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)
            [[ $# -ge 2 ]] || arena_die '--action requires a value'
            action="$2"
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
[[ -n "$run_id" && -n "$action" ]] || arena_die 'resolve requires RUN_ID and --action'
case "$action" in
    approve|reject|recover|cancel) ;;
    *) arena_die 'action must be approve, reject, recover, or cancel' ;;
esac
if [[ "$action" != approve && -z "$reason" ]]; then
    arena_die "$action requires --reason"
fi
[[ -z "$reason" ]] || arena_validate_text "$reason" 'reason' 256
arena_validate_run_id "$run_id"

run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"

# Source state.sh after manifest resolution: the priority precheck needs its
# lock and intent helpers.
source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" resolve

# Serialize the projection + state commit; the recover pane-reachability
# check runs INSIDE the lock. Every exit path releases the lock.
lock_path="${run_dir}/.run-lock"
resolve_lock_held=0
arena_resolve_cleanup() {
    local status=$?

    if [[ "$resolve_lock_held" == 1 ]] && arena_lock_is_held "$lock_path" && \
        [[ "$(arena_lock_owner_token "$lock_path")" == "resolve-$$" ]]; then
        arena_lock_release "$lock_path" "resolve-$$"
    fi
    exit "$status"
}
trap arena_resolve_cleanup EXIT
arena_lock_acquire "$lock_path" "resolve-$$"
resolve_lock_held=1

# T10-T13 guards and deltas; operates on the in-memory ARENA_STATE_* fields
# (from arena_state_read or a legacy first-migration materialization).
arena_resolve_apply() {
    case "$action" in
        approve)
            { [[ "$ARENA_STATE_PHASE" == decided && \
                "$ARENA_STATE_REASON_CODE" == approval_pending && \
                "$ARENA_STATE_VERDICT" == APPROVE ]]; } || \
                arena_state_die 'approve is allowed only after a reviewer APPROVE'
            ARENA_STATE_RUN_STATUS='completed'
            ARENA_STATE_RESPONSIBLE_PARTY='none'
            ARENA_STATE_REASON_CODE='none'
            ARENA_STATE_REASON_DETAIL="$reason"
            ARENA_STATE_WAITING_SINCE=''
            ;;
        reject)
            { [[ "$ARENA_STATE_PHASE" == decided && \
                ( "$ARENA_STATE_REASON_CODE" == approval_pending || \
                    "$ARENA_STATE_REASON_CODE" == block_resolution_required ) ]]; } || \
                arena_state_die 'reject is not allowed from this state'
            ARENA_STATE_RUN_STATUS='active'
            ARENA_STATE_RESPONSIBLE_PARTY='writer'
            ARENA_STATE_REASON_CODE='human_changes_requested'
            ARENA_STATE_REASON_DETAIL="$reason"
            ARENA_STATE_WAITING_SINCE="$(date +%s)"
            ;;
        recover)
            { [[ "$ARENA_STATE_RUN_STATUS" == blocked && \
                "$ARENA_STATE_REASON_CODE" == reviewer_unreachable ]]; } || \
                arena_state_die 'recover handles operational escalation only, never a formal BLOCKED verdict'
            # Reachability precondition: a live reviewer-agent pane in a
            # running session. Refusal prints the two-step prerequisite.
            # The liveness probe runs in a command substitution so its
            # failure is contained (the helper exits on an unavailable
            # pane) and the refusal path below reports it.
            if ! command -v tmux >/dev/null 2>&1 || \
                ! tmux has-session -t "=${ARENA_MANIFEST_SESSION_NAME}" 2>/dev/null || \
                ! reviewer_pane="$(arena_find_live_pane "$ARENA_MANIFEST_SESSION_NAME" reviewer reviewer-agent 2>/dev/null)"; then
                arena_state_die "reviewer pane unreachable; first run: agent-arena resume ${run_id} (respawns the reviewer pane), confirm the trust prompt in the pane, then re-run recover"
            fi
            ARENA_STATE_RUN_STATUS='active'
            ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
            if [[ "$ARENA_STATE_PHASE" == submitted ]]; then
                ARENA_STATE_REASON_CODE='review_pending'
            fi
            if [[ "$ARENA_STATE_PHASE" == validated ]]; then
                ARENA_STATE_REASON_CODE='decision_pending'
            fi
            ARENA_STATE_REASON_DETAIL="$reason"
            ARENA_STATE_WAITING_SINCE="$(date +%s)"
            ;;
        cancel)
            case "$ARENA_STATE_REASON_CODE" in
                approval_pending|block_resolution_required|reviewer_unreachable) ;;
                *) arena_state_die 'cancel is not allowed from this state' ;;
            esac
            ARENA_STATE_RUN_STATUS='canceled'
            ARENA_STATE_RESPONSIBLE_PARTY='none'
            ARENA_STATE_REASON_CODE='none'
            ARENA_STATE_REASON_DETAIL="$reason"
            ARENA_STATE_WAITING_SINCE=''
            ;;
    esac
}

if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == human ]] || arena_state_die \
        "resolve requires human responsibility (current: ${ARENA_STATE_RESPONSIBLE_PARTY})"
    arena_resolve_apply
    ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
else
    # Legacy run: project inside the lock, migrate to v1, and apply the
    # action in the same commit. The legacy disposition maps into the
    # guards: a projected L1 (decided/human/approval_pending, V=APPROVE)
    # admits approve/reject/cancel; a projected legacy BLOCKED (L3) admits
    # reject/cancel. No legacy projection ever yields reviewer_unreachable,
    # so recover has no legacy first-migration path.
    projection_status=0
    arena_state_project_legacy "$run_dir" || projection_status=$?
    [[ "$projection_status" == 0 ]] || exit "$projection_status"
    [[ "$ARENA_PROJECTED_PARTY" == human ]] || arena_state_die \
        "resolve requires human responsibility (legacy projection: ${ARENA_PROJECTED_PARTY})"
    case "${ARENA_PROJECTED_REASON}:${action}" in
        approval_pending:approve|approval_pending:reject|approval_pending:cancel|\
        block_resolution_required:reject|block_resolution_required:cancel) ;;
        *) arena_state_die "legacy projection ${ARENA_PROJECTED_PHASE}/${ARENA_PROJECTED_PARTY}/${ARENA_PROJECTED_REASON} does not admit resolve ${action}" ;;
    esac
    # Materialize the projected semantic state at revision 1 (round sticky
    # unknown), then apply the action delta; the shared guards re-check the
    # materialized fields.
    arena_state_defaults
    ARENA_STATE_PHASE='decided'
    ARENA_STATE_RESPONSIBLE_PARTY='human'
    ARENA_STATE_REASON_CODE="${ARENA_PROJECTED_REASON}"
    ARENA_STATE_VERDICT="${ARENA_PROJECTED_VERDICT}"
    ARENA_STATE_VALIDATION_RESULT="${ARENA_PROJECTED_VR}"
    ARENA_STATE_VALIDATION_DIGEST="${ARENA_PROJECTED_VD}"
    ARENA_STATE_CHECKPOINT_SHA="${ARENA_PROJECTED_CS}"
    ARENA_STATE_CHECKPOINT_ROUND='unknown'
    if [[ "$ARENA_PROJECTED_REASON" == block_resolution_required ]]; then
        ARENA_STATE_RUN_STATUS='blocked'
    fi
    arena_resolve_apply
fi
ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
ARENA_STATE_LAST_TRANSITION_ACTOR="$actor"
ARENA_STATE_LAST_TRANSITION_ACTION="resolve-${action}"
arena_state_write "$run_dir"
arena_lock_release "$lock_path" "resolve-$$"
resolve_lock_held=0
arena_note "resolved ${action} for ${run_id}"
