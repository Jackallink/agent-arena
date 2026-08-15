#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena status RUN_ID [--state-root PATH]

Show the run manifest plus the latest submitted checkpoint, validation report, and
decision record, then the one-sentence diagnosis and any transition anomaly.
This command makes no changes.
EOF
}

run_id=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
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
if arena_state_precheck_lock_live "${run_dir}/.run-lock"; then
    printf 'transition in progress\n'
    exit 4
fi
if arena_state_precheck_lock_live "${runs_root}/${repo_id}/.parent-lock"; then
    printf 'transition in progress\n'
    exit 4
fi
# Priority check (2): creation intent with no live owner. S1/S2/S5/S6 are
# owned by start (exit 5, retry: start); S3/S4 take the manual abort
# protocol (exit 2) for status.
arena_state_precheck_intents "$runs_root" "$repo_id" "$run_id" status
# Priority check (3): repair intent with no live lock, before any ordinary
# state parse.
if [[ -f "${run_dir}/.repair.intent" ]]; then
    printf 'incomplete transition; retry: agent-arena repair-state %s --candidate <token> --reason "..."\n' "$run_id"
    exit 5
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
}

printf 'Run: %s\n' "$ARENA_MANIFEST_RUN_ID"
printf 'Repository: %s\n' "$ARENA_MANIFEST_REPOSITORY"
printf 'Base: %s\n' "$ARENA_MANIFEST_BASE_SHA"
printf 'Profile: %s\n' "$ARENA_MANIFEST_PROFILE"
printf 'Writer adapter: %s\n' "$ARENA_MANIFEST_WRITER_ADAPTER"
printf 'Gate: %s\n' "$ARENA_MANIFEST_GATE_ADAPTER"
printf 'Writer: %s\n' "$ARENA_MANIFEST_WRITER_LABEL"
printf 'Writer worktree: %s\n' "$ARENA_MANIFEST_WRITER_WORKTREE"
printf 'Branch: %s\n' "$ARENA_MANIFEST_BRANCH"
printf 'Tmux session: %s\n' "$ARENA_MANIFEST_SESSION_NAME"

if [[ -f "${run_dir}/run-state.tsv" ]]; then
    # Priority check (4): ordinary parse of the authoritative state.
    # Corrupted or illegal state fails closed (exit 2).
    arena_state_read "$run_dir"
    printf 'State: %s\n' "$run_dir"
    integrity_status=0
    if [[ -f "${run_dir}/review.tsv" ]]; then
        arena_read_review_manifest "$run_dir"
        printf 'Review HEAD: %s\n' "$ARENA_REVIEW_HEAD"
        printf 'Review worktree: %s\n' "$ARENA_REVIEW_WORKTREE"
        if arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
            "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
            "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
            printf 'Integrity: OK\n'
        else
            printf 'Integrity: FAILED (review snapshot is missing, dirty, or tampered)\n'
            integrity_status=1
        fi
        expected_short="$(arena_short_sha "$ARENA_REVIEW_HEAD")"
        if [[ -f "${run_dir}/validation.md" ]]; then
            pointer="$(<"${run_dir}/validation.md")"
            if [[ "$pointer" == "Latest validation report: validation-${expected_short}.md" ]]; then
                printf 'Validation: %s\n' "$pointer"
            else
                printf 'Validation: not run for current checkpoint\n'
            fi
        else
            printf 'Validation: not run\n'
        fi
        if [[ -f "${run_dir}/decision.md" ]]; then
            if grep -Fqx "Review HEAD: ${ARENA_REVIEW_HEAD}" "${run_dir}/decision.md"; then
                printf 'Decision: %s\n' "${run_dir}/decision.md"
            else
                printf 'Decision: not recorded for current checkpoint\n'
            fi
        else
            printf 'Decision: not recorded\n'
        fi
    else
        printf 'Review: no checkpoint submitted\n'
        printf 'Validation: not run\n'
        printf 'Decision: not recorded\n'
    fi
    if [[ "$integrity_status" != 0 ]]; then
        # Tampered evidence fails closed (exit 2): status is an oracle, and
        # a dirty review snapshot is an evidence conflict, not a usage error.
        exit 2
    fi
    if [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == none ]]; then
        # Terminal per-scenario line: no pane check, no release command.
        printf 'state: %s; verdict: %s\n' "$ARENA_STATE_RUN_STATUS" "${ARENA_STATE_VERDICT:-none}"
    else
        arena_status_diagnosis "$ARENA_STATE_RESPONSIBLE_PARTY" "$ARENA_STATE_REASON_CODE" \
            "$ARENA_STATE_WAITING_SINCE" "$ARENA_MANIFEST_SESSION_NAME" "$ARENA_MANIFEST_RUN_ID"
    fi
    exit 0
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
        exit 2
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
        exit 5
        ;;
esac
