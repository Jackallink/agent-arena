#!/usr/bin/env bash

arena_project_config_path() {
    printf '%s/.agent-arena/project.conf' "$1"
}

arena_load_project_config() {
    local repository="$1"
    local config
    local line key value

    config="$(arena_project_config_path "$repository")"
    [[ -f "$config" ]] || arena_die "missing project configuration: $config; run 'agent-arena init --repo $repository'"

    ARENA_PROJECT_NAME=''
    ARENA_PROJECT_VALIDATION_SCRIPT=''
    ARENA_CONFIG_APPROVAL_MODE='human'
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^(project_name|validation_script|approval_mode)=\"([^\"]*)\"$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$key" in
                project_name) ARENA_PROJECT_NAME="$value" ;;
                validation_script) ARENA_PROJECT_VALIDATION_SCRIPT="$value" ;;
                approval_mode) ARENA_CONFIG_APPROVAL_MODE="$value" ;;
            esac
        else
            arena_die "invalid project configuration line in $config: $line"
        fi
    done <"$config"
    case "$ARENA_CONFIG_APPROVAL_MODE" in
        human|auto) ;;
        *) arena_die "invalid approval_mode in $config: $ARENA_CONFIG_APPROVAL_MODE (legal values: human, auto)" ;;
    esac

    arena_validate_text "$ARENA_PROJECT_NAME" 'project_name' 128
    arena_validate_text "$ARENA_PROJECT_VALIDATION_SCRIPT" 'validation_script' 256
    [[ "$ARENA_PROJECT_VALIDATION_SCRIPT" != /* ]] || arena_die "validation_script must be relative"
    [[ "/${ARENA_PROJECT_VALIDATION_SCRIPT}/" != *'/../'* ]] || \
        arena_die "validation_script must not traverse parent directories"
    [[ "$ARENA_PROJECT_VALIDATION_SCRIPT" != '.' && "$ARENA_PROJECT_VALIDATION_SCRIPT" != '..' ]] || \
        arena_die "validation_script must name a file"
    ARENA_PROJECT_CONFIG="$config"
    ARENA_PROJECT_VALIDATION_PATH="${repository}/${ARENA_PROJECT_VALIDATION_SCRIPT}"
}
