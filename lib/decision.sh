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

decision_archive="${run_dir}/decision-${short_sha}.md"
[[ ! -e "$decision_archive" && ! -L "$decision_archive" ]] || \
    arena_die 'a decision already exists for this checkpoint; create a new writer checkpoint'
tmp_decision="$(mktemp "${run_dir}/.decision.XXXXXX")"
{
    printf '# Agent Arena Gate Decision\n\n'
    printf 'Run: %s\n\n' "$run_id"
    printf 'Review HEAD: %s\n\n' "$ARENA_REVIEW_HEAD"
    printf 'VERDICT: %s\n\n' "$verdict"
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
cp "$decision_archive" "${run_dir}/decision.md"
chmod 600 "${run_dir}/decision.md"

if [[ "$relay" == 1 ]]; then
    if ! "${source_root}/lib/relay.sh" "$run_id" --to writer --from reviewer \
        --message "Gate ${verdict} for ${short_sha}. Read the recorded decision and follow its next step."; then
        arena_note "decision persisted, but writer relay was unavailable; read ${run_dir}/decision.md"
    fi
fi

arena_note "recorded ${verdict} for ${ARENA_REVIEW_HEAD}"
arena_note "writer feedback: ${run_dir}/decision.md"
