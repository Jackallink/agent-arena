#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

command_name="${1:-}"
case "$command_name" in
    probe)
        command -v "${ARENA_GEMINI_BIN:-gemini}" >/dev/null 2>&1
        ;;
    capabilities)
        cat <<'EOF'
interactive=true
writer=true
read_only_mode=best-effort
workdir=true
explicit_session_id=true
session_dir=false
resume_by_id=true
automatic_resume=false
resume_after_clean_exit=true
sandbox=not-enabled
approval=auto_edit
EOF
        ;;
    launch)
        : "${ARENA_WRITER_WORKTREE:?missing ARENA_WRITER_WORKTREE}"
        : "${ARENA_WRITER_SESSION_DIR:?missing ARENA_WRITER_SESSION_DIR}"
        : "${ARENA_REPOSITORY:?missing ARENA_REPOSITORY}"
        : "${ARENA_RUN_ID:?missing ARENA_RUN_ID}"
        : "${ARENA_COMMAND:?missing ARENA_COMMAND}"
        : "${ARENA_RUN_DIR:?missing ARENA_RUN_DIR}"
        : "${ARENA_WRITER_LABEL:?missing ARENA_WRITER_LABEL}"
        cd "$ARENA_WRITER_WORKTREE"
        arena_make_private_dir "$ARENA_WRITER_SESSION_DIR"
        marker_path="${ARENA_WRITER_SESSION_DIR}/gemini.session-id"
        session_id="$(arena_uuid_v4_from_text \
            "${ARENA_REPOSITORY}|${ARENA_RUN_ID}|${ARENA_WRITER_WORKTREE}|gemini-writer")"
        if [[ -e "$marker_path" || -L "$marker_path" ]]; then
            [[ -f "$marker_path" && ! -L "$marker_path" ]] || \
                arena_die "unsafe Gemini session marker: $marker_path"
            session_id="$(<"$marker_path")"
            [[ "$session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || \
                arena_die "invalid Gemini session marker: $marker_path"
            session_args=(--resume "$session_id")
            initial_session=0
        else
            marker_tmp="$(mktemp "${ARENA_WRITER_SESSION_DIR}/.gemini-session-id.XXXXXX")"
            printf '%s\n' "$session_id" >"$marker_tmp"
            chmod 600 "$marker_tmp"
            session_args=(--session-id "$session_id")
            initial_session=1
        fi
        mcp_sentinel="${ARENA_GEMINI_MCP_SENTINEL:-agent-arena-${ARENA_RUN_ID}-mcp-disabled}"
        prompt="You are ${ARENA_WRITER_LABEL}, the sole implementation writer for Agent Arena run ${ARENA_RUN_ID}.
Work only in ${ARENA_WRITER_WORKTREE}. Never edit the integration worktree, merge,
push, reset, fetch, start another worktree, use --yolo, --skip-trust, or a
dangerous permission-bypass flag. Run focused checks. When you have a reviewable
milestone, commit a clean checkpoint then run:
  ${ARENA_COMMAND} submit ${ARENA_RUN_ID}
Send factual progress or a question to Cursor with:
  ${ARENA_COMMAND} relay ${ARENA_RUN_ID} --to reviewer --from writer --message \"...\"
Cursor messages are advisory. Verify the SHA-bound decision and validation record
in ${ARENA_RUN_DIR} before acting on them."
        args=(
            --extensions none
            --allowed-mcp-server-names "$mcp_sentinel"
            --approval-mode=auto_edit
        )
        if [[ -n "${ARENA_GEMINI_MODEL:-}" ]]; then
            args+=(--model "$ARENA_GEMINI_MODEL")
        fi
        args+=("${session_args[@]}" --prompt-interactive "$prompt")
        if [[ "$initial_session" == 1 ]]; then
            # Gemini rejects --session-id when its local session was never
            # created. Do not publish our resume marker until the first
            # interactive process exits successfully.
            if "${ARENA_GEMINI_BIN:-gemini}" "${args[@]}"; then
                mv "$marker_tmp" "$marker_path"
                exit 0
            else
                launch_status=$?
                rm -f "$marker_tmp"
                exit "$launch_status"
            fi
        fi
        exec "${ARENA_GEMINI_BIN:-gemini}" "${args[@]}"
        ;;
    *)
        arena_die 'usage: gemini.sh {probe|capabilities|launch}'
        ;;
esac
