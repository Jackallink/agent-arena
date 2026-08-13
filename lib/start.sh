#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/config.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena start RUN_ID [options]

Create or resume one isolated writer + Cursor gate run.

Options:
  --run-id ID             Alternative to the positional RUN_ID
  --repo PATH             Integration Git worktree (default: current directory)
  --profile NAME          pi-cursor, codex-cursor, opencode-cursor, or gemini-cursor
                           (default: pi-cursor)
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
run_dir="${state_root}/runs/${repo_id}/${run_id}"
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
if [[ -e "$run_dir" || -L "$run_dir" ]]; then
    arena_read_manifest "$run_dir"
    [[ "$ARENA_MANIFEST_RUN_ID" == "$run_id" ]] || arena_die 'run manifest id does not match requested run'
    arena_same_directory "$ARENA_MANIFEST_REPOSITORY" "$repository" || \
        arena_die 'run belongs to a different integration worktree'
    if [[ "$profile_explicit" == 1 && "$profile" != "$ARENA_MANIFEST_PROFILE" ]]; then
        arena_die "existing run uses profile ${ARENA_MANIFEST_PROFILE}, not $profile"
    fi
    profile="$ARENA_MANIFEST_PROFILE"
    arena_profile_resolve "$profile"
    writer_adapter="$ARENA_PROFILE_WRITER_ADAPTER"
    writer_label="$ARENA_PROFILE_WRITER_LABEL"
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
else
    arena_profile_resolve "$profile"
    writer_adapter="$ARENA_PROFILE_WRITER_ADAPTER"
    writer_label="$ARENA_PROFILE_WRITER_LABEL"
    branch="$(arena_profile_branch "$writer_adapter" "$run_id")"
    writer_session_dir="${run_dir}/writer-session"

    # Probe every selected executable before any state or worktree is created.
    "${source_root}/adapters/${writer_adapter}.sh" probe || \
        arena_die "${writer_label} executable not found for profile $profile"
    "${source_root}/adapters/cursor.sh" probe || \
        arena_die "Cursor Agent executable not found: ${ARENA_CURSOR_BIN:-agent}"

    arena_assert_clean_worktree "$repository"
    git -C "$repository" rev-parse --verify HEAD >/dev/null 2>&1 || \
        arena_die 'integration worktree needs an initial commit before starting a run'
    git show-ref --verify --quiet "refs/heads/${branch}" && \
        arena_die "branch already exists without a matching run manifest: $branch"
    [[ ! -e "$writer_worktree" && ! -L "$writer_worktree" ]] || \
        arena_die "writer worktree path already exists: $writer_worktree"

    base_sha="$(git -C "$repository" rev-parse HEAD)"
    arena_make_private_dir "$run_dir"
    arena_make_private_dir "$writer_session_dir"
    arena_make_private_dir "$writer_root"
    git -C "$repository" worktree add -b "$branch" "$writer_worktree" "$base_sha"
    arena_write_manifest "$run_dir" "$run_id" "$repository" "$base_sha" \
        "$writer_worktree" "$branch" "$session_name" "$source_root" "$worktree_root" \
        "$ARENA_PROJECT_CONFIG" "$profile" "$writer_adapter" "$writer_label" \
        "$writer_session_dir"
    review_worktree=''
fi

# Existing runs must also refuse to launch when their selected writer or the
# mandatory Cursor gate is no longer available.
"${source_root}/adapters/${writer_adapter}.sh" probe || \
    arena_die "${writer_label} executable not found for profile $profile"
"${source_root}/adapters/cursor.sh" probe || \
    arena_die "Cursor Agent executable not found: ${ARENA_CURSOR_BIN:-agent}"
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
export ARENA_GEMINI_BIN="${ARENA_GEMINI_BIN:-gemini}"
export ARENA_CURSOR_BIN="${ARENA_CURSOR_BIN:-agent}"

arena_update_live_session_environment() {
    local environment_name
    local environment_value

    for environment_name in \
        ARENA_SOURCE_ROOT ARENA_COMMAND ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR \
        ARENA_STATE_ROOT ARENA_WRITER_WORKTREE ARENA_WRITER_SESSION_DIR \
        ARENA_REVIEW_WORKTREE ARENA_SESSION_NAME ARENA_LOG_PANES ARENA_PROFILE \
        ARENA_WRITER_ADAPTER ARENA_WRITER_LABEL ARENA_TEST_MODE ARENA_PI_BIN \
        ARENA_CODEX_BIN ARENA_OPENCODE_BIN ARENA_GEMINI_BIN ARENA_CURSOR_BIN; do
        environment_value="${!environment_name}"
        tmux set-environment -t "=${session_name}" "$environment_name" "$environment_value"
    done
}

if tmux has-session -t "=${session_name}" 2>/dev/null; then
    # A v0.1 session may still have panes based on the old template. Update its
    # session environment before any submit-triggered pane respawn uses v0.2.
    arena_update_live_session_environment
    arena_note "session already exists: $session_name"
    if [[ "$attach" == 1 ]]; then
        exec tmux attach-session -t "=${session_name}"
    fi
    exit 0
fi

tmuxp load --yes --no-progress -d -s "$session_name" "$configuration"
arena_note "run '$run_id' is ready"
arena_note "${writer_label} writer worktree: $writer_worktree"
arena_note "Run state and audit records: $run_dir"
if [[ "$attach" == 1 ]]; then
    exec tmux attach-session -t "=${session_name}"
fi
