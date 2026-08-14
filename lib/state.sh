#!/usr/bin/env bash
set -euo pipefail

state_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${state_dir}/common.sh"
source "${state_dir}/lock.sh"

ARENA_STATE_KEYS='schema_version state_revision run_status phase responsible_party reason_code reason_detail verdict validation_result checkpoint_round checkpoint_sha waiting_since last_transition_at last_transition_actor last_transition_action validation_digest'

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
    local key value seen=''

    [[ -f "$manifest" ]] || arena_state_die "missing state file: $manifest"
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
    arena_state_validate "$run_dir"
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

    if [[ -f "${run_dir}/validation.md" ]]; then
        pointer_name="$(sed -n 's/^Latest validation report: //p' "${run_dir}/validation.md" | head -1)"
        if [[ -z "$pointer_name" ]]; then
            arena_state_projection_conflict 'validation pointer unparseable'
        fi
    fi

    # PRECHECK scan: bind every validation report by the SHA inside it.
    # Rotated .rN copies are audit artifacts, not canonical evidence.
    for file in "${run_dir}"/validation-*.md; do
        [[ -f "$file" ]] || continue
        case "$file" in *.r[0-9]*.md) continue ;; esac
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
    local tmp_file value
    shift
    tmp_file="$(mktemp "${run_dir}/.run-state.XXXXXX")"
    for key in $ARENA_STATE_KEYS; do
        value=''
        for arg in "$@"; do
            if [[ "$arg" == "${key}="* ]]; then
                value="${arg#*=}"
                break
            fi
        done
        printf '%s\t%s\n' "$key" "$value"
    done >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/run-state.tsv"
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
    for arg in "$@"; do
        printf '%s\n' "$arg"
    done >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$intent"
}

arena_creation_intent_read() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    local intent key value
    intent="$(arena_creation_intent_path "$runs_root" "$repo_id" "$run_id")"
    ARENA_INTENT_FIELDS=''
    [[ -f "$intent" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" != "$line" ]] || arena_die "corrupted creation intent: $intent"
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

arena_state_precheck_intents() {
    local runs_root="$1" repo_id="$2" run_id="$3" caller="$4"
    local stage intent lock_path run_dir

    run_dir="${runs_root}/${repo_id}/${run_id}"
    lock_path="${run_dir}/.run-lock"
    if [[ -d "$run_dir" ]] && arena_lock_is_held "$lock_path" && arena_lock_owner_alive "$lock_path"; then
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
