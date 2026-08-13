#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    probe) command -v "${ARENA_GEMINI_BIN:-gemini}" >/dev/null 2>&1 ;;
    capabilities)
        printf '%s\n' 'status=planned' 'reason=approval-and-session-contract-not-yet-validated'
        ;;
    launch)
        printf '%s\n' 'agent-arena: Gemini adapter is planned, not enabled' >&2
        exit 3
        ;;
    *)
        printf '%s\n' 'usage: gemini.sh {probe|capabilities|launch}' >&2
        exit 2
        ;;
esac
