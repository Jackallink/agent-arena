#!/usr/bin/env bash

# JSON emission helpers for the machine-readable oracle exits (--json).
# The contract lives in docs/superpowers/specs/2026-08-15-dashboard-tui.md:
# JSON goes to stdout on every exit path; stderr keeps the human diagnostics;
# exit codes are unchanged. Consumers: agent-arena list --json, status --json,
# and the ui/ companion (strict serde).

# Escape one string per RFC 8259: backslash, double quote, and C0 control
# characters. UTF-8 bytes pass through untouched (valid JSON).
arena_json_escape() {
    local s="$1" out='' ch i code
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        case "$ch" in
            '\') out="$out\\\\" ;;
            '"') out="$out\\\"" ;;
            $'\n') out="$out\\n" ;;
            $'\r') out="$out\\r" ;;
            $'\t') out="$out\\t" ;;
            *)
                code="$(printf '%d' "'$ch" 2>/dev/null)" || code=63
                if [[ "$code" -lt 32 ]]; then
                    out="$out$(printf '\\u%04x' "$code")"
                else
                    out="$out$ch"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

# Emit one JSON string literal (quotes included).
arena_json_string() {
    printf '"%s"' "$(arena_json_escape "$1")"
}
