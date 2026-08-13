#!/usr/bin/env bash

# Profile definitions are deliberately closed. A manifest can never select an
# arbitrary executable as its writer adapter.
ARENA_PROFILE_LIBRARY_LOADED=1

arena_profile_resolve() {
    local profile="$1"

    ARENA_PROFILE_NAME=''
    ARENA_PROFILE_WRITER_ADAPTER=''
    ARENA_PROFILE_WRITER_LABEL=''
    case "$profile" in
        pi-cursor)
            ARENA_PROFILE_NAME='pi-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='pi'
            ARENA_PROFILE_WRITER_LABEL='Pi'
            ;;
        codex-cursor)
            ARENA_PROFILE_NAME='codex-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='codex'
            ARENA_PROFILE_WRITER_LABEL='Codex'
            ;;
        opencode-cursor)
            ARENA_PROFILE_NAME='opencode-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='opencode'
            ARENA_PROFILE_WRITER_LABEL='OpenCode'
            ;;
        agy-cursor)
            ARENA_PROFILE_NAME='agy-cursor'
            ARENA_PROFILE_WRITER_ADAPTER='agy'
            ARENA_PROFILE_WRITER_LABEL='Agy'
            ;;
        *)
            arena_die "unknown profile '$profile'; choose pi-cursor, codex-cursor, opencode-cursor, or agy-cursor"
            ;;
    esac
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
