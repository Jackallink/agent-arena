#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena doctor

Checks local prerequisites, writer-profile availability, and the gate adapter
matrix without starting a model or modifying a project. Cursor is the default
gate; --gate or a WRITER-GATE profile selects the reviewer.
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

# The Cursor gate is the default, but its absence alone no longer fails
# doctor: the gate matrix below decides, and writer-gate profiles report
# their own blocked state through the profile probes.
if "${source_root}/adapters/gate-cursor.sh" probe; then
    cursor_available=1
else
    cursor_available=0
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

printf '%s\n' 'Gates:'
gate_count=0
for gate in $(arena_gate_list); do
    if "${source_root}/adapters/gate-${gate}.sh" probe; then
        printf '%-20s %-12s %s\n' "gate:${gate}" enabled "$gate"
        gate_count=$((gate_count + 1))
    else
        printf '%-20s %-12s %s\n' "gate:${gate}" missing "$gate"
    fi
done
[[ "$gate_count" -gt 0 ]] || arena_die 'doctor found no available gate adapter'

[[ "$writer_count" -gt 0 ]] || {
    printf '%s\n' 'agent-arena: no supported writer CLI is available' >&2
    failed=1
}
if [[ "$failed" -ne 0 ]]; then
    arena_die 'doctor found missing required prerequisites or no usable writer profile'
fi
arena_note 'doctor passed: at least one writer profile and one gate adapter are available'
