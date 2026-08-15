#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
# Per-run anomaly detection needs the lock and intent helpers plus the
# read-only legacy projection; the priority check is the same the
# transition commands and status run.
source "${source_root}/lib/state.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena list [--state-root PATH]

List every recorded run with fixed columns: REPOSITORY RUN_ID PROFILE GATE
RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY. AUTHORITY
is `state` for the authoritative v1 state and `legacy` for the read-only
projection; ANOMALY is one of corrupt, conflict, in-progress, or incomplete
(empty when none). This command makes no changes.
EOF
}

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
        *) arena_die "unknown option: $1" ;;
    esac
done

runs_root="$(arena_state_root)/runs"
if [[ ! -d "$runs_root" ]]; then
    arena_note 'no runs recorded'
    exit 0
fi

# Print one fixed-column row for a run and exit with that run's anomaly
# code: 4 live lock (in-progress), 5 incomplete transition, 2 corrupt
# state or legacy evidence conflict, 0 normal. The caller aggregates the
# per-run codes by priority 5 > 4 > 2 > 0.
arena_list_row() {
    local run_dir="$1" runs_root="$2"
    local run_id repository profile gate row_exit anomaly stage intent repo_id
    local run_status phase party reason_code waiting_since authority
    local projection_status

    run_id=''; repository=''; profile=''; gate=''
    run_status=''; phase=''; party=''; reason_code=''
    waiting_since=''; authority=''; anomaly=''
    row_exit=0

    run_id="$(awk -F $'\t' '$1 == "run_id" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    repository="$(awk -F $'\t' '$1 == "repository" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    profile="$(awk -F $'\t' '$1 == "profile" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    gate="$(awk -F $'\t' '$1 == "gate_adapter" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    # v0.1 manifests carry no profile or gate_adapter field; they are
    # Pi-only by definition with the Cursor gate.
    [[ -n "$run_id" ]] || run_id='<unreadable>'
    [[ -n "$repository" ]] || repository='<unreadable>'
    [[ -n "$profile" ]] || profile='pi-cursor'
    [[ -n "$gate" ]] || gate='cursor'

    repo_id="$(basename "$(dirname "$run_dir")")"
    # Priority check (1): a live run or parent creation lock wins (exit 4).
    if arena_state_precheck_lock_live "${run_dir}/.run-lock" || \
        arena_state_precheck_lock_live "${runs_root}/${repo_id}/.parent-lock"; then
        anomaly='in-progress'
        row_exit=4
        printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
            "$repository" "$run_id" "$profile" "$gate" \
            "$run_status" "$phase" "$party" "$reason_code" \
            "$waiting_since" "$authority" "$anomaly"
        return "$row_exit"
    fi
    # Priority check (2): creation intent with no live owner. S3/S4 take the
    # manual abort path (exit 2) for list; S1/S2/S5/S6 are owned by start
    # (exit 5).
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    if [[ -e "$intent" ]]; then
        stage="$(arena_creation_intent_stage "$runs_root" "$repo_id" "$run_id")"
        anomaly='incomplete'
        case "$stage" in
            S3|S4) row_exit=2 ;;
            *) row_exit=5 ;;
        esac
        printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
            "$repository" "$run_id" "$profile" "$gate" \
            "$run_status" "$phase" "$party" "$reason_code" \
            "$waiting_since" "$authority" "$anomaly"
        return "$row_exit"
    fi
    # Priority check (3): repair intent with no live lock (exit 5) before
    # any ordinary state parse.
    if [[ -f "${run_dir}/.repair.intent" ]]; then
        anomaly='incomplete'
        row_exit=5
        printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
            "$repository" "$run_id" "$profile" "$gate" \
            "$run_status" "$phase" "$party" "$reason_code" \
            "$waiting_since" "$authority" "$anomaly"
        return "$row_exit"
    fi
    # Priority check (4): ordinary parse.
    if [[ -f "${run_dir}/run-state.tsv" ]]; then
        if arena_state_read "$run_dir" >/dev/null 2>&1; then
            authority='state'
            run_status="$ARENA_STATE_RUN_STATUS"
            phase="$ARENA_STATE_PHASE"
            party="$ARENA_STATE_RESPONSIBLE_PARTY"
            reason_code="$ARENA_STATE_REASON_CODE"
            waiting_since="$ARENA_STATE_WAITING_SINCE"
        else
            anomaly='corrupt'
            row_exit=2
        fi
    else
        authority='legacy'
        projection_status=0
        arena_state_project_legacy "$run_dir" >/dev/null 2>&1 || projection_status=$?
        case "$projection_status" in
            0)
                run_status='active'
                phase="$ARENA_PROJECTED_PHASE"
                party="$ARENA_PROJECTED_PARTY"
                reason_code="$ARENA_PROJECTED_REASON"
                waiting_since='unknown'
                ;;
            2)
                anomaly='conflict'
                row_exit=2
                ;;
            5)
                anomaly='incomplete'
                row_exit=5
                ;;
        esac
    fi
    printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
        "$repository" "$run_id" "$profile" "$gate" \
        "$run_status" "$phase" "$party" "$reason_code" \
        "$waiting_since" "$authority" "$anomaly"
    return "$row_exit"
}

rows=''
max_exit=0
found=0
while IFS= read -r manifest; do
    [[ -n "$manifest" ]] || continue
    run_dir="$(dirname "$manifest")"
    row="$(arena_list_row "$run_dir" "$runs_root")" && row_exit=0 || row_exit=$?
    rows="${rows}${row}"$'\n'
    [[ "$row_exit" -gt "$max_exit" ]] && max_exit="$row_exit"
    found=1
done < <(find "$runs_root" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv 2>/dev/null | sort)

if [[ "$found" == 0 ]]; then
    arena_note 'no runs recorded'
    exit 0
fi

printf 'REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY\n'
# Rows are sorted by the composite key (REPOSITORY, RUN_ID): the repository
# is the first column, so a line sort applies the exact composite order.
printf '%s' "$rows" | sort
exit "$max_exit"
