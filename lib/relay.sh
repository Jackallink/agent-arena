#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena relay RUN_ID --to ROLE --message TEXT [options]

Send one literal, short message to the live writer or reviewer pane.

Options:
  --to ROLE          writer or reviewer
  --from ROLE        writer, reviewer, or human (default: human)
  --message TEXT     One-line text, up to 1000 characters
  --state-root PATH  Private state root override
  -h, --help         Show this help

Delivery is best effort. tmux cannot tell whether an interactive model is mid-turn.
EOF
}

run_id=''
recipient=''
sender='human'
message=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)
            [[ $# -ge 2 ]] || arena_die '--to requires a value'
            recipient="$2"
            shift 2
            ;;
        --from)
            [[ $# -ge 2 ]] || arena_die '--from requires a value'
            sender="$2"
            shift 2
            ;;
        --message)
            [[ $# -ge 2 ]] || arena_die '--message requires text'
            message="$2"
            shift 2
            ;;
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
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

[[ -n "$run_id" && -n "$recipient" && -n "$message" ]] || \
    arena_die 'relay requires RUN_ID, --to, and --message'
arena_validate_run_id "$run_id"
arena_validate_relay_message "$message"
case "$recipient" in
    writer|reviewer) ;;
    *) arena_die '--to must be writer or reviewer' ;;
esac
case "$sender" in
    writer|reviewer|human) ;;
    *) arena_die '--from must be writer, reviewer, or human' ;;
esac

arena_require_command tmux
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
tmux has-session -t "=${ARENA_MANIFEST_SESSION_NAME}" 2>/dev/null || \
    arena_die "tmux session is not running: ${ARENA_MANIFEST_SESSION_NAME}"

target_pane="$(arena_find_live_pane "$ARENA_MANIFEST_SESSION_NAME" "$recipient" "${recipient}-agent")"
case "$sender" in
    writer) sender_label='Pi' ;;
    reviewer) sender_label='Cursor' ;;
    human) sender_label='Human' ;;
esac
payload="[${sender_label}] ${message}"
tmux send-keys -t "$target_pane" -l -- "$payload"
tmux send-keys -t "$target_pane" Enter
arena_note "relayed ${sender} message to ${recipient}"
