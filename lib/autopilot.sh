#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/lock.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena autopilot [options]

Orchestrate approval modes. In auto mode, approve validated APPROVE checkpoints
after the cooling window; in every mode, alert (exit 6) when a run needs a
human. Never cancels, rejects, merges, or pushes.

Options:
  --once                  Run one scan and exit (cron-friendly)
  --interval SECONDS      Watch loop interval (default 30)
  --approve-delay SECONDS Minimum wait after the decision before approving
                          (default 300)
  --relay-after MINUTES   Remind a stalled writer at most this often (default 30)
  --resume-attempts N     Max automatic reviewer-pane respawns per blocked run
                          (default 0 = never; trust prompts still need a human)
  --repo PATH|ID          Scope: one repository (default: cwd repository)
  --all-repos             Scope: every repository in the state root
  --rounds N              Run N scans then exit (hermetic-test hook)
  --state-root PATH       Private run-state root override
  -h, --help              Show this help
EOF
}

once=0
interval=30
approve_delay=300
relay_after=30
resume_attempts=0
scope_mode='cwd'
repo_arg=''
rounds=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) once=1; shift ;;
        --watch) once=0; shift ;;
        --interval) [[ $# -ge 2 ]] || arena_die '--interval requires a value'; interval="$2"; shift 2 ;;
        --approve-delay) [[ $# -ge 2 ]] || arena_die '--approve-delay requires a value'; approve_delay="$2"; shift 2 ;;
        --relay-after) [[ $# -ge 2 ]] || arena_die '--relay-after requires a value'; relay_after="$2"; shift 2 ;;
        --resume-attempts) [[ $# -ge 2 ]] || arena_die '--resume-attempts requires a value'; resume_attempts="$2"; shift 2 ;;
        --repo) [[ $# -ge 2 ]] || arena_die '--repo requires a value'; repo_arg="$2"; scope_mode='repo'; shift 2 ;;
        --all-repos) scope_mode='all'; shift ;;
        --rounds) [[ $# -ge 2 ]] || arena_die '--rounds requires a value'; rounds="$2"; shift 2 ;;
        --state-root) [[ $# -ge 2 ]] || arena_die '--state-root requires a value'; ARENA_STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *) arena_die 'autopilot takes no positional arguments' ;;
    esac
done
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 1 ]] || arena_die '--interval must be a positive integer'
[[ "$approve_delay" =~ ^[0-9]+$ ]] || arena_die '--approve-delay must be an integer'
[[ "$relay_after" =~ ^[0-9]+$ ]] || arena_die '--relay-after must be an integer'
[[ "$resume_attempts" =~ ^[0-9]+$ ]] || arena_die '--resume-attempts must be an integer'

state_root="$(arena_state_root)"
runs_root="${state_root}/runs"
instance="$(hostname 2>/dev/null || printf localhost).$$.${RANDOM}"
arena_command="${ARENA_COMMAND:-${source_root}/bin/agent-arena}"
now() { date +%s; }

# ---- observation files (never authoritative) ----
autopilot_log="${state_root}/autopilot.log"
throttle_file="${state_root}/autopilot-throttle.tsv"

AP_ACTED=0

arena_autopilot_log() {
    local run_id="$1" mode="$2" state="$3" action="$4" result="$5"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$run_id" "$mode" "$state" "$action" "$result" >>"$autopilot_log"
    # rotate at 1 MB, keep 3
    if [[ "$(wc -c <"$autopilot_log" 2>/dev/null || printf 0)" -gt 1048576 ]]; then
        mv "$autopilot_log" "${autopilot_log}.1" 2>/dev/null || true
        mv "${autopilot_log}.1" "${autopilot_log}.2" 2>/dev/null || true
        mv "${autopilot_log}.2" "${autopilot_log}.3" 2>/dev/null || true
        : >"$autopilot_log"
    fi
}

# ---- scope ----
arena_autopilot_scope_dirs() {
    local repo_id dir
    case "$scope_mode" in
        all)
            find "$runs_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
            ;;
        repo)
            if [[ -d "$repo_arg" ]]; then
                repo_id="$(arena_repo_id "$(arena_abs_dir "$repo_arg")")"
            else
                repo_id="$repo_arg"
            fi
            dir="${runs_root}/${repo_id}"
            if [[ -d "$dir" ]]; then
                printf '%s\n' "$dir"
            fi
            ;;
        cwd)
            repo_id="$(arena_repo_id "$(arena_abs_dir "$PWD")")"
            dir="${runs_root}/${repo_id}"
            if [[ -d "$dir" ]]; then
                printf '%s\n' "$dir"
            fi
            ;;
    esac
    return 0
}

# ---- status read (the ONLY read path per run) ----
# Returns via stdout: the status output; sets AP_STATUS_EXIT, AP_MODE,
# AP_STATE (run_status/phase/party/reason), AP_VERDICT, AP_VR, AP_LTA,
# AP_REVIEWER_PANE, AP_WRITER_PANE, AP_WAITING (waiting_since from the
# diagnosis line or empty).
arena_autopilot_read_run() {
    local run_dir="$1" run_id="$2" out
    AP_MODE='human'
    AP_STATE=''
    AP_VERDICT=''
    AP_VR=''
    AP_LTA=''
    AP_REVIEWER_PANE=''
    AP_WRITER_PANE=''
    AP_WAITING=''
    # manifest mode (mirrors status): fall back to human for legacy manifests
    if [[ -f "${run_dir}/manifest.tsv" ]]; then
        AP_MODE="$(awk -F $'\t' '$1 == "mode" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
        [[ -n "$AP_MODE" ]] || AP_MODE='human'
    fi
    if out="$(ARENA_STATE_ROOT="$state_root" "$arena_command" status "$run_id" --state-root "$state_root" 2>&1)"; then
        AP_STATUS_EXIT=0
    else
        AP_STATUS_EXIT=$?
    fi
    AP_OUTPUT="$out"
    AP_VERDICT="$(printf '%s\n' "$out" | sed -n 's/^Verdict: //p' | head -1)"
    AP_VR="$(printf '%s\n' "$out" | sed -n 's/^Validation result: //p' | head -1)"
    AP_LTA="$(printf '%s\n' "$out" | sed -n 's/^Last transition at: //p' | head -1)"
    AP_REVIEWER_PANE="$(printf '%s\n' "$out" | sed -n 's/^Reviewer pane: //p' | head -1)"
    AP_WRITER_PANE="$(printf '%s\n' "$out" | sed -n 's/^Writer pane: //p' | head -1)"
    AP_STATE="$(printf '%s\n' "$out" | sed -n 's/^State: //p' | head -1)"
    # one-sentence diagnosis: "waiting on <party> for <reason> since <ts>; ..."
    AP_WAITING="$(printf '%s\n' "$out" | sed -n 's/.*waiting on [a-z]* for [a-z_]* since \([0-9]*\).*/\1/p' | head -1)"
    # terminal line: "state: completed; verdict: APPROVE"
    if [[ -z "$AP_STATE" ]]; then
        AP_STATE="$(printf '%s\n' "$out" | sed -n 's/^state: \([a-z]*\); verdict:.*/\1/p' | head -1)"
    fi
}

# state tuple: party:reason (parsed from the waiting/diagnosis line)
arena_autopilot_tuple() {
    local out="$1"
    printf '%s\n' "$out" | sed -n 's/.*waiting on \([a-z]*\) for \([a-z_]*\) since.*/\1:\2/p' | head -1
}

# ---- actions ----
arena_autopilot_resolve_approve() {
    local run_id="$1" ts="$2"
    ARENA_STATE_ROOT="$state_root" "$arena_command" resolve "$run_id" \
        --action approve --actor system --reason "autopilot ${instance} ${ts}" >/dev/null 2>&1
}

arena_autopilot_escalate() {
    local run_id="$1" ts="$2"
    ARENA_STATE_ROOT="$state_root" "$arena_command" escalate "$run_id" \
        --reason-code reviewer_unreachable --reason "autopilot ${instance} ${ts}" --actor system >/dev/null 2>&1
}

arena_autopilot_relay() {
    local run_id="$1"
    ARENA_STATE_ROOT="$state_root" "$arena_command" relay "$run_id" --to writer \
        --message "[autopilot] run ${run_id} has been waiting for changes for a while; please continue and submit a new checkpoint." >/dev/null 2>&1
}

arena_autopilot_resume() {
    local run_id="$1" repo_arg_opt="$2"
    ARENA_STATE_ROOT="$state_root" ARENA_WORKTREE_ROOT="${ARENA_WORKTREE_ROOT:-}" \
        "$arena_command" resume "$run_id" $repo_arg_opt --no-attach >/dev/null 2>&1
}

# relay throttle: return 0 when a reminder may be sent, 1 when throttled
arena_autopilot_relay_allowed() {
    local run_id="$1" now_ts="$2" window_min="$3" last
    last="$(awk -F $'\t' -v r="$run_id" '$1 == r && $2 == "changes_requested" { print $3 }' "$throttle_file" 2>/dev/null | tail -1)"
    [[ -z "$last" ]] && return 0
    [[ "$((now_ts - last))" -ge "$((window_min * 60))" ]]
}

arena_autopilot_relay_record() {
    local run_id="$1" now_ts="$2"
    {
        awk -F $'\t' -v r="$run_id" '$1 != r || $2 != "changes_requested" { print }' "$throttle_file" 2>/dev/null
        printf '%s\t%s\t%s\n' "$run_id" 'changes_requested' "$now_ts"
    } >"${throttle_file}.tmp" 2>/dev/null || true
    mv "${throttle_file}.tmp" "$throttle_file" 2>/dev/null || true
}

# ---- per-run scan: returns 0 ok / 4 defer / 6 needs-human-or-error ----
arena_autopilot_scan_run() {
    local run_dir="$1" run_id="$2" tuple verdict vr lta reviewer_pane writer_pane
    local now_ts party reason waiting

    now_ts="$(now)"
    arena_autopilot_read_run "$run_dir" "$run_id"
    tuple="$(arena_autopilot_tuple "$AP_OUTPUT")"
    party="${tuple%%:*}"
    reason="${tuple##*:}"
    [[ "$party" == "$reason" ]] && party='' && reason=''

    case "$AP_STATUS_EXIT" in
        4)
            arena_autopilot_log "$run_id" "$AP_MODE" 'locked' 'scan' 'deferred'
            return 4
            ;;
        2)
            arena_autopilot_log "$run_id" "$AP_MODE" 'corrupt-or-conflict' 'scan' 'error'
            return 6
            ;;
        5)
            # incomplete: intent stages / legacy residue skip silently;
            # repair-intent residue and other incomplete states error
            if printf '%s' "$AP_OUTPUT" | grep -q 'incomplete transition'; then
                arena_autopilot_log "$run_id" "$AP_MODE" 'incomplete' 'scan' 'error'
                return 6
            fi
            arena_autopilot_log "$run_id" "$AP_MODE" 'intent-or-legacy' 'scan' 'deferred'
            return 0
            ;;
        1)
            arena_autopilot_log "$run_id" "$AP_MODE" 'unexpected' 'scan' 'error'
            return 6
            ;;
    esac

    # state parse from the extended output
    if printf '%s' "$AP_OUTPUT" | grep -q '^run_status'; then
        # status oracle prints run-state fields only for v1 runs? no: we
        # derive from the diagnosis; if no diagnosis, treat as observe
        :
    fi

    case "$party:$reason" in
        human:approval_pending)
            if [[ "$AP_VERDICT" == APPROVE && "$AP_VR" == PASS ]]; then
                if [[ -n "$AP_LTA" && "$((now_ts - AP_LTA))" -ge "$approve_delay" ]]; then
                    if [[ "$AP_MODE" == auto ]]; then
                        if arena_autopilot_resolve_approve "$run_id" "$now_ts"; then
                            AP_ACTED=$((AP_ACTED + 1))
                            arena_autopilot_log "$run_id" "$AP_MODE" 'approval_pending' 'resolve-approve' 'acted'
                        else
                            arena_autopilot_log "$run_id" "$AP_MODE" 'approval_pending' 'resolve-approve' 'error'
                            return 6
                        fi
                    else
                        arena_autopilot_log "$run_id" "$AP_MODE" 'approval_pending' 'alert' 'needs-human'
                        return 6
                    fi
                else
                    arena_autopilot_log "$run_id" "$AP_MODE" 'approval_pending' 'cooling' 'deferred'
                fi
            else
                arena_autopilot_log "$run_id" "$AP_MODE" 'approval_pending' 'guard-mismatch' 'error'
                return 6
            fi
            ;;
        human:block_resolution_required)
            arena_autopilot_log "$run_id" "$AP_MODE" 'blocked' 'alert' 'needs-human'
            return 6
            ;;
        human:reviewer_unreachable)
            if [[ "$AP_MODE" == auto && "$resume_attempts" -gt 0 ]]; then
                arena_autopilot_log "$run_id" "$AP_MODE" 'blocked' 'resume' 'unconfirmed'
                arena_autopilot_resume "$run_id" "$repo_arg" || true
            fi
            arena_autopilot_log "$run_id" "$AP_MODE" 'blocked' 'alert' 'needs-human'
            return 6
            ;;
        reviewer:review_pending|reviewer:decision_pending)
            if [[ "$AP_REVIEWER_PANE" == unreachable ]]; then
                if [[ "$AP_MODE" == auto ]]; then
                    arena_autopilot_escalate "$run_id" "$now_ts" || true
                    AP_ACTED=$((AP_ACTED + 1))
                    arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'escalate' 'acted'
                else
                    arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'alert' 'needs-human'
                fi
                return 6
            fi
            # stall: waiting longer than the pinned 30-minute threshold alerts
            if [[ -n "$AP_WAITING" && "$AP_WAITING" =~ ^[0-9]+$ && \
                "$((now_ts - AP_WAITING))" -gt 1800 ]]; then
                arena_autopilot_log "$run_id" "$AP_MODE" "stalled:${reason}" 'alert' 'needs-human'
                return 6
            fi
            arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'scan' 'deferred'
            ;;
        writer:changes_requested|writer:human_changes_requested)
            if [[ "$AP_WRITER_PANE" == unreachable ]]; then
                arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'alert' 'needs-human'
                return 6
            fi
            if arena_autopilot_relay_allowed "$run_id" "$now_ts" "$relay_after"; then
                arena_autopilot_relay "$run_id" || true
                arena_autopilot_relay_record "$run_id" "$now_ts"
                AP_ACTED=$((AP_ACTED + 1))
                arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'relay' 'acted'
            else
                arena_autopilot_log "$run_id" "$AP_MODE" "$reason" 'relay' 'skipped-throttled'
            fi
            ;;
        *)
            arena_autopilot_log "$run_id" "$AP_MODE" "${party:-?}:${reason:-?}" 'scan' 'deferred'
            ;;
    esac
    return 0
}

# ---- heartbeat ----
arena_autopilot_heartbeat() {
    local last_scan="$1" scanned="$2" acted="$3" errors="$4" needs_human="$5" scope="$6"
    local file="${state_root}/autopilot.tsv"
    {
        awk -F $'\t' -v inst="$instance" '$1 != inst { print }' "$file" 2>/dev/null
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$instance" "$last_scan" "$scanned" "$acted" "$errors" "$needs_human" "$(now)" "$scope"
    } >"${file}.tmp" 2>/dev/null || true
    mv "${file}.tmp" "$file" 2>/dev/null || true
    # refresh the autopilot lock liveness
    if arena_lock_is_held "${state_root}/.autopilot-lock"; then
        arena_lock_touch "${state_root}/.autopilot-lock" "autopilot-$$" 2>/dev/null || true
    fi
}

# ---- one scan round: returns the aggregate exit code (6 > 4 > 0) ----
arena_autopilot_round() {
    local scanned=0 acted=0 errors=0 needs_human=0 round_exit=0 per_run_exit row
    local scope_dirs run_dir run_id

    scope_dirs="$(arena_autopilot_scope_dirs)"
    while IFS= read -r repo_dir; do
        [[ -n "$repo_dir" ]] || continue
        while IFS= read -r manifest; do
            [[ -n "$manifest" ]] || continue
            run_dir="$(dirname "$manifest")"
            run_id="$(basename "$run_dir")"
            scanned=$((scanned + 1))
            per_run_exit=0
            arena_autopilot_scan_run "$run_dir" "$run_id" || per_run_exit=$?
            case "$per_run_exit" in
                6) needs_human=$((needs_human + 1)) ;;
            esac
            # per-run TSV summary (--once stdout; watch keeps it in the log)
            printf '%s\t%s\t%s\t%s\t%s\n' "$run_id" "$AP_MODE" "${AP_STATE:-?}" 'scan' "$per_run_exit"
        done < <(find "$repo_dir" -mindepth 2 -maxdepth 2 -type f -name manifest.tsv 2>/dev/null | sort)
    done <<<"$scope_dirs"

    acted="$AP_ACTED"
    [[ "$needs_human" -gt 0 ]] && round_exit=6
    arena_autopilot_heartbeat "$(now)" "$scanned" "$acted" "$errors" "$needs_human" "$scope_mode"
    return "$round_exit"
}

# ---- main loop ----
# Single-instance per state root: acquire the autopilot lock up front. A live
# lock is pid alive AND last_seen fresh (< 3x interval); a stale or dead
# owner is reclaimed atomically. v0.4-style owners without last_seen stay
# live while the pid is alive (backward compatible).
arena_autopilot_lock_path="${state_root}/.autopilot-lock"
arena_autopilot_lock_live() {
    local last_seen now_ts
    arena_lock_is_held "$1" || return 1
    arena_lock_owner_alive "$1" || return 1
    last_seen="$(awk -F= '$1 == "last_seen_at" { print $2 }' "$1/owner" 2>/dev/null)"
    if [[ -z "$last_seen" ]]; then
        return 0
    fi
    [[ "$last_seen" =~ ^[0-9]+$ ]] || return 0
    now_ts="$(now)"
    [[ "$((now_ts - last_seen))" -le "$((3 * interval))" ]]
}
if ! mkdir "$arena_autopilot_lock_path" 2>/dev/null; then
    if arena_autopilot_lock_live "$arena_autopilot_lock_path"; then
        printf 'autopilot already running (pid %s); --once with a live watch exits 4 (normal)\n' \
            "$(arena_lock_owner_pid "$arena_autopilot_lock_path")" >&2
        exit 4
    fi
    arena_lock_reclaim "$arena_autopilot_lock_path" "autopilot-$$" || exit 4
fi
{
    printf 'pid=%s\n' "$$"
    printf 'token=%s\n' "autopilot-$$"
    printf 'created_at=%s\n' "$(now)"
    printf 'last_seen_at=%s\n' "$(now)"
} >"${arena_autopilot_lock_path}/owner.tmp.$$"
mv "${arena_autopilot_lock_path}/owner.tmp.$$" "${arena_autopilot_lock_path}/owner"

arena_autopilot_cleanup() {
    if arena_lock_is_held "$arena_autopilot_lock_path" && \
        [[ "$(arena_lock_owner_token "$arena_autopilot_lock_path")" == "autopilot-$$" ]]; then
        rm -rf "$arena_autopilot_lock_path" 2>/dev/null || true
    fi
}
trap arena_autopilot_cleanup EXIT
# SIGTERM/SIGINT must release the lock too (kill of a watch would otherwise
# leave a live-looking lock behind for the next --once)
trap 'arena_autopilot_cleanup; exit 0' TERM INT

if [[ "$once" == 1 ]]; then
    arena_autopilot_round
    exit $?
fi
round_count=0
last_round_exit=0
while :; do
    round_count=$((round_count + 1))
    last_round_exit=0
    arena_autopilot_round || last_round_exit=$?
    if [[ "$rounds" -gt 0 && "$round_count" -ge "$rounds" ]]; then
        exit "$last_round_exit"
    fi
    sleep "$interval"
done
