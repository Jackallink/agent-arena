#!/usr/bin/env bash

# Profile definitions are deliberately closed. A manifest can never select an
# arbitrary executable as its writer adapter.
ARENA_PROFILE_LIBRARY_LOADED=1

arena_profile_resolve() {
    local profile="$1"

    ARENA_PROFILE_NAME=''
    ARENA_PROFILE_WRITER_ADAPTER=''
    ARENA_PROFILE_WRITER_LABEL=''
    ARENA_PROFILE_GATE_ADAPTER=''
    case "$profile" in
        pi-cursor)
            ARENA_PROFILE_NAME='pi-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='pi'
            ARENA_PROFILE_WRITER_LABEL='Pi'
            ARENA_PROFILE_GATE_ADAPTER='cursor'
            ;;
        codex-cursor)
            ARENA_PROFILE_NAME='codex-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='codex'
            ARENA_PROFILE_WRITER_LABEL='Codex'
            ARENA_PROFILE_GATE_ADAPTER='cursor'
            ;;
        opencode-cursor)
            ARENA_PROFILE_NAME='opencode-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='opencode'
            ARENA_PROFILE_WRITER_LABEL='OpenCode'
            ARENA_PROFILE_GATE_ADAPTER='cursor'
            ;;
        agy-cursor)
            ARENA_PROFILE_NAME='agy-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='agy'
            ARENA_PROFILE_WRITER_LABEL='Agy'
            ARENA_PROFILE_GATE_ADAPTER='cursor'
            ;;
        *)
            if [[ "$profile" == *-* ]]; then
                arena_profile_split "$profile"
                ARENA_PROFILE_NAME="$profile"
                ARENA_PROFILE_WRITER_ADAPTER="$ARENA_PROFILE_WRITER"
                case "$ARENA_PROFILE_WRITER" in
                    pi) ARENA_PROFILE_WRITER_LABEL='Pi' ;;
                    codex) ARENA_PROFILE_WRITER_LABEL='Codex' ;;
                    opencode) ARENA_PROFILE_WRITER_LABEL='OpenCode' ;;
                    agy) ARENA_PROFILE_WRITER_LABEL='Agy' ;;
                esac
                ARENA_PROFILE_GATE_ADAPTER="$ARENA_PROFILE_GATE"
                return
            fi
            arena_die "unknown profile '$profile'; choose a WRITER-GATE combination such as pi-cursor or pi-opencode"
            ;;
    esac
}

arena_gate_resolve() {
    local gate="$1"

    ARENA_GATE_NAME=''
    case "$gate" in
        cursor|opencode) ARENA_GATE_NAME="$gate" ;;
        *) arena_die "unknown gate '$gate'; choose cursor or opencode" ;;
    esac
}

arena_gate_list() {
    printf '%s\n' cursor opencode
}

arena_gate_policy_paths() {
    local gate="$1"
    local adapter="${source_root:-.}/adapters/gate-${gate}.sh"

    [[ -x "$adapter" ]] || arena_die "gate adapter is missing: $adapter"
    "$adapter" capabilities | awk -F= '$1 == "policy_path" || $1 == "wrapper_path" { print $1 "\t" $2 }'
}

arena_profile_split() {
    local profile="$1"
    local writer="${profile%%-*}"
    local gate="${profile#*-}"

    case "$writer" in
        pi|codex|opencode|agy) ;;
        *) arena_die "unknown writer '$writer' in profile '$profile'" ;;
    esac
    arena_gate_resolve "$gate"
    ARENA_PROFILE_WRITER="$writer"
    ARENA_PROFILE_GATE="$gate"
}

arena_profile_list() {
    printf '%s\n' pi-cursor codex-cursor opencode-cursor agy-cursor
}

arena_profile_branch() {
    local writer_adapter="$1"
    local run_id="$2"

    case "$writer_adapter" in
        pi|codex|opencode|agy) printf 'agent-arena/%s/%s' "$writer_adapter" "$run_id" ;;
        *) arena_die "unknown writer adapter '$writer_adapter'" ;;
    esac
}
