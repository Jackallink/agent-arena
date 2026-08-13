#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Legacy alias for the Cursor gate adapter. v0.2 callers still pass the
# ARENA_CURSOR_* pane variables; map them onto the generic ARENA_GATE_* names
# and delegate to the manifest-dispatched gate adapter. Removed in Task 6.
if [[ -z "${ARENA_GATE_WORKSPACE:-}" && -n "${ARENA_CURSOR_WORKSPACE:-}" ]]; then
    export ARENA_GATE_WORKSPACE="$ARENA_CURSOR_WORKSPACE"
fi
if [[ -z "${ARENA_GATE_PHASE:-}" && -n "${ARENA_CURSOR_PHASE:-}" ]]; then
    export ARENA_GATE_PHASE="$ARENA_CURSOR_PHASE"
fi
exec "${source_root}/adapters/gate-cursor.sh" "$@"
