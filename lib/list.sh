#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/json.sh"
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
        --json)
            list_json=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done
list_json="${list_json:-0}"

runs_root="$(arena_state_root)/runs"
if [[ ! -d "$runs_root" ]]; then
    if [[ "$list_json" == 1 ]]; then
        printf '{"schema":1,"generated_at":%s,"runs":[]}\n' "$(date +%s)"
    else
        arena_note 'no runs recorded'
    fi
    exit 0
fi

# Resolve one run's list fields into ARENA_LIST_* globals and return the
# run's anomaly code: 4 live lock (in-progress), 5 incomplete transition,
# 2 corrupt state or legacy evidence conflict, 0 normal. The caller
# aggregates the per-run codes by priority 5 > 4 > 2 > 0 and renders the
# fields as fixed columns (human) or a JSON object (--json).
arena_list_fields() {
    local run_dir="$1" runs_root="$2"
    local anomaly stage intent repo_id projection_status

    ARENA_LIST_RUN_ID=''; ARENA_LIST_REPOSITORY=''; ARENA_LIST_PROFILE=''; ARENA_LIST_GATE=''
    ARENA_LIST_MODE='human'; ARENA_LIST_RUN_STATUS=''; ARENA_LIST_PHASE=''; ARENA_LIST_PARTY=''
    ARENA_LIST_REASON_CODE=''; ARENA_LIST_WAITING_SINCE=''; ARENA_LIST_AUTHORITY=''; ARENA_LIST_ANOMALY=''
    ARENA_LIST_PIPELINE=''

    ARENA_LIST_RUN_ID="$(awk -F $'\t' '$1 == "run_id" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    ARENA_LIST_REPOSITORY="$(awk -F $'\t' '$1 == "repository" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    ARENA_LIST_PROFILE="$(awk -F $'\t' '$1 == "profile" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    ARENA_LIST_GATE="$(awk -F $'\t' '$1 == "gate_adapter" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    ARENA_LIST_MODE="$(awk -F $'\t' '$1 == "mode" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    ARENA_LIST_PIPELINE="$(awk -F $'\t' '$1 == "pipeline" { print $2 }' "${run_dir}/manifest.tsv" | head -1)"
    # v0.1 manifests carry no profile or gate_adapter field; they are
    # Pi-only by definition with the Cursor gate.
    [[ -n "$ARENA_LIST_RUN_ID" ]] || ARENA_LIST_RUN_ID='<unreadable>'
    [[ -n "$ARENA_LIST_REPOSITORY" ]] || ARENA_LIST_REPOSITORY='<unreadable>'
    [[ -n "$ARENA_LIST_PROFILE" ]] || ARENA_LIST_PROFILE='pi-cursor'
    [[ -n "$ARENA_LIST_GATE" ]] || ARENA_LIST_GATE='cursor'
    [[ -n "$ARENA_LIST_MODE" ]] || ARENA_LIST_MODE='human'

    repo_id="$(basename "$(dirname "$run_dir")")"
    # Priority check (1): a live run or parent creation lock wins (exit 4).
    if arena_state_precheck_lock_live "${run_dir}/.run-lock" || \
        arena_state_precheck_lock_live "${runs_root}/${repo_id}/.parent-lock"; then
        ARENA_LIST_ANOMALY='in-progress'
        return 4
    fi
    # Priority check (2): creation intent with no live owner. S3/S4 take the
    # manual abort path (exit 2) for list; S1/S2/S5/S6 are owned by start
    # (exit 5).
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$ARENA_LIST_RUN_ID")"
    if [[ -e "$intent" ]]; then
        stage="$(arena_creation_intent_stage "$runs_root" "$repo_id" "$ARENA_LIST_RUN_ID")"
        ARENA_LIST_ANOMALY='incomplete'
        case "$stage" in
            S3|S4) return 2 ;;
            *) return 5 ;;
        esac
    fi
    # Priority check (3): repair intent with no live lock (exit 5) before
    # any ordinary state parse.
    if [[ -f "${run_dir}/.repair.intent" ]]; then
        ARENA_LIST_ANOMALY='incomplete'
        return 5
    fi
    # Priority check (4): ordinary parse.
    if [[ -f "${run_dir}/run-state.tsv" ]]; then
        # Probe first in a subshell: arena_state_read dies with exit 2 on
        # corruption, and an explicit exit inside an if-condition would
        # otherwise kill the whole row. Success path re-reads in this shell
        # so the ARENA_STATE_* fields stay available.
        if ( arena_state_read "$run_dir" ) >/dev/null 2>&1; then
            arena_state_read "$run_dir"
            ARENA_LIST_AUTHORITY='state'
            ARENA_LIST_RUN_STATUS="$ARENA_STATE_RUN_STATUS"
            ARENA_LIST_PHASE="$ARENA_STATE_PHASE"
            ARENA_LIST_PARTY="$ARENA_STATE_RESPONSIBLE_PARTY"
            ARENA_LIST_REASON_CODE="$ARENA_STATE_REASON_CODE"
            ARENA_LIST_WAITING_SINCE="$ARENA_STATE_WAITING_SINCE"
        else
            ARENA_LIST_ANOMALY='corrupt'
            return 2
        fi
    else
        ARENA_LIST_AUTHORITY='legacy'
        projection_status=0
        arena_state_project_legacy "$run_dir" >/dev/null 2>&1 || projection_status=$?
        case "$projection_status" in
            0)
                ARENA_LIST_RUN_STATUS='active'
                ARENA_LIST_PHASE="$ARENA_PROJECTED_PHASE"
                ARENA_LIST_PARTY="$ARENA_PROJECTED_PARTY"
                ARENA_LIST_REASON_CODE="$ARENA_PROJECTED_REASON"
                ARENA_LIST_WAITING_SINCE='unknown'
                ;;
            2)
                ARENA_LIST_ANOMALY='conflict'
                return 2
                ;;
            5)
                ARENA_LIST_ANOMALY='incomplete'
                return 5
                ;;
        esac
    fi
    return 0
}

# Render the resolved fields as the fixed-column human row.
arena_list_row_text() {
    local row_exit=0
    arena_list_fields "$1" "$2" || row_exit=$?
    printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
        "$ARENA_LIST_REPOSITORY" "$ARENA_LIST_RUN_ID" "$ARENA_LIST_PROFILE" "$ARENA_LIST_GATE" \
        "$ARENA_LIST_RUN_STATUS" "$ARENA_LIST_PHASE" "$ARENA_LIST_PARTY" "$ARENA_LIST_REASON_CODE" \
        "$ARENA_LIST_WAITING_SINCE" "$ARENA_LIST_AUTHORITY" "$ARENA_LIST_ANOMALY"
    return "$row_exit"
}

# Render the resolved fields as one JSON object (JSON contract v1).
arena_list_row_json() {
    local row_exit=0 list_first_stage list_stage
    arena_list_fields "$1" "$2" || row_exit=$?
    printf '{"run_id":%s,"repository":%s,"profile":%s,"gate":%s,"mode":%s,' \
        "$(arena_json_string "$ARENA_LIST_RUN_ID")" \
        "$(arena_json_string "$ARENA_LIST_REPOSITORY")" \
        "$(arena_json_string "$ARENA_LIST_PROFILE")" \
        "$(arena_json_string "$ARENA_LIST_GATE")" \
        "$(arena_json_string "$ARENA_LIST_MODE")"
    printf '"run_status":%s,"phase":%s,"party":%s,"reason_code":%s,' \
        "$(arena_json_string "$ARENA_LIST_RUN_STATUS")" \
        "$(arena_json_string "$ARENA_LIST_PHASE")" \
        "$(arena_json_string "$ARENA_LIST_PARTY")" \
        "$(arena_json_string "$ARENA_LIST_REASON_CODE")"
    if [[ -n "$ARENA_LIST_PIPELINE" ]]; then
        printf '"pipeline":['
        list_first_stage=1
        for list_stage in ${ARENA_LIST_PIPELINE//,/ }; do
            [[ "$list_first_stage" == 1 ]] || printf ','
            list_first_stage=0
            printf '%s' "$(arena_json_string "$list_stage")"
        done
        printf '],'
    fi
    printf '"waiting_since":%s,"authority":%s,"anomaly":%s}' \
        "$(arena_json_string "$ARENA_LIST_WAITING_SINCE")" \
        "$(arena_json_string "$ARENA_LIST_AUTHORITY")" \
        "$(arena_json_string "$ARENA_LIST_ANOMALY")"
    printf '\n'
    return "$row_exit"
}

if [[ "$list_json" == 1 ]]; then
    list_row_renderer='arena_list_row_json'
else
    list_row_renderer='arena_list_row_text'
fi

rows=''
max_exit=0
found=0
while IFS= read -r manifest; do
    [[ -n "$manifest" ]] || continue
    run_dir="$(dirname "$manifest")"
    row="$("$list_row_renderer" "$run_dir" "$runs_root")" && row_exit=0 || row_exit=$?
    rows="${rows}${row}"$'\n'
    [[ "$row_exit" -gt "$max_exit" ]] && max_exit="$row_exit"
    found=1
done < <(find "$runs_root" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv 2>/dev/null | sort)

if [[ "$found" == 0 ]]; then
    # Every known run vanished between the root check and the scan; the
    # empty array is still the correct document.
    if [[ "$list_json" == 1 ]]; then
        printf '{"schema":1,"generated_at":%s,"runs":[]}\n' "$(date +%s)"
    else
        arena_note 'no runs recorded'
    fi
    exit 0
fi

if [[ "$list_json" == 1 ]]; then
    # Rows are already in composite (repository, run_id) order; each is a
    # JSON object per line — join them into the runs array.
    printf '{"schema":1,"generated_at":%s,"runs":[' "$(date +%s)"
    first=1
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        [[ "$first" == 1 ]] || printf ','
        first=0
        printf '%s' "$row"
    done <<<"$rows"
    printf ']}\n'
    exit "$max_exit"
fi

printf 'REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY\n'
# Rows are sorted by the composite key (REPOSITORY, RUN_ID): the repository
# is the first column, so a line sort applies the exact composite order.
printf '%s' "$rows" | sort
exit "$max_exit"
