#!/usr/bin/env bash
set -euo pipefail

state_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${state_dir}/common.sh"

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
