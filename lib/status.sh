#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/json.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena status RUN_ID [--json] [--state-root PATH]

Show the run manifest plus the latest submitted checkpoint, validation report, and
decision record, then the one-sentence diagnosis and any transition anomaly.
With --json, print the JSON contract document to stdout on every exit path
(stderr keeps the human diagnostics; exit codes are unchanged).
This command makes no changes.
EOF
}

status_json=0
run_id=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        --json)
            status_json=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -* ) arena_die "unknown option: $1" ;;
        *)
            [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'
            run_id="$1"
            shift
            ;;
    esac
done

# --- JSON contract emission (docs/superpowers/specs/2026-08-15-dashboard-tui.md) ---
# Human output is byte-identical without --json. With --json, field lines are
# buffered into the fields object, the error path is tracked by the current
# stage marker, and every exit emits the document from the EXIT trap (so any
# die() anywhere below still yields valid JSON with the right exit code).
ARENA_STATUS_ERROR='unknown'
ARENA_STATUS_FIELDS=''
ARENA_STATUS_PANES=''
ARENA_STATUS_STAGES=''
ARENA_STATUS_FINISHED=0
status_kvs=()

arena_status_kv() {  # KEY_JSON KEY_HUMAN VALUE
    if [[ "$status_json" == 1 ]]; then
        status_kvs+=("\"$1\":$(arena_json_string "$3")")
    else
        printf '%s: %s\n' "$2" "$3"
    fi
}

arena_status_finish() {  # EXIT_CODE  (error name comes from ARENA_STATUS_ERROR)
    if [[ "$status_json" == 1 ]]; then
        ARENA_STATUS_FINISHED=1
        local fields="" kv panes_out status_err stages_out=''
        [[ "$1" == 0 ]] && status_err='null' || status_err="$ARENA_STATUS_ERROR"
        for kv in "${status_kvs[@]}"; do
            fields="${fields:+$fields,}$kv"
        done
        panes_out="$ARENA_STATUS_PANES"
        [[ -n "$panes_out" ]] || panes_out='{}'
        # The pipeline stage chain is a success-path-only additive field:
        # it is inserted after the fields object and never appears on
        # error documents (the EXIT-trap document stays untouched too).
        [[ -n "$ARENA_STATUS_STAGES" ]] && stages_out=",\"stages\":${ARENA_STATUS_STAGES}"
        if [[ "$status_err" == 'null' ]]; then
            printf '{"schema":1,"run_id":%s,"fields":{%s}%s,"panes":%s,"error":null}\n' \
                "$(arena_json_string "$run_id")" "$fields" "$stages_out" "$panes_out"
        else
            printf '{"schema":1,"run_id":%s,"fields":{%s},"panes":%s,"error":%s}\n' \
                "$(arena_json_string "$run_id")" "$fields" "$panes_out" \
                "$(arena_json_string "$status_err")"
        fi
    fi
    exit "$1"
}

arena_status_fail() {  # EXIT_CODE  — emit JSON (or nothing for humans) and exit
    if [[ "$status_json" == 1 ]]; then
        arena_status_finish "$1"
    fi
    exit "$1"
}

# Build the pipeline stage chain JSON for the status document. No-op for
# human output, for non-pipeline runs, and on error paths (the helper is
# only called on the success branch), so the stages key stays absent there.
# Stage names/statuses go through arena_json_string; a non-numeric
# attempts value coerces to 0 (the manifest key space owns the values).
arena_status_build_stages() {
    [[ "$status_json" == 1 && -n "$ARENA_MANIFEST_PIPELINE" ]] || return 0
    local stage idx status attempts stages='' sep='' IFS=','
    for stage in $ARENA_MANIFEST_PIPELINE; do
        idx="$(arena_manifest_stage_index "$stage")" || \
            arena_die "unknown pipeline stage '$stage' in run manifest"
        status="${ARENA_STAGE_STATUS[$idx]}"
        attempts="${ARENA_STAGE_ATTEMPTS[$idx]}"
        [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
        stages="${stages}${sep}{\"name\":$(arena_json_string "$stage"),\"status\":$(arena_json_string "$status"),\"attempts\":${attempts}}"
        sep=','
    done
    ARENA_STATUS_STAGES="[${stages}]"
}

if [[ "$status_json" == 1 ]]; then
    arena_status_trap_exit() {
        local code=$?
        if [[ "$ARENA_STATUS_FINISHED" == 0 ]]; then
            ARENA_STATUS_FINISHED=1
            printf '{"schema":1,"run_id":%s,"fields":{},"panes":{},"error":%s}\n' \
                "$(arena_json_string "$run_id")" "$(arena_json_string "$ARENA_STATUS_ERROR")"
        fi
        exit "$code"
    }
    trap arena_status_trap_exit EXIT
fi

[[ -n "$run_id" ]] || arena_die 'status requires RUN_ID'
arena_validate_run_id "$run_id"
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
# The state file is the authority for status; the legacy projection is
# read-only and never writes. Corruption fails closed (exit 2).
source "${source_root}/lib/state.sh"

runs_root="$(arena_state_root)/runs"
repo_id="$(basename "$(dirname "$run_dir")")"

# Priority check (1): LIVE LOCK (run or parent creation lock with a live
# owner) always wins: 'transition in progress', exit 4.
ARENA_STATUS_ERROR='locked'
if arena_state_precheck_lock_live "${run_dir}/.run-lock"; then
    [[ "$status_json" == 1 ]] && printf 'transition in progress\n' >&2 || printf 'transition in progress\n'
    arena_status_fail 4
fi
if arena_state_precheck_lock_live "${runs_root}/${repo_id}/.parent-lock"; then
    [[ "$status_json" == 1 ]] && printf 'transition in progress\n' >&2 || printf 'transition in progress\n'
    arena_status_fail 4
fi
# Priority check (2): creation intent with no live owner. S1/S2/S5/S6 are
# owned by start (exit 5, retry: start); S3/S4 take the manual abort
# protocol (exit 2) for status.
if [[ "$status_json" == 1 ]]; then
    # The precheck prints its human diagnostics to stderr and exits
    # 4/5/2; capture and re-emit them, then finish with the mapped error.
    precheck_rc=0
    precheck_err="$(arena_state_precheck_intents "$runs_root" "$repo_id" "$run_id" status 2>&1)" || precheck_rc=$?
    if [[ "$precheck_rc" != 0 ]]; then
        [[ -n "$precheck_err" ]] && printf '%s\n' "$precheck_err" >&2
        case "$precheck_rc" in
            4) ARENA_STATUS_ERROR='locked' ;;
            5) ARENA_STATUS_ERROR='incomplete' ;;
            *) ARENA_STATUS_ERROR='conflict' ;;
        esac
        arena_status_fail "$precheck_rc"
    fi
else
    arena_state_precheck_intents "$runs_root" "$repo_id" "$run_id" status
fi
# Priority check (3): repair intent with no live lock, before any ordinary
# state parse.
if [[ -f "${run_dir}/.repair.intent" ]]; then
    [[ "$status_json" == 1 ]] && \
        printf 'incomplete transition; retry: agent-arena repair-state %s --candidate <token> --reason "..."\n' "$run_id" >&2 || \
        printf 'incomplete transition; retry: agent-arena repair-state %s --candidate <token> --reason "..."\n' "$run_id"
    ARENA_STATUS_ERROR='incomplete'
    arena_status_fail 5
fi

# Observation-only reviewer-pane liveness: never dies; status reports the
# reachability instead of acting on it.
arena_status_reviewer_pane_alive() {
    local session_name="$1"
    local count
    count="$(tmux list-panes -s -t "=${session_name}" -F "$(arena_pane_format)" 2>/dev/null | \
        awk -F $'\t' -v session="$session_name" \
            '$1 == session && $3 == "reviewer" && $4 == "reviewer-agent" && \
             $5 == "0" && $6 == "0" && $7 == "0" && $8 == "0" { n += 1 } END { print n + 0 }')"
    [[ "$count" == 1 ]]
}

arena_status_writer_pane_alive() {
    local session_name="$1"
    local count
    count="$(tmux list-panes -s -t "=${session_name}" -F "$(arena_pane_format)" 2>/dev/null | \
        awk -F $'\t' -v session="$session_name" \
            '$1 == session && $3 == "writer" && $4 == "writer-agent" && \
             $5 == "0" && $6 == "0" && $7 == "0" && $8 == "0" { n += 1 } END { print n + 0 }')"
    [[ "$count" == 1 ]]
}

# The one-sentence diagnosis plus the per-scenario lines. Terminal states
# (party none) print the terminal line instead and are handled by the caller.
arena_status_diagnosis() {
    local party="$1" reason="$2" since="$3" session_name="$4" target_run_id="$5"
    local pane_line='' release=''

    if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "=${session_name}" 2>/dev/null; then
        pane_line='tmux session: not running; '
    elif ! arena_status_reviewer_pane_alive "$session_name"; then
        pane_line='reviewer pane: unreachable; '
    fi
    case "${party}:${reason}" in
        reviewer:review_pending) release="agent-arena validate ${target_run_id}" ;;
        reviewer:decision_pending) release="agent-arena decision ${target_run_id} --verdict ..." ;;
        human:approval_pending) release="agent-arena resolve ${target_run_id} --action approve|reject" ;;
        human:block_resolution_required) release="agent-arena resolve ${target_run_id} --action reject|cancel" ;;
        human:reviewer_unreachable) release="agent-arena resolve ${target_run_id} --action recover|cancel" ;;
        writer:*) release="writer continues; then agent-arena submit ${target_run_id}" ;;
    esac
    printf 'waiting on %s for %s since %s; %srelease: %s\n' \
        "$party" "$reason" "${since:-unknown}" "$pane_line" "$release"
    if [[ "$pane_line" == 'reviewer pane: unreachable; ' ]]; then
        printf 'reviewer pane: unreachable; agent-arena resume %s (respawns the reviewer pane), confirm the trust prompt in the pane, then re-run recover\n' "$target_run_id"
    fi
    # Pane liveness lines (machine-readable for autopilot): reachable unless
    # the tmux session is gone or the role pane is dead/ambiguous.
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=${session_name}" 2>/dev/null; then
        if arena_status_reviewer_pane_alive "$session_name"; then
            printf 'Reviewer pane: reachable\n'
        else
            printf 'Reviewer pane: unreachable\n'
        fi
        if arena_status_writer_pane_alive "$session_name"; then
            printf 'Writer pane: reachable\n'
        else
            printf 'Writer pane: unreachable\n'
        fi
    fi
}

arena_status_kv 'run_id' 'Run' "$ARENA_MANIFEST_RUN_ID"
arena_status_kv 'repository' 'Repository' "$ARENA_MANIFEST_REPOSITORY"
arena_status_kv 'base' 'Base' "$ARENA_MANIFEST_BASE_SHA"
arena_status_kv 'profile' 'Profile' "$ARENA_MANIFEST_PROFILE"
arena_status_kv 'writer_adapter' 'Writer adapter' "$ARENA_MANIFEST_WRITER_ADAPTER"
arena_status_kv 'gate' 'Gate' "$ARENA_MANIFEST_GATE_ADAPTER"
arena_status_kv 'writer' 'Writer' "$ARENA_MANIFEST_WRITER_LABEL"
arena_status_kv 'writer_worktree' 'Writer worktree' "$ARENA_MANIFEST_WRITER_WORKTREE"
arena_status_kv 'branch' 'Branch' "$ARENA_MANIFEST_BRANCH"
arena_status_kv 'tmux_session' 'Tmux session' "$ARENA_MANIFEST_SESSION_NAME"
# Approval mode from the manifest snapshot; drift against project.conf shows
# a warning marker. A missing/unreadable config never dies status.
config_mode="$(source "${source_root}/lib/config.sh" 2>/dev/null && \
    arena_load_project_config "$ARENA_MANIFEST_REPOSITORY" >/dev/null 2>&1 && \
    printf '%s' "${ARENA_CONFIG_APPROVAL_MODE:-human}")"
if [[ -n "$config_mode" && "$ARENA_MANIFEST_MODE" != "$config_mode" ]]; then
    if [[ "$status_json" == 1 ]]; then
        status_kvs+=("\"mode\":$(arena_json_string "$ARENA_MANIFEST_MODE")")
        status_kvs+=("\"config_mode\":$(arena_json_string "$config_mode")")
    else
        printf 'Mode: %s (config: %s) ⚠\n' "$ARENA_MANIFEST_MODE" "$config_mode"
    fi
else
    arena_status_kv 'mode' 'Mode' "$ARENA_MANIFEST_MODE"
fi

if [[ -f "${run_dir}/run-state.tsv" ]]; then
    # Priority check (4): ordinary parse of the authoritative state.
    # Corrupted or illegal state fails closed (exit 2).
    ARENA_STATUS_ERROR='corrupt'
    arena_state_read "$run_dir"
    arena_status_kv 'state_dir' 'State' "$run_dir"
    arena_status_kv 'verdict' 'Verdict' "${ARENA_STATE_VERDICT:-not recorded}"
    arena_status_kv 'validation_result' 'Validation result' "${ARENA_STATE_VALIDATION_RESULT:-not run}"
    arena_status_kv 'last_transition_at' 'Last transition at' "$ARENA_STATE_LAST_TRANSITION_AT"
    integrity_status=0
    if [[ -f "${run_dir}/review.tsv" ]]; then
        arena_read_review_manifest "$run_dir"
        arena_status_kv 'review_head' 'Review HEAD' "$ARENA_REVIEW_HEAD"
        arena_status_kv 'review_worktree' 'Review worktree' "$ARENA_REVIEW_WORKTREE"
        ARENA_STATUS_ERROR='integrity_failed'
        if arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
            "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
            "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
            arena_status_kv 'integrity' 'Integrity' 'OK'
        else
            arena_status_kv 'integrity' 'Integrity' 'FAILED (review snapshot is missing, dirty, or tampered)'
            integrity_status=1
        fi
        ARENA_STATUS_ERROR='unknown'
        expected_short="$(arena_short_sha "$ARENA_REVIEW_HEAD")"
        if [[ -f "${run_dir}/validation.md" ]]; then
            pointer="$(<"${run_dir}/validation.md")"
            if [[ "$pointer" == "Latest validation report: validation-${expected_short}.md" ]]; then
                arena_status_kv 'validation' 'Validation' "$pointer"
            else
                arena_status_kv 'validation' 'Validation' 'not run for current checkpoint'
            fi
        else
            arena_status_kv 'validation' 'Validation' 'not run'
        fi
        if [[ -f "${run_dir}/decision.md" ]]; then
            if grep -Fqx "Review HEAD: ${ARENA_REVIEW_HEAD}" "${run_dir}/decision.md"; then
                arena_status_kv 'decision' 'Decision' "${run_dir}/decision.md"
            else
                arena_status_kv 'decision' 'Decision' 'not recorded for current checkpoint'
            fi
        else
            arena_status_kv 'decision' 'Decision' 'not recorded'
        fi
    else
        arena_status_kv 'review' 'Review' 'no checkpoint submitted'
        arena_status_kv 'validation' 'Validation' 'not run'
        arena_status_kv 'decision' 'Decision' 'not recorded'
    fi
    if [[ "$integrity_status" != 0 ]]; then
        # Tampered evidence fails closed (exit 2): status is an oracle, and
        # a dirty review snapshot is an evidence conflict, not a usage error.
        arena_status_fail 2
    fi
    if [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == none ]]; then
        # Terminal per-scenario line: no pane check, no release command.
        if [[ "$status_json" == 1 ]]; then
            status_kvs+=("\"terminal\":$(arena_json_string "state: ${ARENA_STATE_RUN_STATUS}; verdict: ${ARENA_STATE_VERDICT:-none}")")
        else
            printf 'state: %s; verdict: %s\n' "$ARENA_STATE_RUN_STATUS" "${ARENA_STATE_VERDICT:-none}"
        fi
    else
        if [[ "$status_json" == 1 ]]; then
            diag="$(arena_status_diagnosis "$ARENA_STATE_RESPONSIBLE_PARTY" "$ARENA_STATE_REASON_CODE" \
                "$ARENA_STATE_WAITING_SINCE" "$ARENA_MANIFEST_SESSION_NAME" "$ARENA_MANIFEST_RUN_ID" 2>/dev/null)"
            status_kvs+=("\"diagnosis\":$(arena_json_string "$diag")")
        else
            arena_status_diagnosis "$ARENA_STATE_RESPONSIBLE_PARTY" "$ARENA_STATE_REASON_CODE" \
                "$ARENA_STATE_WAITING_SINCE" "$ARENA_MANIFEST_SESSION_NAME" "$ARENA_MANIFEST_RUN_ID"
        fi
    fi
    # Pane liveness for the JSON contract (the human lines stay inside the
    # diagnosis text, as before).
    if [[ "$status_json" == 1 ]]; then
        reviewer_alive=false
        writer_alive=false
        if command -v tmux >/dev/null 2>&1 && tmux has-session -t "=${ARENA_MANIFEST_SESSION_NAME}" 2>/dev/null; then
            arena_status_reviewer_pane_alive "$ARENA_MANIFEST_SESSION_NAME" && reviewer_alive=true
            arena_status_writer_pane_alive "$ARENA_MANIFEST_SESSION_NAME" && writer_alive=true
        fi
        ARENA_STATUS_PANES="{\"reviewer\":${reviewer_alive},\"writer\":${writer_alive}}"
    fi
    arena_status_build_stages
    arena_status_finish 0
fi

# Legacy run: read-only projection (zero writes, lock-free). Exit codes:
# 0 projected; 2 evidence conflict (fail closed with the conflict list and
# the repair candidates); 5 evidence residue owned by one command.
printf 'State: legacy projection (no run-state.tsv)\n'
# The projection sets ARENA_PROJECTED_* in the current shell, so it must
# not run inside a command substitution; conflicts are printed to stderr
# and captured to a scratch file for the conflict branch.
projection_status=0
conflict_lines=''
projection_tmp="$(mktemp "${TMPDIR:-/tmp}/arena-proj.XXXXXX")"
if arena_state_project_legacy "$run_dir" 2>"$projection_tmp"; then
    :
else
    projection_status=$?
    conflict_lines="$(cat "$projection_tmp")"
fi
rm -f "$projection_tmp"
case "$projection_status" in
    0)
        printf 'legacy / inferred, not persisted: %s / %s / %s\n' \
            "$ARENA_PROJECTED_PHASE" "$ARENA_PROJECTED_PARTY" "$ARENA_PROJECTED_REASON"
        arena_status_diagnosis "$ARENA_PROJECTED_PARTY" "$ARENA_PROJECTED_REASON" \
            "$ARENA_PROJECTED_WAITING_SINCE" "$ARENA_MANIFEST_SESSION_NAME" "$ARENA_MANIFEST_RUN_ID"
        exit 0
        ;;
    2)
        printf 'legacy evidence conflicts:\n'
        printf '%s\n' "$conflict_lines"
        # Repair candidates: refusal-only conflicts print none; admitted
        # candidates also list the discarded (tombstoned) evidence.
        arena_state_repair_candidates "$run_dir"
        if [[ -n "$ARENA_REPAIR_TOMBSTONES" ]]; then
            printf 'discarded evidence:\n'
            IFS=';' read -r -a discarded_files <<<"$ARENA_REPAIR_TOMBSTONES"
            for discarded_file in "${discarded_files[@]}"; do
                printf '  - %s\n' "$discarded_file"
            done
        fi
        arena_status_fail 2
        ;;
    5)
        case "$ARENA_PROJECTED_RESIDUE" in
            validate)
                printf 'incomplete transition; retry: agent-arena validate %s\n' "$run_id"
                ;;
            decision)
                printf 'incomplete transition; retry: agent-arena decision %s --verdict ...\n' "$run_id"
                ;;
            *)
                printf 'incomplete transition; retry: agent-arena repair-state %s --candidate <token> --reason "..."\n' "$run_id"
                ;;
        esac
        ARENA_STATUS_ERROR='incomplete'
        arena_status_fail 5
        ;;
esac
