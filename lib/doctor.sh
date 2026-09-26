#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena doctor [--repo PATH]

Checks local prerequisites, writer-profile availability, and the gate adapter
matrix without starting a model or modifying a project. Cursor is the default
gate; --gate or a WRITER-GATE profile selects the reviewer.

--repo PATH also reports the artifact-pipeline stage configuration resolved
from roles.conf (global scope plus the project scope under PATH).
EOF
}

doctor_repo=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --repo)
            [[ $# -ge 2 ]] || arena_die '--repo requires a path'
            doctor_repo="$2"
            shift 2
            ;;
        *)
            arena_die "unknown option: $1"
            ;;
    esac
done

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
            printf '%-20s %-12s %s\n' "profile:${profile}" enabled "${label} writer + gate"
        else
            printf '%-20s %-12s %s\n' "profile:${profile}" blocked 'gate is unavailable'
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

# Artifact-pipeline advisory (spec 2026-09-26 §8): roles.conf stages and
# their adapter capability. Configuration errors (unknown key, unknown
# adapter, missing prompt) fail fast here with path:line context; a stage
# whose adapter lacks the headless_stage capability is reported skipped.
if [[ -n "$doctor_repo" ]]; then
    source "${source_root}/lib/roles_conf.sh"
    arena_roles_load "$doctor_repo"
    printf '%s\n' 'Pipeline stages (roles.conf):'
    for doctor_stage in intent spec plan; do
        var="ARENA_ROLES_${doctor_stage}_ADAPTER"
        doctor_adapter="${!var}"
        if [[ -n "$doctor_adapter" ]]; then
            printf '%-20s %-12s %s\n' "stage:${doctor_stage}" enabled "adapter ${doctor_adapter}"
        elif [[ ",$ARENA_ROLES_SKIPPED," == *",$doctor_stage,"* ]]; then
            printf '%-20s %-12s %s\n' "stage:${doctor_stage}" skipped "adapter lacks headless_stage capability (role prompt never runs headless)"
        else
            printf '%-20s %-12s %s\n' "stage:${doctor_stage}" unset 'no roles.conf entry (stage not configured)'
        fi
    done
fi

# Dashboard status is advisory: it never fails doctor, it only tells the
# operator what `agent-arena dashboard` will do right now.
if [[ -x "${source_root}/ui/target/debug/agent-arena-ui" || -x "${source_root}/ui/target/release/agent-arena-ui" ]]; then
    printf '%-20s %-12s %s\n' 'dashboard' ready 'run agent-arena dashboard'
elif command -v cargo >/dev/null 2>&1; then
    printf '%-20s %-12s %s\n' 'dashboard' 'buildable' 'run (cd ui && cargo build)'
else
    printf '%-20s %-12s %s\n' 'dashboard' 'absent' 'install Rust stable, then (cd ui && cargo build)'
fi

[[ "$writer_count" -gt 0 ]] || {
    printf '%s\n' 'agent-arena: no supported writer CLI is available' >&2
    failed=1
}
if [[ "$failed" -ne 0 ]]; then
    arena_die 'doctor found missing required prerequisites or no usable writer profile'
fi
arena_note 'doctor passed: at least one writer profile and one gate adapter are available'
