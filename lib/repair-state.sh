#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena repair-state RUN_ID --candidate TOKEN --reason "..."

Accept a status-printed repair candidate. The token binds the evidence digest
and the current state baseline; stale or foreign tokens are rejected. The
repair is intent-first: a crash after the intent re-executes from the intent.
EOF
}

run_id=''
candidate=''
reason=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidate) [[ $# -ge 2 ]] || arena_die '--candidate requires a value'; candidate="$2"; shift 2 ;;
        --reason) [[ $# -ge 2 ]] || arena_die '--reason requires a value'; reason="$2"; shift 2 ;;
        --state-root) [[ $# -ge 2 ]] || arena_die '--state-root requires a value'; ARENA_STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *) [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'; run_id="$1"; shift ;;
    esac
done
[[ -n "$run_id" && -n "$candidate" && -n "$reason" ]] || \
    arena_die 'repair-state requires RUN_ID, --candidate, and --reason'
[[ "$candidate" =~ ^[0-9a-f]+$ ]] || arena_die '--candidate must be a hex token'
arena_validate_run_id "$run_id"
arena_validate_text "$reason" 'reason' 256
run_dir="$(arena_find_run_dir "$run_id")"

# Source state.sh after manifest resolution: the priority precheck needs its
# lock and intent helpers.
source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" repair-state

# Serialize the three-state check + tombstone/commit sequence. Every exit
# path (arena_die, state conflict, fail-closed) releases the lock;
# exit "$status" preserves the real exit code.
lock_path="${run_dir}/.run-lock"
repair_lock_held=0
arena_repair_cleanup() {
    local status=$?

    if [[ "$repair_lock_held" == 1 ]] && arena_lock_is_held "$lock_path" && \
        [[ "$(arena_lock_owner_token "$lock_path")" == "repair-$$" ]]; then
        arena_lock_release "$lock_path" "repair-$$"
    fi
    exit "$status"
}
trap arena_repair_cleanup EXIT
arena_lock_acquire "$lock_path" "repair-$$"
repair_lock_held=1

from_intent=0
if [[ -f "${run_dir}/.repair.intent" ]]; then
    # A repair intent exists: the OWNER recovers per the three-state rule.
    # (a) state == original baseline -> the crash landed before the commit;
    # continue the tombstone/commit sequence from the intent, never from
    # the (now stale) token. (b) state == target digest -> zero-write
    # finish. (c) anything else -> fail closed.
    arena_repair_intent_read "$run_dir"
    current_digest='absent'
    [[ -f "${run_dir}/run-state.tsv" ]] && \
        current_digest="$(arena_file_hash "${run_dir}/run-state.tsv")"
    case "$ARENA_REPAIR_BASELINE" in
        absent) baseline_digest='absent' ;;
        valid:*:*) baseline_digest="${ARENA_REPAIR_BASELINE#valid:}"; baseline_digest="${baseline_digest%:*}" ;;
        corrupt:*) baseline_digest="${ARENA_REPAIR_BASELINE#corrupt:}" ;;
        *) arena_state_die 'corrupted repair intent: unreadable baseline' ;;
    esac
    if [[ "$current_digest" == "$baseline_digest" ]]; then
        from_intent=1
        # Continue from the intent: rebuild the materialized target pairs
        # and re-verify the stored digest and the state invariants.
        arena_state_repair_pairs_from_payload "$ARENA_REPAIR_TARGET_PAYLOAD" || \
            arena_state_die 'corrupted repair intent: unreadable target payload'
        recomputed_digest="$(arena_sha256_text "$(arena_state_render_tsv "${ARENA_REPAIR_PAIRS[@]}")"$'\n')"
        [[ "$recomputed_digest" == "$ARENA_REPAIR_TARGET_DIGEST" ]] || \
            arena_state_die 'corrupted repair intent: target payload does not match the target digest'
        arena_state_repair_verify "$run_dir" || \
            arena_state_die 'repair intent carries an illegal target state; failing closed'
    elif [[ "$current_digest" == "$ARENA_REPAIR_TARGET_DIGEST" ]]; then
        rm -f "${run_dir}/.repair.intent"
        arena_lock_release "$lock_path" "repair-$$"
        repair_lock_held=0
        arena_note 'repair already committed; intent cleaned'
        exit 0
    else
        arena_lock_release "$lock_path" "repair-$$"
        repair_lock_held=0
        arena_state_die 'repair intent does not match the current state; failing closed'
    fi
fi

if [[ "$from_intent" == 0 ]]; then
    # Fresh path: re-compute the evidence digest and the candidates under
    # the lock, match the supplied token, materialize the dynamic fields,
    # and write the intent FIRST (T14: intent before any tombstone).
    arena_state_repair_candidates "$run_dir" "$candidate"
    [[ "$ARENA_REPAIR_MATCH" == 1 ]] || \
        arena_state_die "stale or foreign repair candidate '${candidate}'; re-run status for a fresh token"
    now="$(date +%s)"
    if [[ "$ARENA_REPAIR_TARGET_WS_MODE" == preserve ]]; then
        ws_value="$ARENA_REPAIR_TARGET_WS_VALUE"
    else
        ws_value="$now"
    fi
    arena_state_repair_pairs "$ws_value" "$now" "$reason" "$ARENA_REPAIR_TARGET_REVISION"
    arena_state_repair_verify "$run_dir" || \
        arena_state_die 'repair candidate violates the state invariants'
    stamp="$(date +%s)"
    ARENA_REPAIR_AUDIT_COPY=''
    if [[ "$ARENA_REPAIR_BASELINE_STRING" == corrupt:* ]]; then
        ARENA_REPAIR_AUDIT_COPY="run-state.tsv.corrupt.${stamp}"
    fi
    for name in ${ARENA_REPAIR_TOMBSTONES//;/ }; do
        [[ -n "$name" ]] || continue
        if [[ -e "${run_dir}/orphaned/${name}.${stamp}" ]]; then
            stamp="${stamp}-$$"
            break
        fi
    done
    arena_repair_intent_write "$run_dir" "$ARENA_REPAIR_BASELINE_STRING" \
        "$ARENA_REPAIR_EVIDENCE_DIGEST" "$candidate" "$reason" \
        "$ARENA_REPAIR_TARGET_DIGEST" "$ARENA_REPAIR_PAYLOAD_X1F" \
        "$ARENA_REPAIR_AUDIT_COPY" "$ARENA_REPAIR_TOMBSTONES" "$stamp"
    # Materialize the tombstone inputs for the shared commit tail; on the
    # intent-recovery path these arrive via arena_repair_intent_read.
    ARENA_REPAIR_MOVE_MAP="$ARENA_REPAIR_TOMBSTONES"
    ARENA_REPAIR_STAMP="$stamp"
fi

# Shared commit tail, idempotent at every crash boundary: audit-copy the
# corrupted file, tombstone the orphan evidence, write the target state,
# verify the digest, and remove the intent last.
if [[ -n "$ARENA_REPAIR_AUDIT_COPY" ]]; then
    if [[ ! -e "${run_dir}/${ARENA_REPAIR_AUDIT_COPY}" ]]; then
        cp "${run_dir}/run-state.tsv" "${run_dir}/${ARENA_REPAIR_AUDIT_COPY}"
        chmod 600 "${run_dir}/${ARENA_REPAIR_AUDIT_COPY}"
    fi
fi
for name in ${ARENA_REPAIR_MOVE_MAP//;/ }; do
    [[ -n "$name" ]] || continue
    src="${run_dir}/${name}"
    dst="${run_dir}/orphaned/${name}.${ARENA_REPAIR_STAMP}"
    [[ -f "$src" ]] || continue
    [[ ! -e "$dst" ]] || arena_state_die "orphan tombstone destination already exists: $dst"
    mkdir -p "${run_dir}/orphaned"
    mv "$src" "$dst"
done
arena_state_write "$run_dir" "${ARENA_REPAIR_PAIRS[@]}"
[[ "$(arena_file_hash "${run_dir}/run-state.tsv")" == "$ARENA_REPAIR_TARGET_DIGEST" ]] || \
    arena_state_die 'repair state commit digest mismatch; failing closed'
rm -f "${run_dir}/.repair.intent"
arena_lock_release "$lock_path" "repair-$$"
repair_lock_held=0
arena_note 'repair-state committed the candidate target state'
exit 0
