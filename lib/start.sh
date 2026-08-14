#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/config.sh"
source "${source_root}/lib/state.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena start RUN_ID [options]

Create or resume one isolated writer + gate run.

Options:
  --run-id ID             Alternative to the positional RUN_ID
  --repo PATH             Integration Git worktree (default: current directory)
  --profile NAME          WRITER-GATE combination such as pi-cursor or
                           pi-opencode (default: pi-cursor)
  --writer NAME           Writer adapter: pi, codex, opencode, or agy (with --gate)
  --gate NAME             Gate adapter: cursor or opencode (with --writer)
  --state-root PATH       Private run-state root override
  --worktree-root PATH    Private worktree root override
  --log-panes             Opt in to raw terminal logs in the private run directory
  --no-attach             Create the tmux session detached
  -h, --help              Show this help

The integration tree must be clean when a new run is created. Agent Arena never
fetches, stashes, resets, merges, pushes, or automatically removes worktrees.
EOF
}

repository='.'
run_id=''
profile='pi-cursor'
profile_explicit=0
writer_arg=''
gate_arg=''
writer_explicit=0
gate_explicit=0
attach=1
log_panes=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)
            [[ $# -ge 2 ]] || arena_die '--run-id requires a value'
            run_id="$2"
            shift 2
            ;;
        --repo)
            [[ $# -ge 2 ]] || arena_die '--repo requires a path'
            repository="$2"
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || arena_die '--profile requires a value'
            profile="$2"
            profile_explicit=1
            shift 2
            ;;
        --writer)
            [[ $# -ge 2 ]] || arena_die '--writer requires a value'
            writer_arg="$2"
            writer_explicit=1
            shift 2
            ;;
        --gate)
            [[ $# -ge 2 ]] || arena_die '--gate requires a value'
            gate_arg="$2"
            gate_explicit=1
            shift 2
            ;;
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        --worktree-root)
            [[ $# -ge 2 ]] || arena_die '--worktree-root requires a path'
            ARENA_WORKTREE_ROOT="$2"
            shift 2
            ;;
        --log-panes)
            log_panes=1
            shift
            ;;
        --no-attach)
            attach=0
            shift
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

if [[ "$writer_explicit" == 1 || "$gate_explicit" == 1 ]]; then
    [[ "$profile_explicit" == 0 ]] || arena_die '--profile cannot be combined with --writer/--gate'
fi
if [[ "$writer_explicit" == 1 && "$gate_explicit" == 1 ]]; then
    profile="${writer_arg}-${gate_arg}"
fi

[[ -n "$run_id" ]] || arena_die 'start requires RUN_ID'
arena_validate_run_id "$run_id"
arena_require_command git
arena_require_command tmux
arena_require_command tmuxp

[[ -d "$repository" ]] || arena_die "repository path does not exist: $repository"
repository="$(arena_abs_dir "$repository")"
git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    arena_die "not a Git repository: $repository"
[[ "$(git -C "$repository" rev-parse --show-toplevel)" == "$repository" ]] || \
    arena_die '--repo must be the integration Git worktree root'
arena_load_project_config "$repository"

state_root="$(arena_state_root)"
worktree_root="$(arena_worktree_root)"
repo_id="$(arena_repo_id "$repository")"
runs_root="${state_root}/runs"
repo_runs_dir="${runs_root}/${repo_id}"
run_dir="${repo_runs_dir}/${run_id}"
writer_root="${worktree_root}/${repo_id}/${run_id}"
writer_worktree="${writer_root}/writer"
session_name="agent-arena-${repo_id}-${run_id}"
configuration="${source_root}/templates/tmuxp/arena.yaml"

[[ -f "$configuration" ]] || arena_die "tmuxp configuration not found: $configuration"
for value in "$repository" "$state_root" "$worktree_root" "$run_dir" "$writer_worktree" \
    "$source_root" "$session_name" "$ARENA_PROJECT_CONFIG"; do
    arena_reject_control_characters "$value"
    [[ "$value" != *'"'* && "$value" != *\\* ]] || \
        arena_die 'tmuxp-bound paths may not contain double quotes or backslashes'
done

umask 077

# T1r: read a creation intent tolerantly. The canonical writer emits
# key=value lines; a partially rewritten intent may carry bare key<TAB>value
# lines. Both forms bind fields for the retry comparison; a line with neither
# separator is corrupted and fails closed.
arena_start_read_intent() {
    local line key value

    ARENA_START_INTENT_FIELDS=''
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == *$'\t'* ]]; then
            key="${line%%$'\t'*}"
            value="${line#*$'\t'}"
        else
            key="${line%%=*}"
            value="${line#*=}"
            [[ "$key" != "$line" ]] || arena_die "corrupted creation intent: $intent"
        fi
        ARENA_START_INTENT_FIELDS="$ARENA_START_INTENT_FIELDS $key"
        printf -v "ARENA_START_INTENT_${key}" '%s' "$value"
    done <"$intent"
}

# A retry must bind the SAME parameters and derived inputs as the
# interrupted start. Every field present in the intent is compared verbatim;
# a difference fails closed with exit 2. Fields the intent does not carry are
# tolerated (a crashed partial intent fails closed only on what it binds).
arena_start_verify_intent() {
    local arg key value bound_var bound

    for arg in "$@"; do
        key="${arg%%=*}"
        value="${arg#*=}"
        [[ " $ARENA_START_INTENT_FIELDS " == *" $key "* ]] || continue
        bound_var="ARENA_START_INTENT_${key}"
        bound="${!bound_var:-}"
        [[ "$bound" == "$value" ]] || {
            printf 'agent-arena: start parameters differ from the interrupted run: %s\n' "$key" >&2
            return 1
        }
    done
    return 0
}

parent_lock="${repo_runs_dir}/.parent-lock"
intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
run_lock_held=0
parent_lock_held=0

# Every exit path (arena_die, tmuxp failure, stage refusal) releases any
# lock this process still owns.
arena_start_cleanup() {
    local status=$?

    if [[ "$run_lock_held" == 1 ]] && arena_lock_is_held "${run_dir}/.run-lock" && \
        [[ "$(arena_lock_owner_token "${run_dir}/.run-lock")" == "start-$$" ]]; then
        arena_lock_release "${run_dir}/.run-lock" "start-$$"
    fi
    if [[ "$parent_lock_held" == 1 ]] && arena_lock_is_held "$parent_lock" && \
        [[ "$(arena_lock_owner_token "$parent_lock")" == "start-$$" ]]; then
        arena_lock_release "$parent_lock" "start-$$"
    fi
    exit "$status"
}
trap arena_start_cleanup EXIT

# Priority check: a live run or parent lock wins (exit 4); S3/S4 refuse with
# the manual abort protocol (exit 2); S1/S2/S5/S6 belong to start alone.
arena_state_precheck_intents "$runs_root" "$repo_id" "$run_id" start

intent_stage='NONE'
if [[ -e "$intent" ]]; then
    intent_stage="$(arena_creation_intent_stage "$runs_root" "$repo_id" "$run_id")"
fi

if [[ -e "$run_dir" || -L "$run_dir" ]] && [[ "$intent_stage" != S2 ]]; then
    arena_read_manifest "$run_dir"
    [[ "$ARENA_MANIFEST_RUN_ID" == "$run_id" ]] || arena_die 'run manifest id does not match requested run'
    arena_same_directory "$ARENA_MANIFEST_REPOSITORY" "$repository" || \
        arena_die 'run belongs to a different integration worktree'
    if [[ "$profile_explicit" == 1 && "$profile" != "$ARENA_MANIFEST_PROFILE" ]]; then
        arena_die "existing run uses profile ${ARENA_MANIFEST_PROFILE}, not $profile"
    fi
    if [[ "$writer_explicit" == 1 || "$gate_explicit" == 1 ]]; then
        requested_writer="${writer_arg:-$ARENA_MANIFEST_WRITER_ADAPTER}"
        requested_gate="${gate_arg:-$ARENA_MANIFEST_GATE_ADAPTER}"
        arena_profile_resolve "${requested_writer}-${requested_gate}"
        if [[ "$ARENA_PROFILE_WRITER_ADAPTER" != "$ARENA_MANIFEST_WRITER_ADAPTER" || \
            "$ARENA_PROFILE_GATE_ADAPTER" != "$ARENA_MANIFEST_GATE_ADAPTER" ]]; then
            arena_die "existing run uses writer ${ARENA_MANIFEST_WRITER_ADAPTER} with gate ${ARENA_MANIFEST_GATE_ADAPTER}, not ${requested_writer}-${requested_gate}"
        fi
    fi
    profile="$ARENA_MANIFEST_PROFILE"
    arena_profile_resolve "$profile"
    writer_adapter="$ARENA_PROFILE_WRITER_ADAPTER"
    writer_label="$ARENA_PROFILE_WRITER_LABEL"
    gate_adapter="$ARENA_PROFILE_GATE_ADAPTER"
    export ARENA_GATE_ADAPTER="$gate_adapter"
    branch="$(arena_profile_branch "$writer_adapter" "$run_id")"
    [[ "$ARENA_MANIFEST_BRANCH" == "$branch" ]] || arena_die 'run branch does not match requested profile'
    arena_assert_worktree "$ARENA_MANIFEST_WRITER_WORKTREE"
    [[ "$(git -C "$ARENA_MANIFEST_WRITER_WORKTREE" branch --show-current)" == "$branch" ]] || \
        arena_die "writer worktree is not on expected branch $branch"
    base_sha="$ARENA_MANIFEST_BASE_SHA"
    writer_worktree="$ARENA_MANIFEST_WRITER_WORKTREE"
    writer_session_dir="$ARENA_MANIFEST_WRITER_SESSION_DIR"
    session_name="$ARENA_MANIFEST_SESSION_NAME"
    if [[ -f "${run_dir}/review.tsv" ]]; then
        arena_read_review_manifest "$run_dir"
        review_worktree="$ARENA_REVIEW_WORKTREE"
    else
        review_worktree=''
    fi

    # T1r recovery: S5 commits the T1 state (round=0) exactly once and keeps
    # the existing artifacts; S6 is a crashed intent removal. Both verify the
    # intent against the manifest's record before touching anything, and the
    # S5 commit runs under the run lock.
    if [[ "$intent_stage" == S5 || "$intent_stage" == S6 ]]; then
        arena_start_read_intent
        arena_start_verify_intent \
            "run_id=${run_id}" "repository=${repository}" "state_root=${state_root}" \
            "worktree_root=${worktree_root}" "profile=${profile}" \
            "gate_adapter=${gate_adapter}" "session_name=${session_name}" \
            "base_sha=${base_sha}" "branch=${branch}" "writer_worktree=${writer_worktree}" \
            "writer_adapter_path=${source_root}/adapters/${writer_adapter}.sh" \
            "gate_adapter_path=${source_root}/adapters/gate-${gate_adapter}.sh" || exit 2
        arena_lock_acquire "${run_dir}/.run-lock" "start-$$"
        run_lock_held=1
        if [[ "$intent_stage" == S5 ]]; then
            arena_state_defaults
            arena_state_write "$run_dir" \
                "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
                "state_revision=${ARENA_STATE_REVISION}" \
                "run_status=${ARENA_STATE_RUN_STATUS}" \
                "phase=${ARENA_STATE_PHASE}" \
                "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" \
                "reason_code=${ARENA_STATE_REASON_CODE}" \
                "reason_detail=${ARENA_STATE_REASON_DETAIL}" \
                "verdict=${ARENA_STATE_VERDICT}" \
                "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
                "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" \
                "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
                "waiting_since=${ARENA_STATE_WAITING_SINCE}" \
                "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
                "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" \
                "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
                "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
        fi
        rm -f "$intent"
        arena_lock_release "${run_dir}/.run-lock" "start-$$"
        run_lock_held=0
    fi
else
    if [[ "$writer_explicit" == 1 || "$gate_explicit" == 1 ]]; then
        [[ "$writer_explicit" == 1 && "$gate_explicit" == 1 ]] || \
            arena_die '--writer and --gate must be given together'
    fi
    arena_profile_resolve "$profile"
    writer_adapter="$ARENA_PROFILE_WRITER_ADAPTER"
    writer_label="$ARENA_PROFILE_WRITER_LABEL"
    gate_adapter="$ARENA_PROFILE_GATE_ADAPTER"
    export ARENA_GATE_ADAPTER="$gate_adapter"
    branch="$(arena_profile_branch "$writer_adapter" "$run_id")"
    writer_session_dir="${run_dir}/writer-session"

    # Probe every selected executable before any state or worktree is created.
    "${source_root}/adapters/${writer_adapter}.sh" probe || \
        arena_die "${writer_label} executable not found for profile $profile"
    "${source_root}/adapters/gate-${gate_adapter}.sh" probe || \
        arena_die "gate adapter is not available: ${gate_adapter}"

    arena_assert_clean_worktree "$repository"
    git -C "$repository" rev-parse --verify HEAD >/dev/null 2>&1 || \
        arena_die 'integration worktree needs an initial commit before starting a run'
    git show-ref --verify --quiet "refs/heads/${branch}" && \
        arena_die "branch already exists without a matching run manifest: $branch"
    [[ ! -e "$writer_worktree" && ! -L "$writer_worktree" ]] || \
        arena_die "writer worktree path already exists: $writer_worktree"

    base_sha="$(git -C "$repository" rev-parse HEAD)"

    # T1r (S1/S2): a retry must bind the SAME parameters and derived inputs;
    # any difference fails closed before any lock is taken.
    if [[ "$intent_stage" == S1 || "$intent_stage" == S2 ]]; then
        arena_start_read_intent
        arena_start_verify_intent \
            "run_id=${run_id}" "repository=${repository}" "state_root=${state_root}" \
            "worktree_root=${worktree_root}" "profile=${profile}" \
            "gate_adapter=${gate_adapter}" "session_name=${session_name}" \
            "base_sha=${base_sha}" "branch=${branch}" "writer_worktree=${writer_worktree}" \
            "writer_adapter_path=${source_root}/adapters/${writer_adapter}.sh" \
            "gate_adapter_path=${source_root}/adapters/gate-${gate_adapter}.sh" || exit 2
    fi

    # Creation lock ordering: parent lock → intent → mkdir run_dir →
    # worktree add → run lock → state (T1) → manifest → remove intent →
    # release parent lock → session re-check under the run lock → tmuxp load
    # → release the run lock.
    mkdir -p "$repo_runs_dir"
    arena_lock_acquire "$parent_lock" "start-$$"
    parent_lock_held=1
    arena_creation_intent_write "$runs_root" "$repo_id" "$run_id" \
        "repository=${repository}" "state_root=${state_root}" \
        "worktree_root=${worktree_root}" "profile=${profile}" \
        "gate_adapter=${gate_adapter}" "session_name=${session_name}" \
        "base_sha=${base_sha}" "branch=${branch}" \
        "writer_worktree=${writer_worktree}" \
        "writer_adapter_path=${source_root}/adapters/${writer_adapter}.sh" \
        "gate_adapter_path=${source_root}/adapters/gate-${gate_adapter}.sh"
    arena_make_private_dir "$run_dir"
    arena_make_private_dir "$writer_session_dir"
    arena_make_private_dir "$writer_root"
    git -C "$repository" worktree add -b "$branch" "$writer_worktree" "$base_sha"
    arena_lock_acquire "${run_dir}/.run-lock" "start-$$"
    run_lock_held=1
    arena_state_defaults
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
        "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=${ARENA_STATE_RUN_STATUS}" \
        "phase=${ARENA_STATE_PHASE}" \
        "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" \
        "reason_code=${ARENA_STATE_REASON_CODE}" \
        "reason_detail=${ARENA_STATE_REASON_DETAIL}" \
        "verdict=${ARENA_STATE_VERDICT}" \
        "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
        "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" \
        "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
        "waiting_since=${ARENA_STATE_WAITING_SINCE}" \
        "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
        "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" \
        "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
        "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
    arena_write_manifest "$run_dir" "$run_id" "$repository" "$base_sha" \
        "$writer_worktree" "$branch" "$session_name" "$source_root" "$worktree_root" \
        "$ARENA_PROJECT_CONFIG" "$profile" "$writer_adapter" "$writer_label" \
        "$writer_session_dir" "$gate_adapter"
    rm -f "$intent"
    arena_lock_release "$parent_lock" "start-$$"
    parent_lock_held=0
    review_worktree=''
fi

# Existing runs must also refuse to launch when their selected writer or
# gate adapter is no longer available.
"${source_root}/adapters/${writer_adapter}.sh" probe || \
    arena_die "${writer_label} executable not found for profile $profile"
"${source_root}/adapters/gate-${gate_adapter}.sh" probe || \
    arena_die "gate adapter is not available: ${gate_adapter}"
arena_make_private_dir "$writer_session_dir"

export ARENA_REPOSITORY="$repository"
export ARENA_RUN_ID="$run_id"
export ARENA_RUN_DIR="$run_dir"
export ARENA_STATE_ROOT="$state_root"
export ARENA_WRITER_WORKTREE="$writer_worktree"
export ARENA_WRITER_SESSION_DIR="$writer_session_dir"
export ARENA_REVIEW_WORKTREE="$review_worktree"
export ARENA_SESSION_NAME="$session_name"
export ARENA_LOG_PANES="$log_panes"
export ARENA_PROFILE="$profile"
export ARENA_WRITER_ADAPTER="$writer_adapter"
export ARENA_WRITER_LABEL="$writer_label"
export ARENA_TEST_MODE="${ARENA_TEST_MODE:-0}"
export ARENA_PI_BIN="${ARENA_PI_BIN:-pi}"
export ARENA_CODEX_BIN="${ARENA_CODEX_BIN:-codex}"
export ARENA_OPENCODE_BIN="${ARENA_OPENCODE_BIN:-opencode}"
export ARENA_AGY_BIN="${ARENA_AGY_BIN:-agy}"
export ARENA_CURSOR_BIN="${ARENA_CURSOR_BIN:-agent}"

arena_update_live_session_environment() {
    local environment_name
    local environment_value

    for environment_name in \
        ARENA_SOURCE_ROOT ARENA_COMMAND ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR \
        ARENA_STATE_ROOT ARENA_WRITER_WORKTREE ARENA_WRITER_SESSION_DIR \
        ARENA_REVIEW_WORKTREE ARENA_SESSION_NAME ARENA_LOG_PANES ARENA_PROFILE \
        ARENA_WRITER_ADAPTER ARENA_WRITER_LABEL ARENA_GATE_ADAPTER ARENA_TEST_MODE ARENA_PI_BIN \
        ARENA_CODEX_BIN ARENA_OPENCODE_BIN ARENA_AGY_BIN ARENA_CURSOR_BIN; do
        environment_value="${!environment_name}"
        tmux set-environment -t "=${session_name}" "$environment_name" "$environment_value"
    done
}

if tmux has-session -t "=${session_name}" 2>/dev/null; then
    # A v0.1 session may still have panes based on the old template. Update its
    # session environment before any submit-triggered pane respawn uses v0.2.
    arena_update_live_session_environment
    arena_note "session already exists: $session_name"
    if [[ "$run_lock_held" == 1 ]]; then
        arena_lock_release "${run_dir}/.run-lock" "start-$$"
        run_lock_held=0
    fi
    if [[ "$attach" == 1 ]]; then
        exec tmux attach-session -t "=${session_name}"
    fi
    exit 0
fi

tmuxp_log="$(mktemp "${TMPDIR:-/tmp}/agent-arena-tmuxp.XXXXXX")"
if ! tmuxp load --yes --no-progress -d -s "$session_name" "$configuration" >"$tmuxp_log" 2>&1; then
    # tmuxp wraps the preflight failure in a Python traceback; surface the
    # Arena error (or the last output lines) instead of the raw stack.
    arena_note 'tmuxp failed to create the session; the cause is:'
    if ! grep -E '^agent-arena: ' "$tmuxp_log" | head -8; then
        tail -8 "$tmuxp_log"
    fi
    rm -f "$tmuxp_log"
    arena_die 'tmuxp load failed; fix the reported error and retry start'
fi
rm -f "$tmuxp_log"
if [[ "$run_lock_held" == 1 ]]; then
    arena_lock_release "${run_dir}/.run-lock" "start-$$"
    run_lock_held=0
fi
arena_note "run '$run_id' is ready"
arena_note "${writer_label} writer worktree: $writer_worktree"
arena_note "Run state and audit records: $run_dir"
if [[ "$attach" == 1 ]]; then
    exec tmux attach-session -t "=${session_name}"
fi
