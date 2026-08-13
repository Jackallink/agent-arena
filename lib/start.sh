#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/config.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena start RUN_ID [options]

Create or resume a Pi writer + Cursor gate run.

Options:
  --run-id ID             Alternative to the positional RUN_ID
  --repo PATH             Integration Git worktree (default: current directory)
  --profile NAME          Only pi-cursor is enabled in v0.1 (default: pi-cursor)
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
        -* ) arena_die "unknown option: $1" ;;
        *)
            [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'
            run_id="$1"
            shift
            ;;
    esac
done

[[ -n "$run_id" ]] || arena_die 'start requires RUN_ID'
[[ "$profile" == pi-cursor ]] || arena_die "profile '$profile' is planned or unknown; only pi-cursor is enabled"
arena_validate_run_id "$run_id"
arena_require_command git
arena_require_command tmux
arena_require_command tmuxp
"${source_root}/adapters/pi.sh" probe || arena_die "Pi executable not found: ${ARENA_PI_BIN:-pi}"
"${source_root}/adapters/cursor.sh" probe || arena_die "Cursor Agent executable not found: ${ARENA_CURSOR_BIN:-agent}"

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
branch="agent-arena/pi/${run_id}"
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
    [[ "$ARENA_MANIFEST_BRANCH" == "$branch" ]] || arena_die 'run branch does not match requested run'
    arena_assert_worktree "$ARENA_MANIFEST_WRITER_WORKTREE"
    [[ "$(git -C "$ARENA_MANIFEST_WRITER_WORKTREE" branch --show-current)" == "$branch" ]] || \
        arena_die "writer worktree is not on expected branch $branch"
    base_sha="$ARENA_MANIFEST_BASE_SHA"
    writer_worktree="$ARENA_MANIFEST_WRITER_WORKTREE"
    session_name="$ARENA_MANIFEST_SESSION_NAME"
    if [[ -f "${run_dir}/review.tsv" ]]; then
        arena_read_review_manifest "$run_dir"
        review_worktree="$ARENA_REVIEW_WORKTREE"
    else
        review_worktree=''
    fi
else
    arena_assert_clean_worktree "$repository"
    git -C "$repository" rev-parse --verify HEAD >/dev/null 2>&1 || \
        arena_die 'integration worktree needs an initial commit before starting a run'
    git show-ref --verify --quiet "refs/heads/${branch}" && \
        arena_die "branch already exists without a matching run manifest: $branch"
    [[ ! -e "$writer_worktree" && ! -L "$writer_worktree" ]] || \
        arena_die "writer worktree path already exists: $writer_worktree"

    base_sha="$(git -C "$repository" rev-parse HEAD)"
    arena_make_private_dir "$run_dir"
    arena_make_private_dir "${run_dir}/pi-session"
    arena_make_private_dir "$writer_root"
    git -C "$repository" worktree add -b "$branch" "$writer_worktree" "$base_sha"
    arena_write_manifest "$run_dir" "$run_id" "$repository" "$base_sha" \
        "$writer_worktree" "$branch" "$session_name" "$source_root" "$worktree_root" \
        "$ARENA_PROJECT_CONFIG"
    review_worktree=''
fi

arena_make_private_dir "${run_dir}/pi-session"
export ARENA_REPOSITORY="$repository"
export ARENA_RUN_ID="$run_id"
export ARENA_RUN_DIR="$run_dir"
export ARENA_STATE_ROOT="$state_root"
export ARENA_WRITER_WORKTREE="$writer_worktree"
export ARENA_PI_SESSION_DIR="${run_dir}/pi-session"
export ARENA_REVIEW_WORKTREE="$review_worktree"
export ARENA_SESSION_NAME="$session_name"
export ARENA_LOG_PANES="$log_panes"
export ARENA_PROFILE="$profile"
export ARENA_TEST_MODE="${ARENA_TEST_MODE:-0}"
export ARENA_PI_BIN="${ARENA_PI_BIN:-pi}"
export ARENA_CURSOR_BIN="${ARENA_CURSOR_BIN:-agent}"

if tmux has-session -t "=${session_name}" 2>/dev/null; then
    arena_note "session already exists: $session_name"
    if [[ "$attach" == 1 ]]; then
        exec tmux attach-session -t "=${session_name}"
    fi
    exit 0
fi

tmuxp load --yes --no-progress -d -s "$session_name" "$configuration"
arena_note "run '$run_id' is ready"
arena_note "Pi writer worktree: $writer_worktree"
arena_note "Run state and audit records: $run_dir"
if [[ "$attach" == 1 ]]; then
    exec tmux attach-session -t "=${session_name}"
fi
