#!/usr/bin/env bash
set -euo pipefail

# This intentionally performs no model request, login, project mutation, or
# network operation. It documents the local CLI flags that the writer adapters
# rely on. Missing optional CLIs are reported as skips so hermetic CI can still
# run tests/run.sh without provider installations.

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

require_help_text() {
    local label="$1"
    local executable="$2"
    local required_text="$3"
    local help_text

    if ! command -v "$executable" >/dev/null 2>&1; then
        printf 'skip: %s is not installed\n' "$label"
        return 0
    fi
    help_text="$("$executable" --help 2>&1)" || {
        printf '%s\n' "${label}: --help failed" >&2
        return 1
    }
    grep -Fq -- "$required_text" <<<"$help_text" || {
        printf '%s\n' "${label}: --help no longer advertises ${required_text}" >&2
        return 1
    }
    printf 'ok: %s (%s)\n' "$label" "$("$executable" --version 2>&1 | head -n 1)"
}

require_help_text 'Codex working directory' "${ARENA_CODEX_BIN:-codex}" '--sandbox'
require_help_text 'Codex approval' "${ARENA_CODEX_BIN:-codex}" '--ask-for-approval'
require_help_text 'Codex terminal mode' "${ARENA_CODEX_BIN:-codex}" '--no-alt-screen'
require_help_text 'OpenCode pure mode' "${ARENA_OPENCODE_BIN:-opencode}" '--pure'
require_help_text 'OpenCode agent mode' "${ARENA_OPENCODE_BIN:-opencode}" '--agent'
require_help_text 'Agy interactive prompt' "${ARENA_AGY_BIN:-agy}" '--prompt-interactive'
require_help_text 'Agy print mode' "${ARENA_AGY_BIN:-agy}" '--print'
require_help_text 'Agy sandbox' "${ARENA_AGY_BIN:-agy}" '--sandbox'
require_help_text 'Agy edit mode' "${ARENA_AGY_BIN:-agy}" 'accept-edits'
require_help_text 'Agy conversation' "${ARENA_AGY_BIN:-agy}" '--conversation'

if command -v "${ARENA_OPENCODE_BIN:-opencode}" >/dev/null 2>&1; then
    opencode_policy='{"$schema":"https://opencode.ai/config.json","agent":{"arena_writer":{"description":"Agent Arena isolated writer","mode":"primary","permission":{"*":"deny","read":"allow","glob":"allow","grep":"allow","bash":"allow","edit":"allow","webfetch":"deny","websearch":"deny","task":"deny","question":"deny","external_directory":"deny"}}}}'
    resolved_opencode_agent="$(OPENCODE_CONFIG_CONTENT="$opencode_policy" \
        OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_EXTERNAL_SKILLS=1 \
        "${ARENA_OPENCODE_BIN:-opencode}" --pure debug agent arena_writer)"
    grep -Fq '"name": "arena_writer"' <<<"$resolved_opencode_agent" || {
        printf '%s\n' 'OpenCode: generated writer policy did not load' >&2
        exit 1
    }
    grep -Fq '"write": true' <<<"$resolved_opencode_agent" || {
        printf '%s\n' 'OpenCode: generated writer policy did not permit writer edits' >&2
        exit 1
    }
    printf '%s\n' 'ok: OpenCode generated writer policy'
fi

for adapter in pi codex opencode agy; do
    capabilities="$("${source_root}/adapters/${adapter}.sh" capabilities)"
    grep -Fqx 'writer=true' <<<"$capabilities" || {
        printf '%s\n' "${adapter}: adapter does not declare writer=true" >&2
        exit 1
    }
done
printf '%s\n' 'cli contract smoke: ok'
