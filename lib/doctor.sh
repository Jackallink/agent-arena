#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena doctor

Checks local prerequisites and writer-profile availability without starting a model
or modifying a project. Cursor is required for every formal gate.
EOF
}

[[ "${1:-}" != --help && "${1:-}" != -h ]] || {
    usage
    exit 0
}
[[ $# -eq 0 ]] || arena_die "unknown option: $1"

probe_command() {
    local label="$1"
    local command_name="$2"
    local state="$3"

    if command -v "$command_name" >/dev/null 2>&1; then
        printf '%-20s %-12s %s\n' "$label" "$state" "$(command -v "$command_name")"
        return 0
    fi
    printf '%-20s %-12s missing (%s)\n' "$label" "$state" "$command_name"
    return 1
}

failed=0
probe_command git git required || failed=1
probe_command tmux tmux required || failed=1
probe_command tmuxp tmuxp required || failed=1
if probe_command cursor "${ARENA_CURSOR_BIN:-agent}" required; then
    cursor_available=1
else
    cursor_available=0
    failed=1
fi

writer_count=0
for profile in $(arena_profile_list); do
    arena_profile_resolve "$profile"
    adapter="${ARENA_PROFILE_WRITER_ADAPTER}"
    label="${ARENA_PROFILE_WRITER_LABEL}"
    if "${source_root}/adapters/${adapter}.sh" probe; then
        printf '%-20s %-12s %s\n' "$adapter" enabled "$label"
        writer_count=$((writer_count + 1))
        if [[ "$cursor_available" == 1 ]]; then
            printf '%-20s %-12s %s\n' "profile:${profile}" enabled "${label} writer + Cursor gate"
        else
            printf '%-20s %-12s %s\n' "profile:${profile}" blocked 'Cursor gate is unavailable'
        fi
    else
        printf '%-20s %-12s %s\n' "$adapter" missing "$label"
        printf '%-20s %-12s %s\n' "profile:${profile}" unavailable "${label} executable is missing"
    fi
done

[[ "$writer_count" -gt 0 ]] || {
    printf '%s\n' 'agent-arena: no supported writer CLI is available' >&2
    failed=1
}
if [[ "$failed" -ne 0 ]]; then
    arena_die 'doctor found missing required prerequisites or no usable writer profile'
fi
arena_note 'available profiles retain Cursor as the formal review, validation, and decision gate'
