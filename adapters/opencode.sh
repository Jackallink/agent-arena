#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    probe) command -v "${ARENA_OPENCODE_BIN:-opencode}" >/dev/null 2>&1 ;;
    capabilities)
        printf '%s\n' 'status=planned' 'reason=read-only-policy-and-session-contract-not-yet-validated'
        ;;
    launch)
        printf '%s\n' 'agent-arena: OpenCode adapter is planned, not enabled' >&2
        exit 3
        ;;
    *)
        printf '%s\n' 'usage: opencode.sh {probe|capabilities|launch}' >&2
        exit 2
        ;;
esac
