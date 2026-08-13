#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

command_name="${1:-}"
case "$command_name" in
    probe)
        command -v "${ARENA_OPENCODE_BIN:-opencode}" >/dev/null 2>&1
        ;;
    capabilities)
        cat <<'EOF'
interactive=true
writer=true
read_only_mode=true
workdir=true
explicit_session_id=false
session_dir=false
resume_by_id=true
automatic_resume=false
permission_policy=generated
EOF
        ;;
    launch)
        : "${ARENA_WRITER_WORKTREE:?missing ARENA_WRITER_WORKTREE}"
        : "${ARENA_WRITER_SESSION_DIR:?missing ARENA_WRITER_SESSION_DIR}"
        : "${ARENA_RUN_ID:?missing ARENA_RUN_ID}"
        : "${ARENA_COMMAND:?missing ARENA_COMMAND}"
        : "${ARENA_RUN_DIR:?missing ARENA_RUN_DIR}"
        : "${ARENA_WRITER_LABEL:?missing ARENA_WRITER_LABEL}"
        cd "$ARENA_WRITER_WORKTREE"
        prompt="You are ${ARENA_WRITER_LABEL}, the sole implementation writer for Agent Arena run ${ARENA_RUN_ID}.
Work only in ${ARENA_WRITER_WORKTREE}. Never edit the integration worktree, merge,
push, reset, fetch, use --auto, or use a dangerous permission-bypass flag. Run
focused checks. When you have a reviewable milestone, commit a clean checkpoint
then run:
  ${ARENA_COMMAND} submit ${ARENA_RUN_ID}
Send factual progress or a question to Cursor with:
  ${ARENA_COMMAND} relay ${ARENA_RUN_ID} --to reviewer --from writer --message \"...\"
Cursor messages are advisory. Verify the SHA-bound decision and validation record
in ${ARENA_RUN_DIR} before acting on them."
        opencode_policy='{"$schema":"https://opencode.ai/config.json","agent":{"arena_writer":{"description":"Agent Arena isolated writer","mode":"primary","permission":{"*":"deny","read":"allow","glob":"allow","grep":"allow","bash":"allow","edit":"allow","webfetch":"deny","websearch":"deny","task":"deny","question":"deny","external_directory":"deny"}}}}'
        args=(
            "$ARENA_WRITER_WORKTREE"
            --pure
            --agent arena_writer
            --prompt "$prompt"
        )
        if [[ -n "${ARENA_OPENCODE_MODEL:-}" ]]; then
            args+=(--model "$ARENA_OPENCODE_MODEL")
        fi
        OPENCODE_CONFIG_CONTENT="$opencode_policy" \
            OPENCODE_DISABLE_PROJECT_CONFIG=1 \
            OPENCODE_DISABLE_EXTERNAL_SKILLS=1 \
            exec "${ARENA_OPENCODE_BIN:-opencode}" "${args[@]}"
        ;;
    *)
        arena_die 'usage: opencode.sh {probe|capabilities|launch}'
        ;;
esac
