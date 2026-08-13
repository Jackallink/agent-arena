#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

role="${1:-}"
case "$role" in
    control|writer|reviewer|validation) ;;
    *) arena_die 'usage: pane.sh {control|writer|reviewer|validation}' ;;
esac

for variable_name in ARENA_REPOSITORY ARENA_RUN_ID ARENA_RUN_DIR ARENA_WRITER_WORKTREE \
    ARENA_WRITER_SESSION_DIR ARENA_SESSION_NAME ARENA_PROFILE ARENA_WRITER_ADAPTER \
    ARENA_WRITER_LABEL; do
    [[ -n "${!variable_name:-}" ]] || arena_die "missing environment variable $variable_name"
done

enable_pane_log() {
    local log_dir log_file pipe_command

    [[ "${ARENA_LOG_PANES:-0}" == 1 ]] || return 0
    [[ -n "${TMUX_PANE:-}" ]] || return 0
    arena_require_command tmux
    log_dir="${ARENA_RUN_DIR}/logs"
    log_file="${log_dir}/${role}.log"
    arena_make_private_dir "$log_dir"
    : >"$log_file"
    chmod 600 "$log_file"
    printf -v pipe_command 'cat >> %q' "$log_file"
    tmux pipe-pane -o -t "$TMUX_PANE" "$pipe_command"
}

set_pane_mode() {
    [[ -n "${TMUX_PANE:-}" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    tmux set-option -p -t "$TMUX_PANE" @agent_arena_role "$role" >/dev/null 2>&1 || return 0
    tmux set-option -p -t "$TMUX_PANE" @agent_arena_mode "$1" >/dev/null 2>&1 || return 0
}

launch_shell() {
    exec "${SHELL:-/bin/zsh}" -l
}

enable_pane_log
set_pane_mode initializing

if [[ "${ARENA_TEST_MODE:-0}" == 1 ]]; then
    set_pane_mode test
    printf 'role=%s\nprofile=%s\nwriter_adapter=%s\nrepository=%s\nwriter_worktree=%s\nrun_dir=%s\n' \
        "$role" "$ARENA_PROFILE" "$ARENA_WRITER_ADAPTER" "$ARENA_REPOSITORY" \
        "$ARENA_WRITER_WORKTREE" "$ARENA_RUN_DIR"
    exit 0
fi

case "$role" in
    control)
        set_pane_mode control-shell
        cd "$ARENA_REPOSITORY"
        cat <<EOF
Agent Arena integration control
  Repository: $ARENA_REPOSITORY
  Run:        $ARENA_RUN_ID
  Writer:     $ARENA_WRITER_LABEL ($ARENA_WRITER_WORKTREE)

This is the human integration worktree. Agents must not write here.
Useful commands:
  $ARENA_COMMAND status $ARENA_RUN_ID
  $ARENA_COMMAND submit $ARENA_RUN_ID
EOF
        launch_shell
        ;;
    writer)
        set_pane_mode writer-agent
        arena_read_manifest "$ARENA_RUN_DIR"
        [[ "$ARENA_MANIFEST_PROFILE" == "$ARENA_PROFILE" ]] || \
            arena_die 'writer pane profile differs from manifest'
        [[ "$ARENA_MANIFEST_WRITER_ADAPTER" == "$ARENA_WRITER_ADAPTER" ]] || \
            arena_die 'writer pane adapter differs from manifest'
        [[ "$ARENA_MANIFEST_WRITER_LABEL" == "$ARENA_WRITER_LABEL" ]] || \
            arena_die 'writer pane label differs from manifest'
        arena_same_directory "$ARENA_MANIFEST_WRITER_SESSION_DIR" "$ARENA_WRITER_SESSION_DIR" || \
            arena_die 'writer pane session directory differs from manifest'
        exec "${source_root}/adapters/${ARENA_MANIFEST_WRITER_ADAPTER}.sh" launch
        ;;
    reviewer)
        set_pane_mode reviewer-agent
        arena_read_manifest "$ARENA_RUN_DIR"
        if [[ -n "${ARENA_REVIEW_WORKTREE:-}" ]]; then
            review_worktree="$ARENA_REVIEW_WORKTREE"
            arena_assert_worktree "$review_worktree"
            arena_read_review_manifest "$ARENA_RUN_DIR"
            arena_same_directory "$ARENA_REVIEW_WORKTREE" "$review_worktree" || \
                arena_die 'review worktree differs from its manifest'
            arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
                "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
                "$ARENA_REVIEW_GATE_POLICY_PATH" || \
                arena_die 'review snapshot is not an intact submitted checkpoint'
            export ARENA_GATE_WORKSPACE="$ARENA_REVIEW_WORKTREE"
            export ARENA_GATE_PHASE=review
        else
            export ARENA_GATE_WORKSPACE="$ARENA_WRITER_WORKTREE"
            export ARENA_GATE_PHASE=intake
        fi
        arena_gate_resolve "$ARENA_MANIFEST_GATE_ADAPTER"
        exec "${source_root}/adapters/gate-${ARENA_GATE_NAME}.sh" launch
        ;;
    validation)
        set_pane_mode validation-shell
        if [[ -n "${ARENA_REVIEW_WORKTREE:-}" ]]; then
            cd "$ARENA_REVIEW_WORKTREE"
        else
            cd "$ARENA_WRITER_WORKTREE"
        fi
        cat <<EOF
Agent Arena validation pane
  Run state: $ARENA_RUN_DIR

After the writer commits and submits a checkpoint, run:
  $ARENA_COMMAND validate $ARENA_RUN_ID

Cursor owns the review/validation/decision gate. This pane is a deterministic
human-operated fallback for inspecting reports or rerunning the project check; it
does not replace Cursor's formal SHA-bound decision.
EOF
        launch_shell
        ;;
esac
