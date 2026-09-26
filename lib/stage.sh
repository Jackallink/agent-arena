#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"
source "${source_root}/lib/roles_conf.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena stage RUN_ID <intent|spec|plan> [--prompt-text T | --prompt-file F]

Generate the next artifact draft for a pipeline run. The stage session runs
headlessly (sandboxed where the platform allows it) and writes
<stage>-draft.md into the run directory; the human gate reviews it with
`agent-arena artifact`. intent requires the originator's prompt text or
file; later stages take the previous artifact as input.
EOF
}

run_id=''
stage_name=''
prompt_text=''
prompt_file=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --prompt-text)
            [[ $# -ge 2 ]] || arena_die '--prompt-text requires a value'
            [[ -z "$prompt_file" ]] || arena_die '--prompt-text and --prompt-file are mutually exclusive'
            prompt_text="$2"
            shift 2
            ;;
        --prompt-file)
            [[ $# -ge 2 ]] || arena_die '--prompt-file requires a path'
            [[ -z "$prompt_text" ]] || arena_die '--prompt-text and --prompt-file are mutually exclusive'
            prompt_file="$2"
            shift 2
            ;;
        intent|spec|plan)
            [[ -z "$stage_name" ]] || arena_die "stage given twice: $stage_name and $1"
            stage_name="$1"
            shift
            ;;
        *)
            [[ -z "$run_id" ]] || arena_die "unknown option or extra argument: $1"
            run_id="$1"
            shift
            ;;
    esac
done
[[ -n "$run_id" ]] || arena_die 'stage requires RUN_ID'
[[ -n "$stage_name" ]] || arena_die 'stage requires one of: intent, spec, plan'
arena_validate_run_id "$run_id"

run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"

[[ -n "$ARENA_MANIFEST_PIPELINE" ]] || \
    arena_die "run '$run_id' is not a pipeline run (no pipeline in manifest)"
[[ ",$ARENA_MANIFEST_PIPELINE," == *",$stage_name,"* ]] || \
    arena_die "stage '$stage_name' is not part of run '$run_id' pipeline: $ARENA_MANIFEST_PIPELINE"

arena_state_read "$run_dir"
[[ "$ARENA_STATE_RUN_STATUS" == active ]] || \
    arena_die "stage refused on terminal run: $ARENA_STATE_RUN_STATUS"
[[ "$ARENA_STATE_PHASE" == "$stage_name" ]] || \
    arena_die "phase=$ARENA_STATE_PHASE, stage must be $ARENA_STATE_PHASE"
[[ "$ARENA_STATE_REASON_CODE" != stage_generating ]] || \
    arena_die "stage session already generating (phase=$ARENA_STATE_PHASE)"

# intent needs the originator's input on the first attempt only: a
# regeneration after --reject re-enters with the recorded summary.
if [[ "$stage_name" == intent && -z "$prompt_text" && -z "$prompt_file" ]]; then
    case "$stage_name" in
        intent) stage_reg="${ARENA_STAGE_REJECT_SUMMARY[0]}" ;;
        spec) stage_reg="${ARENA_STAGE_REJECT_SUMMARY[1]}" ;;
        plan) stage_reg="${ARENA_STAGE_REJECT_SUMMARY[2]}" ;;
    esac
    if [[ -z "$stage_reg" ]]; then
        arena_die 'stage intent requires --prompt-text or --prompt-file'
    fi
fi
if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || arena_die "prompt file not found: $prompt_file"
    prompt_file="$(cd "$(dirname "$prompt_file")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$prompt_file")")"
fi
[[ -n "$prompt_text" || -z "$prompt_file" ]] || true

# Resolve the stage configuration for this run's repository.
source "${source_root}/lib/roles_conf.sh"
arena_roles_load "$ARENA_MANIFEST_REPOSITORY"
case "$stage_name" in
    intent) stage_adapter="$ARENA_ROLES_intent_ADAPTER" ;;
    spec) stage_adapter="$ARENA_ROLES_spec_ADAPTER" ;;
    plan) stage_adapter="$ARENA_ROLES_plan_ADAPTER" ;;
esac
[[ -n "$stage_adapter" ]] || \
    arena_die "stage '$stage_name' has no enabled adapter in roles.conf"
case "$stage_name" in
    intent) stage_model="$ARENA_ROLES_intent_MODEL" ;;
    spec) stage_model="$ARENA_ROLES_spec_MODEL" ;;
    plan) stage_model="$ARENA_ROLES_plan_MODEL" ;;
esac
case "$stage_name" in
    intent) stage_template="$ARENA_ROLES_intent_PROMPT_RESOLVED" ;;
    spec) stage_template="$ARENA_ROLES_spec_PROMPT_RESOLVED" ;;
    plan) stage_template="$ARENA_ROLES_plan_PROMPT_RESOLVED" ;;
esac

# Lock: a live owner refuses; a dead owner is reclaimed (audit key below).
lock_path="${run_dir}/.run-lock"
recovered_at=''
if arena_lock_is_held "$lock_path"; then
    if arena_lock_owner_alive "$lock_path"; then
        arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
    fi
    recovered_at="$(date +%s)"
fi
arena_lock_acquire "$lock_path" "stage-$$"

# Compose attachments: template + previous accepted artifact + prompt input
# (+ regeneration context after a reject).
attach=''
attach="${attach}${stage_template}"
prev_stage=''
case "$stage_name" in
    spec) prev_stage='intent' ;;
    plan) prev_stage='spec' ;;
esac
if [[ -n "$prev_stage" && -f "${run_dir}/${prev_stage}.md" ]]; then
    attach="${attach} ${run_dir}/${prev_stage}.md"
fi
if [[ -n "$prompt_file" ]]; then
    attach="${attach} ${prompt_file}"
elif [[ -n "$prompt_text" ]]; then
    prompt_file="${run_dir}/prompt-${stage_name}.txt"
    printf '%s\n' "$prompt_text" >"$prompt_file"
    attach="${attach} ${prompt_file}"
fi
case "$stage_name" in
    intent) reject_summary="${ARENA_STAGE_REJECT_SUMMARY[0]}" ;;
    spec) reject_summary="${ARENA_STAGE_REJECT_SUMMARY[1]}" ;;
    plan) reject_summary="${ARENA_STAGE_REJECT_SUMMARY[2]}" ;;
esac
if [[ -n "$reject_summary" ]]; then
    regen_context="${run_dir}/regen-${stage_name}.md"
    {
        printf '# Regeneration context\n\n'
        printf 'The previous %s draft was rejected with this summary:\n\n' "$stage_name"
        printf '> %s\n\n' "$reject_summary"
        if [[ -f "${run_dir}/${stage_name}-draft.md" ]]; then
            printf '## Previous draft (for reference)\n\n'
            cat "${run_dir}/${stage_name}-draft.md"
            printf '\n'
        fi
    } >"$regen_context"
    attach="${attach} ${regen_context}"
fi

case "$stage_name" in
    intent) stage_attempts="${ARENA_STAGE_ATTEMPTS[0]}" ;;
    spec) stage_attempts="${ARENA_STAGE_ATTEMPTS[1]}" ;;
    plan) stage_attempts="${ARENA_STAGE_ATTEMPTS[2]}" ;;
esac
next_attempt=$(( stage_attempts + 1 ))
sandbox_bin="${ARENA_STAGE_SANDBOX_BIN:-sandbox-exec}"
if command -v "$sandbox_bin" >/dev/null 2>&1; then
    sandbox_mode='seatbelt'
else
    sandbox_mode='soft'
    # The adapter enforces the same message when it discovers the missing
    # binary; surface it here too so the human gate sees it in the stage
    # command output (it also lands in the session .err record).
    printf 'agent-arena: STAGE SANDBOX UNAVAILABLE — soft constraints only (adapter tools gate: read,write)\n' >&2
fi

instruction="Produce the ${stage_name} artifact for Agent Arena run ${run_id}.
Write your draft to ${run_dir}/${stage_name}-draft.md (plain markdown).
The attached files carry the prompt template and the inputs you need.
Do not modify anything outside that draft file."

mkdir -p "${run_dir}/sessions"
upsert_args=(
    "stage_${stage_name}_status" 'generating'
    "stage_${stage_name}_attempts" "$next_attempt"
    "stage_${stage_name}_agent" "$stage_adapter"
    "stage_${stage_name}_model" "$stage_model"
    "stage_${stage_name}_sandbox" "$sandbox_mode"
)
if [[ -n "$recovered_at" ]]; then
    upsert_args+=("stage_${stage_name}_recovered_at" "$recovered_at")
fi
arena_manifest_upsert "$run_dir" "${upsert_args[@]}"

ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
    "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=active" \
    "phase=$stage_name" \
    "responsible_party=none" \
    "reason_code=stage_generating" \
    "reason_detail=" \
    "verdict=" \
    "validation_result=" \
    "checkpoint_round=0" \
    "checkpoint_sha=" \
    "waiting_since=" \
    "last_transition_at=$(date +%s)" \
    "last_transition_actor=human" \
    "last_transition_action=stage" \
    "validation_digest="

export ARENA_RUN_DIR="$run_dir"
export ARENA_RUN_ID="$run_id"
export ARENA_STAGE="$stage_name"
export ARENA_STAGE_ATTEMPT="$next_attempt"
export ARENA_STAGE_ROLE="You are the ${stage_name} drafter for Agent Arena run ${run_id}. Write files only when instructed."
export ARENA_STAGE_INSTRUCTION="$instruction"
export ARENA_STAGE_ATTACH="${attach# }"
export ARENA_STAGE_SESSION_DIR="${run_dir}/sessions"
export ARENA_STAGE_MODEL_ARG="$stage_model"
export ARENA_STAGE_SANDBOX_MODE="$sandbox_mode"
export ARENA_STAGE_SANDBOX_BIN="$sandbox_bin"

session_log="${run_dir}/sessions/${stage_name}-a${next_attempt}.jsonl"
set +e
bash "${source_root}/adapters/${stage_adapter}.sh" stage-launch \
    >"$session_log" 2>"${session_log}.err"
stage_exit=$?
set -e

draft_path="${run_dir}/${stage_name}-draft.md"
arena_lock_release "$lock_path" "stage-$$"

now="$(date +%s)"
if [[ "$stage_exit" == 0 && -s "$draft_path" ]]; then
    arena_manifest_upsert "$run_dir" \
        "stage_${stage_name}_status" 'awaiting_accept' \
        "stage_${stage_name}_draft" "${stage_name}-draft.md"
    ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
        "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=active" \
        "phase=$stage_name" \
        "responsible_party=human" \
        "reason_code=awaiting_stage_accept" \
        "reason_detail=" \
        "verdict=" \
        "validation_result=" \
        "checkpoint_round=0" \
        "checkpoint_sha=" \
        "waiting_since=$now" \
        "last_transition_at=$now" \
        "last_transition_actor=human" \
        "last_transition_action=stage" \
        "validation_digest="
    printf 'stage %s: draft ready for review (%s)\n' "$run_id" "$draft_path"
    printf 'next: agent-arena artifact %s --stage %s --accept | --reject --summary "..."\n' "$run_id" "$stage_name"
    exit 0
fi

# Failure harvest: the command itself succeeded; the session did not.
fail_reason="session exit ${stage_exit}"
[[ -s "$draft_path" ]] || fail_reason="no draft produced (session exit ${stage_exit})"
arena_manifest_upsert "$run_dir" \
    "stage_${stage_name}_status" 'failed' \
    "stage_${stage_name}_draft" ''
ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
    "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=active" \
    "phase=$stage_name" \
    "responsible_party=human" \
    "reason_code=stage_failed" \
    "reason_detail=${fail_reason}" \
    "verdict=" \
    "validation_result=" \
    "checkpoint_round=0" \
    "checkpoint_sha=" \
    "waiting_since=$now" \
    "last_transition_at=$now" \
    "last_transition_actor=human" \
    "last_transition_action=stage" \
    "validation_digest="
printf 'stage %s: %s\n' "$run_id" "$fail_reason"
printf 'session log: %s\n' "$session_log"
printf 'retry: agent-arena stage %s %s\n' "$run_id" "$stage_name"
exit 0
