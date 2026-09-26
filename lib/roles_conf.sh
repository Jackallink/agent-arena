#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

# Artifact-pipeline stage configuration (spec 2026-09-26 §8).
#
# Two scopes, later wins per key:
#   global: ${ARENA_CONFIG_HOME:-$HOME/.config}/agent-arena/roles.conf
#   project: <repo>/.agent-arena/roles.conf
#
# Keys per stage s in {intent,spec,plan}:
#   <s>_adapter   writer-capable adapter name (validated against adapters/)
#   <s>_model     --model passthrough (optional)
#   <s>_prompt    prompt template file, resolved relative to the defining
#                 conf file's directory (required once the stage is enabled)
#
# A stage is enabled only when its adapter is configured AND the adapter
# declares headless_stage=true in its capabilities output (an adapter that
# cannot run headless one-shot sessions is skipped with a warning).
#
# Globals use lowercase stage keys (ARENA_ROLES_intent_ADAPTER etc.) so
# every access can use plain ${!var} indirection (bash 3.2 compatible).

ARENA_ROLES_PIPELINE=''
ARENA_ROLES_SKIPPED=''

arena_roles_global_conf_path() {
    printf '%s\n' "${ARENA_CONFIG_HOME:-$HOME/.config}/agent-arena/roles.conf"
}

arena_roles_project_conf_path() {
    local repository="$1"
    printf '%s\n' "${repository}/.agent-arena/roles.conf"
}

# Parse one conf file into the ARENA_ROLES_<stage>_<field> globals.
arena_roles_parse_file() {
    local conf_path="$1"
    local line_number=0 key value stage

    [[ -f "$conf_path" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$(( line_number + 1 ))
        [[ -z "$line" || "$line" == '#'* ]] && continue
        [[ "$line" == *=* ]] || arena_die "${conf_path}:${line_number}: expected KEY=VALUE"
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            intent_adapter|spec_adapter|plan_adapter)
                stage="${key%%_*}"
                printf -v "ARENA_ROLES_${stage}_ADAPTER" '%s' "$value"
                printf -v "ARENA_ROLES_${stage}_CONF" '%s' "$conf_path"
                ;;
            intent_model|spec_model|plan_model)
                stage="${key%%_*}"
                printf -v "ARENA_ROLES_${stage}_MODEL" '%s' "$value"
                ;;
            intent_prompt|spec_prompt|plan_prompt)
                stage="${key%%_*}"
                printf -v "ARENA_ROLES_${stage}_PROMPT" '%s' "$value"
                printf -v "ARENA_ROLES_${stage}_PROMPT_CONF" '%s' "$conf_path"
                ;;
            *)
                arena_die "${conf_path}:${line_number}: unknown key '${key}'"
                ;;
        esac
    done <"$conf_path"
}

# Adapter capability gate: the adapter script must exist; the
# headless_stage=true capability decides whether it can run artifact
# stages (adapters without it are skipped with a warning).
arena_roles_adapter_exists() {
    local adapter="$1"
    [[ -f "${source_root}/adapters/${adapter}.sh" ]]
}

arena_roles_adapter_supports_stages() {
    local adapter="$1"
    [[ -f "${source_root}/adapters/${adapter}.sh" ]] || return 1
    bash "${source_root}/adapters/${adapter}.sh" capabilities 2>/dev/null | grep -q '^headless_stage=true$'
}

# Load both scopes and resolve the enabled pipeline. Sets:
#   ARENA_ROLES_PIPELINE          comma list, canonical order (possibly empty)
#   ARENA_ROLES_SKIPPED           comma list of skipped stages
#   ARENA_ROLES_<stage>_ADAPTER / _MODEL / _PROMPT_RESOLVED
arena_roles_load() {
    local repository="$1"
    local global_conf project_conf stage adapter prompt_path prompt_conf
    local var
    local -a enabled=() skipped=()

    for stage in intent spec plan; do
        for var in ADAPTER MODEL PROMPT PROMPT_CONF CONF; do
            printf -v "ARENA_ROLES_${stage}_${var}" '%s' ''
        done
    done

    global_conf="$(arena_roles_global_conf_path)"
    project_conf="$(arena_roles_project_conf_path "$repository")"
    arena_roles_parse_file "$global_conf"
    arena_roles_parse_file "$project_conf"

    for stage in intent spec plan; do
        var="ARENA_ROLES_${stage}_ADAPTER"
        adapter="${!var}"
        [[ -n "$adapter" ]] || continue
        arena_roles_adapter_exists "$adapter" || \
            arena_die "roles.conf: unknown adapter '${adapter}' for ${stage}_adapter (conf: $(dirname "$(arena_roles_global_conf_path)") or project .agent-arena/roles.conf)"
        if ! arena_roles_adapter_supports_stages "$adapter"; then
            skipped+=("$stage")
            printf -v "ARENA_ROLES_${stage}_ADAPTER" '%s' ''
            continue
        fi
        var="ARENA_ROLES_${stage}_PROMPT"
        prompt_path="${!var}"
        var="ARENA_ROLES_${stage}_PROMPT_CONF"
        prompt_conf="${!var}"
        [[ -n "$prompt_path" ]] || \
            arena_die "roles.conf: stage '${stage}' has an adapter but no ${stage}_prompt"
        [[ "$prompt_path" == /* ]] || {
            [[ -n "$prompt_conf" ]] || prompt_conf="$global_conf"
            prompt_path="$(dirname "$prompt_conf")/$prompt_path"
        }
        [[ -f "$prompt_path" ]] || \
            arena_die "roles.conf: ${stage}_prompt file not found: $prompt_path"
        printf -v "ARENA_ROLES_${stage}_PROMPT_RESOLVED" '%s' "$prompt_path"
        enabled+=("$stage")
    done

    ARENA_ROLES_PIPELINE="$(IFS=,; printf '%s' "${enabled[*]:-}")"
    ARENA_ROLES_SKIPPED="$(IFS=,; printf '%s' "${skipped[*]:-}")"
}

# Resolve the effective pipeline for a start invocation: the --pipeline
# flag (none/lean/full or an explicit comma list) selects a subset of the
# conf-enabled stages; without the flag the conf-enabled set is used.
# Prints the effective comma list (empty = v0.6 implementation-only).
arena_roles_resolve_pipeline() {
    local repository="$1"
    local pipeline_arg="$2"
    local requested stage count
    local -a ordered=()

    arena_roles_load "$repository"
    [[ -z "$ARENA_ROLES_SKIPPED" ]] || {
        printf 'agent-arena: roles.conf stages skipped (no headless_stage capability): %s\n' \
            "$ARENA_ROLES_SKIPPED" >&2
    }
    if [[ -z "$pipeline_arg" ]]; then
        printf '%s\n' "$ARENA_ROLES_PIPELINE"
        return 0
    fi
    case "$pipeline_arg" in
        none) printf '\n'; return 0 ;;
        lean) pipeline_arg='intent' ;;
        full) pipeline_arg='intent,spec,plan' ;;
    esac
    count=0
    for stage in intent spec plan; do
        case ",${pipeline_arg}," in
            *",${stage},"*)
                count=$(( count + 1 ))
                [[ ",$ARENA_ROLES_PIPELINE," == *",$stage,"* ]] || \
                    arena_die "stage '${stage}' requested via --pipeline has no enabled adapter in roles.conf"
                ordered+=("$stage")
                ;;
        esac
    done
    [[ "$count" == "${#ordered[@]}" ]] || \
        arena_die "--pipeline must name intent, spec, and/or plan stages (got: $pipeline_arg)"
    printf '%s\n' "$(IFS=,; printf '%s' "${ordered[*]:-}")"
}
