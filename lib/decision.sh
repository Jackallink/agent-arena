#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena decision RUN_ID --verdict VERDICT --summary TEXT --next TEXT [options]

Record the gate's SHA-bound review result. APPROVE requires a passing validation report;
CHANGES_REQUESTED and BLOCKED may document a failed validation report.

Options:
  --finding TEXT          Repeatable, preferably "path:line — reason"
  --no-relay              Persist decision without notifying the writer pane
  --state-root PATH       Private state root override
  -h, --help              Show this help
EOF
}

run_id=''
verdict=''
summary=''
next_step=''
relay=1
findings=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verdict)
            [[ $# -ge 2 ]] || arena_die '--verdict requires a value'
            verdict="$2"
            shift 2
            ;;
        --summary)
            [[ $# -ge 2 ]] || arena_die '--summary requires a value'
            summary="$2"
            shift 2
            ;;
        --next)
            [[ $# -ge 2 ]] || arena_die '--next requires a value'
            next_step="$2"
            shift 2
            ;;
        --finding)
            [[ $# -ge 2 ]] || arena_die '--finding requires a value'
            findings+=("$2")
            shift 2
            ;;
        --no-relay)
            relay=0
            shift
            ;;
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

[[ -n "$run_id" && -n "$verdict" && -n "$summary" && -n "$next_step" ]] || \
    arena_die 'decision requires RUN_ID, --verdict, --summary, and --next'
arena_validate_run_id "$run_id"
case "$verdict" in
    APPROVE|CHANGES_REQUESTED|BLOCKED) ;;
    *) arena_die 'verdict must be APPROVE, CHANGES_REQUESTED, or BLOCKED' ;;
esac
arena_validate_text "$summary" 'summary' 4000
arena_validate_text "$next_step" 'next step' 4000
if [[ -n "${findings[*]:-}" ]]; then
    for finding in "${findings[@]}"; do
        arena_validate_text "$finding" 'finding' 4000
    done
fi

arena_require_command git
run_dir="$(arena_find_run_dir "$run_id")"
arena_read_manifest "$run_dir"

# The state file is the authority for the transition commit below. Source
# state.sh here: the priority precheck needs its lock and intent helpers.
source "${source_root}/lib/state.sh"

# Priority check BEFORE the lock: a live run or parent lock wins (exit 4);
# an interrupted creation intent is owned by start (exit 5).
arena_state_precheck_intents "$(arena_state_root)/runs" \
    "$(basename "$(dirname "$run_dir")")" "$run_id" decision

# Serialize the evidence + state commit; released before the best-effort
# relay. Every exit path (arena_die, state conflict, guard refusal)
# releases the lock; exit "$status" preserves the real exit code (a plain
# EXIT trap body would mask it under Bash 3.2).
decision_lock_held=0
arena_decision_cleanup() {
    local status=$?

    if [[ "$decision_lock_held" == 1 ]] && arena_lock_is_held "${run_dir}/.run-lock" && \
        [[ "$(arena_lock_owner_token "${run_dir}/.run-lock")" == "decision-$$" ]]; then
        arena_lock_release "${run_dir}/.run-lock" "decision-$$"
    fi
    exit "$status"
}
trap arena_decision_cleanup EXIT
arena_lock_acquire "${run_dir}/.run-lock" "decision-$$"
decision_lock_held=1

# Integrity + writer-head checks inside the lock: the T6-T8 guard (writer
# HEAD == review HEAD == CS) must hold at commit time, not just at parse time.
arena_read_review_manifest "$run_dir"
arena_review_snapshot_is_intact "$ARENA_REVIEW_WORKTREE" "$ARENA_REVIEW_HEAD" \
    "$ARENA_REVIEW_CURSOR_POLICY_HASH" "$ARENA_REVIEW_GATE_WRAPPER_HASH" \
    "$ARENA_REVIEW_GATE_POLICY_PATH" "$ARENA_REVIEW_GATE_WRAPPER_PATH" || \
    arena_die 'review snapshot is not an intact submitted checkpoint'
arena_assert_clean_worktree "$ARENA_MANIFEST_WRITER_WORKTREE"

current_writer_head="$(git -C "$ARENA_MANIFEST_WRITER_WORKTREE" rev-parse HEAD)"
[[ "$current_writer_head" == "$ARENA_REVIEW_HEAD" ]] || \
    arena_die 'writer has moved beyond the reviewed checkpoint; submit and validate again'
short_sha="$(arena_short_sha "$ARENA_REVIEW_HEAD")"
validation_report="${run_dir}/validation-${short_sha}.md"
[[ -f "$validation_report" ]] || arena_die 'missing validation report for reviewed checkpoint'
grep -Fqx "Review HEAD: ${ARENA_REVIEW_HEAD}" "$validation_report" || \
    arena_die 'validation report is not bound to the reviewed checkpoint'
if [[ "$verdict" == APPROVE ]]; then
    grep -Fqx 'RESULT: PASS' "$validation_report" || \
        arena_die 'APPROVE requires a passing validation report'
fi

# A decision archive is bound by the SHA inside its Review HEAD line, never
# by its filename (v0.3 archives carry the short SHA in the name).
arena_decision_archive_for_sha() {
    local run_dir="$1"
    local sha="$2"
    local file line dec_sha

    [[ -n "$sha" ]] || return 1
    for file in "${run_dir}"/decision-*.md; do
        [[ -f "$file" ]] || continue
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        dec_sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        [[ -n "$dec_sha" && "$dec_sha" == "$sha" ]] || continue
        printf '%s\n' "$file"
        return 0
    done
    return 1
}

# Evidence first: the decision archive is written before the state file; the
# run-state.tsv replacement is the commit point.
arena_write_decision_archive() {
    local metadata_revision="$1"
    local metadata_vd="$2"
    local tmp_decision

    tmp_decision="$(mktemp "${run_dir}/.decision.XXXXXX")"
    {
        printf '# Agent Arena Gate Decision\n\n'
        printf 'Run: %s\n\n' "$run_id"
        printf 'Review HEAD: %s\n\n' "$ARENA_REVIEW_HEAD"
        printf 'VERDICT: %s\n\n' "$verdict"
        printf 'State revision: %s\n' "$metadata_revision"
        printf 'Validation digest: %s\n\n' "$metadata_vd"
        printf '## Summary\n\n%s\n\n' "$summary"
        printf '## Findings\n\n'
        if [[ -n "${findings[*]:-}" ]]; then
            for finding in "${findings[@]}"; do
                printf '%s\n' "- $finding"
            done
        else
            printf '%s\n' '- No additional findings.'
        fi
        printf '\n## Next Step for Writer\n\n%s\n' "$next_step"
    } >"$tmp_decision"
    chmod 600 "$tmp_decision"
    mv "$tmp_decision" "$decision_archive"
}

# Publication order archive -> decision.md (atomic replace) -> run-state.tsv.
# T6r/L-T6 complete any missing decision.md pointer with the same replace.
arena_publish_decision_pointer() {
    local tmp_pointer

    tmp_pointer="$(mktemp "${run_dir}/.decision-md.XXXXXX")"
    cp "$decision_archive" "$tmp_pointer"
    chmod 600 "$tmp_pointer"
    mv "$tmp_pointer" "${run_dir}/decision.md"
}

# T6/T7/T8 target states per verdict. WS resets to the transition time.
arena_apply_decision_verdict() {
    ARENA_STATE_PHASE='decided'
    ARENA_STATE_VERDICT="$verdict"
    ARENA_STATE_REASON_DETAIL=''
    ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
    ARENA_STATE_WAITING_SINCE="${ARENA_STATE_LAST_TRANSITION_AT}"
    ARENA_STATE_LAST_TRANSITION_ACTOR='reviewer'
    ARENA_STATE_LAST_TRANSITION_ACTION='decision'
    case "$verdict" in
        APPROVE)
            ARENA_STATE_RUN_STATUS='active'
            ARENA_STATE_RESPONSIBLE_PARTY='human'
            ARENA_STATE_REASON_CODE='approval_pending'
            ;;
        CHANGES_REQUESTED)
            ARENA_STATE_RUN_STATUS='active'
            ARENA_STATE_RESPONSIBLE_PARTY='writer'
            ARENA_STATE_REASON_CODE='changes_requested'
            ;;
        BLOCKED)
            ARENA_STATE_RUN_STATUS='blocked'
            ARENA_STATE_RESPONSIBLE_PARTY='human'
            ARENA_STATE_REASON_CODE='block_resolution_required'
            ;;
    esac
}

lock_path="${run_dir}/.run-lock"
decision_archive=''
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    [[ "$ARENA_STATE_RUN_STATUS" == active && "$ARENA_STATE_PHASE" == validated && \
        "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && \
        "$ARENA_STATE_REASON_CODE" == decision_pending ]] || arena_state_die \
        "illegal transition from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && "$ARENA_STATE_CHECKPOINT_SHA" == "$ARENA_REVIEW_HEAD" ]] || \
        arena_state_die 'state checkpoint does not match the review manifest'
    if [[ "$verdict" == APPROVE ]]; then
        [[ "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
            arena_state_die 'APPROVE requires a passing validation report'
    fi
    if decision_archive="$(arena_decision_archive_for_sha "$run_dir" "$ARENA_STATE_CHECKPOINT_SHA")"; then
        # T6r: archive-only residue (archive present, decision.md or state
        # missing). A state already carrying a verdict is a duplicate.
        if [[ -n "$ARENA_STATE_VERDICT" ]]; then
            arena_state_die 'a decision already exists for this checkpoint'
        fi
        archive_verdict="$(grep '^VERDICT: ' "$decision_archive" | head -1 | sed 's/^VERDICT: //' || true)"
        archive_meta_revision="$(grep '^State revision: ' "$decision_archive" | head -1 | sed 's/^State revision: //' || true)"
        archive_meta_vd="$(grep '^Validation digest: ' "$decision_archive" | head -1 | sed 's/^Validation digest: //' || true)"
        [[ "$archive_verdict" == "$verdict" ]] || \
            arena_state_die 'decision archive verdict does not match the requested decision'
        [[ "$archive_meta_revision" == "$ARENA_STATE_REVISION" && \
            "$archive_meta_vd" == "$ARENA_STATE_VALIDATION_DIGEST" ]] || \
            arena_state_die 'decision archive metadata does not match the current state'
    else
        # T6-T8 normal path: no existing archive for CS; write the evidence.
        decision_archive="${run_dir}/decision-${short_sha}.md"
        arena_write_decision_archive "$ARENA_STATE_REVISION" "$ARENA_STATE_VALIDATION_DIGEST"
    fi
    arena_publish_decision_pointer
    ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
    arena_apply_decision_verdict
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
else
    # Legacy run: project inside the lock, before any evidence is written.
    # An archive carrying the v0.4 baseline metadata (State revision: 0) is
    # a decision-owned residue recovered by L-T6; a validated (L4)
    # projection admits T6-T8 as its first migration; a projected decided
    # or blocked run (plain v0.3 archive) never routes through L-T6 and is
    # an illegal transition; foreign residue and conflicts keep their codes.
    projection_status=0
    arena_state_project_legacy "$run_dir" || projection_status=$?
    if [[ "$projection_status" == 0 ]]; then
        case "${ARENA_PROJECTED_PHASE}:${ARENA_PROJECTED_PARTY}:${ARENA_PROJECTED_REASON}" in
            validated:reviewer:decision_pending) ;;
            *)
                arena_state_die "legacy projection ${ARENA_PROJECTED_PHASE}/${ARENA_PROJECTED_PARTY}/${ARENA_PROJECTED_REASON} does not admit this decision"
                ;;
        esac
        if [[ "$verdict" == APPROVE ]]; then
            [[ "$ARENA_PROJECTED_VR" == PASS ]] || \
                arena_state_die 'APPROVE requires a passing validation report'
        fi
        # The archive is written while no state file exists: the legacy
        # baseline encoding (State revision: 0) records exactly that.
        decision_archive="${run_dir}/decision-${short_sha}.md"
        arena_write_decision_archive 0 "$ARENA_PROJECTED_VD"
    elif [[ "$projection_status" == 5 ]]; then
        if [[ "$ARENA_PROJECTED_RESIDUE" != decision ]]; then
            printf 'agent-arena: incomplete transition; evidence residue owned by another command; retry the owning command\n' >&2
            exit 5
        fi
        # L-T6: the archive is the evidence already on disk; re-check its
        # verdict, digest, and binding against the projection.
        [[ "$ARENA_PROJECTED_VERDICT" == "$verdict" ]] || \
            arena_state_die 'decision archive verdict does not match the requested decision'
        decision_archive="$(arena_decision_archive_for_sha "$run_dir" "$ARENA_PROJECTED_CS")"
        [[ -n "$decision_archive" ]] || arena_state_die 'decision archive residue is missing'
        archive_meta_vd="$(grep '^Validation digest: ' "$decision_archive" | head -1 | sed 's/^Validation digest: //' || true)"
        [[ "$archive_meta_vd" == "$ARENA_PROJECTED_VD" ]] || \
            arena_state_die 'decision archive metadata does not match the validation evidence'
    else
        exit 2
    fi
    arena_publish_decision_pointer
    # Legacy first migration: materialize v1 decided at revision 1 with the
    # projected semantic state plus the archive verdict (round sticky unknown).
    arena_state_defaults
    ARENA_STATE_PHASE='decided'
    ARENA_STATE_VERDICT="$verdict"
    ARENA_STATE_VALIDATION_RESULT="${ARENA_PROJECTED_VR}"
    ARENA_STATE_VALIDATION_DIGEST="${ARENA_PROJECTED_VD}"
    ARENA_STATE_CHECKPOINT_SHA="${ARENA_PROJECTED_CS}"
    ARENA_STATE_CHECKPOINT_ROUND='unknown'
    arena_apply_decision_verdict
    arena_state_write "$run_dir"
fi
arena_lock_release "$lock_path" "decision-$$"
decision_lock_held=0

if [[ "$relay" == 1 ]]; then
    if ! "${source_root}/lib/relay.sh" "$run_id" --to writer --from reviewer \
        --message "Gate ${verdict} for ${short_sha}. Read the recorded decision and follow its next step."; then
        arena_note "decision persisted, but writer relay was unavailable; read ${run_dir}/decision.md"
    fi
fi

arena_note "recorded ${verdict} for ${ARENA_REVIEW_HEAD}"
arena_note "writer feedback: ${run_dir}/decision.md"
