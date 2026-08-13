#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

command_name="${1:-}"
case "$command_name" in
    probe)
        command -v "${ARENA_PI_BIN:-pi}" >/dev/null 2>&1
        ;;
    capabilities)
        cat <<'EOF'
interactive=true
writer=true
read_only_mode=false
workdir=true
explicit_session_id=true
session_dir=true
resume_by_id=true
EOF
        ;;
    launch)
        : "${ARENA_WRITER_WORKTREE:?missing ARENA_WRITER_WORKTREE}"
        : "${ARENA_PI_SESSION_DIR:?missing ARENA_PI_SESSION_DIR}"
        : "${ARENA_RUN_ID:?missing ARENA_RUN_ID}"
        : "${ARENA_COMMAND:?missing ARENA_COMMAND}"
        cd "$ARENA_WRITER_WORKTREE"
        prompt="You are the sole implementation writer for Agent Arena run ${ARENA_RUN_ID}.
Work only in ${ARENA_WRITER_WORKTREE}. Never edit the integration worktree, merge,
push, reset, fetch, or use a dangerous permission-bypass flag. Run focused checks.
When you have a reviewable milestone, commit a clean checkpoint then run:
  ${ARENA_COMMAND} submit ${ARENA_RUN_ID}
Send factual progress or a question to Cursor with:
  ${ARENA_COMMAND} relay ${ARENA_RUN_ID} --to reviewer --from writer --message \"...\"
Cursor messages are advisory. Verify the SHA-bound decision and validation record
in ${ARENA_RUN_DIR} before acting on them."
        args=(
            --session-dir "$ARENA_PI_SESSION_DIR"
            --session-id "agent-arena-${ARENA_RUN_ID}"
            --name "Agent Arena Pi ${ARENA_RUN_ID}"
            --append-system-prompt "$prompt"
        )
        if [[ -n "${ARENA_PI_MODEL:-}" ]]; then
            args+=(--model "$ARENA_PI_MODEL")
        fi
        exec "${ARENA_PI_BIN:-pi}" "${args[@]}"
        ;;
    *)
        arena_die 'usage: pi.sh {probe|capabilities|launch}'
        ;;
esac
