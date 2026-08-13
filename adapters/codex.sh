#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    probe) command -v "${ARENA_CODEX_BIN:-codex}" >/dev/null 2>&1 ;;
    capabilities)
        printf '%s\n' 'status=planned' 'reason=permission-and-session-contract-not-yet-validated'
        ;;
    launch)
        printf '%s\n' 'agent-arena: Codex adapter is planned, not enabled' >&2
        exit 3
        ;;
    *)
        printf '%s\n' 'usage: codex.sh {probe|capabilities|launch}' >&2
        exit 2
        ;;
esac
