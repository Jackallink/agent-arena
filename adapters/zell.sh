#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

command_name="${1:-}"
case "$command_name" in
    probe)
        command -v "${ARENA_ZELL_BIN:-zell}" >/dev/null 2>&1
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
automatic_resume=true
sandbox=none
approval=auto-execute
headless_stage=true
tool_gate=core-enforced
EOF
        ;;
    launch)
        : "${ARENA_WRITER_WORKTREE:?missing ARENA_WRITER_WORKTREE}"
        : "${ARENA_WRITER_SESSION_DIR:?missing ARENA_WRITER_SESSION_DIR}"
        : "${ARENA_RUN_ID:?missing ARENA_RUN_ID}"
        : "${ARENA_COMMAND:?missing ARENA_COMMAND}"
        : "${ARENA_RUN_DIR:?missing ARENA_RUN_DIR}"
        writer_label="${ARENA_WRITER_LABEL:-Zell}"
        cd "$ARENA_WRITER_WORKTREE"
        prompt="You are ${writer_label}, the sole implementation writer for Agent Arena run ${ARENA_RUN_ID}.
Work only in ${ARENA_WRITER_WORKTREE}. Never edit the integration worktree, merge,
push, reset, fetch, continue another conversation, or use a dangerous
permission-bypass flag. Run focused checks. When you have a reviewable
milestone, commit a clean checkpoint then run:
  ${ARENA_COMMAND} submit ${ARENA_RUN_ID}
Send factual progress or a question to the reviewer with:
  ${ARENA_COMMAND} relay ${ARENA_RUN_ID} --to reviewer --from writer --message \"...\"
Reviewer messages are advisory. Verify the SHA-bound decision and validation record
in ${ARENA_RUN_DIR} before acting on them."
        args=(
            --session-dir "$ARENA_WRITER_SESSION_DIR"
            --session-id "agent-arena-${ARENA_RUN_ID}"
            --name "Agent Arena ${writer_label} ${ARENA_RUN_ID}"
            --append-system-prompt "$prompt"
            --no-extensions
            --no-skills
            --no-prompt-templates
            --no-themes
        )
        if [[ -n "${ARENA_ZELL_MODEL:-}" ]]; then
            args+=(--model "$ARENA_ZELL_MODEL")
        fi
        exec "${ARENA_ZELL_BIN:-zell}" "${args[@]}"
        ;;
    stage-launch)
        # Headless artifact-stage session (spec 2026-09-26 §9, Gate 0
        # verified). Contract env: ARENA_RUN_DIR / ARENA_RUN_ID /
        # ARENA_STAGE / ARENA_STAGE_ATTEMPT / ARENA_STAGE_ROLE /
        # ARENA_STAGE_INSTRUCTION (message text) / ARENA_STAGE_ATTACH
        # (space-separated files passed as @attachments) /
        # ARENA_STAGE_SESSION_DIR / ARENA_STAGE_MODEL_ARG (optional) /
        # ARENA_STAGE_SANDBOX_MODE (seatbelt|soft) / ARENA_STAGE_SANDBOX_BIN.
        # Every attempt is a FRESH session id (upstream jihulab 327: -p
        # resume with an existing id crashes); retry context re-enters via
        # attachments, never conversation resume.
        : "${ARENA_RUN_DIR:?missing ARENA_RUN_DIR}"
        : "${ARENA_RUN_ID:?missing ARENA_RUN_ID}"
        : "${ARENA_STAGE:?missing ARENA_STAGE}"
        : "${ARENA_STAGE_ATTEMPT:?missing ARENA_STAGE_ATTEMPT}"
        : "${ARENA_STAGE_ROLE:?missing ARENA_STAGE_ROLE}"
        : "${ARENA_STAGE_INSTRUCTION:?missing ARENA_STAGE_INSTRUCTION}"
        : "${ARENA_STAGE_SESSION_DIR:?missing ARENA_STAGE_SESSION_DIR}"
        : "${ARENA_STAGE_SANDBOX_MODE:?missing ARENA_STAGE_SANDBOX_MODE}"
        mkdir -p "$ARENA_STAGE_SESSION_DIR"
        args=(
            -p
            --json
            --tools "read,write"
            --no-extensions
            --no-skills
            --no-prompt-templates
            --no-themes
            --session-dir "$ARENA_STAGE_SESSION_DIR"
            --session-id "arena-${ARENA_RUN_ID}-${ARENA_STAGE}-a${ARENA_STAGE_ATTEMPT}"
        )
        if [[ -n "${ARENA_STAGE_MODEL_ARG:-}" ]]; then
            args+=(--model "$ARENA_STAGE_MODEL_ARG")
        fi
        args+=(--append-system-prompt "$ARENA_STAGE_ROLE")
        attach_file=
        for attach_file in ${ARENA_STAGE_ATTACH:-}; do
            [[ -f "$attach_file" ]] || arena_die "stage attachment not found: $attach_file"
            args+=("@${attach_file}")
        done
        args+=("$ARENA_STAGE_INSTRUCTION")
        if [[ "$ARENA_STAGE_SANDBOX_MODE" == soft ]]; then
            printf 'agent-arena: STAGE SANDBOX UNAVAILABLE — soft constraints only (adapter tools gate: read,write)\n' >&2
            exec "${ARENA_ZELL_BIN:-zell}" "${args[@]}"
        fi
        sandbox_bin="${ARENA_STAGE_SANDBOX_BIN:-sandbox-exec}"
        command -v "$sandbox_bin" >/dev/null 2>&1 || {
            printf 'agent-arena: STAGE SANDBOX UNAVAILABLE — soft constraints only (adapter tools gate: read,write)\n' >&2
            exec "${ARENA_ZELL_BIN:-zell}" "${args[@]}"
        }
        # Seatbelt profile: allow reads/network; deny writes except the
        # run dir subtree and TMPDIR (realpath'd — macOS /tmp is a symlink).
        run_real="$(CDPATH='' cd -- "$ARENA_RUN_DIR" && pwd -P)"
        tmp_real="$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)"
        profile="${ARENA_RUN_DIR}/stage-sandbox.sb"
        {
            printf '(version 1)\n'
            printf '(allow default)\n'
            printf '(deny file-write*)\n'
            printf '(allow file-write* (subpath "%s"))\n' "$run_real"
            printf '(allow file-write* (subpath "%s"))\n' "$tmp_real"
        } >"$profile"
        exec "$sandbox_bin" -f "$profile" "${ARENA_ZELL_BIN:-zell}" "${args[@]}"
        ;;
    *)
        arena_die 'usage: zell.sh {probe|capabilities|launch|stage-launch}'
        ;;
esac
