#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"
source "${source_root}/lib/bootstrap.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena artifact RUN_ID --stage <intent|spec|plan> (--accept | --reject --summary T | --show)

Human gate over one generated artifact draft. --accept records the on-disk
sha256 digest, renames <stage>-draft.md to <stage>.md, and advances the
pipeline (the final accept bootstraps the implementation worktree).
--reject records the summary and re-arms the stage; the summary re-enters
the next generation attempt as reviewer feedback. --show prints the draft
verbatim to stdout (read-only; works whenever the draft file exists).
EOF
}

run_id=''
stage_name=''
accept=0
reject=0
show=0
summary=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        --stage)
            [[ $# -ge 2 ]] || arena_die '--stage requires a value'
            case "$2" in
                intent|spec|plan) ;;
                *) arena_die "invalid --stage: $2 (legal values: intent, spec, plan)" ;;
            esac
            stage_name="$2"
            shift 2
            ;;
        --accept)
            [[ "$reject" == 0 && "$show" == 0 ]] || arena_die '--accept, --reject, and --show are mutually exclusive'
            accept=1
            shift
            ;;
        --reject)
            [[ "$accept" == 0 && "$show" == 0 ]] || arena_die '--accept, --reject, and --show are mutually exclusive'
            reject=1
            shift
            ;;
        --show)
            [[ "$accept" == 0 && "$reject" == 0 ]] || arena_die '--accept, --reject, and --show are mutually exclusive'
            show=1
            shift
            ;;
        --summary)
            [[ $# -ge 2 ]] || arena_die '--summary requires a value'
            summary="$2"
            shift 2
            ;;
        -*)
            arena_die "unknown option: $1"
            ;;
        *)
            [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'
            run_id="$1"
            shift
            ;;
    esac
done
[[ -n "$run_id" ]] || arena_die 'artifact requires RUN_ID'
arena_validate_run_id "$run_id"
[[ -n "$stage_name" ]] || arena_die 'artifact requires --stage'
(( accept + reject + show == 1 )) || arena_die 'artifact requires exactly one of --accept, --reject, --show'
if [[ "$reject" == 1 ]]; then
    [[ -n "$summary" ]] || arena_die '--reject requires --summary'
    (( ${#summary} <= 256 )) || arena_die 'reject summary exceeds 256 characters'
    arena_reject_control_characters "$summary"
    [[ "$summary" != *$'\t'* ]] || arena_die 'reject summary may not contain tabs'
fi

run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
[[ -n "$ARENA_MANIFEST_PIPELINE" ]] || \
    arena_die "run '$run_id' is not a pipeline run (no pipeline in manifest)"

arena_state_read "$run_dir"
[[ "$ARENA_STATE_RUN_STATUS" == active ]] || \
    arena_die "artifact refused on terminal run: $ARENA_STATE_RUN_STATUS"
# Phase match first: the operator-facing mismatch message carries the
# current phase even when the requested stage is outside the pipeline.
[[ "$ARENA_STATE_PHASE" == "$stage_name" ]] || \
    arena_die "phase=$ARENA_STATE_PHASE, artifact --stage must match the current phase"
[[ ",$ARENA_MANIFEST_PIPELINE," == *",$stage_name,"* ]] || \
    arena_die "stage '$stage_name' is not part of run '$run_id' pipeline: $ARENA_MANIFEST_PIPELINE"
[[ "$ARENA_STATE_REASON_CODE" == awaiting_stage_accept || "$ARENA_STATE_REASON_CODE" == awaiting_stage_start ]] || \
    arena_die "artifact gate not open (reason_code=$ARENA_STATE_REASON_CODE)"

draft_path="${run_dir}/${stage_name}-draft.md"

# --show is read-only: it skips the gate reason_code check (the draft is
# inspectable at any point of its stage phase) and never mutates state.
if [[ "$show" == 1 ]]; then
    [[ -f "$draft_path" ]] || arena_die "no draft to show: $draft_path (stage not generated yet?)"
    cat "$draft_path"
    exit 0
fi

case "$stage_name" in
    intent) stage_status="${ARENA_STAGE_STATUS[0]}" ;;
    spec) stage_status="${ARENA_STAGE_STATUS[1]}" ;;
    plan) stage_status="${ARENA_STAGE_STATUS[2]}" ;;
esac
last_stage="${ARENA_MANIFEST_PIPELINE##*,}"

if [[ "$stage_status" == accepted ]]; then
    # Crash recovery: bookkeeping committed, bootstrap did not run.
    arena_die "stage '$stage_name' is already accepted"
fi

if [[ "$accept" == 1 ]]; then
    [[ -f "$draft_path" ]] || \
        arena_die "no ${stage_name} draft to accept (run: agent-arena stage ${run_id} ${stage_name})"
    if [[ "$stage_status" != awaiting_accept ]]; then
        arena_die "stage '$stage_name' has no draft awaiting review (status: $stage_status)"
    fi
    digest="$(arena_file_hash "$draft_path")"
    lock_path="${run_dir}/.run-lock"
    recovered_at=''
    if arena_lock_is_held "$lock_path"; then
        if arena_lock_owner_alive "$lock_path"; then
            arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
        fi
        recovered_at="$(date +%s)"
    fi
    arena_lock_acquire "$lock_path" "artifact-$$"
    upsert_args=(
        "stage_${stage_name}_status" 'accepted'
        "stage_${stage_name}_draft" ''
        "stage_${stage_name}_digest" "$digest"
        "stage_${stage_name}_accepted_at" "$(date +%s)"
        "stage_${stage_name}_reject_summary" ''
    )
    if [[ -n "$recovered_at" ]]; then
        upsert_args+=("stage_${stage_name}_recovered_at" "$recovered_at")
    fi
    arena_manifest_upsert "$run_dir" "${upsert_args[@]}"
    mv "$draft_path" "${run_dir}/${stage_name}.md"
    arena_lock_release "$lock_path" "artifact-$$"

    printf 'artifact %s %s: accepted (sha256 %s)\n' "$run_id" "$stage_name" "$(arena_short_sha "$digest")"
    if [[ "$stage_name" != "$last_stage" ]]; then
        next_stage=''
        case "$stage_name" in
            intent) next_stage='spec' ;;
            spec) next_stage='plan' ;;
        esac
        now="$(date +%s)"
        arena_lock_acquire "$lock_path" "artifact-$$"
        ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
        arena_state_write "$run_dir" \
            "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
            "state_revision=${ARENA_STATE_REVISION}" \
            "run_status=active" \
            "phase=$next_stage" \
            "responsible_party=human" \
            "reason_code=awaiting_stage_start" \
            "reason_detail=" \
            "verdict=" \
            "validation_result=" \
            "checkpoint_round=0" \
            "checkpoint_sha=" \
            "waiting_since=$now" \
            "last_transition_at=$now" \
            "last_transition_actor=human" \
            "last_transition_action=artifact" \
            "validation_digest="
        arena_lock_release "$lock_path" "artifact-$$"
        printf 'next: agent-arena stage %s %s\n' "$run_id" "$next_stage"
    else
        # Final stage: the deferred implementation bootstrap (two-phase
        # start, walkthrough F3). The run lock is free here; bootstrap
        # takes parent → run in the start lock order.
        arena_implementation_bootstrap "$run_dir"
    fi
    exit 0
fi

# --reject: the draft stays on disk as regeneration context; the summary
# re-enters the next attempt via the stage command.
[[ -f "$draft_path" ]] || \
    arena_die "no ${stage_name} draft to reject (run: agent-arena stage ${run_id} ${stage_name})"
lock_path="${run_dir}/.run-lock"
recovered_at=''
if arena_lock_is_held "$lock_path"; then
    if arena_lock_owner_alive "$lock_path"; then
        arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
    fi
    recovered_at="$(date +%s)"
fi
arena_lock_acquire "$lock_path" "artifact-$$"
upsert_args=(
    "stage_${stage_name}_status" 'pending'
    "stage_${stage_name}_reject_summary" "$summary"
)
if [[ -n "$recovered_at" ]]; then
    upsert_args+=("stage_${stage_name}_recovered_at" "$recovered_at")
fi
arena_manifest_upsert "$run_dir" "${upsert_args[@]}"
now="$(date +%s)"
ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
    "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=active" \
    "phase=$stage_name" \
    "responsible_party=human" \
    "reason_code=awaiting_stage_start" \
    "reason_detail=" \
    "verdict=" \
    "validation_result=" \
    "checkpoint_round=0" \
    "checkpoint_sha=" \
    "waiting_since=$now" \
    "last_transition_at=$now" \
    "last_transition_actor=human" \
    "last_transition_action=artifact" \
    "validation_digest="
arena_lock_release "$lock_path" "artifact-$$"

printf 'artifact %s %s: rejected\n' "$run_id" "$stage_name"
printf 'next: agent-arena stage %s %s\n' "$run_id" "$stage_name"
