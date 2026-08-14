#!/usr/bin/env bash
set -euo pipefail

state_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${state_dir}/common.sh"
source "${state_dir}/lock.sh"

ARENA_STATE_KEYS='schema_version state_revision run_status phase responsible_party reason_code reason_detail verdict validation_result checkpoint_round checkpoint_sha waiting_since last_transition_at last_transition_actor last_transition_action validation_digest'
# Basenames the legacy projection must ignore (repair candidate re-projection).
ARENA_PROJECTION_EXCLUDE=''

# Corrupted or illegal state fails closed with the spec's exit code 2.
arena_state_die() {
    printf 'agent-arena: %s\n' "$*" >&2
    exit 2
}

arena_state_defaults() {
    ARENA_STATE_SCHEMA_VERSION='1'
    ARENA_STATE_REVISION='1'
    ARENA_STATE_RUN_STATUS='active'
    ARENA_STATE_PHASE='intake'
    ARENA_STATE_RESPONSIBLE_PARTY='writer'
    ARENA_STATE_REASON_CODE='none'
    ARENA_STATE_REASON_DETAIL=''
    ARENA_STATE_VERDICT=''
    ARENA_STATE_VALIDATION_RESULT=''
    ARENA_STATE_CHECKPOINT_ROUND='0'
    ARENA_STATE_CHECKPOINT_SHA=''
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR='system'
    ARENA_STATE_LAST_TRANSITION_ACTION='start'
    ARENA_STATE_VALIDATION_DIGEST=''
}

arena_state_read() {
    local run_dir="$1"
    local manifest="${run_dir}/run-state.tsv"

    [[ -f "$manifest" ]] || arena_state_die "missing state file: $manifest"
    arena_state_read_file "$manifest"
}

# arena_state_read_file MANIFEST: read and validate one state file at an
# explicit path (the repair path validates candidate renders this way).
arena_state_read_file() {
    local manifest="$1"
    local key value seen=''

    arena_state_defaults
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || arena_state_die "corrupted state file: empty key in $manifest"
        case " $seen " in *" $key "*) arena_state_die "corrupted state file: duplicate key $key in $manifest" ;; esac
        seen="$seen $key"
        case " $ARENA_STATE_KEYS " in *" $key "*) ;; *) arena_state_die "corrupted state file: unknown key $key in $manifest" ;; esac
        case "$key" in
            schema_version) ARENA_STATE_SCHEMA_VERSION="$value" ;;
            state_revision) ARENA_STATE_REVISION="$value" ;;
            run_status) ARENA_STATE_RUN_STATUS="$value" ;;
            phase) ARENA_STATE_PHASE="$value" ;;
            responsible_party) ARENA_STATE_RESPONSIBLE_PARTY="$value" ;;
            reason_code) ARENA_STATE_REASON_CODE="$value" ;;
            reason_detail) ARENA_STATE_REASON_DETAIL="$value" ;;
            verdict) ARENA_STATE_VERDICT="$value" ;;
            validation_result) ARENA_STATE_VALIDATION_RESULT="$value" ;;
            checkpoint_round) ARENA_STATE_CHECKPOINT_ROUND="$value" ;;
            checkpoint_sha) ARENA_STATE_CHECKPOINT_SHA="$value" ;;
            waiting_since) ARENA_STATE_WAITING_SINCE="$value" ;;
            last_transition_at) ARENA_STATE_LAST_TRANSITION_AT="$value" ;;
            last_transition_actor) ARENA_STATE_LAST_TRANSITION_ACTOR="$value" ;;
            last_transition_action) ARENA_STATE_LAST_TRANSITION_ACTION="$value" ;;
            validation_digest) ARENA_STATE_VALIDATION_DIGEST="$value" ;;
        esac
    done <"$manifest"
    for key in $ARENA_STATE_KEYS; do
        case " $seen " in *" $key "*) ;; *) arena_state_die "corrupted state file: missing key $key in $manifest" ;; esac
    done
    arena_state_validate "$manifest"
}

arena_state_validate() {
    local run_dir="$1"

    [[ "$ARENA_STATE_SCHEMA_VERSION" == 1 ]] || {
        [[ "$ARENA_STATE_SCHEMA_VERSION" =~ ^[0-9]+$ ]] && arena_state_die 'state file uses a future schema version; upgrade Agent Arena'
        arena_state_die "corrupted state file: invalid schema_version"
    }
    [[ "$ARENA_STATE_REVISION" =~ ^[1-9][0-9]*$ ]] || arena_state_die 'corrupted state file: invalid state_revision'
    case "$ARENA_STATE_RUN_STATUS" in active|blocked|completed|canceled) ;; *) arena_state_die 'corrupted state file: invalid run_status' ;; esac
    case "$ARENA_STATE_PHASE" in intake|submitted|validated|decided) ;; *) arena_state_die 'corrupted state file: invalid phase' ;; esac
    case "$ARENA_STATE_RESPONSIBLE_PARTY" in writer|reviewer|human|none) ;; *) arena_state_die 'corrupted state file: invalid responsible_party' ;; esac
    case "$ARENA_STATE_REASON_CODE" in none|review_pending|decision_pending|approval_pending|changes_requested|human_changes_requested|reviewer_unreachable|block_resolution_required) ;; *) arena_state_die 'corrupted state file: invalid reason_code' ;; esac
    case "$ARENA_STATE_VERDICT" in ''|APPROVE|CHANGES_REQUESTED|BLOCKED) ;; *) arena_state_die 'corrupted state file: invalid verdict' ;; esac
    case "$ARENA_STATE_VALIDATION_RESULT" in ''|PASS|FAIL) ;; *) arena_state_die 'corrupted state file: invalid validation_result' ;; esac
    [[ "$ARENA_STATE_CHECKPOINT_ROUND" == unknown || "$ARENA_STATE_CHECKPOINT_ROUND" =~ ^[0-9]+$ ]] || arena_state_die 'corrupted state file: invalid checkpoint_round'
    # CR=0 only in intake; every non-intake phase is positive-or-unknown.
    if [[ "$ARENA_STATE_PHASE" == intake ]]; then
        [[ "$ARENA_STATE_CHECKPOINT_ROUND" == 0 ]] || arena_state_die 'corrupted state file: intake phase requires checkpoint_round 0'
    else
        [[ "$ARENA_STATE_CHECKPOINT_ROUND" == unknown || "$ARENA_STATE_CHECKPOINT_ROUND" =~ ^[1-9][0-9]*$ ]] || \
            arena_state_die 'corrupted state file: non-intake phase requires positive-or-unknown checkpoint_round'
    fi
    [[ "$ARENA_STATE_CHECKPOINT_SHA" == '' || "$ARENA_STATE_CHECKPOINT_SHA" =~ ^[0-9a-f]{40}$ ]] || arena_state_die 'corrupted state file: invalid checkpoint_sha'
    [[ "$ARENA_STATE_VALIDATION_DIGEST" == '' || "$ARENA_STATE_VALIDATION_DIGEST" =~ ^[0-9a-f]{64}$ ]] || arena_state_die 'corrupted state file: invalid validation_digest'
    [[ "$ARENA_STATE_WAITING_SINCE" == '' || "$ARENA_STATE_WAITING_SINCE" == unknown || "$ARENA_STATE_WAITING_SINCE" =~ ^[0-9]+$ ]] || arena_state_die 'corrupted state file: invalid waiting_since'
    [[ "$ARENA_STATE_LAST_TRANSITION_AT" =~ ^[0-9]+$ ]] || arena_state_die 'corrupted state file: invalid last_transition_at'
    case "$ARENA_STATE_LAST_TRANSITION_ACTOR" in writer|reviewer|human|system) ;; *) arena_state_die 'corrupted state file: invalid last_transition_actor' ;; esac
    case "$ARENA_STATE_LAST_TRANSITION_ACTION" in start|submit|validate|decision|escalate|resolve-approve|resolve-reject|resolve-recover|resolve-cancel|repair-state) ;; *) arena_state_die 'corrupted state file: invalid last_transition_action' ;; esac
    [[ "$ARENA_STATE_REASON_DETAIL" == '' || ! "$ARENA_STATE_REASON_DETAIL" =~ [[:cntrl:]] && "${#ARENA_STATE_REASON_DETAIL}" -le 256 ]] || arena_state_die 'corrupted state file: invalid reason_detail'

    # Legal-combination invariants (spec: layered by run_status)
    case "$ARENA_STATE_RUN_STATUS" in
        active)
            case "$ARENA_STATE_PHASE" in
                intake)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer && "$ARENA_STATE_REASON_CODE" == none && \
                        -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && \
                        -z "$ARENA_STATE_VALIDATION_DIGEST" && -z "$ARENA_STATE_CHECKPOINT_SHA" && \
                        "$ARENA_STATE_CHECKPOINT_ROUND" == 0 && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_state_die 'corrupted state file: illegal intake combination'
                    ;;
                submitted)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == review_pending && \
                        -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && \
                        -z "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" && \
                        "$ARENA_STATE_CHECKPOINT_ROUND" != 0 && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_state_die 'corrupted state file: illegal submitted combination'
                    ;;
                validated)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == decision_pending && \
                        -z "$ARENA_STATE_VERDICT" && -n "$ARENA_STATE_VALIDATION_RESULT" && \
                        -n "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_state_die 'corrupted state file: illegal validated combination'
                    ;;
                decided)
                    [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_state_die 'corrupted state file: illegal decided combination'
                    case "$ARENA_STATE_RESPONSIBLE_PARTY:$ARENA_STATE_REASON_CODE" in
                        human:approval_pending)
                            [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                                arena_state_die 'corrupted state file: approval_pending requires APPROVE and PASS'
                            ;;
                        writer:changes_requested)
                            [[ "$ARENA_STATE_VERDICT" == CHANGES_REQUESTED && -n "$ARENA_STATE_VALIDATION_RESULT" ]] || \
                                arena_state_die 'corrupted state file: changes_requested requires CHANGES_REQUESTED and a validation result'
                            ;;
                        writer:human_changes_requested)
                            { [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                                { [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" ]]; }; } || \
                                arena_state_die 'corrupted state file: illegal human_changes_requested combination'
                            ;;
                        *) arena_state_die 'corrupted state file: illegal decided combination' ;;
                    esac
                    ;;
            esac
            ;;
        blocked)
            [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == human && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_state_die 'corrupted state file: illegal blocked combination'
            # reviewer_unreachable inherits the source-phase V/VR/VD/CS
            # constraints (CR positive-or-unknown is enforced globally above).
            case "$ARENA_STATE_REASON_CODE:$ARENA_STATE_PHASE" in
                reviewer_unreachable:submitted)
                    [[ -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && \
                        -z "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" ]] || \
                        arena_state_die 'corrupted state file: illegal blocked/submitted combination'
                    ;;
                reviewer_unreachable:validated)
                    [[ -z "$ARENA_STATE_VERDICT" && -n "$ARENA_STATE_VALIDATION_RESULT" && \
                        -n "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" ]] || \
                        arena_state_die 'corrupted state file: illegal blocked/validated combination'
                    ;;
                block_resolution_required:decided) ;;
                *) arena_state_die 'corrupted state file: illegal blocked combination' ;;
            esac
            if [[ "$ARENA_STATE_REASON_CODE" == block_resolution_required ]]; then
                [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" && \
                    -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_DIGEST" ]] || \
                    arena_state_die 'corrupted state file: illegal block_resolution_required combination'
            fi
            ;;
        completed)
            [[ "$ARENA_STATE_PHASE" == decided && "$ARENA_STATE_RESPONSIBLE_PARTY" == none && \
                "$ARENA_STATE_REASON_CODE" == none && "$ARENA_STATE_VERDICT" == APPROVE && \
                "$ARENA_STATE_VALIDATION_RESULT" == PASS && -n "$ARENA_STATE_VALIDATION_DIGEST" && \
                -n "$ARENA_STATE_CHECKPOINT_SHA" && -z "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_state_die 'corrupted state file: illegal completed combination'
            ;;
        canceled)
            [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == none && "$ARENA_STATE_REASON_CODE" == none && -z "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_state_die 'corrupted state file: illegal canceled combination'
            case "$ARENA_STATE_PHASE" in
                submitted) [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && -z "$ARENA_STATE_VALIDATION_DIGEST" ]] || arena_state_die 'corrupted state file: illegal canceled/submitted combination' ;;
                validated) [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_RESULT" && -n "$ARENA_STATE_VALIDATION_DIGEST" && -z "$ARENA_STATE_VERDICT" ]] || arena_state_die 'corrupted state file: illegal canceled/validated combination' ;;
                decided)
                    { [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                        { [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" ]]; }; } || \
                        arena_state_die 'corrupted state file: illegal canceled/decided combination'
                    ;;
                *) arena_state_die 'corrupted state file: illegal canceled phase' ;;
            esac
            ;;
    esac
    if [[ -n "$ARENA_STATE_WAITING_SINCE" && "$ARENA_STATE_WAITING_SINCE" != unknown ]]; then
        [[ "$ARENA_STATE_WAITING_SINCE" -le "$ARENA_STATE_LAST_TRANSITION_AT" ]] || \
            arena_state_die 'corrupted state file: waiting_since after last_transition_at'
    fi
}

# ---------------------------------------------------------------------------
# Transition engine: shared dispatcher for T-rows that mutate state.
# arena_state_transition RUN_DIR SOURCE_CHECK GUARD_FN DELTA_FN ACTION_NAME
# reads and validates the current state, refuses illegal sources, runs the
# guard (return 2 on failure), applies the delta, increments the revision,
# stamps the transition fields, and commits atomically. Delta functions may
# rely on caller-scope variables (e.g. writer_head).
# ---------------------------------------------------------------------------

arena_state_transition() {
    local run_dir="$1" source_check="$2" guard_fn="$3" delta_fn="$4" action_name="$5"
    local new_revision

    arena_state_read "$run_dir"
    "$source_check" || arena_state_die \
        "illegal transition from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    "$guard_fn" || return 2
    new_revision=$((ARENA_STATE_REVISION + 1))
    "$delta_fn"
    ARENA_STATE_REVISION="$new_revision"
    ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_ACTION="$action_name"
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
}

arena_source_intake_or_decided_writer() {
    [[ "$ARENA_STATE_RUN_STATUS" == active ]] || return 1
    if [[ "$ARENA_STATE_PHASE" == intake ]]; then
        [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer && "$ARENA_STATE_REASON_CODE" == none ]] || return 1
        return 0
    fi
    if [[ "$ARENA_STATE_PHASE" == decided ]]; then
        [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer ]] || return 1
        case "$ARENA_STATE_REASON_CODE" in
            changes_requested|human_changes_requested) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

arena_source_submitted_reviewer() {
    [[ "$ARENA_STATE_RUN_STATUS" == active && "$ARENA_STATE_PHASE" == submitted && \
        "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == review_pending ]]
}

arena_state_delta_submit_new_sha() {
    ARENA_STATE_RUN_STATUS='active'
    ARENA_STATE_PHASE='submitted'
    ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
    ARENA_STATE_REASON_CODE='review_pending'
    ARENA_STATE_REASON_DETAIL=''
    ARENA_STATE_VERDICT=''
    ARENA_STATE_VALIDATION_RESULT=''
    ARENA_STATE_VALIDATION_DIGEST=''
    ARENA_STATE_CHECKPOINT_SHA="$writer_head"
    if [[ "$ARENA_STATE_CHECKPOINT_ROUND" == unknown ]]; then
        : # sticky unknown
    elif [[ "$ARENA_STATE_CHECKPOINT_ROUND" =~ ^[0-9]+$ ]]; then
        ARENA_STATE_CHECKPOINT_ROUND=$((ARENA_STATE_CHECKPOINT_ROUND + 1))
    fi
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_ACTOR='writer'
}

# ---------------------------------------------------------------------------
# Legacy projection (read-only; zero writes): derive a semantic state from
# v0.3 evidence files when no run-state.tsv exists. Matching is by the binding
# SHA inside the evidence, never by filename alone. A PRECHECK runs before the
# row matching. Exit codes: 0 projected; 2 conflict (each conflict line is
# printed to stderr and ARENA_PROJECTED_CONFLICTS is set); 5 evidence residue
# owned by one command (ARENA_PROJECTED_RESIDUE names the owner).
# ---------------------------------------------------------------------------

arena_state_projection_clear() {
    ARENA_PROJECTED_PHASE=''; ARENA_PROJECTED_PARTY=''; ARENA_PROJECTED_REASON=''
    ARENA_PROJECTED_VERDICT=''; ARENA_PROJECTED_VR=''; ARENA_PROJECTED_VD=''
    ARENA_PROJECTED_CS=''; ARENA_PROJECTED_ROUND='unknown'; ARENA_PROJECTED_LABEL='legacy'
    ARENA_PROJECTED_WAITING_SINCE='unknown'; ARENA_PROJECTED_LAST_TRANSITION_AT='unknown'
    ARENA_PROJECTED_RESIDUE=''
    ARENA_PROJECTED_CONFLICTS=''
}

# Repair candidates re-project the evidence ignoring SHA-disagreeing files;
# the exclusion list (space-separated basenames) makes the projection treat
# those files as absent. Empty outside candidate computation.
arena_state_projection_excluded() {
    local name="$1"
    local excluded
    for excluded in $ARENA_PROJECTION_EXCLUDE; do
        [[ "$name" == "$excluded" ]] && return 0
    done
    return 1
}

# Append one conflict line to ARENA_PROJECTED_CONFLICTS and print it to stderr.
arena_state_projection_conflict() {
    ARENA_PROJECTED_CONFLICTS="${ARENA_PROJECTED_CONFLICTS}${1};"
    printf 'agent-arena: conflict: %s\n' "$1" >&2
}

arena_state_project_legacy() {
    local run_dir="$1"
    local review_head short_head file line sha
    local dec_file='' dec_sha='' verdict='' state_rev='' dec_multiple=0
    local pointer_name='' report_file='' bound_report='' vr='' vd=''

    arena_state_projection_clear

    if [[ ! -f "${run_dir}/review.tsv" ]]; then
        # L6 requires no orphan evidence of any kind: no Val/Dec pointers,
        # reports, or decision files.
        for file in "${run_dir}"/validation.md "${run_dir}"/decision.md \
            "${run_dir}"/validation-*.md "${run_dir}"/decision-*.md; do
            [[ -f "$file" ]] || continue
            # Diagnostic reports are audit-only artifacts, never evidence.
            case "$file" in *.diagnostic.md) continue ;; esac
            arena_state_projection_conflict "orphan evidence with no review.tsv ($(basename "$file"))"
        done
        if [[ -n "$ARENA_PROJECTED_CONFLICTS" ]]; then
            return 2
        fi
        ARENA_PROJECTED_PHASE='intake'; ARENA_PROJECTED_PARTY='writer'; ARENA_PROJECTED_REASON='none'
        return 0
    fi

    review_head="$(awk -F $'\t' '$1 == "review_head" { print $2; exit }' "${run_dir}/review.tsv" || true)"
    if [[ ! "$review_head" =~ ^[0-9a-f]{40}$ ]]; then
        arena_state_projection_conflict 'review.tsv review_head unreadable'
        return 2
    fi
    ARENA_PROJECTED_CS="$review_head"
    short_head="$(arena_short_sha "$review_head")"

    # PRECHECK scan: bind every decision archive by the SHA inside it.
    for file in "${run_dir}"/decision-*.md; do
        [[ -f "$file" ]] || continue
        if arena_state_projection_excluded "$(basename "$file")"; then
            continue
        fi
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        dec_sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        if [[ -z "$dec_sha" ]]; then
            arena_state_projection_conflict "decision archive without a binding SHA ($(basename "$file"))"
            continue
        fi
        if [[ "$dec_sha" != "$review_head" ]]; then
            arena_state_projection_conflict "decision archive bound to differing SHA ($dec_sha)"
            continue
        fi
        if [[ -n "$dec_file" ]]; then
            dec_multiple=1
            arena_state_projection_conflict 'multiple decision archives bound to review_head'
            continue
        fi
        dec_file="$file"
    done

    if [[ -f "${run_dir}/validation.md" ]] && ! arena_state_projection_excluded 'validation.md'; then
        pointer_name="$(sed -n 's/^Latest validation report: //p' "${run_dir}/validation.md" | head -1)"
        if [[ -z "$pointer_name" ]]; then
            arena_state_projection_conflict 'validation pointer unparseable'
        fi
    fi

    # PRECHECK scan: bind every validation report by the SHA inside it.
    # Rotated .rN copies and .diagnostic.md reports are audit artifacts,
    # not canonical evidence.
    for file in "${run_dir}"/validation-*.md; do
        [[ -f "$file" ]] || continue
        case "$file" in *.r[0-9]*.md|*.diagnostic.md) continue ;; esac
        if arena_state_projection_excluded "$(basename "$file")"; then
            continue
        fi
        [[ "$file" == "${run_dir}/${pointer_name}" ]] && continue
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        if [[ -z "$sha" ]]; then
            arena_state_projection_conflict "validation report without a binding SHA ($(basename "$file"))"
        elif [[ "$sha" != "$review_head" ]]; then
            arena_state_projection_conflict "validation report bound to differing SHA ($sha)"
        elif [[ -n "$bound_report" ]]; then
            arena_state_projection_conflict 'multiple validation reports bound to review_head'
        else
            bound_report="$file"
        fi
    done

    if [[ -n "$pointer_name" ]]; then
        if [[ -f "${run_dir}/${pointer_name}" && ! -L "${run_dir}/${pointer_name}" ]]; then
            report_file="${run_dir}/${pointer_name}"
            if ! grep -Fqx "Review HEAD: ${review_head}" "$report_file"; then
                arena_state_projection_conflict 'validation pointer bound to differing SHA'
                report_file=''
            fi
        else
            arena_state_projection_conflict 'validation pointer without a canonical report'
        fi
    fi

    if [[ -z "$report_file" && -n "$bound_report" ]]; then
        report_file="$bound_report"
    fi
    if [[ -n "$report_file" ]]; then
        vr="$(grep '^RESULT: ' "$report_file" | tail -1 | sed 's/^RESULT: //' || true)"
        case "$vr" in
            PASS|FAIL) ;;
            *) arena_state_projection_conflict 'validation report RESULT unparseable'; vr='' ;;
        esac
        if [[ -n "$vr" ]]; then
            vd="$(arena_file_hash "$report_file")" || \
                arena_state_projection_conflict 'cannot hash validation report'
        fi
    fi

    if [[ -n "$dec_file" && "$dec_multiple" == 0 ]]; then
        verdict="$(grep '^VERDICT: ' "$dec_file" | head -1 | sed 's/^VERDICT: //' || true)"
        case "$verdict" in
            APPROVE|CHANGES_REQUESTED|BLOCKED) ;;
            *) arena_state_projection_conflict 'decision verdict unparseable'; verdict='' ;;
        esac
        state_rev="$(grep '^State revision: ' "$dec_file" | head -1 | sed 's/^State revision: //' || true)"
        if [[ -n "$state_rev" && "$state_rev" != 0 ]]; then
            arena_state_projection_conflict 'decision archive metadata references a missing state file'
        fi
    fi

    # PRECHECK (a): report without pointer → validate-owned residue ONLY when
    # R exists, the report parses, and it binds to the current review_head;
    # otherwise it is a conflict.
    if [[ -z "$pointer_name" && -n "$report_file" ]]; then
        if [[ -z "$ARENA_PROJECTED_CONFLICTS" && -n "$vr" ]]; then
            ARENA_PROJECTED_RESIDUE='validate'
            ARENA_PROJECTED_PHASE='submitted'; ARENA_PROJECTED_PARTY='reviewer'
            ARENA_PROJECTED_REASON='review_pending'
            return 5
        fi
    fi

    # PRECHECK (b): pending decision archive with no state → decision-owned
    # residue ONLY with v0.4 metadata `State revision: 0`; a plain v0.3
    # decision continues into rows L1–L3.
    if [[ -n "$dec_file" && "$dec_multiple" == 0 && -n "$verdict" ]]; then
        if [[ -z "$report_file" ]]; then
            arena_state_projection_conflict 'decision without a canonical validation report'
        elif [[ "$verdict" == APPROVE && "$vr" != PASS ]]; then
            arena_state_projection_conflict 'legacy APPROVE requires RESULT: PASS'
        fi
        if [[ -z "$ARENA_PROJECTED_CONFLICTS" && -n "$vr" && -n "$vd" ]]; then
            ARENA_PROJECTED_VERDICT="$verdict"; ARENA_PROJECTED_VR="$vr"; ARENA_PROJECTED_VD="$vd"
            case "$verdict" in
                APPROVE)
                    ARENA_PROJECTED_PHASE='decided'; ARENA_PROJECTED_PARTY='human'
                    ARENA_PROJECTED_REASON='approval_pending'
                    ARENA_PROJECTED_LABEL='legacy_human_disposition_unknown'
                    ;;
                CHANGES_REQUESTED)
                    ARENA_PROJECTED_PHASE='decided'; ARENA_PROJECTED_PARTY='writer'
                    ARENA_PROJECTED_REASON='changes_requested'
                    ;;
                BLOCKED)
                    ARENA_PROJECTED_PHASE='blocked'; ARENA_PROJECTED_PARTY='human'
                    ARENA_PROJECTED_REASON='block_resolution_required'
                    ;;
            esac
            if [[ "$state_rev" == 0 ]]; then
                ARENA_PROJECTED_RESIDUE='decision'
                return 5
            fi
            return 0
        fi
    fi

    # L4: no Dec; Val pointer + canonical report bound to review_head.
    if [[ -z "$dec_file" && -z "$ARENA_PROJECTED_CONFLICTS" && -n "$pointer_name" && \
        -n "$report_file" && -n "$vr" && -n "$vd" ]]; then
        ARENA_PROJECTED_PHASE='validated'; ARENA_PROJECTED_PARTY='reviewer'
        ARENA_PROJECTED_REASON='decision_pending'
        ARENA_PROJECTED_VR="$vr"; ARENA_PROJECTED_VD="$vd"
        return 0
    fi

    # L5: no Dec, no Val, and no report or pointer artifacts of any kind.
    if [[ -z "$ARENA_PROJECTED_CONFLICTS" ]]; then
        ARENA_PROJECTED_PHASE='submitted'; ARENA_PROJECTED_PARTY='reviewer'
        ARENA_PROJECTED_REASON='review_pending'
        return 0
    fi
    return 2
}

arena_state_write() {
    local run_dir="$1"
    local tmp_file
    shift
    tmp_file="$(mktemp "${run_dir}/.run-state.XXXXXX")"
    arena_state_render_tsv "$@" >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/run-state.tsv"
}

# arena_state_render_tsv [KEY=VAL ...]: print the canonical state wire
# format (ARENA_STATE_KEYS order). With no arguments the in-memory
# ARENA_STATE_* variables are used (the defaults/mutation entry point);
# explicit KEY=VAL arguments override them. This is the one serialization
# every writer and digest computation shares.
arena_state_render_tsv() {
    local key value var_name
    for key in $ARENA_STATE_KEYS; do
        value=''
        if [[ $# -eq 0 ]]; then
            # No explicit key=value arguments: write the in-memory
            # ARENA_STATE_* variables (the defaults/mutation entry point).
            case "$key" in
                state_revision) var_name='ARENA_STATE_REVISION' ;;
                *) var_name="ARENA_STATE_$(printf '%s' "$key" | tr 'a-z' 'A-Z')" ;;
            esac
            value="${!var_name}"
        else
            for arg in "$@"; do
                if [[ "$arg" == "${key}="* ]]; then
                    value="${arg#*=}"
                    break
                fi
            done
        fi
        printf '%s\t%s\n' "$key" "$value"
    done
}

arena_creation_intent_path() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    printf '%s/%s/.creating-%s' "$runs_root" "$repo_id" "$run_id"
}

arena_creation_intent_write() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    shift 3
    local intent tmp_file arg
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    tmp_file="$(mktemp "${runs_root}/${repo_id}/.creating-intent.XXXXXX")"
    {
        printf 'run_id\t%s\n' "$run_id"
        for arg in "$@"; do
            printf '%s\n' "$arg"
        done
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$intent"
}

arena_creation_intent_read() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    local intent line key value
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    ARENA_INTENT_FIELDS=''
    [[ -f "$intent" ]] || return 1
    # Tolerate both line forms: a bare-TSV line (the run_id header written
    # first by arena_creation_intent_write, or a partially rewritten intent)
    # splits on TAB; a key=value line splits on '='. A line with neither
    # separator is corrupted and fails closed.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == *$'\t'* ]]; then
            key="${line%%$'\t'*}"
            value="${line#*$'\t'}"
        else
            key="${line%%=*}"
            value="${line#*=}"
            [[ "$key" != "$line" ]] || arena_die "corrupted creation intent: $intent"
        fi
        ARENA_INTENT_FIELDS="$ARENA_INTENT_FIELDS $key"
        printf -v "ARENA_INTENT_${key}" '%s' "$value"
    done <"$intent"
    return 0
}

arena_creation_intent_stage() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    local run_dir="${runs_root}/${repo_id}/${run_id}" intent manifest writer_wt

    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    if [[ ! -e "$intent" ]]; then
        printf 'NONE\n'
        return 0
    fi
    if [[ ! -e "$run_dir" ]]; then printf 'S1\n'; return 0; fi
    if [[ ! -e "${run_dir}/manifest.tsv" ]]; then
        if find "$run_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            printf 'S3\n'
        else
            printf 'S2\n'
        fi
        return 0
    fi
    manifest="${run_dir}/manifest.tsv"
    writer_wt="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "$manifest")"
    if [[ -z "$writer_wt" || ! -e "$writer_wt" ]]; then printf 'S4\n'; return 0; fi
    if [[ ! -e "${run_dir}/run-state.tsv" ]]; then printf 'S5\n'; else printf 'S6\n'; fi
    return 0
}

arena_state_precheck_lock_live() {
    local lock_path="$1"
    [[ -e "$lock_path" ]] || return 1
    if arena_lock_is_held "$lock_path"; then
        if arena_lock_owner_alive "$lock_path"; then
            return 0
        fi
        return 1
    fi
    if arena_lock_metadata_less_fresh "$lock_path"; then
        return 0
    fi
    return 1
}

arena_state_precheck_intents() {
    local runs_root="$1" repo_id="$2" run_id="$3" caller="$4"
    local stage intent lock_path parent_lock run_dir

    run_dir="${runs_root}/${repo_id}/${run_id}"
    lock_path="${run_dir}/.run-lock"
    parent_lock="${runs_root}/${repo_id}/.parent-lock"
    if arena_state_precheck_lock_live "$lock_path"; then
        printf 'transition in progress\n' >&2
        exit 4
    fi
    if arena_state_precheck_lock_live "$parent_lock"; then
        printf 'transition in progress\n' >&2
        exit 4
    fi
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    [[ -e "$intent" ]] || return 0
    stage="$(arena_creation_intent_stage "$runs_root" "$repo_id" "$run_id")"
    case "$stage" in
        S3|S4)
            if [[ "$caller" == status || "$caller" == list || "$caller" == start ]]; then
                printf 'interrupted start stage %s: inspect %s; if it contains only Arena-created artifacts, remove the directory, the creation intent, the Git worktree registration (git worktree remove; git worktree prune), and the writer branch, then re-run start\n' "$stage" "$run_dir" >&2
                exit 2
            fi
            printf 'interrupted start; retry: agent-arena start %s\n' "$run_id" >&2
            exit 5
            ;;
        S1|S2|S5|S6)
            if [[ "$caller" == start ]]; then
                return 0
            fi
            printf 'interrupted start; retry: agent-arena start %s\n' "$run_id" >&2
            exit 5
            ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Repair-state candidate contract (T14): candidates, the token payload, the
# tombstone move map, and the repair intent protocol. All functions here are
# deterministic and zero-write except arena_repair_intent_write.
# ---------------------------------------------------------------------------

# The evidence digest of a run: sha256 over the sorted (basename, digest)
# pairs of every canonical evidence file. Rotated .rN copies and
# .diagnostic.md reports are audit-only and excluded. The digest is
# identical at status time and under the repair lock, before any tombstone.
arena_state_evidence_digest() {
    local run_dir="$1"
    local input='' file hash
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -f "$file" ]] || continue
        case "$file" in
            *.r[0-9]*.md|*.diagnostic.md) continue ;;
        esac
        hash="$(arena_file_hash "$file")" || continue
        printf -v input '%s%s\t%s\n' "$input" "$(basename -- "$file")" "$hash"
    done < <(printf '%s\n' \
        "${run_dir}/review.tsv" \
        "${run_dir}/validation.md" \
        "${run_dir}/decision.md" \
        "${run_dir}"/validation-*.md \
        "${run_dir}"/decision-*.md | sort -u)
    arena_sha256_text "$input"
}

# A decision archive bound to the given SHA by its internal Review HEAD line.
arena_state_decision_archive_for_head() {
    local run_dir="$1" head="$2"
    local file line sha
    for file in "${run_dir}"/decision-*.md; do
        [[ -f "$file" ]] || continue
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        [[ -n "$sha" && "$sha" == "$head" ]] && return 0
    done
    return 1
}

# A candidate is only safe when every recorded conflict is a SHA
# disagreement the exclusion re-projection resolves. Any other conflict
# (unparseable verdicts/RESULTs, pointer without a report, missing reports
# for L1-L3, orphan evidence without review.tsv, ...) is refusal-only.
arena_state_repair_conflicts_admit() {
    local -a conflicts
    local conflict admitted=0
    IFS=';' read -r -a conflicts <<<"$ARENA_PROJECTED_CONFLICTS"
    for conflict in "${conflicts[@]}"; do
        [[ -n "$conflict" ]] || continue
        case "$conflict" in
            'decision archive bound to differing SHA ('*')') admitted=1 ;;
            'validation report bound to differing SHA ('*')') admitted=1 ;;
            'validation pointer bound to differing SHA') admitted=1 ;;
            *) return 1 ;;
        esac
    done
    [[ "$admitted" == 1 ]]
}

# The tombstone move map: every Val/Dec evidence file bound to a SHA that
# differs from review.tsv's review_head, plus the validation pointer when
# its canonical report is bound elsewhere. Basenames, joined by ';'.
# Unparseable bindings refuse (return 1) - they are never silently moved.
arena_state_repair_tombstones() {
    local run_dir="$1"
    local review_head file line sha pointer_name
    ARENA_REPAIR_TOMBSTONES=''
    review_head="$(awk -F $'\t' '$1 == "review_head" { print $2; exit }' "${run_dir}/review.tsv" 2>/dev/null || true)"
    [[ "$review_head" =~ ^[0-9a-f]{40}$ ]] || return 1
    for file in "${run_dir}"/decision-*.md; do
        [[ -f "$file" ]] || continue
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        [[ -n "$sha" ]] || return 1
        if [[ "$sha" != "$review_head" ]]; then
            ARENA_REPAIR_TOMBSTONES="${ARENA_REPAIR_TOMBSTONES}${ARENA_REPAIR_TOMBSTONES:+;}$(basename -- "$file")"
        fi
    done
    for file in "${run_dir}"/validation-*.md; do
        [[ -f "$file" ]] || continue
        case "$file" in *.r[0-9]*.md|*.diagnostic.md) continue ;; esac
        line="$(grep '^Review HEAD: [0-9a-f]\{40\}$' "$file" | head -1 || true)"
        sha="$(printf '%s\n' "$line" | sed 's/^Review HEAD: //')"
        [[ -n "$sha" ]] || return 1
        if [[ "$sha" != "$review_head" ]]; then
            ARENA_REPAIR_TOMBSTONES="${ARENA_REPAIR_TOMBSTONES}${ARENA_REPAIR_TOMBSTONES:+;}$(basename -- "$file")"
        fi
    done
    if [[ -f "${run_dir}/validation.md" ]]; then
        pointer_name="$(sed -n 's/^Latest validation report: //p' "${run_dir}/validation.md" | head -1)"
        if [[ -n "$pointer_name" && -f "${run_dir}/${pointer_name}" && ! -L "${run_dir}/${pointer_name}" ]] && \
            ! grep -Fqx "Review HEAD: ${review_head}" "${run_dir}/${pointer_name}"; then
            ARENA_REPAIR_TOMBSTONES="${ARENA_REPAIR_TOMBSTONES}${ARENA_REPAIR_TOMBSTONES:+;}validation.md"
            ARENA_REPAIR_TOMBSTONES="${ARENA_REPAIR_TOMBSTONES};${pointer_name}"
        fi
    fi
    return 0
}

# Emit one candidate from the current (clean) projection: record the
# target-field values, build the placeholder payload, and either print the
# candidate line or match the expected token (ARENA_REPAIR_MATCH=1).
arena_state_repair_emit() {
    local baseline="$1" evidence="$2" revision="$3" ws_rule="$4" expect="$5"
    local run_status phase round ws_mode='now' token payload checkpoint_suffix=''

    case "$ARENA_PROJECTED_PHASE" in
        intake) run_status='active'; phase='intake'; round='0' ;;
        submitted) run_status='active'; phase='submitted'; round='unknown' ;;
        validated) run_status='active'; phase='validated'; round='unknown' ;;
        decided) run_status='active'; phase='decided'; round='unknown' ;;
        blocked) run_status='blocked'; phase='decided'; round='unknown' ;;
        *) return 0 ;;
    esac
    # Valid-v1 sources preserve waiting_since when the candidate's party
    # and reason equal the current state's; legacy/corrupt materialize @now.
    if [[ "$ws_rule" == preserve ]]; then
        if [[ "$ARENA_PROJECTED_PARTY" == "$ARENA_STATE_RESPONSIBLE_PARTY" && \
            "$ARENA_PROJECTED_REASON" == "$ARENA_STATE_REASON_CODE" ]]; then
            ws_mode='preserve'
            ARENA_REPAIR_TARGET_WS_VALUE="$ARENA_STATE_WAITING_SINCE"
        fi
    fi
    ARENA_REPAIR_TARGET_RUN_STATUS="$run_status"
    ARENA_REPAIR_TARGET_PHASE="$phase"
    ARENA_REPAIR_TARGET_PARTY="$ARENA_PROJECTED_PARTY"
    ARENA_REPAIR_TARGET_REASON="$ARENA_PROJECTED_REASON"
    ARENA_REPAIR_TARGET_VERDICT="$ARENA_PROJECTED_VERDICT"
    ARENA_REPAIR_TARGET_VR="$ARENA_PROJECTED_VR"
    ARENA_REPAIR_TARGET_VD="$ARENA_PROJECTED_VD"
    ARENA_REPAIR_TARGET_CS="$ARENA_PROJECTED_CS"
    ARENA_REPAIR_TARGET_ROUND="$round"
    ARENA_REPAIR_TARGET_REVISION="$revision"
    ARENA_REPAIR_TARGET_WS_MODE="$ws_mode"
    ARENA_REPAIR_BASELINE_STRING="$baseline"
    ARENA_REPAIR_EVIDENCE_DIGEST="$evidence"
    arena_state_repair_pairs '@now' '@now' '@reason' '@revision'
    payload="$ARENA_REPAIR_PAYLOAD"
    token="$(arena_sha256_text "${evidence}${baseline}${payload}")"
    token="${token:0:12}"
    if [[ -n "$expect" ]]; then
        [[ "$token" == "$expect" ]] && ARENA_REPAIR_MATCH=1
        return 0
    fi
    if [[ -n "$ARENA_PROJECTED_CS" ]]; then
        checkpoint_suffix=" checkpoint $(arena_short_sha "$ARENA_PROJECTED_CS")"
    fi
    printf 'repair-candidate %s -> %s/%s/%s/%s revision %s%s\n' \
        "$token" "$run_status" "$phase" "$ARENA_PROJECTED_PARTY" "$ARENA_PROJECTED_REASON" \
        "$revision" "$checkpoint_suffix"
}

# Conflict candidate: only pure SHA disagreements, re-projected with every
# disagreeing file excluded, and only when that projection is clean.
arena_state_repair_candidate_conflicts() {
    local run_dir="$1" baseline="$2" evidence="$3" revision="$4" ws_rule="$5" expect="$6"
    local projection_status=0
    arena_state_repair_conflicts_admit || return 0
    arena_state_repair_tombstones "$run_dir" || return 0
    [[ -n "$ARENA_REPAIR_TOMBSTONES" ]] || return 0
    ARENA_PROJECTION_EXCLUDE="${ARENA_REPAIR_TOMBSTONES//;/ }"
    arena_state_project_legacy "$run_dir" 2>/dev/null || projection_status=$?
    ARENA_PROJECTION_EXCLUDE=''
    [[ "$projection_status" == 0 ]] || return 0
    arena_state_repair_emit "$baseline" "$evidence" "$revision" "$ws_rule" "$expect"
}

# Build the canonical candidate key=value pairs (wire-table order) and the
# two serializations: ARENA_REPAIR_PAYLOAD joins with ';' for the token
# (placeholders passed in), ARENA_REPAIR_PAYLOAD_X1F joins with \x1f for
# the intent (materialized values). ARENA_REPAIR_TARGET_DIGEST is the
# sha256 of the exact state-file bytes the pairs render to.
arena_state_repair_pairs() {
    local ws_value="$1" lta_value="$2" reason_value="$3" revision_value="$4"
    ARENA_REPAIR_PAIRS=(
        "schema_version=1"
        "state_revision=${revision_value}"
        "run_status=${ARENA_REPAIR_TARGET_RUN_STATUS}"
        "phase=${ARENA_REPAIR_TARGET_PHASE}"
        "responsible_party=${ARENA_REPAIR_TARGET_PARTY}"
        "reason_code=${ARENA_REPAIR_TARGET_REASON}"
        "reason_detail=${reason_value}"
        "verdict=${ARENA_REPAIR_TARGET_VERDICT}"
        "validation_result=${ARENA_REPAIR_TARGET_VR}"
        "checkpoint_round=${ARENA_REPAIR_TARGET_ROUND}"
        "checkpoint_sha=${ARENA_REPAIR_TARGET_CS}"
        "waiting_since=${ws_value}"
        "last_transition_at=${lta_value}"
        "last_transition_actor=system"
        "last_transition_action=repair-state"
        "validation_digest=${ARENA_REPAIR_TARGET_VD}"
    )
    ARENA_REPAIR_PAYLOAD="$(IFS=';'; printf '%s' "${ARENA_REPAIR_PAIRS[*]}")"
    ARENA_REPAIR_PAYLOAD_X1F="$(IFS=$'\x1f'; printf '%s' "${ARENA_REPAIR_PAIRS[*]}")"
    # The target digest binds the exact bytes arena_state_write will put on
    # disk (including the final newline); command substitution alone would
    # strip it and every commit would fail the digest check.
    ARENA_REPAIR_TARGET_DIGEST="$(arena_sha256_text "$(arena_state_render_tsv "${ARENA_REPAIR_PAIRS[@]}")"$'\n')"
}

# Rebuild ARENA_REPAIR_PAIRS from an intent's materialized payload.
arena_state_repair_pairs_from_payload() {
    local payload="$1"
    IFS=$'\x1f' read -r -a ARENA_REPAIR_PAIRS <<<"$payload"
    [[ "${#ARENA_REPAIR_PAIRS[@]}" == 16 ]] || return 1
    return 0
}

# Verify the pairs satisfy every state invariant by rendering them to a
# temporary file and reading it through the full validation path.
arena_state_repair_verify() {
    local run_dir="$1"
    local tmp_check
    tmp_check="$(mktemp "${run_dir}/.repair-check.XXXXXX")"
    arena_state_render_tsv "${ARENA_REPAIR_PAIRS[@]}" >"$tmp_check"
    if ( arena_state_read_file "$tmp_check" >/dev/null 2>&1 ); then
        rm -f "$tmp_check"
        return 0
    fi
    rm -f "$tmp_check"
    return 1
}

# arena_state_repair_candidates RUN_DIR [EXPECT_TOKEN]: compute the repair
# candidates for a run. Without EXPECT_TOKEN each candidate prints one
# 'repair-candidate TOKEN -> ...' line; with it, the matching candidate
# sets ARENA_REPAIR_MATCH=1 and leaves the target fields in ARENA_REPAIR_*.
# Sources: legacy conflicts, corrupted state files, and the spec-restricted
# valid-v1 evidence conflicts. Refusal-only conflicts print nothing.
arena_state_repair_candidates() {
    local run_dir="$1"
    local expect="${2:-}"
    local baseline evidence projection_status raw_schema conflict
    local review_head report vr

    [[ -d "$run_dir" ]] || return 0
    ARENA_REPAIR_MATCH=0
    ARENA_REPAIR_TARGET_REVISION=''
    ARENA_REPAIR_TARGET_WS_MODE=''
    ARENA_REPAIR_TARGET_WS_VALUE=''
    ARENA_REPAIR_TOMBSTONES=''
    ARENA_REPAIR_BASELINE_STRING=''
    ARENA_REPAIR_EVIDENCE_DIGEST=''

    evidence="$(arena_state_evidence_digest "$run_dir")"
    ARENA_REPAIR_EVIDENCE_DIGEST="$evidence"

    if [[ ! -f "${run_dir}/run-state.tsv" ]]; then
        # Legacy source: only a conflicted projection offers candidates.
        baseline='absent'
        projection_status=0
        arena_state_project_legacy "$run_dir" 2>/dev/null || projection_status=$?
        [[ "$projection_status" == 2 ]] || return 0
        arena_state_repair_candidate_conflicts "$run_dir" "$baseline" "$evidence" '1' 'now' "$expect"
        return 0
    fi

    if ( arena_state_read "$run_dir" >/dev/null 2>&1 ); then
        :
    else
        # Corrupted state source - but a future schema version has no
        # recovery path (upgrade Arena instead).
        raw_schema="$(awk -F $'\t' '$1 == "schema_version" { print $2; exit }' "${run_dir}/run-state.tsv" 2>/dev/null || true)"
        if [[ "$raw_schema" =~ ^[0-9]+$ && "$raw_schema" != 1 ]]; then
            return 0
        fi
        baseline="$(arena_file_hash "${run_dir}/run-state.tsv")" || return 0
        [[ "$baseline" =~ ^[0-9a-f]{64}$ ]] || return 0
        baseline="corrupt:${baseline}"
        projection_status=0
        arena_state_project_legacy "$run_dir" 2>/dev/null || projection_status=$?
        if [[ "$projection_status" == 0 ]]; then
            arena_state_repair_emit "$baseline" "$evidence" '1' 'now' "$expect"
        elif [[ "$projection_status" == 2 ]]; then
            arena_state_repair_candidate_conflicts "$run_dir" "$baseline" "$evidence" '1' 'now' "$expect"
        fi
        return 0
    fi

    # Valid-v1 source: only the genuine conflicts no owning command can
    # recover - checkpoint_sha disagreeing with review.tsv, verdict empty
    # while a decision archive exists, or validation_result/digest
    # disagreeing with the canonical report. Terminal states are never
    # candidates.
    arena_state_read "$run_dir" 2>/dev/null
    [[ "$ARENA_STATE_RUN_STATUS" == completed || "$ARENA_STATE_RUN_STATUS" == canceled ]] && return 0
    conflict=0
    review_head=''
    [[ -f "${run_dir}/review.tsv" ]] && \
        review_head="$(awk -F $'\t' '$1 == "review_head" { print $2; exit }' "${run_dir}/review.tsv" 2>/dev/null || true)"
    if [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && "$review_head" =~ ^[0-9a-f]{40}$ && \
        "$ARENA_STATE_CHECKPOINT_SHA" != "$review_head" ]]; then
        conflict=1
    elif [[ -z "$ARENA_STATE_VERDICT" && "$review_head" =~ ^[0-9a-f]{40}$ ]] && \
        arena_state_decision_archive_for_head "$run_dir" "$review_head"; then
        conflict=1
    elif [[ -n "$ARENA_STATE_VALIDATION_RESULT" && "$review_head" =~ ^[0-9a-f]{40}$ ]]; then
        report="${run_dir}/validation-$(arena_short_sha "$review_head").md"
        if [[ -f "$report" ]]; then
            vr="$(grep '^RESULT: ' "$report" | tail -1 | sed 's/^RESULT: //' || true)"
            [[ "$vr" != "$ARENA_STATE_VALIDATION_RESULT" ]] && conflict=1
            [[ "$(arena_file_hash "$report")" != "$ARENA_STATE_VALIDATION_DIGEST" ]] && conflict=1
        fi
    fi
    [[ "$conflict" == 1 ]] || return 0
    raw_state_digest="$(arena_file_hash "${run_dir}/run-state.tsv")" || return 0
    baseline="valid:${raw_state_digest}:${ARENA_STATE_REVISION}"
    projection_status=0
    arena_state_project_legacy "$run_dir" 2>/dev/null || projection_status=$?
    if [[ "$projection_status" == 0 ]]; then
        ARENA_REPAIR_TOMBSTONES=''
        arena_state_repair_emit "$baseline" "$evidence" "$((ARENA_STATE_REVISION + 1))" 'preserve' "$expect"
    elif [[ "$projection_status" == 2 ]]; then
        arena_state_repair_candidate_conflicts "$run_dir" "$baseline" "$evidence" "$((ARENA_STATE_REVISION + 1))" 'preserve' "$expect"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Repair intent: the atomic, intent-first record for T14. It carries the
# original state baseline, the evidence baseline digest, the token, the
# reason, the materialized target values (pairs + target digest), the
# audit-copy target, and the complete tombstone move map.
# ---------------------------------------------------------------------------

arena_repair_intent_write() {
    local run_dir="$1" baseline="$2" evidence="$3" token="$4" reason="$5" \
        target_digest="$6" target_payload="$7" audit_copy="$8" move_map="$9" stamp="${10}"
    local tmp_file
    tmp_file="$(mktemp "${run_dir}/.repair.intent.XXXXXX")"
    {
        printf 'baseline\t%s\n' "$baseline"
        printf 'evidence\t%s\n' "$evidence"
        printf 'token\t%s\n' "$token"
        printf 'reason\t%s\n' "$reason"
        printf 'target_digest\t%s\n' "$target_digest"
        printf 'target_payload\t%s\n' "$target_payload"
        printf 'audit_copy\t%s\n' "$audit_copy"
        printf 'move_map\t%s\n' "$move_map"
        printf 'stamp\t%s\n' "$stamp"
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/.repair.intent"
}

arena_repair_intent_read() {
    local run_dir="$1"
    local key value seen=''
    ARENA_REPAIR_BASELINE=''; ARENA_REPAIR_EVIDENCE=''; ARENA_REPAIR_TOKEN=''
    ARENA_REPAIR_REASON=''; ARENA_REPAIR_TARGET_DIGEST=''; ARENA_REPAIR_TARGET_PAYLOAD=''
    ARENA_REPAIR_AUDIT_COPY=''; ARENA_REPAIR_MOVE_MAP=''; ARENA_REPAIR_STAMP=''
    while IFS=$'\t' read -r key value; do
        case "$key" in
            baseline) ARENA_REPAIR_BASELINE="$value" ;;
            evidence) ARENA_REPAIR_EVIDENCE="$value" ;;
            token) ARENA_REPAIR_TOKEN="$value" ;;
            reason) ARENA_REPAIR_REASON="$value" ;;
            target_digest) ARENA_REPAIR_TARGET_DIGEST="$value" ;;
            target_payload) ARENA_REPAIR_TARGET_PAYLOAD="$value" ;;
            audit_copy) ARENA_REPAIR_AUDIT_COPY="$value" ;;
            move_map) ARENA_REPAIR_MOVE_MAP="$value" ;;
            stamp) ARENA_REPAIR_STAMP="$value" ;;
            *) arena_state_die "corrupted repair intent: unknown key $key" ;;
        esac
        seen="$seen $key"
    done <"${run_dir}/.repair.intent"
    for key in baseline evidence token reason target_digest target_payload stamp; do
        case " $seen " in *" $key "*) ;; *) arena_state_die "corrupted repair intent: missing key $key" ;; esac
    done
    [[ "$ARENA_REPAIR_BASELINE" =~ ^(absent|valid:[0-9a-f]{64}:[0-9]+|corrupt:[0-9a-f]{64})$ ]] || \
        arena_state_die 'corrupted repair intent: unreadable baseline'
    [[ "$ARENA_REPAIR_EVIDENCE" =~ ^[0-9a-f]{64}$ ]] || \
        arena_state_die 'corrupted repair intent: unreadable evidence digest'
    [[ "$ARENA_REPAIR_TOKEN" =~ ^[0-9a-f]{12}$ ]] || \
        arena_state_die 'corrupted repair intent: unreadable token'
    [[ "$ARENA_REPAIR_TARGET_DIGEST" =~ ^[0-9a-f]{64}$ ]] || \
        arena_state_die 'corrupted repair intent: unreadable target digest'
    [[ "$ARENA_REPAIR_STAMP" =~ ^[0-9][0-9-]*$ ]] || \
        arena_state_die 'corrupted repair intent: unreadable stamp'
}
