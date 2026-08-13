#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena doctor

Checks local prerequisites without starting a model or modifying a project.
EOF
}

[[ "${1:-}" != --help && "${1:-}" != -h ]] || {
    usage
    exit 0
}
[[ $# -eq 0 ]] || arena_die "unknown option: $1"

probe() {
    local label="$1"
    local command_name="$2"
    local state="$3"

    if command -v "$command_name" >/dev/null 2>&1; then
        printf '%-16s %-12s %s\n' "$label" "$state" "$(command -v "$command_name")"
        return 0
    fi
    printf '%-16s %-12s missing (%s)\n' "$label" "$state" "$command_name"
    return 1
}

failed=0
probe git git required || failed=1
probe tmux tmux required || failed=1
probe tmuxp tmuxp required || failed=1
probe pi "${ARENA_PI_BIN:-pi}" enabled || failed=1
probe cursor "${ARENA_CURSOR_BIN:-agent}" enabled || failed=1
probe codex "${ARENA_CODEX_BIN:-codex}" planned || true
probe opencode "${ARENA_OPENCODE_BIN:-opencode}" planned || true
probe gemini "${ARENA_GEMINI_BIN:-gemini}" planned || true

if [[ "$failed" -ne 0 ]]; then
    arena_die 'doctor found missing prerequisites for the pi-cursor profile'
fi
arena_note 'pi-cursor profile is available; planned adapters are detected only, not enabled'
