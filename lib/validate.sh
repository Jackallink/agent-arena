#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/config.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena validate RUN_ID [--state-root PATH]

Run the submitted snapshot's project-defined validation script. Validation rejects a
dirty review snapshot before and after execution and records a report bound to its SHA.
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

[[ -n "$run_id" ]] || arena_die 'validate requires RUN_ID'
arena_validate_run_id "$run_id"
arena_require_command git
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"
arena_read_review_manifest "$run_dir"
arena_assert_worktree "$ARENA_REVIEW_WORKTREE"
review_head="$(git -C "$ARENA_REVIEW_WORKTREE" rev-parse HEAD)"
[[ "$review_head" == "$ARENA_REVIEW_HEAD" ]] || \
    arena_die 'review worktree HEAD differs from the submitted checkpoint'
arena_load_project_config "$ARENA_REVIEW_WORKTREE"
[[ -x "$ARENA_PROJECT_VALIDATION_PATH" ]] || \
    arena_die "project validation script is not executable: $ARENA_PROJECT_VALIDATION_PATH"

short_sha="$(arena_short_sha "$review_head")"

# T5 validate uses the dedicated op-token CAS protocol. state.sh carries the
# state, transition, and projection helpers and sources lock.sh itself.
source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" validate

validate_lock_held=0
arena_validate_cleanup() {
    local status=$?

    if [[ "$validate_lock_held" == 1 ]] && arena_lock_is_held "${run_dir}/.run-lock" && \
        [[ "$(arena_lock_owner_token "${run_dir}/.run-lock")" == "validate-$$" ]]; then
        arena_lock_release "${run_dir}/.run-lock" "validate-$$"
    fi
    exit "$status"
}
trap arena_validate_cleanup EXIT

arena_validate_exit() {
    local code="$1"
    shift
    printf 'agent-arena: %s\n' "$*" >&2
    exit "$code"
}

arena_source_validate_reviewer() {
    [[ "$ARENA_STATE_RUN_STATUS" == active && "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer ]] || return 1
    case "$ARENA_STATE_PHASE:$ARENA_STATE_REASON_CODE" in
        submitted:review_pending|validated:decision_pending) return 0 ;;
        *) return 1 ;;
    esac
}

# A decision archive is bound by the SHA inside its Review HEAD line, never
# by its filename (v0.3 archives carry the short SHA in the name).
arena_decision_archive_pending() {
    local run_dir="$1"
    local sha="$2"
    local file line dec_sha

    [[ -n "$sha" ]] || return 1
    for file in "${run_dir}"/decision-*.md; do
        [[ -f "$file" ]] || continue
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        dec_sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        [[ "$dec_sha" == "$sha" ]] && return 0
    done
    return 1
}

# Temporary cleanup: a lock holder may delete an op-token temporary only when
# the owner PID embedded in the token (validate.PID.NONCE) is confirmed dead.
# The holder's own temporary is always removed on its own paths.
arena_validation_clean_dead_temps() {
    local run_dir="$1"
    local own_token="$2"
    local file token owner_pid

    for file in "${run_dir}"/.validation.*.tmp; do
        [[ -f "$file" ]] || continue
        token="${file#${run_dir}/.validation.}"
        token="${token%.tmp}"
        [[ "$token" == "$own_token" ]] && continue
        owner_pid="${token#validate.}"
        [[ "$owner_pid" == "$token" ]] && continue
        owner_pid="${owner_pid%%.*}"
        [[ "$owner_pid" =~ ^[0-9]+$ ]] || continue
        if ! kill -0 "$owner_pid" 2>/dev/null; then
            rm -f "$file"
        fi
    done
}

run_gate() {
    printf '# Agent Arena Validation Report\n\n'
    printf 'Run: %s\n\n' "$run_id"
    printf 'Review HEAD: %s\n\n' "$review_head"
    printf 'Project: %s\n\n' "$ARENA_PROJECT_NAME"
    printf 'Command: %s\n\n' "$ARENA_PROJECT_VALIDATION_SCRIPT"
    printf '## Output\n\n'
    local gate_status

    if ! arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
        "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
        printf '%s\n' 'Snapshot integrity check failed before validation.' >&2
        return 2
    fi
    if (
        cd "$ARENA_REVIEW_WORKTREE"
        "$ARENA_PROJECT_VALIDATION_PATH"
    ); then
        gate_status=0
    else
        gate_status=$?
    fi
    if ! arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
        "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
        "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH"; then
        printf '%s\n' 'Snapshot integrity check failed after validation.' >&2
        return 2
    fi
    return "$gate_status"
}

# FIRST lock: pending-archive refusal (exit 5, the gate never runs), the T5
# source guard, dead-owner temporary cleanup, and the CAS baseline capture
# (state_revision + checkpoint_sha + decision-archive ABSENCE). The archive
# component of the baseline may only ever be the literal 'absent'.
lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "validate-$$"
validate_lock_held=1

legacy_projected=0
base_revision='absent'
base_sha=''
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -z "$ARENA_STATE_VERDICT" ]] && \
        arena_decision_archive_pending "$run_dir" "$ARENA_STATE_CHECKPOINT_SHA"; then
        arena_validate_exit 5 'incomplete transition; pending decision residue; complete the decision retry first'
    fi
    if ! arena_source_validate_reviewer; then
        arena_state_die "illegal validate from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    fi
    [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && "$ARENA_STATE_CHECKPOINT_SHA" == "$review_head" ]] || \
        arena_state_die 'submitted checkpoint does not match the review manifest'
    base_revision="$ARENA_STATE_REVISION"
    base_sha="$ARENA_STATE_CHECKPOINT_SHA"
else
    # Legacy run: project inside the lock. A validate-owned residue (a
    # canonical report without a pointer) recovers by safe/convergent
    # re-execution; every other residue or conflict refuses here.
    if ! arena_state_project_legacy "$run_dir"; then
        projection_status=$?
        if [[ "$projection_status" == 5 && "$ARENA_PROJECTED_RESIDUE" == validate ]]; then
            :
        elif [[ "$projection_status" == 5 ]]; then
            arena_validate_exit 5 'incomplete transition; evidence residue owned by another command; retry the owning command'
        else
            exit "$projection_status"
        fi
    fi
    legacy_projected=1
    case "${ARENA_PROJECTED_PHASE}:${ARENA_PROJECTED_REASON}" in
        submitted:review_pending|validated:decision_pending) ;;
        *) arena_state_die "illegal validate from legacy ${ARENA_PROJECTED_PHASE}/${ARENA_PROJECTED_PARTY}/${ARENA_PROJECTED_REASON}" ;;
    esac
    base_sha="$ARENA_PROJECTED_CS"
    if arena_decision_archive_pending "$run_dir" "$base_sha"; then
        arena_validate_exit 5 'incomplete transition; pending decision residue; complete the decision retry first'
    fi
fi

op_token="validate.$$.$RANDOM"
arena_validation_clean_dead_temps "$run_dir" "$op_token"
tmp_report="${run_dir}/.validation.${op_token}.tmp"
arena_lock_release "$lock_path" "validate-$$"
validate_lock_held=0

# Gate outside the lock; it writes ONLY this op-token's temporary and never
# a canonical path.
gate_status=0
run_gate >"$tmp_report" 2>&1 || gate_status=$?

if [[ "$gate_status" == 2 ]]; then
    # Snapshot-integrity failure: no transition, diagnostic-only report,
    # never the canonical report path or the pointer.
    printf '\nRESULT: FAIL\n' >>"$tmp_report"
    printf 'Diagnostic: snapshot integrity check failed; no state transition was recorded.\n' >>"$tmp_report"
    chmod 600 "$tmp_report"
    mv "$tmp_report" "${run_dir}/validation-${short_sha}.diagnostic.md"
    cat "${run_dir}/validation-${short_sha}.diagnostic.md"
    exit 2
fi

# SECOND lock: compare the full baseline against the current values, with
# exactly three ordered outcomes: (a) an archive appeared AND the revision
# is unchanged — a pending decision residue, exit 5; (b) the revision
# changed — the decision completed, this result is stale, exit 3; (c) the
# triple baseline matches — CAS success, publish.
arena_lock_acquire "$lock_path" "validate-$$"
validate_lock_held=1

legacy_first=0
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if [[ "$base_revision" != absent && "$ARENA_STATE_REVISION" != "$base_revision" ]]; then
        rm -f "$tmp_report"
        arena_validate_exit 3 'state moved during validation; result discarded, re-run validate'
    fi
    if [[ "$base_revision" == absent ]]; then
        # Legacy baseline: the run was migrated during the gate. Only a
        # same-SHA submitted/validated migration continues this validate.
        if [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && "$ARENA_STATE_CHECKPOINT_SHA" == "$base_sha" ]]; then
            case "${ARENA_STATE_PHASE}:${ARENA_STATE_REASON_CODE}" in
                submitted:review_pending|validated:decision_pending) ;;
                *)
                    rm -f "$tmp_report"
                    arena_validate_exit 3 'state moved during validation; result discarded, re-run validate'
                    ;;
            esac
        else
            rm -f "$tmp_report"
            arena_validate_exit 3 'state moved during validation; result discarded, re-run validate'
        fi
        if [[ -z "$ARENA_STATE_VERDICT" ]] && \
            arena_decision_archive_pending "$run_dir" "$base_sha"; then
            rm -f "$tmp_report"
            arena_validate_exit 5 'incomplete transition; pending decision residue; complete the decision retry first'
        fi
    else
        [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && "$ARENA_STATE_CHECKPOINT_SHA" == "$base_sha" ]] || {
            rm -f "$tmp_report"
            arena_validate_exit 3 'state moved during validation; result discarded, re-run validate'
        }
        if arena_decision_archive_pending "$run_dir" "$base_sha"; then
            rm -f "$tmp_report"
            arena_validate_exit 5 'incomplete transition; pending decision residue; complete the decision retry first'
        fi
    fi
    pre_phase="$ARENA_STATE_PHASE"
    pre_reason="$ARENA_STATE_REASON_CODE"
else
    if [[ "$legacy_projected" == 0 ]]; then
        arena_state_die 'state file disappeared during validation'
    fi
    if ! arena_state_project_legacy "$run_dir"; then
        projection_status=$?
        if [[ "$projection_status" == 5 && "$ARENA_PROJECTED_RESIDUE" == validate ]]; then
            :
        elif [[ "$projection_status" == 5 ]]; then
            rm -f "$tmp_report"
            arena_validate_exit 5 'incomplete transition; evidence residue owned by another command; retry the owning command'
        else
            rm -f "$tmp_report"
            exit "$projection_status"
        fi
    fi
    if [[ -n "$ARENA_PROJECTED_CS" && "$ARENA_PROJECTED_CS" != "$base_sha" ]]; then
        rm -f "$tmp_report"
        arena_validate_exit 3 'state moved during validation; result discarded, re-run validate'
    fi
    if arena_decision_archive_pending "$run_dir" "$base_sha"; then
        rm -f "$tmp_report"
        arena_validate_exit 5 'incomplete transition; pending decision residue; complete the decision retry first'
    fi
    pre_phase="$ARENA_PROJECTED_PHASE"
    pre_reason="$ARENA_PROJECTED_REASON"
    # Legacy first migration: materialize v1 in the same commit as the
    # evidence. Round stays sticky-unknown; the projected WS is preserved
    # by the revalidate rule below or reset by the reason change.
    legacy_first=1
    arena_state_defaults
    ARENA_STATE_RUN_STATUS='active'
    ARENA_STATE_PHASE='validated'
    ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
    ARENA_STATE_REASON_CODE='decision_pending'
    ARENA_STATE_CHECKPOINT_SHA="$base_sha"
    ARENA_STATE_CHECKPOINT_ROUND='unknown'
    ARENA_STATE_WAITING_SINCE="$ARENA_PROJECTED_WAITING_SINCE"
fi

# CAS success: publish in spec order — archive-COPY first (copy the old
# canonical to a temporary, then mv it into place, so a crash never leaves
# a truncated .rN), then atomic canonical replace, then the pointer, then
# the state commit.
report="${run_dir}/validation-${short_sha}.md"
if [[ -f "$report" ]]; then
    rotated="${report%.md}.r1.md"
    rotation_index=1
    while [[ -e "$rotated" ]]; do
        rotation_index=$((rotation_index + 1))
        rotated="${report%.md}.r${rotation_index}.md"
    done
    archive_tmp="$(mktemp "${run_dir}/.archive.XXXXXX")"
    cp "$report" "$archive_tmp"
    chmod 600 "$archive_tmp"
    mv "$archive_tmp" "$rotated"
fi
if [[ "$gate_status" == 0 ]]; then
    printf '\nRESULT: PASS\n' >>"$tmp_report"
else
    printf '\nRESULT: FAIL\n' >>"$tmp_report"
fi
chmod 600 "$tmp_report"
mv "$tmp_report" "$report"
printf 'Latest validation report: %s\n' "$(basename "$report")" >"${run_dir}/validation.md"
chmod 600 "${run_dir}/validation.md"
new_digest="$(arena_file_hash "$report")"

# T5 delta: RS=active, PH=validated, RP=reviewer, RC=decision_pending.
# From validated the waiting_since is preserved (reason unchanged); from
# submitted the reason changed, so the waiting_since resets. The decision
# compares the PRE-transition phase/reason captured under the lock.
if [[ "$pre_phase" == validated && "$pre_reason" == decision_pending ]]; then
    : # revalidate: waiting_since preserved
else
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
fi
if [[ "$legacy_first" == 1 ]]; then
    new_revision=1
else
    new_revision=$((ARENA_STATE_REVISION + 1))
fi
ARENA_STATE_PHASE='validated'
ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
ARENA_STATE_REASON_CODE='decision_pending'
ARENA_STATE_VERDICT=''
ARENA_STATE_VALIDATION_RESULT="$([[ "$gate_status" == 0 ]] && printf PASS || printf FAIL)"
ARENA_STATE_VALIDATION_DIGEST="$new_digest"
ARENA_STATE_REVISION="$new_revision"
ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
ARENA_STATE_LAST_TRANSITION_ACTOR='reviewer'
ARENA_STATE_LAST_TRANSITION_ACTION='validate'
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
    "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
    "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
    "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
    "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
    "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
    "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
    "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
arena_lock_release "$lock_path" "validate-$$"
validate_lock_held=0

cat "$report"
[[ "$gate_status" == 0 ]] && exit 0
exit 10
