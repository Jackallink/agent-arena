#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/lock.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena mode RUN_ID human|auto

Switch a live run's approval mode. The switch is recorded in the run manifest
(mode_actor + mode_updated_at) under the run lock; terminal runs are refused.

Options:
  --state-root PATH      Private run-state root override
  -h, --help             Show this help
EOF
}

run_id=''
new_mode=''
positional=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a value'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *)
            positional=$((positional + 1))
            case "$positional" in
                1) run_id="$1" ;;
                2) new_mode="$1" ;;
                *) arena_die 'too many arguments' ;;
            esac
            shift
            ;;
    esac
done
[[ -n "$run_id" ]] || arena_die 'mode requires RUN_ID'
case "$new_mode" in
    human|auto) ;;
    *) arena_die 'mode requires one of: human, auto' ;;
esac

arena_validate_run_id "$run_id"
run_dir="$(arena_find_run_dir "$run_id")"

arena_lock_acquire "${run_dir}/.run-lock" "mode-$$"
mode_lock_held=1

arena_read_manifest "$run_dir"
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    source "${source_root}/lib/state.sh"
    arena_state_read "$run_dir"
    case "$ARENA_STATE_RUN_STATUS" in
        completed|canceled)
            arena_die "mode switch refused on terminal run: $ARENA_STATE_RUN_STATUS"
            ;;
    esac
fi
[[ "$ARENA_MANIFEST_MODE" == "$new_mode" ]] && {
    printf 'Mode: %s (unchanged)\n' "$new_mode"
    arena_lock_release "${run_dir}/.run-lock" "mode-$$"
    exit 0
}

now="$(date +%s)"
tmp_file="$(mktemp "${run_dir}/.manifest.XXXXXX")"
{
    awk -F $'\t' -v mode="$new_mode" -v now="$now" '
        $1 == "mode" { print "mode\t" mode; seen_mode = 1; next }
        $1 == "mode_actor" { print "mode_actor\thuman"; seen_actor = 1; next }
        $1 == "mode_updated_at" { print "mode_updated_at\t" now; seen_ts = 1; next }
        { print }
        END {
            if (!seen_mode) print "mode\t" mode
            if (!seen_actor) print "mode_actor\thuman"
            if (!seen_ts) print "mode_updated_at\t" now
        }
    ' "${run_dir}/manifest.tsv"
} >"$tmp_file"
chmod 600 "$tmp_file"
mv "$tmp_file" "${run_dir}/manifest.tsv"

printf 'Mode: %s (was %s)\n' "$new_mode" "$ARENA_MANIFEST_MODE"
printf '%s\tmode\t%s\thuman\tmode-switch\tacted\n' "$now" "$run_id" >>"$(arena_state_root)/autopilot.log" 2>/dev/null || true

arena_lock_release "${run_dir}/.run-lock" "mode-$$"
mode_lock_held=0
