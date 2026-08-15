#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
arena="${source_root}/bin/agent-arena"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-arena-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
    printf 'test failure: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure: $*"
    fi
}

require_match() {
    local expected="$1"
    local file="$2"

    grep -Fq -- "$expected" "$file" || fail "missing '$expected' in $file"
}

require_no_match() {
    local forbidden="$1"
    local file="$2"

    if grep -Fq -- "$forbidden" "$file"; then
        fail "unexpected '$forbidden' in $file"
    fi
}

manifest_value() {
    local manifest="$1"
    local key="$2"

    awk -F $'\t' -v key="$key" '$1 == key { print $2 }' "$manifest"
}

# Extract one cell from a single-space-separated list row. The fixed-column
# rows may carry empty cells (terminal authority, empty anomaly); splitting
# on every space character preserves them.
list_column() {
    local row="$1"
    local column="$2"

    printf '%s\n' "$row" | awk -F '[ ]' -v column="$column" '{ print $column }'
}

assert_no_dangerous_writer_flags() {
    local file="$1"
    local flag

    for flag in \
        --auto \
        --force \
        --yolo \
        --full-auto \
        --search \
        --add-dir \
        --worktree \
        --skip-trust \
        --continue \
        --dangerously-skip-permissions \
        --dangerously-bypass-approvals-and-sandbox; do
        require_no_match "arg=${flag}" "$file"
    done
}

assert_no_run_manifest() {
    local run_id="$1"

    if find "${state_base}/runs" -mindepth 3 -maxdepth 3 -type f \
        -name manifest.tsv -path "*/${run_id}/manifest.tsv" -print -quit 2>/dev/null | grep -q .; then
        fail "unexpected run manifest for ${run_id}"
    fi
}

fake_bin="${tmp_root}/fake-bin"
mkdir -p "$fake_bin"
fake_tmux_log="${tmp_root}/tmux.log"
fake_tmuxp_log="${tmp_root}/tmuxp.log"
fake_agent_log="${tmp_root}/agent.log"
fake_pi_log="${tmp_root}/pi.log"
fake_codex_log="${tmp_root}/codex.log"
fake_opencode_log="${tmp_root}/opencode.log"
fake_agy_log="${tmp_root}/agy.log"
cat >"${fake_bin}/pi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'cwd=%s\n' "$PWD"
    printf 'profile=%s\n' "${ARENA_PROFILE:-}"
    printf 'writer_adapter=%s\n' "${ARENA_WRITER_ADAPTER:-}"
    printf 'writer_session_dir=%s\n' "${ARENA_WRITER_SESSION_DIR:-}"
    for argument in "$@"; do
        printf 'arg=%q\n' "$argument"
    done
    printf '%s\n' '--'
} >>"${FAKE_PI_LOG:?}"
EOF
cat >"${fake_bin}/agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_AGENT_LOG:?}"
exit 0
EOF
cat >"${fake_bin}/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'cwd=%s\n' "$PWD"
    printf 'profile=%s\n' "${ARENA_PROFILE:-}"
    printf 'writer_adapter=%s\n' "${ARENA_WRITER_ADAPTER:-}"
    printf 'writer_session_dir=%s\n' "${ARENA_WRITER_SESSION_DIR:-}"
    for argument in "$@"; do
        printf 'arg=%q\n' "$argument"
    done
    printf '%s\n' '--'
} >>"${FAKE_CODEX_LOG:?}"
EOF
cat >"${fake_bin}/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'cwd=%s\n' "$PWD"
    printf 'profile=%s\n' "${ARENA_PROFILE:-}"
    printf 'writer_adapter=%s\n' "${ARENA_WRITER_ADAPTER:-}"
    printf 'writer_session_dir=%s\n' "${ARENA_WRITER_SESSION_DIR:-}"
    printf 'pure=%s\n' "${OPENCODE_PURE:-}"
    printf 'disable_project_config=%s\n' "${OPENCODE_DISABLE_PROJECT_CONFIG:-}"
    printf 'disable_external_skills=%s\n' "${OPENCODE_DISABLE_EXTERNAL_SKILLS:-}"
    printf 'config_content=%q\n' "${OPENCODE_CONFIG_CONTENT:-}"
    for argument in "$@"; do
        printf 'arg=%q\n' "$argument"
    done
    printf '%s\n' '--'
} >>"${FAKE_OPENCODE_LOG:?}"
EOF
cat >"${fake_bin}/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'cwd=%s\n' "$PWD"
    printf 'profile=%s\n' "${ARENA_PROFILE:-}"
    printf 'writer_adapter=%s\n' "${ARENA_WRITER_ADAPTER:-}"
    printf 'writer_session_dir=%s\n' "${ARENA_WRITER_SESSION_DIR:-}"
    for argument in "$@"; do
        printf 'arg=%q\n' "$argument"
    done
    printf '%s\n' '--'
} >>"${FAKE_AGY_LOG:?}"
exit "${FAKE_AGY_EXIT:-0}"
EOF
cat >"${fake_bin}/tmuxp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_TMUXP_LOG:?}"
if [[ -n "${FAKE_TMUXP_LOCK_CHECK:-}" ]]; then
    if [[ -e "${FAKE_TMUXP_LOCK_CHECK}" ]]; then
        printf 'lock-present=%s\n' "${FAKE_TMUXP_LOCK_CHECK}" >>"${FAKE_TMUXP_LOG:?}"
    else
        printf 'lock-absent=%s\n' "${FAKE_TMUXP_LOCK_CHECK}" >>"${FAKE_TMUXP_LOG:?}"
    fi
fi
printf '%s\n' "${FAKE_TMUXP_OUTPUT:-}"
exit "${FAKE_TMUXP_EXIT:-0}"
EOF
cat >"${fake_bin}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
case "$command_name" in
    has-session)
        case "${FAKE_TMUX_MODE:-offline}" in
            relay|live) exit 0 ;;
        esac
        exit 1
        ;;
    list-panes)
        case "${FAKE_TMUX_MODE:-offline}" in
            relay|live) ;;
            *) exit 1 ;;
        esac
        session=''
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -t && $# -ge 2 ]]; then
                session="${2#=}"
                shift 2
            else
                shift
            fi
        done
        case "${FAKE_TMUX_PANES:-normal}" in
            normal)
                printf '%s\t%%12\twriter\twriter-agent\t0\t0\t0\t0\n' "$session"
                printf '%s\t%%13\treviewer\treviewer-agent\t0\t0\t0\t0\n' "$session"
                ;;
            ambiguous)
                printf '%s\t%%12\twriter\twriter-agent\t0\t0\t0\t0\n' "$session"
                printf '%s\t%%14\twriter\twriter-agent\t0\t0\t0\t0\n' "$session"
                ;;
            dead)
                printf '%s\t%%12\twriter\twriter-agent\t1\t0\t0\t0\n' "$session"
                ;;
            reviewer-dead)
                printf '%s\t%%12\twriter\twriter-agent\t0\t0\t0\t0\n' "$session"
                printf '%s\t%%13\treviewer\treviewer-agent\t1\t0\t0\t0\n' "$session"
                ;;
            input-off)
                printf '%s\t%%12\twriter\twriter-agent\t0\t1\t0\t0\n' "$session"
                ;;
            copy-mode)
                printf '%s\t%%12\twriter\twriter-agent\t0\t0\t1\t0\n' "$session"
                ;;
            synchronized)
                printf '%s\t%%12\twriter\twriter-agent\t0\t0\t0\t1\n' "$session"
                ;;
            *) exit 2 ;;
        esac
        ;;
    send-keys)
        printf '%s\n' "$*" >>"${FAKE_TMUX_LOG:?}"
        ;;
    set-environment)
        printf 'set-environment %s\n' "$*" >>"${FAKE_TMUX_LOG:?}"
        ;;
    respawn-pane)
        if [[ -n "${FAKE_TMUX_LOCK_CHECK:-}" ]]; then
            if [[ -e "${FAKE_TMUX_LOCK_CHECK}" ]]; then
                printf 'respawn-lock-present=%s\n' "${FAKE_TMUX_LOCK_CHECK}" >>"${FAKE_TMUX_LOG:?}"
            else
                printf 'respawn-lock-absent=%s\n' "${FAKE_TMUX_LOCK_CHECK}" >>"${FAKE_TMUX_LOG:?}"
            fi
        fi
        printf 'respawn-pane %s\n' "$*" >>"${FAKE_TMUX_LOG:?}"
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod 755 "${fake_bin}"/*

project="${tmp_root}/project"
state_base="${tmp_root}/state"
worktree_base="${tmp_root}/worktrees"
mkdir -p "$project"
git -C "$project" init --initial-branch=main >/dev/null
git -C "$project" config user.name 'Agent Arena Test'
git -C "$project" config user.email 'agent-arena@example.test'
printf '%s\n' 'fixture' >"${project}/README.md"
git -C "$project" add README.md
git -C "$project" commit -m 'test: create fixture' >/dev/null

run_arena() {
    PATH="${fake_bin}:${PATH}" \
        FAKE_TMUX_LOG="$fake_tmux_log" \
        FAKE_TMUXP_LOG="$fake_tmuxp_log" \
        FAKE_AGENT_LOG="$fake_agent_log" \
        FAKE_PI_LOG="$fake_pi_log" \
        FAKE_CODEX_LOG="$fake_codex_log" \
        FAKE_OPENCODE_LOG="$fake_opencode_log" \
        FAKE_AGY_LOG="$fake_agy_log" \
        FAKE_GEMINI_EXIT="${FAKE_GEMINI_EXIT:-0}" \
        ARENA_STATE_ROOT="$state_base" \
        ARENA_WORKTREE_ROOT="$worktree_base" \
        "$arena" "$@"
}

printf '%s\n' '0. help text reflects the pluggable gate'
run_arena help >"${tmp_root}/help.out"
require_match 'writer + gate' "${tmp_root}/help.out"
require_match "gate's formal decision" "${tmp_root}/help.out"

printf '%s\n' '1. doctor'
run_arena doctor >"${tmp_root}/doctor.out"
require_match 'cursor' "${tmp_root}/doctor.out"
require_match 'profile:pi-cursor' "${tmp_root}/doctor.out"
require_match 'profile:codex-cursor' "${tmp_root}/doctor.out"
require_match 'profile:opencode-cursor' "${tmp_root}/doctor.out"
require_match 'profile:agy-cursor' "${tmp_root}/doctor.out"
require_match 'Gates:' "${tmp_root}/doctor.out"
require_match 'gate:cursor' "${tmp_root}/doctor.out"
require_match 'gate:opencode' "${tmp_root}/doctor.out"
# the default Cursor gate missing must not fail doctor while another gate is available
if ARENA_CURSOR_BIN='agent-arena-test-missing-gate-cursor' \
    run_arena doctor >"${tmp_root}/doctor-no-cursor.out" 2>&1; then :; else
    fail 'doctor failed with the Cursor gate missing while the OpenCode gate is available'
fi
grep -F 'gate:cursor' "${tmp_root}/doctor-no-cursor.out" | grep -Fq 'missing' || \
    fail 'doctor did not report the Cursor gate as missing'
grep -F 'gate:opencode' "${tmp_root}/doctor-no-cursor.out" | grep -Fq 'enabled' || \
    fail 'doctor did not report the OpenCode gate as enabled'
require_match 'profile:pi-cursor' "${tmp_root}/doctor-no-cursor.out"
require_match 'blocked' "${tmp_root}/doctor-no-cursor.out"
# zero available gates must fail doctor with the gate matrix message
if ARENA_CURSOR_BIN='agent-arena-test-missing-gate-cursor' \
    ARENA_OPENCODE_BIN='agent-arena-test-missing-gate-opencode' \
    run_arena doctor >"${tmp_root}/doctor-no-gate.out" 2>&1; then
    fail 'doctor succeeded with no available gate adapter'
fi
require_match 'no available gate adapter' "${tmp_root}/doctor-no-gate.out"

printf '%s\n' '2. init'
run_arena init --repo "$project"
[[ -f "${project}/.agent-arena/project.conf" ]] || fail 'init did not create project config'
[[ -x "${project}/.agent-arena/validate.sh" ]] || fail 'init did not create executable validation script'
expect_failure run_arena init --repo "$project"
cat >"${project}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'fixture validation passed'
EOF
chmod 755 "${project}/.agent-arena/validate.sh"
git -C "$project" add .agent-arena
git -C "$project" commit -m 'test: add arena adapter' >/dev/null

printf '%s\n' '3. dirty integration preflight'
printf '%s\n' dirty >"${project}/uncommitted.txt"
expect_failure run_arena start dirty-run --repo "$project" --no-attach
rm -f "${project}/uncommitted.txt"

printf '%s\n' '4. writer worktree lifecycle'
export FAKE_TMUX_MODE=offline
run_arena start run-one --repo "$project" --no-attach 2>&1 | tee "${tmp_root}/start.out"
require_match 'run '\''run-one'\'' is ready' "${tmp_root}/start.out"
require_match 'load --yes --no-progress -d -s agent-arena-' "$fake_tmuxp_log"
state_root="$state_base"
run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-one/manifest.tsv' -exec dirname {} \;)"
[[ -n "$run_dir" ]] || fail 'start did not create run manifest'
writer_worktree="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${run_dir}/manifest.tsv")"
writer_session_dir="$(awk -F $'\t' '$1 == "writer_session_dir" { print $2 }' "${run_dir}/manifest.tsv")"
[[ -d "$writer_worktree" ]] || fail 'start did not create writer worktree'
[[ -d "$writer_session_dir" ]] || fail 'start did not create private writer session directory'
[[ "$(git -C "$writer_worktree" branch --show-current)" == agent-arena/pi/run-one ]] || \
    fail 'writer worktree branch is incorrect'
expect_failure run_arena submit run-one

printf '%s\n' '5. checkpoint and review snapshot'
printf '%s\n' 'implementation' >"${writer_worktree}/implementation.txt"
git -C "$writer_worktree" add implementation.txt
git -C "$writer_worktree" commit -m 'feat: add implementation fixture' >/dev/null
run_arena submit run-one >"${tmp_root}/submit.out"
review_worktree="$(awk -F $'\t' '$1 == "review_worktree" { print $2 }' "${run_dir}/review.tsv")"
writer_head="$(git -C "$writer_worktree" rev-parse HEAD)"
[[ "$(git -C "$review_worktree" rev-parse HEAD)" == "$writer_head" ]] || \
    fail 'review snapshot does not match submitted writer checkpoint'
review_status="$(git -C "$review_worktree" status --porcelain=v1 --untracked-files=all)"
require_match '?? .cursor/cli.json' <(printf '%s\n' "$review_status")
require_match '?? .agent-arena-gate' <(printf '%s\n' "$review_status")
[[ -f "${review_worktree}/.cursor/cli.json" ]] || fail 'review snapshot lacks Cursor gate policy'
[[ -x "${review_worktree}/.agent-arena-gate" ]] || fail 'review snapshot lacks gate wrapper'
[[ "$(manifest_value "${run_dir}/review.tsv" gate_adapter)" == 'cursor' ]] || \
    fail 'review manifest did not record gate_adapter=cursor'
[[ "$(manifest_value "${run_dir}/review.tsv" gate_policy_path)" == '.cursor/cli.json' ]] || \
    fail 'review manifest did not record gate_policy_path=.cursor/cli.json'
[[ "$(manifest_value "${run_dir}/review.tsv" gate_wrapper_path)" == '.agent-arena-gate' ]] || \
    fail 'review manifest did not record gate_wrapper_path=.agent-arena-gate'
# legacy-safety: a v0.2-era review.tsv carries no gate_adapter or
# gate_policy_path line; reading it must succeed and default them to the
# Cursor gate adapter and its .cursor/cli.json policy
legacy_review_backup="${tmp_root}/review.tsv.with-gate-adapter"
cp "${run_dir}/review.tsv" "$legacy_review_backup"
awk -F $'\t' '$1 != "gate_adapter" && $1 != "gate_policy_path" && $1 != "gate_wrapper_path"' \
    "${run_dir}/review.tsv" >"${run_dir}/review.tsv.legacy"
mv "${run_dir}/review.tsv.legacy" "${run_dir}/review.tsv"
[[ "$(manifest_value "${run_dir}/review.tsv" gate_adapter)" == '' ]] || \
    fail 'legacy fixture still carries a gate_adapter line'
[[ "$(manifest_value "${run_dir}/review.tsv" gate_policy_path)" == '' ]] || \
    fail 'legacy fixture still carries a gate_policy_path line'
[[ "$(manifest_value "${run_dir}/review.tsv" gate_wrapper_path)" == '' ]] || \
    fail 'legacy fixture still carries a gate_wrapper_path line'
run_arena status run-one >"${tmp_root}/legacy-review-status.out"
require_match 'Integrity: OK' "${tmp_root}/legacy-review-status.out"
legacy_review_fields="$(ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$ARENA_SOURCE_ROOT/lib/common.sh"
    arena_read_manifest "$1"
    arena_read_review_manifest "$1"
    printf "%s\n%s\n%s\n" "$ARENA_REVIEW_GATE_ADAPTER" "$ARENA_REVIEW_GATE_POLICY_PATH" \
        "$ARENA_REVIEW_GATE_WRAPPER_PATH"
' _ "$run_dir")"
legacy_gate_adapter="$(printf '%s\n' "$legacy_review_fields" | awk 'NR == 1')"
legacy_gate_policy_path="$(printf '%s\n' "$legacy_review_fields" | awk 'NR == 2')"
legacy_gate_wrapper_path="$(printf '%s\n' "$legacy_review_fields" | awk 'NR == 3')"
[[ "$legacy_gate_adapter" == cursor ]] || \
    fail 'legacy review.tsv without gate_adapter did not default to the cursor gate'
[[ "$legacy_gate_policy_path" == '.cursor/cli.json' ]] || \
    fail 'legacy review.tsv without gate_policy_path did not default to .cursor/cli.json'
[[ "$legacy_gate_wrapper_path" == '.agent-arena-gate' ]] || \
    fail 'legacy review.tsv without gate_wrapper_path did not default to .agent-arena-gate'
mv "$legacy_review_backup" "${run_dir}/review.tsv"
# the review gate must match the gate recorded in the run manifest
mismatch_backup="${tmp_root}/review.tsv.pre-mismatch"
cp "${run_dir}/review.tsv" "$mismatch_backup"
mismatch_review="$(mktemp "${run_dir}/.review-mismatch.XXXXXX")"
awk -F $'\t' 'BEGIN { OFS = FS } $1 == "gate_adapter" { $2 = "opencode" } { print }' \
    "${run_dir}/review.tsv" >"$mismatch_review"
mv "$mismatch_review" "${run_dir}/review.tsv"
expect_failure run_arena status run-one
mv "$mismatch_backup" "${run_dir}/review.tsv"
require_match '"permissions"' "${review_worktree}/.cursor/cli.json"
require_match '"allow"' "${review_worktree}/.cursor/cli.json"
require_match '"deny"' "${review_worktree}/.cursor/cli.json"
require_no_match 'approvalMode' "${review_worktree}/.cursor/cli.json"
require_no_match 'networkAccess' "${review_worktree}/.cursor/cli.json"
for deny_shell in 'Shell(echo *)' 'Shell(printf *)' 'Shell(tee *)' 'Shell(cp *)' \
    'Shell(mv *)' 'Shell(bash *)' 'Shell(sh *)' 'Shell(zsh *)' \
    'Shell(python3 *)' 'Shell(curl *)' 'Shell(wget *)'; do
    require_match "$deny_shell" "${review_worktree}/.cursor/cli.json"
done
require_match '"Write(**)"' "${review_worktree}/.cursor/cli.json"
require_match '"Delete(**)"' "${review_worktree}/.cursor/cli.json"
require_match '"Shell(git commit *)"' "${review_worktree}/.cursor/cli.json"
require_no_match 'Shell(sed' "${review_worktree}/.cursor/cli.json"
expect_failure "${review_worktree}/.agent-arena-gate" start run-one
shared_exclude="$(git -C "$review_worktree" rev-parse --git-path info/exclude)"
shared_exclude_before="$(<"$shared_exclude")"

printf '%s\n' '6. Cursor reviewer command contract'
PATH="${fake_bin}:${PATH}" \
    FAKE_AGENT_LOG="$fake_agent_log" \
    ARENA_CURSOR_BIN=agent \
    ARENA_GATE_WORKSPACE="$review_worktree" \
    ARENA_GATE_PHASE=review \
    ARENA_RUN_ID=run-one \
    ARENA_RUN_DIR="$run_dir" \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/gate-cursor.sh" launch
require_match "--sandbox enabled --workspace ${review_worktree}" "$fake_agent_log"
if grep -Fq -- '--mode plan' "$fake_agent_log"; then
    fail 'Cursor review phase unexpectedly uses read-only plan mode'
fi
if grep -Eq -- '--force|--yolo' "$fake_agent_log"; then
    fail 'Cursor review phase unexpectedly bypasses approval controls'
fi
PATH="${fake_bin}:${PATH}" \
    FAKE_AGENT_LOG="$fake_agent_log" \
    ARENA_CURSOR_BIN=agent \
    ARENA_GATE_WORKSPACE="$writer_worktree" \
    ARENA_GATE_PHASE=intake \
    ARENA_RUN_ID=run-one \
    ARENA_RUN_DIR="$run_dir" \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/gate-cursor.sh" launch
require_match "--workspace ${writer_worktree} --mode plan" "$fake_agent_log"
: >"$fake_agent_log"

printf '%s\n' '7. validation binding and dirty snapshot rejection'
run_arena validate run-one >"${tmp_root}/validation.out"
require_match 'RESULT: PASS' "${tmp_root}/validation.out"
printf '%s\n' dirty >"${review_worktree}/reviewer-edit.txt"
expect_failure run_arena validate run-one
rm -f "${review_worktree}/reviewer-edit.txt"
run_arena validate run-one >"${tmp_root}/validation-retry.out"
require_match 'RESULT: PASS' "${tmp_root}/validation-retry.out"
run_one_short="${writer_head:0:12}"
require_match 'RESULT: PASS' "${run_dir}/validation-${run_one_short}.r1.md"
run_arena validate run-one >"${tmp_root}/validation-extra.out"
require_match 'RESULT: PASS' "${run_dir}/validation-${run_one_short}.r2.md"

printf '%s\n' '8. decision gate and relay-failure persistence'
printf '%s\n' dirty >"${writer_worktree}/writer-uncommitted.txt"
expect_failure run_arena decision run-one --verdict APPROVE --summary 'fixture approved' --next 'handoff to human'
rm -f "${writer_worktree}/writer-uncommitted.txt"
run_arena decision run-one --verdict APPROVE --summary 'fixture approved' \
    --next 'handoff to human' --finding 'implementation.txt:1 — verified' >"${tmp_root}/decision.out"
require_match 'VERDICT: APPROVE' "${run_dir}/decision.md"
require_match 'decision persisted, but writer relay was unavailable' "${tmp_root}/decision.out"
expect_failure run_arena decision run-one --verdict APPROVE --summary again --next again --no-relay

printf '%s\n' '9. bidirectional literal relay and pane safety'
export FAKE_TMUX_MODE=relay
export FAKE_TMUX_PANES=normal
run_arena relay run-one --to reviewer --from writer --message '-writer status'
run_arena relay run-one --to writer --from reviewer --message 'review next step'
require_match '%13 -l -- [Pi] -writer status' "$fake_tmux_log"
require_match '%12 -l -- [Cursor] review next step' "$fake_tmux_log"
expect_failure run_arena relay run-one --to writer --message $'bad\nmessage'
long_message="$(LC_ALL=C head -c 1001 < /dev/zero | tr '\000' x)"
expect_failure run_arena relay run-one --to writer --message "$long_message"
for pane_mode in ambiguous dead input-off copy-mode synchronized; do
    export FAKE_TMUX_PANES="$pane_mode"
    expect_failure run_arena relay run-one --to writer --message 'unsafe pane must reject'
done
export FAKE_TMUX_PANES=normal

printf '%s\n' '10. generated Cursor policy tampering rejects revalidation and resubmission'
printf '%s\n' '{"tampered":true}' >"${review_worktree}/.cursor/cli.json"
expect_failure run_arena validate run-one
expect_failure run_arena submit run-one
session_name="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "${run_dir}/manifest.tsv")"
expect_failure env \
    PATH="${fake_bin}:${PATH}" \
    FAKE_AGENT_LOG="$fake_agent_log" \
    ARENA_REPOSITORY="$project" \
    ARENA_RUN_ID=run-one \
    ARENA_RUN_DIR="$run_dir" \
    ARENA_WRITER_WORKTREE="$writer_worktree" \
    ARENA_REVIEW_WORKTREE="$review_worktree" \
    ARENA_SESSION_NAME="$session_name" \
    ARENA_COMMAND="$arena" \
    ARENA_CURSOR_BIN=agent \
    "${source_root}/lib/pane.sh" reviewer
printf '%s\n' '#!/usr/bin/env bash' >"${review_worktree}/.agent-arena-gate"
chmod 700 "${review_worktree}/.agent-arena-gate"
expect_failure run_arena decision run-one --verdict CHANGES_REQUESTED --summary 'gate changed' \
    --next 'create a new checkpoint' --no-relay
[[ "$(<"$shared_exclude")" == "$shared_exclude_before" ]] || \
    fail 'review policy changed shared Git exclude state'

printf '%s\n' '11. tracked Cursor policy fails before snapshot creation'
export FAKE_TMUX_MODE=offline
run_arena start run-cursor-policy --repo "$project" --no-attach >/dev/null
policy_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-cursor-policy/manifest.tsv' -exec dirname {} \;)"
policy_writer="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${policy_run_dir}/manifest.tsv")"
mkdir -p "${policy_writer}/.cursor"
printf '%s\n' '{}' >"${policy_writer}/.cursor/cli.json"
git -C "$policy_writer" add .cursor/cli.json
git -C "$policy_writer" commit -m 'test: add project cursor policy' >/dev/null
expect_failure run_arena submit run-cursor-policy
[[ ! -f "${policy_run_dir}/review.tsv" ]] || fail 'tracked policy unexpectedly created a review manifest'
if find "$(dirname "$policy_writer")" -mindepth 1 -maxdepth 1 -name 'review-*' -print -quit | grep -q .; then
    fail 'tracked policy unexpectedly created a review worktree'
fi

printf '%s\n' '12. failed validation rejects approval'
export FAKE_TMUX_MODE=offline
run_arena start run-fail --repo "$project" --no-attach >/dev/null
fail_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-fail/manifest.tsv' -exec dirname {} \;)"
fail_writer="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${fail_run_dir}/manifest.tsv")"
cat >"${fail_writer}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'fixture validation failed' >&2
exit 1
EOF
chmod 755 "${fail_writer}/.agent-arena/validate.sh"
git -C "$fail_writer" add .agent-arena/validate.sh
git -C "$fail_writer" commit -m 'test: add failing validation' >/dev/null
run_arena submit run-fail >/dev/null
expect_failure run_arena validate run-fail
fail_short_sha="$(git -C "$fail_writer" rev-parse HEAD | cut -c1-12)"
require_match 'RESULT: FAIL' "${fail_run_dir}/validation-${fail_short_sha}.md"
expect_failure run_arena decision run-fail --verdict APPROVE --summary 'incorrect approval' --next 'none' --no-relay
run_arena decision run-fail --verdict CHANGES_REQUESTED --summary 'validation failed' \
    --next 'repair the project validation failure' --no-relay >/dev/null

printf '%s\n' '13. validation rejects a clean-but-different review HEAD'
run_arena start run-head-drift --repo "$project" --no-attach >/dev/null
drift_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-head-drift/manifest.tsv' -exec dirname {} \;)"
drift_writer="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${drift_run_dir}/manifest.tsv")"
cat >"${drift_writer}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git commit --allow-empty -m 'test: change review HEAD during validation' >/dev/null
EOF
chmod 755 "${drift_writer}/.agent-arena/validate.sh"
git -C "$drift_writer" add .agent-arena/validate.sh
git -C "$drift_writer" commit -m 'test: add drifting validation' >/dev/null
run_arena submit run-head-drift >/dev/null
expect_failure run_arena validate run-head-drift
drift_short_sha="$(git -C "$drift_writer" rev-parse HEAD | cut -c1-12)"
require_match 'RESULT: FAIL' "${drift_run_dir}/validation-${drift_short_sha}.diagnostic.md"
[[ ! -e "${drift_run_dir}/validation-${drift_short_sha}.md" ]] || \
    fail 'integrity failure wrote a canonical validation report'
require_match $'phase\tsubmitted' <(cat "${drift_run_dir}/run-state.tsv")
expect_failure run_arena decision run-head-drift --verdict CHANGES_REQUESTED \
    --summary 'snapshot moved' --next 'create a new checkpoint' --no-relay

printf '%s\n' '14. identical run IDs remain isolated by repository'
project_two="${tmp_root}/project-two"
mkdir -p "$project_two"
git -C "$project_two" init --initial-branch=main >/dev/null
git -C "$project_two" config user.name 'Agent Arena Test'
git -C "$project_two" config user.email 'agent-arena@example.test'
printf '%s\n' fixture >"${project_two}/README.md"
git -C "$project_two" add README.md
git -C "$project_two" commit -m 'test: create second fixture' >/dev/null
run_arena init --repo "$project_two" >/dev/null
cat >"${project_two}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod 755 "${project_two}/.agent-arena/validate.sh"
git -C "$project_two" add .agent-arena
git -C "$project_two" commit -m 'test: add second adapter' >/dev/null
run_arena start run-one --repo "$project_two" --no-attach >/dev/null
second_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-one/manifest.tsv' ! -path "${run_dir}/manifest.tsv" -exec dirname {} \;)"
second_session="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "${second_run_dir}/manifest.tsv")"
first_session="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "${run_dir}/manifest.tsv")"
[[ "$first_session" != "$second_session" ]] || fail 'same run id crossed project tmux sessions'
expect_failure run_arena status run-one
if ARENA_RUN_DIR="$run_dir" run_arena status run-one >"${tmp_root}/inherited-status.out" 2>&1; then
    fail 'status accepted the tampered run-one review snapshot'
fi
require_match "Run: run-one" "${tmp_root}/inherited-status.out"
require_match 'Integrity: FAILED' "${tmp_root}/inherited-status.out"

printf '%s\n' '15. project-owned ignore rules do not break generated gate integrity'
project_ignored="${tmp_root}/project-ignored"
mkdir -p "$project_ignored"
git -C "$project_ignored" init --initial-branch=main >/dev/null
git -C "$project_ignored" config user.name 'Agent Arena Test'
git -C "$project_ignored" config user.email 'agent-arena@example.test'
printf '%s\n' fixture >"${project_ignored}/README.md"
printf '%s\n' '.cursor/' '.agent-arena-gate' >"${project_ignored}/.gitignore"
git -C "$project_ignored" add README.md .gitignore
git -C "$project_ignored" commit -m 'test: create ignored policy fixture' >/dev/null
run_arena init --repo "$project_ignored" >/dev/null
cat >"${project_ignored}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod 755 "${project_ignored}/.agent-arena/validate.sh"
git -C "$project_ignored" add .agent-arena
git -C "$project_ignored" commit -m 'test: add ignored policy adapter' >/dev/null
run_arena start run-ignored --repo "$project_ignored" --no-attach >/dev/null
ignored_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-ignored/manifest.tsv' -exec dirname {} \;)"
ignored_writer="$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${ignored_run_dir}/manifest.tsv")"
printf '%s\n' implementation >"${ignored_writer}/implementation.txt"
git -C "$ignored_writer" add implementation.txt
git -C "$ignored_writer" commit -m 'feat: add ignored policy fixture' >/dev/null
run_arena submit run-ignored >/dev/null
run_arena validate run-ignored >"${tmp_root}/ignored-validation.out"
require_match 'RESULT: PASS' "${tmp_root}/ignored-validation.out"

printf '%s\n' '16. selected writer profile preflight fails closed'
export FAKE_TMUX_MODE=offline
tmuxp_log_before="$(wc -l <"$fake_tmuxp_log")"
unknown_profile_run='profile-unknown'
expect_failure run_arena start "$unknown_profile_run" --repo "$project" \
    --profile 'not-a-profile' --no-attach
assert_no_run_manifest "$unknown_profile_run"

profile_injection_target="${tmp_root}/profile-injection-target"
malicious_profile_run='profile-malicious'
expect_failure run_arena start "$malicious_profile_run" --repo "$project" \
    --profile "codex-cursor; touch ${profile_injection_target}" --no-attach
assert_no_run_manifest "$malicious_profile_run"
[[ ! -e "$profile_injection_target" ]] || fail 'malicious profile text reached a shell'

start_with_missing_writer() {
    local profile_name="$1"
    local binary_variable="$2"
    local run_id="$3"

    (
        export "${binary_variable}=agent-arena-test-missing-${run_id}"
        run_arena start "$run_id" --repo "$project" --profile "$profile_name" --no-attach
    )
}

missing_profiles=(pi-cursor codex-cursor opencode-cursor agy-cursor)
missing_variables=(ARENA_PI_BIN ARENA_CODEX_BIN ARENA_OPENCODE_BIN ARENA_AGY_BIN)
missing_run_ids=(profile-missing-pi profile-missing-codex profile-missing-opencode profile-missing-agy)
for profile_index in "${!missing_profiles[@]}"; do
    expect_failure start_with_missing_writer "${missing_profiles[$profile_index]}" \
        "${missing_variables[$profile_index]}" "${missing_run_ids[$profile_index]}"
    assert_no_run_manifest "${missing_run_ids[$profile_index]}"
done
[[ "$(wc -l <"$fake_tmuxp_log")" == "$tmuxp_log_before" ]] || \
    fail 'invalid or missing selected writer started tmuxp'

printf '%s\n' '17. profile manifest selection, branch, and closed mapping'
profile_names=(codex-cursor opencode-cursor agy-cursor)
profile_adapters=(codex opencode agy)
profile_labels=(Codex OpenCode Agy)
profile_run_ids=(profile-codex profile-opencode profile-agy)
for profile_index in "${!profile_names[@]}"; do
    profile_name="${profile_names[$profile_index]}"
    writer_adapter="${profile_adapters[$profile_index]}"
    writer_label="${profile_labels[$profile_index]}"
    profile_run_id="${profile_run_ids[$profile_index]}"
    run_arena start "$profile_run_id" --repo "$project" --profile "$profile_name" --no-attach >/dev/null
    profile_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
        -name manifest.tsv -path "*/${profile_run_id}/manifest.tsv" -exec dirname {} \;)"
    [[ -n "$profile_run_dir" ]] || fail "missing ${profile_name} run manifest"
    profile_run_dir="$(CDPATH='' cd -- "$profile_run_dir" && pwd -P)"
    profile_manifest="${profile_run_dir}/manifest.tsv"
    [[ "$(manifest_value "$profile_manifest" profile)" == "$profile_name" ]] || \
        fail "manifest did not preserve ${profile_name}"
    [[ "$(manifest_value "$profile_manifest" writer_adapter)" == "$writer_adapter" ]] || \
        fail "manifest did not select ${writer_adapter}"
    [[ "$(manifest_value "$profile_manifest" writer_label)" == "$writer_label" ]] || \
        fail "manifest did not preserve ${writer_label} label"
    profile_writer="$(manifest_value "$profile_manifest" writer_worktree)"
    profile_session_dir="$(manifest_value "$profile_manifest" writer_session_dir)"
    [[ -d "$profile_session_dir" && "$profile_session_dir" == "${profile_run_dir}/"* ]] || \
        fail "${profile_name} session directory is not private run state"
    [[ "$(git -C "$profile_writer" branch --show-current)" == \
        "agent-arena/${writer_adapter}/${profile_run_id}" ]] || \
        fail "${profile_name} writer branch is incorrect"
    case "$writer_adapter" in
        codex)
            codex_run_dir="$profile_run_dir"
            codex_manifest="$profile_manifest"
            codex_writer="$profile_writer"
            codex_session_dir="$profile_session_dir"
            ;;
        opencode)
            opencode_run_dir="$profile_run_dir"
            opencode_manifest="$profile_manifest"
            opencode_writer="$profile_writer"
            opencode_session_dir="$profile_session_dir"
            ;;
        agy)
            agy_run_dir="$profile_run_dir"
            agy_manifest="$profile_manifest"
            agy_writer="$profile_writer"
            agy_session_dir="$profile_session_dir"
            ;;
    esac
done

expect_failure run_arena start profile-codex --repo "$project" --profile agy-cursor --no-attach
manifest_backup="${tmp_root}/profile-codex.manifest.tsv"
cp "$codex_manifest" "$manifest_backup"
manifest_replacement="$(mktemp "${codex_run_dir}/.manifest-test.XXXXXX")"
awk -F $'\t' 'BEGIN { OFS = FS } $1 == "writer_adapter" { $2 = "pi" } { print }' \
    "$codex_manifest" >"$manifest_replacement"
mv "$manifest_replacement" "$codex_manifest"
expect_failure run_arena start profile-codex --repo "$project" --no-attach
mv "$manifest_backup" "$codex_manifest"
chmod 600 "$codex_manifest"

printf '%s\n' '18. legacy Pi direct submit refreshes a live session for v0.2 panes'
legacy_manifest_backup="${tmp_root}/run-one-v0.2.manifest.tsv"
cp "${run_dir}/manifest.tsv" "$legacy_manifest_backup"
legacy_manifest_tmp="$(mktemp "${run_dir}/.legacy-manifest.XXXXXX")"
awk -F $'\t' '$1 != "profile" && $1 != "writer_adapter" && $1 != "writer_label" && \
    $1 != "writer_session_dir" { print }' "${run_dir}/manifest.tsv" >"$legacy_manifest_tmp"
mv "$legacy_manifest_tmp" "${run_dir}/manifest.tsv"
chmod 600 "${run_dir}/manifest.tsv"
printf '%s\n' 'legacy direct submit checkpoint' >"${writer_worktree}/legacy-submit.txt"
git -C "$writer_worktree" add legacy-submit.txt
git -C "$writer_worktree" commit -m 'feat: add legacy direct submit fixture' >/dev/null
# validate/decision state commits land in later tasks; fabricate the
# decided/writer/changes_requested tuple a CHANGES_REQUESTED re-review would
# produce so the new-SHA submit below is a legal T2 (the submit's evidence
# phase invalidates the stale APPROVE pointers it replaces).
run_one_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${run_dir}/run-state.tsv")"
run_one_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${run_dir}/run-state.tsv")"
run_one_transition_at="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${run_dir}/run-state.tsv")"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tPASS\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\treviewer\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$run_one_revision" "$writer_head" "$run_one_waiting" "$run_one_transition_at" \
    "$(shasum -a 256 "${run_dir}/validation-${run_one_short}.md" | awk '{print $1}')" \
    >"${run_dir}/.run-state-fabricated"
mv "${run_dir}/.run-state-fabricated" "${run_dir}/run-state.tsv"
: >"$fake_tmux_log"
export FAKE_TMUX_MODE=live
ARENA_RUN_DIR="$run_dir" run_arena submit run-one >"${tmp_root}/legacy-live-submit.out"
require_match 'set-environment -t =agent-arena-' "$fake_tmux_log"
require_match 'ARENA_WRITER_SESSION_DIR' "$fake_tmux_log"
require_match 'ARENA_WRITER_ADAPTER pi' "$fake_tmux_log"
require_match 'ARENA_WRITER_LABEL Pi' "$fake_tmux_log"
require_match 'ARENA_SOURCE_ROOT ' "$fake_tmux_log"
require_match 'ARENA_COMMAND ' "$fake_tmux_log"
require_match 'respawn-pane -k -t %13' "$fake_tmux_log"
[[ -d "${run_dir}/pi-session" ]] || fail 'legacy Pi session directory was not restored privately'
[[ "$(manifest_value "${run_dir}/manifest.tsv" gate_adapter)" == 'cursor' ]] || \
    fail 'legacy manifest did not default gate_adapter to cursor'
export FAKE_TMUX_MODE=offline
mv "$legacy_manifest_backup" "${run_dir}/manifest.tsv"
chmod 600 "${run_dir}/manifest.tsv"

printf '%s\n' '19. non-Pi writer stays bound to the Cursor gate'
printf '%s\n' 'codex checkpoint' >"${codex_writer}/codex-checkpoint.txt"
git -C "$codex_writer" add codex-checkpoint.txt
git -C "$codex_writer" commit -m 'feat: add Codex checkpoint fixture' >/dev/null
run_arena submit profile-codex >"${tmp_root}/codex-submit.out"
codex_review_worktree="$(manifest_value "${codex_run_dir}/review.tsv" review_worktree)"
codex_writer_head="$(git -C "$codex_writer" rev-parse HEAD)"
[[ "$(git -C "$codex_review_worktree" rev-parse HEAD)" == "$codex_writer_head" ]] || \
    fail 'Codex checkpoint review snapshot is not bound to its writer HEAD'
: >"$fake_agent_log"
PATH="${fake_bin}:${PATH}" \
    FAKE_AGENT_LOG="$fake_agent_log" \
    ARENA_CURSOR_BIN=agent \
    ARENA_GATE_WORKSPACE="$codex_review_worktree" \
    ARENA_GATE_PHASE=review \
    ARENA_RUN_ID=profile-codex \
    ARENA_RUN_DIR="$codex_run_dir" \
    ARENA_WRITER_LABEL=Codex \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/gate-cursor.sh" launch
require_match "--sandbox enabled --workspace ${codex_review_worktree}" "$fake_agent_log"
require_match 'Codex' "$fake_agent_log"
require_no_match '--mode plan' "$fake_agent_log"
run_arena validate profile-codex >"${tmp_root}/codex-validation.out"
require_match 'RESULT: PASS' "${tmp_root}/codex-validation.out"
run_arena decision profile-codex --verdict APPROVE --summary 'Codex fixture approved' \
    --next 'handoff to human' --no-relay >"${tmp_root}/codex-decision.out"
require_match 'VERDICT: APPROVE' "${codex_run_dir}/decision.md"

printf '%s\n' '20. selected writer relay label'
export FAKE_TMUX_MODE=relay
export FAKE_TMUX_PANES=normal
run_arena relay profile-codex --to reviewer --from writer --message 'codex profile checkpoint ready'
require_match '%13 -l -- [Codex] codex profile checkpoint ready' "$fake_tmux_log"
export FAKE_TMUX_MODE=offline

run_writer_adapter() {
    local adapter="$1"
    local profile_name="$2"
    local writer_label="$3"
    local writer_worktree="$4"
    local writer_session_dir="$5"
    local run_dir="$6"
    local run_id="$7"

    PATH="${fake_bin}:${PATH}" \
        FAKE_PI_LOG="$fake_pi_log" \
        FAKE_CODEX_LOG="$fake_codex_log" \
        FAKE_OPENCODE_LOG="$fake_opencode_log" \
        FAKE_AGY_LOG="$fake_agy_log" \
        ARENA_PI_BIN=pi \
        ARENA_CODEX_BIN=codex \
        ARENA_OPENCODE_BIN=opencode \
        ARENA_AGY_BIN=agy \
        ARENA_REPOSITORY="$project" \
        ARENA_RUN_ID="$run_id" \
        ARENA_RUN_DIR="$run_dir" \
        ARENA_WRITER_WORKTREE="$writer_worktree" \
        ARENA_WRITER_SESSION_DIR="$writer_session_dir" \
        ARENA_PROFILE="$profile_name" \
        ARENA_WRITER_ADAPTER="$adapter" \
        ARENA_WRITER_LABEL="$writer_label" \
        ARENA_COMMAND="$arena" \
        "${source_root}/adapters/${adapter}.sh" launch
}

printf '%s\n' '21. writer adapters stay in the isolated worktree and reject bypass flags'
: >"$fake_pi_log"
run_writer_adapter pi pi-cursor Pi "$writer_worktree" "$writer_session_dir" "$run_dir" run-one
require_match "cwd=${writer_worktree}" "$fake_pi_log"
require_match 'profile=pi-cursor' "$fake_pi_log"
require_match 'writer_adapter=pi' "$fake_pi_log"
require_match "writer_session_dir=${writer_session_dir}" "$fake_pi_log"
require_match 'arg=--session-dir' "$fake_pi_log"
require_match "arg=${writer_session_dir}" "$fake_pi_log"
require_match 'arg=--session-id' "$fake_pi_log"
require_match 'arg=agent-arena-run-one' "$fake_pi_log"
require_match 'arg=--name' "$fake_pi_log"
require_match 'arg=Agent\ Arena\ Pi\ run-one' "$fake_pi_log"
require_match 'arg=--append-system-prompt' "$fake_pi_log"
require_match 'submit' "$fake_pi_log"
require_match 'relay' "$fake_pi_log"
assert_no_dangerous_writer_flags "$fake_pi_log"
"${source_root}/adapters/pi.sh" capabilities >"${tmp_root}/pi.capabilities"
require_match 'automatic_resume=true' "${tmp_root}/pi.capabilities"
: >"$fake_pi_log"
run_writer_adapter pi pi-cursor Pi "$writer_worktree" "$writer_session_dir" "$run_dir" run-one
require_match 'arg=--session-id' "$fake_pi_log"
require_match 'arg=agent-arena-run-one' "$fake_pi_log"
require_match 'arg=--session-dir' "$fake_pi_log"
require_match "arg=${writer_session_dir}" "$fake_pi_log"

: >"$fake_codex_log"
run_writer_adapter codex codex-cursor Codex "$codex_writer" "$codex_session_dir" \
    "$codex_run_dir" profile-codex
require_match 'profile=codex-cursor' "$fake_codex_log"
require_match 'writer_adapter=codex' "$fake_codex_log"
require_match "writer_session_dir=${codex_session_dir}" "$fake_codex_log"
require_match 'arg=-C' "$fake_codex_log"
require_match "arg=${codex_writer}" "$fake_codex_log"
require_match 'arg=--sandbox' "$fake_codex_log"
require_match 'arg=workspace-write' "$fake_codex_log"
require_match 'arg=--ask-for-approval' "$fake_codex_log"
require_match 'arg=on-request' "$fake_codex_log"
require_match 'arg=--no-alt-screen' "$fake_codex_log"
require_match 'submit' "$fake_codex_log"
require_match 'relay' "$fake_codex_log"
assert_no_dangerous_writer_flags "$fake_codex_log"
"${source_root}/adapters/codex.sh" capabilities >"${tmp_root}/codex.capabilities"
require_match 'automatic_resume=false' "${tmp_root}/codex.capabilities"

: >"$fake_opencode_log"
run_writer_adapter opencode opencode-cursor OpenCode "$opencode_writer" \
    "$opencode_session_dir" "$opencode_run_dir" profile-opencode
require_match "cwd=${opencode_writer}" "$fake_opencode_log"
require_match 'profile=opencode-cursor' "$fake_opencode_log"
require_match 'writer_adapter=opencode' "$fake_opencode_log"
require_match "writer_session_dir=${opencode_session_dir}" "$fake_opencode_log"
require_match "arg=${opencode_writer}" "$fake_opencode_log"
require_match 'arg=--pure' "$fake_opencode_log"
require_match 'arg=--agent' "$fake_opencode_log"
require_match 'arg=arena_writer' "$fake_opencode_log"
require_match 'arg=--prompt' "$fake_opencode_log"
require_match 'disable_project_config=1' "$fake_opencode_log"
require_match 'disable_external_skills=1' "$fake_opencode_log"
require_match 'arena_writer' "$fake_opencode_log"
require_match 'submit' "$fake_opencode_log"
require_match 'relay' "$fake_opencode_log"
assert_no_dangerous_writer_flags "$fake_opencode_log"
"${source_root}/adapters/opencode.sh" capabilities >"${tmp_root}/opencode.capabilities"
require_match 'automatic_resume=false' "${tmp_root}/opencode.capabilities"

: >"$fake_agy_log"
run_writer_adapter agy agy-cursor Agy "$agy_writer" "$agy_session_dir" \
    "$agy_run_dir" profile-agy
agy_initial_log="${tmp_root}/agy-initial.log"
cp "$fake_agy_log" "$agy_initial_log"
require_match "cwd=${agy_writer}" "$agy_initial_log"
require_match 'profile=agy-cursor' "$agy_initial_log"
require_match 'writer_adapter=agy' "$agy_initial_log"
require_match "writer_session_dir=${agy_session_dir}" "$agy_initial_log"
require_match 'arg=--prompt-interactive' "$agy_initial_log"
require_match 'arg=--new-project' "$agy_initial_log"
require_match 'arg=--sandbox' "$agy_initial_log"
require_match 'arg=--mode' "$agy_initial_log"
require_match 'arg=accept-edits' "$agy_initial_log"
require_match 'submit' "$agy_initial_log"
require_match 'relay' "$agy_initial_log"
require_no_match 'arg=--continue' "$agy_initial_log"
require_no_match 'arg=--conversation' "$agy_initial_log"
require_no_match 'arg=--dangerously-skip-permissions' "$agy_initial_log"
assert_no_dangerous_writer_flags "$agy_initial_log"
"${source_root}/adapters/agy.sh" capabilities >"${tmp_root}/agy.capabilities"
require_match 'explicit_session_id=false' "${tmp_root}/agy.capabilities"
require_match 'session_dir=false' "${tmp_root}/agy.capabilities"
require_match 'automatic_resume=false' "${tmp_root}/agy.capabilities"

printf '%s\n' '22. writer pane dispatches the manifest-selected adapter'
: >"$fake_codex_log"
PATH="${fake_bin}:${PATH}" \
    FAKE_CODEX_LOG="$fake_codex_log" \
    ARENA_REPOSITORY="$project" \
    ARENA_RUN_ID=profile-codex \
    ARENA_RUN_DIR="$codex_run_dir" \
    ARENA_WRITER_WORKTREE="$codex_writer" \
    ARENA_WRITER_SESSION_DIR="$codex_session_dir" \
    ARENA_SESSION_NAME="$(manifest_value "$codex_manifest" session_name)" \
    ARENA_PROFILE=codex-cursor \
    ARENA_WRITER_ADAPTER=codex \
    ARENA_WRITER_LABEL=Codex \
    ARENA_COMMAND="$arena" \
    ARENA_CODEX_BIN=codex \
    ARENA_LOG_PANES=0 \
    TMUX_PANE='' \
    "${source_root}/lib/pane.sh" writer
require_match 'writer_adapter=codex' "$fake_codex_log"
require_match 'arg=--sandbox' "$fake_codex_log"

printf '%s\n' '23. local package and protected install'
bash "${source_root}/packaging/test.sh" >"${tmp_root}/package.out"
require_match 'package test: ok' "${tmp_root}/package.out"

printf '%s\n' '24. submit records a checkpoint when the reviewer pane is unavailable'
run_arena start run-pane-dead --repo "$project" --no-attach >/dev/null
pane_dead_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path '*/run-pane-dead/manifest.tsv' -exec dirname {} \;)"
pane_dead_writer="$(manifest_value "${pane_dead_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' 'pane-dead checkpoint' >"${pane_dead_writer}/pane-dead.txt"
git -C "$pane_dead_writer" add pane-dead.txt
git -C "$pane_dead_writer" commit -m 'feat: add pane-dead checkpoint fixture' >/dev/null
: >"$fake_tmux_log"
export FAKE_TMUX_MODE=live
export FAKE_TMUX_PANES=dead
if ! run_arena submit run-pane-dead >"${tmp_root}/pane-dead-submit.out"; then
    fail 'submit failed after state commit when the reviewer pane was unavailable'
fi
require_match 'submitted' "${tmp_root}/pane-dead-submit.out"
require_match 'checkpoint recorded without' "${tmp_root}/pane-dead-submit.out"
require_no_match 'respawn-pane' "$fake_tmux_log"
[[ -f "${pane_dead_run_dir}/review.tsv" ]] || \
    fail 'submit did not record the checkpoint when the reviewer pane was unavailable'
export FAKE_TMUX_PANES=normal
export FAKE_TMUX_MODE=offline

printf '%s\n' '25. submit recreates a lost review snapshot'
pane_dead_review="$(manifest_value "${pane_dead_run_dir}/review.tsv" review_worktree)"
rm -rf "$pane_dead_review"
if ! run_arena submit run-pane-dead >"${tmp_root}/pane-dead-resubmit.out"; then
    fail 'submit could not recreate a lost review snapshot'
fi
[[ -d "$pane_dead_review" ]] || fail 'submit did not recreate the lost review snapshot'
[[ "$(git -C "$pane_dead_review" rev-parse HEAD)" == \
    "$(manifest_value "${pane_dead_run_dir}/review.tsv" review_head)" ]] || \
    fail 'recreated review snapshot is not bound to the submitted checkpoint'
[[ "$(manifest_value "${pane_dead_run_dir}/review.tsv" cursor_policy_hash)" =~ ^[0-9a-f]{64}$ ]] || \
    fail 'recreated review manifest lacks fresh policy hashes'

printf '%s\n' '26. submitting a new checkpoint invalidates stale validation and decision pointers'
run_arena validate run-pane-dead >"${tmp_root}/pane-dead-validate.out" 2>/dev/null
run_arena decision run-pane-dead --verdict CHANGES_REQUESTED --summary 'requested changes' \
    --next 'create a new checkpoint' --no-relay >/dev/null
[[ -f "${pane_dead_run_dir}/validation.md" ]] || fail 'validation pointer missing before resubmit'
[[ -f "${pane_dead_run_dir}/decision.md" ]] || fail 'decision pointer missing before resubmit'
pane_dead_head="$(manifest_value "${pane_dead_run_dir}/review.tsv" review_head)"
pane_dead_short="${pane_dead_head:0:12}"
# validate/decision state commits land in later tasks; fabricate the
# decided/writer/changes_requested tuple the decision above would produce so
# the new-SHA submit below is a legal T2.
pane_dead_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${pane_dead_run_dir}/run-state.tsv")"
pane_dead_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${pane_dead_run_dir}/run-state.tsv")"
pane_dead_transition_at="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${pane_dead_run_dir}/run-state.tsv")"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tPASS\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\treviewer\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$pane_dead_revision" "$pane_dead_head" "$pane_dead_waiting" "$pane_dead_transition_at" \
    "$(shasum -a 256 "${pane_dead_run_dir}/validation-${pane_dead_short}.md" | awk '{print $1}')" \
    >"${pane_dead_run_dir}/.run-state-fabricated"
mv "${pane_dead_run_dir}/.run-state-fabricated" "${pane_dead_run_dir}/run-state.tsv"
printf '%s\n' 'second checkpoint' >"${pane_dead_writer}/second.txt"
git -C "$pane_dead_writer" add second.txt
git -C "$pane_dead_writer" commit -m 'feat: add second checkpoint fixture' >/dev/null
run_arena submit run-pane-dead >/dev/null
[[ ! -e "${pane_dead_run_dir}/validation.md" ]] || \
    fail 'submit did not invalidate the stale validation pointer'
[[ ! -e "${pane_dead_run_dir}/decision.md" ]] || \
    fail 'submit did not invalidate the stale decision pointer'
[[ -f "${pane_dead_run_dir}/validation-${pane_dead_short}.md" ]] || \
    fail 'submit removed the previous validation archive'
[[ -f "${pane_dead_run_dir}/decision-${pane_dead_short}.md" ]] || \
    fail 'submit removed the previous decision archive'

printf '%s\n' '27. status verifies snapshot integrity and binds reports to the current checkpoint'
run_arena status run-pane-dead >"${tmp_root}/pane-dead-status.out"
require_match 'Integrity: OK' "${tmp_root}/pane-dead-status.out"
require_match 'Gate: cursor' "${tmp_root}/pane-dead-status.out"
require_match 'Validation: not run' "${tmp_root}/pane-dead-status.out"
require_match 'Decision: not recorded' "${tmp_root}/pane-dead-status.out"
pane_dead_review2="$(manifest_value "${pane_dead_run_dir}/review.tsv" review_worktree)"
printf '%s\n' tampered >>"${pane_dead_review2}/README.md"
if run_arena status run-pane-dead >"${tmp_root}/pane-dead-tampered-status.out" 2>&1; then
    fail 'status accepted a tampered review snapshot'
fi
require_match 'Integrity: FAILED' "${tmp_root}/pane-dead-tampered-status.out"
git -C "$pane_dead_review2" checkout -- README.md
printf '%s\n' 'Latest validation report: validation-000000000000.md' >"${pane_dead_run_dir}/validation.md"
chmod 600 "${pane_dead_run_dir}/validation.md"
run_arena status run-pane-dead >"${tmp_root}/pane-dead-bound-status.out"
require_match 'Validation: not run for current checkpoint' "${tmp_root}/pane-dead-bound-status.out"

printf '%s\n' '28. start surfaces preflight errors instead of a tmuxp traceback'
export FAKE_TMUXP_EXIT=1
export FAKE_TMUXP_OUTPUT=$'Traceback (most recent call last):\nError output:\nagent-arena: preflight boom'
if run_arena start run-tmuxp-fail --repo "$project" --no-attach >"${tmp_root}/tmuxp-fail.out" 2>&1; then
    fail 'start unexpectedly succeeded with a failing tmuxp'
fi
require_match 'agent-arena: preflight boom' "${tmp_root}/tmuxp-fail.out"
require_no_match 'Traceback' "${tmp_root}/tmuxp-fail.out"
unset FAKE_TMUXP_EXIT FAKE_TMUXP_OUTPUT

printf '%s\n' '29. list reports runs with the fixed oracle columns'
run_arena list >"${tmp_root}/list.out"
require_match 'REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY' "${tmp_root}/list.out"
require_match 'run-one' "${tmp_root}/list.out"
require_match 'run-pane-dead' "${tmp_root}/list.out"
require_match 'pi-cursor' "${tmp_root}/list.out"
# run-one was approved at the decision gate (section 8) and resubmitted
# (section 18): its authoritative v1 row carries the submitted projection
list_row_one="$(awk '$2 == "run-one" { print; exit }' "${tmp_root}/list.out")"
[[ -n "$list_row_one" ]] || fail 'list has no run-one row'
[[ "$(list_column "$list_row_one" 5)" == active ]] || \
    fail 'list run-one row does not report run_status active'
[[ "$(list_column "$list_row_one" 6)" == submitted ]] || \
    fail 'list run-one row does not report phase submitted'
[[ "$(list_column "$list_row_one" 7)" == reviewer ]] || \
    fail 'list run-one row does not report party reviewer'
[[ "$(list_column "$list_row_one" 8)" == review_pending ]] || \
    fail 'list run-one row does not report reason_code review_pending'
[[ "$(list_column "$list_row_one" 10)" == state ]] || \
    fail 'list run-one row is not authoritative state'
[[ "$(list_column "$list_row_one" 11)" == '' ]] || \
    fail 'list run-one row carries an anomaly'
PATH="${fake_bin}:${PATH}" ARENA_STATE_ROOT="${tmp_root}/empty-state" \
    "$arena" list >"${tmp_root}/list-empty.out"
require_match 'no runs recorded' "${tmp_root}/list-empty.out"

printf '%s\n' '30. gate selection and writer-gate combination'
if run_arena start run-bad-gate --repo "$project" --writer pi --gate nosuch --no-attach >/dev/null 2>&1; then
    fail 'unknown gate unexpectedly succeeded'
fi
assert_no_run_manifest run-bad-gate
if run_arena start run-bad-combo --repo "$project" --writer pi --no-attach >/dev/null 2>&1; then
    fail '--writer without --gate unexpectedly succeeded'
fi
assert_no_run_manifest run-bad-combo
# AC2: a selected gate whose adapter file is missing must fail before any
# state or worktree is created (the run-opencode-gate run already exists, so
# use a fresh run id)
mv "${source_root}/adapters/gate-opencode.sh" \
    "${source_root}/adapters/gate-opencode.sh.missing"
if run_arena start run-gate-missing --repo "$project" --writer pi --gate opencode --no-attach \
    >"${tmp_root}/gate-missing.out" 2>&1; then
    gate_missing_status=0
else
    gate_missing_status=$?
fi
mv "${source_root}/adapters/gate-opencode.sh.missing" \
    "${source_root}/adapters/gate-opencode.sh"
[[ "$gate_missing_status" -ne 0 ]] || \
    fail 'start unexpectedly succeeded with the gate adapter file missing'
require_match 'gate adapter is not available' "${tmp_root}/gate-missing.out"
assert_no_run_manifest run-gate-missing
run_arena start run-opencode-gate --repo "$project" --profile pi-opencode --no-attach >/dev/null
ocg_manifest="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-opencode-gate/manifest.tsv' -exec dirname {} \;)/manifest.tsv"
[[ "$(manifest_value "$ocg_manifest" gate_adapter)" == 'opencode' ]] || \
    fail 'pi-opencode did not record gate_adapter=opencode'
[[ "$(manifest_value "$ocg_manifest" profile)" == 'pi-opencode' ]] || \
    fail 'pi-opencode did not record the combined profile'
expect_failure run_arena start run-opencode-gate --repo "$project" --profile pi-opencode --gate cursor --no-attach
# resume must not silently ignore explicit --writer/--gate selections
if run_arena start run-opencode-gate --repo "$project" --gate cursor --no-attach \
    >"${tmp_root}/resume-gate-mismatch.out" 2>&1; then
    fail 'resume silently accepted a gate differing from the recorded run'
fi
require_match 'existing run uses writer' "${tmp_root}/resume-gate-mismatch.out"
expect_failure run_arena start run-opencode-gate --repo "$project" --writer codex --gate opencode --no-attach
run_arena start run-opencode-gate --repo "$project" --gate opencode --no-attach >/dev/null
run_arena start --help >"${tmp_root}/start-help.out"
require_match 'isolated writer + gate run' "${tmp_root}/start-help.out"
require_match 'WRITER-GATE combination' "${tmp_root}/start-help.out"
require_match '--writer NAME' "${tmp_root}/start-help.out"
require_match '--gate NAME' "${tmp_root}/start-help.out"

printf '%s\n' '31. reviewer pane dispatches the manifest gate adapter'
: >"$fake_opencode_log"
PATH="${fake_bin}:${PATH}" \
    FAKE_OPENCODE_LOG="$fake_opencode_log" \
    ARENA_REPOSITORY="$project" \
    ARENA_RUN_ID=run-opencode-gate \
    ARENA_RUN_DIR="$(dirname "$ocg_manifest")" \
    ARENA_WRITER_WORKTREE="$(manifest_value "$ocg_manifest" writer_worktree)" \
    ARENA_WRITER_SESSION_DIR="$(manifest_value "$ocg_manifest" writer_session_dir)" \
    ARENA_SESSION_NAME="$(manifest_value "$ocg_manifest" session_name)" \
    ARENA_PROFILE=pi-opencode \
    ARENA_WRITER_ADAPTER=pi \
    ARENA_WRITER_LABEL=Pi \
    ARENA_GATE_ADAPTER=opencode \
    ARENA_REVIEW_WORKTREE='' \
    ARENA_COMMAND="$arena" \
    TMUX_PANE='' \
    "${source_root}/lib/pane.sh" reviewer
require_match "cwd=$(manifest_value "$ocg_manifest" writer_worktree)" "$fake_opencode_log"
require_match 'arg=--pure' "$fake_opencode_log"
require_match 'arg=--agent' "$fake_opencode_log"
require_match 'arg=arena_gate' "$fake_opencode_log"
require_match 'arg=--prompt' "$fake_opencode_log"
require_match 'advisory reviewer' "$fake_opencode_log"
require_match 'config_content=' "$fake_opencode_log"
require_match 'external_directory' "$fake_opencode_log"
require_match 'disable_project_config=1' "$fake_opencode_log"
require_match 'disable_external_skills=1' "$fake_opencode_log"

printf '%s\n' '32. submit fails before snapshot creation when the gate adapter file vanished'
ocg_writer="$(manifest_value "$ocg_manifest" writer_worktree)"
printf '%s\n' 'vanished gate adapter checkpoint' >"${ocg_writer}/vanished.txt"
git -C "$ocg_writer" add vanished.txt
git -C "$ocg_writer" commit -m 'test: checkpoint with a missing gate adapter file' >/dev/null
mv "${source_root}/adapters/gate-opencode.sh" \
    "${source_root}/adapters/gate-opencode.sh.missing"
if run_arena submit run-opencode-gate >"${tmp_root}/vanished-gate.out" 2>&1; then
    vanished_gate_status=0
else
    vanished_gate_status=$?
fi
mv "${source_root}/adapters/gate-opencode.sh.missing" \
    "${source_root}/adapters/gate-opencode.sh"
[[ "$vanished_gate_status" -ne 0 ]] || \
    fail 'submit unexpectedly succeeded with the gate adapter file missing'
require_match 'gate adapter is missing' "${tmp_root}/vanished-gate.out"
if find "$(dirname "$ocg_writer")" -mindepth 1 -maxdepth 1 -name 'review-*' \
    -print -quit | grep -q .; then
    fail 'submit created a review worktree despite the missing gate adapter'
fi

printf '%s\n' '33. opencode gate adapter generates a deny-first gate policy'
ocg_review="$(awk -F $'\t' '$1 == "review_worktree" { print $2 }' "$(dirname "$ocg_manifest")/review.tsv" 2>/dev/null || true)"
if [[ -z "$ocg_review" ]]; then
    # build a review snapshot through the real submit path
    ocg_writer="$(manifest_value "$ocg_manifest" writer_worktree)"
    printf '%s\n' 'gate checkpoint' >"${ocg_writer}/gate-checkpoint.txt"
    git -C "$ocg_writer" add gate-checkpoint.txt
    git -C "$ocg_writer" commit -m 'feat: add opencode gate checkpoint' >/dev/null
    run_arena submit run-opencode-gate >/dev/null
    ocg_review="$(awk -F $'\t' '$1 == "review_worktree" { print $2 }' "$(dirname "$ocg_manifest")/review.tsv")"
fi
[[ -f "${ocg_review}/opencode.json" ]] || fail 'opencode gate policy file missing'
require_match '"arena_gate"' "${ocg_review}/opencode.json"
require_match '"edit":"deny"' "${ocg_review}/opencode.json"
require_match '"webfetch":"deny"' "${ocg_review}/opencode.json"
require_match '"websearch":"deny"' "${ocg_review}/opencode.json"
require_match '"task":"deny"' "${ocg_review}/opencode.json"
require_match '"external_directory":"deny"' "${ocg_review}/opencode.json"
[[ "$(manifest_value "$(dirname "$ocg_manifest")/review.tsv" gate_adapter)" == 'opencode' ]] || \
    fail 'opencode gate review manifest is not bound to the opencode gate'
[[ "$(manifest_value "$(dirname "$ocg_manifest")/review.tsv" gate_wrapper_path)" == '.agent-arena-gate' ]] || \
    fail 'opencode gate review manifest is not bound to the declared wrapper path'
expect_failure "${ocg_review}/.agent-arena-gate" start run-opencode-gate

printf '%s\n' '34. gate policy binding strictness and declared-path validation'
fixture_source="${tmp_root}/fixture-source"
mkdir -p "${fixture_source}/adapters"
binding_worktree="${tmp_root}/binding-snapshot"
git -C "$project" worktree add --detach "$binding_worktree" HEAD >/dev/null
hex64_a="$(printf 'a%.0s' {1..64})"
hex64_b="$(printf 'b%.0s' {1..64})"
write_binding_adapter() {
    local adapter_name="$1"
    local bindings_file="$2"

    cat >"${fixture_source}/adapters/gate-${adapter_name}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat '${bindings_file}'
EOF
    chmod 755 "${fixture_source}/adapters/gate-${adapter_name}.sh"
}
prepare_capture() {
    local adapter_name="$1"

    ARENA_SOURCE_ROOT="$fixture_source" bash -c '
        set -euo pipefail
        source "$1/lib/common.sh"
        arena_prepare_gate_policy "$2" "$3"
        printf "%s\n%s\n%s\n%s\n" "$ARENA_GATE_POLICY_PATH" "$ARENA_GATE_POLICY_HASH" \
            "$ARENA_GATE_WRAPPER_PATH" "$ARENA_GATE_WRAPPER_HASH"
    ' _ "$source_root" "$binding_worktree" "$adapter_name"
}
cat >"${tmp_root}/bindings-valid.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
wrapper	.agent-arena-gate	${hex64_b}
EOF
write_binding_adapter fixture-valid "${tmp_root}/bindings-valid.tsv"
valid_bindings="$(prepare_capture fixture-valid)"
[[ "$(printf '%s\n' "$valid_bindings" | awk 'NR == 1')" == '.cursor/cli.json' ]] || \
    fail 'valid policy binding did not parse the declared policy path'
[[ "$(printf '%s\n' "$valid_bindings" | awk 'NR == 2')" == "$hex64_a" ]] || \
    fail 'valid policy binding did not parse the declared policy hash'
[[ "$(printf '%s\n' "$valid_bindings" | awk 'NR == 3')" == '.agent-arena-gate' ]] || \
    fail 'valid wrapper binding did not parse the declared wrapper path'
[[ "$(printf '%s\n' "$valid_bindings" | awk 'NR == 4')" == "$hex64_b" ]] || \
    fail 'valid wrapper binding did not parse the declared wrapper hash'
cat >"${tmp_root}/bindings-duplicate-policy.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
policy	opencode.json	${hex64_b}
wrapper	.agent-arena-gate	${hex64_a}
EOF
write_binding_adapter fixture-duplicate-policy "${tmp_root}/bindings-duplicate-policy.tsv"
if prepare_capture fixture-duplicate-policy >"${tmp_root}/duplicate-policy.out" 2>&1; then
    fail 'duplicate policy binding lines were accepted'
fi
require_match 'duplicate policy binding' "${tmp_root}/duplicate-policy.out"
cat >"${tmp_root}/bindings-duplicate-wrapper.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
wrapper	.agent-arena-gate	${hex64_a}
wrapper	.agent-arena-gate	${hex64_b}
EOF
write_binding_adapter fixture-duplicate-wrapper "${tmp_root}/bindings-duplicate-wrapper.tsv"
if prepare_capture fixture-duplicate-wrapper >"${tmp_root}/duplicate-wrapper.out" 2>&1; then
    fail 'duplicate wrapper binding lines were accepted'
fi
require_match 'duplicate wrapper binding' "${tmp_root}/duplicate-wrapper.out"
cat >"${tmp_root}/bindings-malformed.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
wrapper	.agent-arena-gate	not-a-sha256-value
EOF
write_binding_adapter fixture-malformed "${tmp_root}/bindings-malformed.tsv"
if prepare_capture fixture-malformed >"${tmp_root}/malformed.out" 2>&1; then
    fail 'a malformed binding line was accepted'
fi
require_match 'malformed policy binding' "${tmp_root}/malformed.out"
cat >"${tmp_root}/bindings-extra-line.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
wrapper	.agent-arena-gate	${hex64_a}
extra	line	ignored
EOF
write_binding_adapter fixture-extra-line "${tmp_root}/bindings-extra-line.tsv"
if prepare_capture fixture-extra-line >"${tmp_root}/extra-line.out" 2>&1; then
    fail 'an unrecognized extra binding line was accepted'
fi
require_match 'malformed policy binding' "${tmp_root}/extra-line.out"
cat >"${tmp_root}/bindings-evil-policy.tsv" <<EOF
policy	../evil	${hex64_a}
wrapper	.agent-arena-gate	${hex64_a}
EOF
write_binding_adapter fixture-evil-policy "${tmp_root}/bindings-evil-policy.tsv"
if prepare_capture fixture-evil-policy >"${tmp_root}/evil-policy.out" 2>&1; then
    fail 'a policy path escaping the snapshot was accepted'
fi
require_match "may not contain '..'" "${tmp_root}/evil-policy.out"
cat >"${tmp_root}/bindings-absolute-policy.tsv" <<EOF
policy	/tmp/evil-policy	${hex64_a}
wrapper	.agent-arena-gate	${hex64_a}
EOF
write_binding_adapter fixture-absolute-policy "${tmp_root}/bindings-absolute-policy.tsv"
if prepare_capture fixture-absolute-policy >"${tmp_root}/absolute-policy.out" 2>&1; then
    fail 'an absolute policy path was accepted'
fi
require_match 'must be relative to the review snapshot' "${tmp_root}/absolute-policy.out"
cat >"${tmp_root}/bindings-evil-wrapper.tsv" <<EOF
policy	.cursor/cli.json	${hex64_a}
wrapper	../evil	${hex64_a}
EOF
write_binding_adapter fixture-evil-wrapper "${tmp_root}/bindings-evil-wrapper.tsv"
if prepare_capture fixture-evil-wrapper >"${tmp_root}/evil-wrapper.out" 2>&1; then
    fail 'a wrapper path escaping the snapshot was accepted'
fi
require_match "may not contain '..'" "${tmp_root}/evil-wrapper.out"
rm -rf "$binding_worktree"
git -C "$project" worktree prune

printf '%s\n' '35. hostile gate adapter output fails submit before review.tsv'
run_arena start run-hostile-gate --repo "$project" --profile pi-opencode --no-attach >/dev/null
hostile_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-hostile-gate/manifest.tsv' -exec dirname {} \;)"
hostile_writer="$(manifest_value "${hostile_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' 'hostile checkpoint' >"${hostile_writer}/hostile.txt"
git -C "$hostile_writer" add hostile.txt
git -C "$hostile_writer" commit -m 'test: checkpoint for a hostile gate adapter' >/dev/null
cp "${source_root}/adapters/gate-opencode.sh" "${tmp_root}/gate-opencode.sh.real"
cat >"${source_root}/adapters/gate-opencode.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
    capabilities)
        printf '%s\n' 'policy_path=../evil-policy' 'wrapper_path=.agent-arena-gate'
        ;;
    policy)
        printf 'policy\t../evil-policy\t%s\n' "${hex64_a}"
        printf 'wrapper\t.agent-arena-gate\t%s\n' "${hex64_b}"
        ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "${source_root}/adapters/gate-opencode.sh"
if run_arena submit run-hostile-gate >"${tmp_root}/hostile-submit.out" 2>&1; then
    hostile_status=0
else
    hostile_status=$?
fi
cp "${tmp_root}/gate-opencode.sh.real" "${source_root}/adapters/gate-opencode.sh"
chmod 755 "${source_root}/adapters/gate-opencode.sh"
[[ "$hostile_status" -ne 0 ]] || fail 'submit accepted a gate policy path escaping the snapshot'
require_match "may not contain '..'" "${tmp_root}/hostile-submit.out"
[[ ! -f "${hostile_run_dir}/review.tsv" ]] || \
    fail 'hostile gate policy path still wrote a review manifest'
run_arena start run-dirty-gate --repo "$project" --profile pi-opencode --no-attach >/dev/null
dirty_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-dirty-gate/manifest.tsv' -exec dirname {} \;)"
dirty_writer="$(manifest_value "${dirty_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' 'dirty checkpoint' >"${dirty_writer}/dirty.txt"
git -C "$dirty_writer" add dirty.txt
git -C "$dirty_writer" commit -m 'test: checkpoint for a dirty policy generation' >/dev/null
cat >"${source_root}/adapters/gate-opencode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    capabilities)
        printf '%s\n' 'policy_path=opencode.json' 'wrapper_path=.agent-arena-gate'
        ;;
    policy)
        review_worktree="${2:?}"
        policy_file="${review_worktree}/opencode.json"
        gate_wrapper="${review_worktree}/.agent-arena-gate"
        printf '%s\n' '{}' >"$policy_file"
        printf '%s\n' '#!/usr/bin/env bash' >"$gate_wrapper"
        chmod 600 "$policy_file"
        chmod 700 "$gate_wrapper"
        printf '%s\n' 'stray edit' >"${review_worktree}/stray.txt"
        if command -v shasum >/dev/null 2>&1; then
            printf 'policy\topencode.json\t%s\n' "$(shasum -a 256 "$policy_file" | awk '{print $1}')"
            printf 'wrapper\t.agent-arena-gate\t%s\n' "$(shasum -a 256 "$gate_wrapper" | awk '{print $1}')"
        else
            printf 'policy\topencode.json\t%s\n' "$(sha256sum "$policy_file" | awk '{print $1}')"
            printf 'wrapper\t.agent-arena-gate\t%s\n' "$(sha256sum "$gate_wrapper" | awk '{print $1}')"
        fi
        ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "${source_root}/adapters/gate-opencode.sh"
if run_arena submit run-dirty-gate >"${tmp_root}/dirty-submit.out" 2>&1; then
    dirty_status=0
else
    dirty_status=$?
fi
cp "${tmp_root}/gate-opencode.sh.real" "${source_root}/adapters/gate-opencode.sh"
chmod 755 "${source_root}/adapters/gate-opencode.sh"
[[ "$dirty_status" -ne 0 ]] || fail 'submit accepted a policy generation that dirtied the snapshot'
require_match 'review snapshot changed while installing gate policy' "${tmp_root}/dirty-submit.out"
[[ ! -f "${dirty_run_dir}/review.tsv" ]] || \
    fail 'dirty policy generation still wrote a review manifest'

printf '%s\n' '36. hostile review manifest paths fail closed'
ocg_run_dir="$(dirname "$ocg_manifest")"
hostile_review_backup="${tmp_root}/review.tsv.pre-hostile"
cp "${ocg_run_dir}/review.tsv" "$hostile_review_backup"
hostile_review="$(mktemp "${ocg_run_dir}/.review-hostile.XXXXXX")"
awk -F $'\t' 'BEGIN { OFS = FS } $1 == "gate_policy_path" { $2 = "../evil" } { print }' \
    "${ocg_run_dir}/review.tsv" >"$hostile_review"
mv "$hostile_review" "${ocg_run_dir}/review.tsv"
if run_arena validate run-opencode-gate >"${tmp_root}/hostile-review-validate.out" 2>&1; then
    fail 'validate accepted a hostile gate_policy_path in review.tsv'
fi
require_match "may not contain '..'" "${tmp_root}/hostile-review-validate.out"
if run_arena status run-opencode-gate >"${tmp_root}/hostile-review-status.out" 2>&1; then
    fail 'status accepted a hostile gate_policy_path in review.tsv'
fi
require_match "may not contain '..'" "${tmp_root}/hostile-review-status.out"
hostile_wrapper_review="$(mktemp "${ocg_run_dir}/.review-hostile-wrapper.XXXXXX")"
awk -F $'\t' 'BEGIN { OFS = FS } $1 == "gate_wrapper_path" { $2 = "../evil" } { print }' \
    "$hostile_review_backup" >"$hostile_wrapper_review"
mv "$hostile_wrapper_review" "${ocg_run_dir}/review.tsv"
if run_arena validate run-opencode-gate >"${tmp_root}/hostile-wrapper-validate.out" 2>&1; then
    fail 'validate accepted a hostile gate_wrapper_path in review.tsv'
fi
require_match "may not contain '..'" "${tmp_root}/hostile-wrapper-validate.out"
mv "$hostile_review_backup" "${ocg_run_dir}/review.tsv"
run_arena status run-opencode-gate >"${tmp_root}/restored-status.out"
require_match 'Integrity: OK' "${tmp_root}/restored-status.out"

printf '%s\n' '37. cursor gate policy refuses pre-existing gate files'
guard_snapshot="${tmp_root}/guard-snapshot"
git -C "$project" worktree add --detach "$guard_snapshot" HEAD >/dev/null
mkdir -p "${guard_snapshot}/.cursor"
printf '%s\n' '{}' >"${guard_snapshot}/.cursor/cli.json"
expect_failure env ARENA_COMMAND="$arena" "${source_root}/adapters/gate-cursor.sh" policy "$guard_snapshot"
rm -f "${guard_snapshot}/.cursor/cli.json"
printf '%s\n' '#!/usr/bin/env bash' >"${guard_snapshot}/.agent-arena-gate"
expect_failure env ARENA_COMMAND="$arena" "${source_root}/adapters/gate-cursor.sh" policy "$guard_snapshot"
rm -f "${guard_snapshot}/.agent-arena-gate"
cursor_bindings="$(env ARENA_COMMAND="$arena" "${source_root}/adapters/gate-cursor.sh" policy "$guard_snapshot")"
printf '%s\n' "$cursor_bindings" | grep -Eq $'^policy\t\.cursor/cli\.json\t[0-9a-fA-F]{64}$' || \
    fail 'cursor gate policy did not print the three-column policy binding'
printf '%s\n' "$cursor_bindings" | grep -Eq $'^wrapper\t\.agent-arena-gate\t[0-9a-fA-F]{64}$' || \
    fail 'cursor gate policy did not print the three-column wrapper binding'
rm -rf "$guard_snapshot"
git -C "$project" worktree prune

printf '%s\n' '38. state wire contract and field invariants'
state_fixture_dir="${tmp_root}/state-fixture"
mkdir -p "$state_fixture_dir"
run_arena start state-wire --repo "$project" --state-root "$state_fixture_dir" --no-attach >/dev/null
state_run_dir="$(find "${state_fixture_dir}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path '*/state-wire/manifest.tsv' -exec dirname {} \;)"
[[ -n "$state_run_dir" ]] || fail 'start did not create the state-wire run'
state_file="${state_run_dir}/run-state.tsv"
[[ -f "$state_file" ]] || fail 'start did not write run-state.tsv'
[[ "$(ls -l "$state_file" | cut -c1-10)" == '-rw-------' ]] || \
    fail 'state file is not mode 600'
state_key_count="$(wc -l <"$state_file" | tr -d ' ')"
[[ "$state_key_count" == 16 ]] || \
    fail "state file carries ${state_key_count} keys instead of 16"
for state_key in schema_version state_revision run_status phase responsible_party \
    reason_code reason_detail verdict validation_result checkpoint_round checkpoint_sha \
    waiting_since last_transition_at last_transition_actor last_transition_action \
    validation_digest; do
    require_match "${state_key}"$'\t' <(cat "$state_file")
done
require_match $'schema_version\t1' <(cat "$state_file")
require_match $'state_revision\t1' <(cat "$state_file")
require_match $'run_status\tactive' <(cat "$state_file")
require_match $'phase\tintake' <(cat "$state_file")
require_match $'responsible_party\twriter' <(cat "$state_file")
require_match $'reason_code\tnone' <(cat "$state_file")
require_match $'checkpoint_round\t0' <(cat "$state_file")
require_match $'last_transition_actor\tsystem' <(cat "$state_file")
require_match $'last_transition_action\tstart' <(cat "$state_file")
[[ -z "$(manifest_value "$state_file" verdict)" ]] || fail 'verdict must start empty'
[[ -z "$(manifest_value "$state_file" validation_result)" ]] || \
    fail 'validation_result must start empty'
[[ -z "$(manifest_value "$state_file" checkpoint_sha)" ]] || \
    fail 'checkpoint_sha must start empty'
[[ -z "$(manifest_value "$state_file" validation_digest)" ]] || \
    fail 'validation_digest must start empty'
[[ "$(manifest_value "$state_file" waiting_since)" =~ ^[0-9]+$ ]] || \
    fail 'waiting_since must be epoch seconds'
run_arena status state-wire --state-root "$state_fixture_dir" >"${tmp_root}/state-wire-status.out"
state_pristine="${state_run_dir}/state-pristine.tsv"
cp "$state_file" "$state_pristine"
# corruption fails closed: completed with the intake phase is illegal; status exits 2
sed 's/\tactive$/\tcompleted/' "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-corrupt.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted an illegal run_status/phase combination (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-corrupt.out"
# duplicate keys are corrupted files and fail closed through the same read path
cp "$state_pristine" "$state_file"
state_dup="$(mktemp "${state_run_dir}/.state-dup.XXXXXX")"
awk -F $'\t' 'BEGIN { OFS = FS } { print } $1 == "phase" { print }' "$state_file" >"$state_dup"
mv "$state_dup" "$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-dup.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted a duplicate state key (exit ${state_status_exit})"
require_match 'duplicate key phase' "${tmp_root}/state-wire-dup.out"
# last_transition_action must be a spec enum value; unknown actions fail closed
cp "$state_pristine" "$state_file"
sed 's/^last_transition_action\tstart$/last_transition_action\tbogus/' "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-action.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted an invalid last_transition_action (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-action.out"
# blocked/reviewer_unreachable inherits the source-phase V/VR/VD/CS constraints
wire_sha40='0123456789abcdef0123456789abcdef01234567'
wire_sha64='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
cp "$state_pristine" "$state_file"
sed -e 's/^run_status\tactive$/run_status\tblocked/' \
    -e 's/^phase\tintake$/phase\tsubmitted/' \
    -e 's/^responsible_party\twriter$/responsible_party\thuman/' \
    -e 's/^reason_code\tnone$/reason_code\treviewer_unreachable/' \
    -e 's/^checkpoint_round\t0$/checkpoint_round\t1/' \
    -e "s/^checkpoint_sha\t/checkpoint_sha\t${wire_sha40}/" \
    -e 's/^verdict\t/verdict\tAPPROVE/' "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-blocked-submitted.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted a blocked/submitted state with a non-empty verdict (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-blocked-submitted.out"
cp "$state_pristine" "$state_file"
sed -e 's/^run_status\tactive$/run_status\tblocked/' \
    -e 's/^phase\tintake$/phase\tvalidated/' \
    -e 's/^responsible_party\twriter$/responsible_party\thuman/' \
    -e 's/^reason_code\tnone$/reason_code\treviewer_unreachable/' \
    -e 's/^checkpoint_round\t0$/checkpoint_round\t1/' \
    -e "s/^checkpoint_sha\t/checkpoint_sha\t${wire_sha40}/" \
    -e "s/^validation_digest\t/validation_digest\t${wire_sha64}/" "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-blocked-validated.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted a blocked/validated state with an empty validation_result (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-blocked-validated.out"
# checkpoint_round must be positive-or-unknown in every non-intake phase
cp "$state_pristine" "$state_file"
sed -e 's/^phase\tintake$/phase\tvalidated/' \
    -e 's/^responsible_party\twriter$/responsible_party\treviewer/' \
    -e 's/^reason_code\tnone$/reason_code\tdecision_pending/' \
    -e 's/^validation_result\t/validation_result\tPASS/' \
    -e "s/^checkpoint_sha\t/checkpoint_sha\t${wire_sha40}/" \
    -e "s/^validation_digest\t/validation_digest\t${wire_sha64}/" "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-validated-round0.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted a validated state with checkpoint_round 0 (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-validated-round0.out"
cp "$state_pristine" "$state_file"
sed -e 's/^run_status\tactive$/run_status\tblocked/' \
    -e 's/^phase\tintake$/phase\tdecided/' \
    -e 's/^responsible_party\twriter$/responsible_party\thuman/' \
    -e 's/^reason_code\tnone$/reason_code\tblock_resolution_required/' \
    -e 's/^verdict\t/verdict\tBLOCKED/' \
    -e 's/^validation_result\t/validation_result\tFAIL/' \
    -e "s/^checkpoint_sha\t/checkpoint_sha\t${wire_sha40}/" \
    -e "s/^validation_digest\t/validation_digest\t${wire_sha64}/" "$state_pristine" >"$state_file"
state_status_exit=0
run_arena status state-wire --state-root "$state_fixture_dir" \
    >"${tmp_root}/state-wire-blocked-decided-round0.out" 2>&1 || state_status_exit=$?
[[ "$state_status_exit" == 2 ]] || \
    fail "status accepted a blocked/decided state with checkpoint_round 0 (exit ${state_status_exit})"
require_match 'corrupted state file' "${tmp_root}/state-wire-blocked-decided-round0.out"

printf '%s\n' '39. run lock acquire, owner token, grace, and stale PID'
lock_root="${tmp_root}/locks"
mkdir -p "$lock_root"
# a second acquire on a live lock must fail without disturbing the owner
lock_exit=0
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-a
    arena_lock_acquire "$2" token-b
' _ "$source_root" "$lock_root/one" || lock_exit=$?
[[ "$lock_exit" != 0 ]] || fail 'second acquire on a live lock did not fail'
# the first owner still holds the lock and can release it with its token
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_release "$2" token-a
' _ "$source_root" "$lock_root/one" || fail 'owner-token release failed'
[[ ! -e "$lock_root/one" ]] || fail 'owner-token release left the lock directory behind'
# token mismatch release
lock_exit=0
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-a
    arena_lock_release "$2" token-wrong
' _ "$source_root" "$lock_root/two" || lock_exit=$?
[[ "$lock_exit" != 0 ]] || fail 'release with a wrong token succeeded'
# metadata-less stale lock (grace): mtime older than 60s
mkdir -p "$lock_root/three"
touch -t 200001010000 "$lock_root/three"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-c
' _ "$source_root" "$lock_root/three" || fail 'stale metadata-less lock was not recoverable'
# metadata-less fresh lock (< 60s) is live: contenders exit 4, never 1
mkdir -p "$lock_root/four"
lock_exit=0
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-d
' _ "$source_root" "$lock_root/four" 2>"${lock_root}/four.err" || lock_exit=$?
[[ "$lock_exit" == 4 ]] || \
    fail "fresh metadata-less lock did not exit 4 (exit ${lock_exit})"
require_match 'transition in progress (lock without metadata)' "${lock_root}/four.err"
# dead-PID lock is recoverable
mkdir -p "$lock_root/five"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"$lock_root/five/owner"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-e
' _ "$source_root" "$lock_root/five" || fail 'dead-PID lock was not recoverable'
# metadata temp residue equals absent metadata: stale residue is recoverable
mkdir -p "$lock_root/six"
printf 'partial' >"$lock_root/six/owner.tmp.123"
touch -t 200001010000 "$lock_root/six"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-f
' _ "$source_root" "$lock_root/six" || fail 'owner temp residue blocked acquisition'
# fresh temp residue equals absent metadata too: still a live lock
mkdir -p "$lock_root/seven"
printf 'partial' >"$lock_root/seven/owner.tmp.456"
lock_exit=0
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-g
' _ "$source_root" "$lock_root/seven" || lock_exit=$?
[[ "$lock_exit" != 0 ]] || fail 'fresh owner temp residue was treated as stale'
# release on a path with no live owner metadata removes it without dying
mkdir -p "$lock_root/eight"
touch -t 200001010000 "$lock_root/eight"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_release "$2" token-any
' _ "$source_root" "$lock_root/eight" || fail 'release on a metadata-less lock died'
[[ ! -e "$lock_root/eight" ]] || fail 'release on a metadata-less lock left the directory behind'
# GNU-style stat failure simulation: -f takes '%m' as an invalid filesystem
# specifier, emits a multi-line table to stdout, and exits 1; -c '%Y'
# serves the mtime epoch. Other invocations fall through to the real stat.
gnu_stat_bin="${tmp_root}/gnu-stat-bin"
mkdir -p "$gnu_stat_bin"
cat >"$gnu_stat_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == '-f' ]]; then
    printf 'contaminated\nline\n'
    exit 1
fi
if [[ "$1" == '-c' && "$2" == '%Y' ]]; then
    exec /usr/bin/stat -f '%m' "${@:3}"
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$gnu_stat_bin/stat"
# arena_lock_mtime must return the clean epoch when the BSD-style attempt
# fails noisily: the failed attempt's stdout must not contaminate the capture
mkdir -p "$lock_root/nine"
touch -t 200001010000 "$lock_root/nine"
expected_mtime="$(/usr/bin/stat -f '%m' "$lock_root/nine")"
lock_mtime_out="$(PATH="$gnu_stat_bin:$PATH" ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_mtime "$2"
' _ "$source_root" "$lock_root/nine")" || \
    fail 'arena_lock_mtime failed under GNU-style stat failure'
[[ "$lock_mtime_out" == "$expected_mtime" ]] || \
    fail "arena_lock_mtime output contaminated under GNU-style stat failure ($lock_mtime_out)"
# an unreadable mtime must fail closed: exit 1, no stdout
broken_stat_bin="${tmp_root}/broken-stat-bin"
mkdir -p "$broken_stat_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$broken_stat_bin/stat"
chmod +x "$broken_stat_bin/stat"
lock_mtime_exit=0
lock_mtime_out="$(PATH="$broken_stat_bin:$PATH" ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_mtime "$2"
' _ "$source_root" "$lock_root/nine")" || lock_mtime_exit=$?
[[ "$lock_mtime_exit" == 1 && -z "$lock_mtime_out" ]] || \
    fail "arena_lock_mtime did not fail closed on unreadable mtime (exit ${lock_mtime_exit}, output '${lock_mtime_out}')"
# a metadata-less stale lock must still be recoverable under the GNU failure mode
mkdir -p "$lock_root/ten"
touch -t 200001010000 "$lock_root/ten"
PATH="$gnu_stat_bin:$PATH" ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-i
' _ "$source_root" "$lock_root/ten" || \
    fail 'stale metadata-less lock not recoverable under GNU-style stat failure'

printf '%s\n' '40. legacy projection rows, precheck, and conflicts'
legacy_proj_dir="${tmp_root}/legacy-proj"
mkdir -p "$legacy_proj_dir"
cat >"${legacy_proj_dir}/manifest.tsv" <<EOF
run_id	legacy-run
repository	$project
base_sha	$(git -C "$project" rev-parse HEAD)
writer_worktree	$project
branch	agent-arena/pi/legacy-run
session_name	agent-arena-legacy-run
tool_root	$source_root
worktree_root	$worktree_base
project_config	$project/.agent-arena/project.conf
profile	pi-cursor
writer_adapter	pi
writer_label	Pi
writer_session_dir	${legacy_proj_dir}/writer-session
gate_adapter	cursor
EOF
sha_40='0123456789abcdef0123456789abcdef01234567'
short_40='0123456789ab'
# L6: no evidence → intake projection
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == intake && "$ARENA_PROJECTED_PARTY" == writer && "$ARENA_PROJECTED_ROUND" == unknown ]] || exit 9
    [[ "$ARENA_PROJECTED_LABEL" == legacy && -z "$ARENA_PROJECTED_RESIDUE" && -z "$ARENA_PROJECTED_CONFLICTS" ]] || exit 9
' _ "$source_root" "$legacy_proj_dir" || fail 'L6 projection wrong'
# L5: review.tsv only → submitted
printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
    "$sha_40" "$project" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')" >"${legacy_proj_dir}/review.tsv"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == submitted && "$ARENA_PROJECTED_PARTY" == reviewer && "$ARENA_PROJECTED_CS" == "'"$sha_40"'" ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == review_pending && "$ARENA_PROJECTED_LABEL" == legacy && -z "$ARENA_PROJECTED_RESIDUE" ]] || exit 9
' _ "$source_root" "$legacy_proj_dir" || fail 'L5 projection wrong'
# conflict: decision archive bound to a different SHA
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${legacy_proj_dir}/decision-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$legacy_proj_dir" >"${tmp_root}/proj-conflict.out" 2>&1; then
    fail 'conflicting decision archive projected successfully'
fi
require_match 'conflict' "${tmp_root}/proj-conflict.out"
require_match 'decision archive bound to differing SHA' "${tmp_root}/proj-conflict.out"
# report-only with R + parseable + bound report = validate residue (exit 5), not conflict
residue_dir="${tmp_root}/legacy-residue"
mkdir -p "$residue_dir"
printf 'review_head\t%s\n' "$sha_40" >"${residue_dir}/review.tsv"
cat >"${residue_dir}/validation-${short_40}.md" <<EOF
# Agent Arena Validation Report

Run: legacy-run

Review HEAD: ${sha_40}

Project: fixture

## Output

all good

RESULT: PASS
EOF
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    if arena_state_project_legacy "$2"; then rc=0; else rc=$?; fi
    [[ "$rc" == 5 ]] || exit 9
    [[ "$ARENA_PROJECTED_RESIDUE" == validate && -z "$ARENA_PROJECTED_CONFLICTS" ]] || exit 9
    [[ "$ARENA_PROJECTED_PHASE" == submitted && "$ARENA_PROJECTED_PARTY" == reviewer ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == review_pending && "$ARENA_PROJECTED_CS" == "'"$sha_40"'" ]] || exit 9
' _ "$source_root" "$residue_dir" || fail 'report-without-pointer residue projection wrong'
# L1 with RESULT: FAIL → conflict (v0.3 APPROVE required PASS)
l1_fail_dir="${tmp_root}/legacy-l1-fail"
mkdir -p "$l1_fail_dir"
printf 'review_head\t%s\n' "$sha_40" >"${l1_fail_dir}/review.tsv"
cat >"${l1_fail_dir}/validation-${short_40}.md" <<EOF
# Agent Arena Validation Report

Run: legacy-run

Review HEAD: ${sha_40}

RESULT: FAIL
EOF
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${l1_fail_dir}/validation.md"
cat >"${l1_fail_dir}/decision-${short_40}.md" <<EOF
# Agent Arena Gate Decision

Run: legacy-run

Review HEAD: ${sha_40}

VERDICT: APPROVE

## Summary

looks good
EOF
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$l1_fail_dir" >"${tmp_root}/proj-l1-fail.out" 2>&1; then
    fail 'L1 APPROVE with RESULT: FAIL projected successfully'
fi
require_match 'conflict' "${tmp_root}/proj-l1-fail.out"
require_match 'legacy APPROVE requires RESULT: PASS' "${tmp_root}/proj-l1-fail.out"
# L1: decision APPROVE + canonical PASS report → decided/human/approval_pending
l1_dir="${tmp_root}/legacy-l1"
mkdir -p "$l1_dir"
printf 'review_head\t%s\n' "$sha_40" >"${l1_dir}/review.tsv"
cat >"${l1_dir}/validation-${short_40}.md" <<EOF
# Agent Arena Validation Report

Run: legacy-run

Review HEAD: ${sha_40}

Project: fixture

## Output

all good

RESULT: PASS
EOF
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${l1_dir}/validation.md"
cat >"${l1_dir}/decision-${short_40}.md" <<EOF
# Agent Arena Gate Decision

Run: legacy-run

Review HEAD: ${sha_40}

VERDICT: APPROVE

## Summary

ship it
EOF
l1_vd="$(shasum -a 256 "${l1_dir}/validation-${short_40}.md" | awk '{print $1}')"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == decided && "$ARENA_PROJECTED_PARTY" == human ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == approval_pending && "$ARENA_PROJECTED_VERDICT" == APPROVE ]] || exit 9
    [[ "$ARENA_PROJECTED_VR" == PASS && "$ARENA_PROJECTED_VD" == "$3" ]] || exit 9
    [[ "$ARENA_PROJECTED_LABEL" == legacy_human_disposition_unknown && -z "$ARENA_PROJECTED_RESIDUE" ]] || exit 9
    [[ "$ARENA_PROJECTED_CS" == "'"$sha_40"'" && "$ARENA_PROJECTED_ROUND" == unknown ]] || exit 9
' _ "$source_root" "$l1_dir" "$l1_vd" || fail 'L1 projection wrong'
# L2: CHANGES_REQUESTED with a FAIL report → decided/writer/changes_requested
l2_dir="${tmp_root}/legacy-l2"
mkdir -p "$l2_dir"
printf 'review_head\t%s\n' "$sha_40" >"${l2_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: FAIL\n' "$sha_40" >"${l2_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${l2_dir}/validation.md"
printf '# Decision\n\nReview HEAD: %s\n\nVERDICT: CHANGES_REQUESTED\n' "$sha_40" >"${l2_dir}/decision-${short_40}.md"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == decided && "$ARENA_PROJECTED_PARTY" == writer ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == changes_requested && "$ARENA_PROJECTED_VERDICT" == CHANGES_REQUESTED ]] || exit 9
    [[ "$ARENA_PROJECTED_VR" == FAIL && "$ARENA_PROJECTED_LABEL" == legacy ]] || exit 9
' _ "$source_root" "$l2_dir" || fail 'L2 projection wrong'
# L3: BLOCKED → blocked/human/block_resolution_required
l3_dir="${tmp_root}/legacy-l3"
mkdir -p "$l3_dir"
printf 'review_head\t%s\n' "$sha_40" >"${l3_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: FAIL\n' "$sha_40" >"${l3_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${l3_dir}/validation.md"
printf '# Decision\n\nReview HEAD: %s\n\nVERDICT: BLOCKED\n' "$sha_40" >"${l3_dir}/decision-${short_40}.md"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == blocked && "$ARENA_PROJECTED_PARTY" == human ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == block_resolution_required && "$ARENA_PROJECTED_VERDICT" == BLOCKED ]] || exit 9
    [[ "$ARENA_PROJECTED_VR" == FAIL && "$ARENA_PROJECTED_LABEL" == legacy ]] || exit 9
' _ "$source_root" "$l3_dir" || fail 'L3 projection wrong'
# L4: no Dec, pointer + canonical report → validated/reviewer/decision_pending
l4_dir="${tmp_root}/legacy-l4"
mkdir -p "$l4_dir"
printf 'review_head\t%s\n' "$sha_40" >"${l4_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: PASS\n' "$sha_40" >"${l4_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${l4_dir}/validation.md"
l4_vd="$(shasum -a 256 "${l4_dir}/validation-${short_40}.md" | awk '{print $1}')"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == validated && "$ARENA_PROJECTED_PARTY" == reviewer ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == decision_pending && "$ARENA_PROJECTED_VR" == PASS ]] || exit 9
    [[ "$ARENA_PROJECTED_VD" == "$3" && "$ARENA_PROJECTED_LABEL" == legacy ]] || exit 9
' _ "$source_root" "$l4_dir" "$l4_vd" || fail 'L4 projection wrong'
# precheck (b): v0.4 archive with State revision: 0 → decision residue (exit 5)
dec_res_dir="${tmp_root}/legacy-dec-res"
mkdir -p "$dec_res_dir"
printf 'review_head\t%s\n' "$sha_40" >"${dec_res_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: PASS\n' "$sha_40" >"${dec_res_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${dec_res_dir}/validation.md"
cat >"${dec_res_dir}/decision-${short_40}.md" <<EOF
# Agent Arena Gate Decision

Run: legacy-run

Review HEAD: ${sha_40}

State revision: 0

VERDICT: APPROVE

## Summary

ship it
EOF
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    if arena_state_project_legacy "$2"; then rc=0; else rc=$?; fi
    [[ "$rc" == 5 ]] || exit 9
    [[ "$ARENA_PROJECTED_RESIDUE" == decision && -z "$ARENA_PROJECTED_CONFLICTS" ]] || exit 9
    [[ "$ARENA_PROJECTED_PHASE" == decided && "$ARENA_PROJECTED_PARTY" == human ]] || exit 9
    [[ "$ARENA_PROJECTED_REASON" == approval_pending && "$ARENA_PROJECTED_VERDICT" == APPROVE ]] || exit 9
    [[ "$ARENA_PROJECTED_VR" == PASS && "$ARENA_PROJECTED_LABEL" == legacy_human_disposition_unknown ]] || exit 9
' _ "$source_root" "$dec_res_dir" || fail 'decision residue projection wrong'
# v0.4 archive with a nonzero State revision in a stateless run → conflict
dec_badrev_dir="${tmp_root}/legacy-dec-badrev"
mkdir -p "$dec_badrev_dir"
printf 'review_head\t%s\n' "$sha_40" >"${dec_badrev_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: PASS\n' "$sha_40" >"${dec_badrev_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${dec_badrev_dir}/validation.md"
printf '# Decision\n\nReview HEAD: %s\n\nState revision: 3\n\nVERDICT: APPROVE\n' "$sha_40" >"${dec_badrev_dir}/decision-${short_40}.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$dec_badrev_dir" >"${tmp_root}/proj-dec-badrev.out" 2>&1; then
    fail 'nonzero State revision archive projected successfully'
fi
require_match 'conflict' "${tmp_root}/proj-dec-badrev.out"
# verdict unparseable → conflict
verdict_bad_dir="${tmp_root}/legacy-verdict-bad"
mkdir -p "$verdict_bad_dir"
printf 'review_head\t%s\n' "$sha_40" >"${verdict_bad_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: PASS\n' "$sha_40" >"${verdict_bad_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${verdict_bad_dir}/validation.md"
printf '# Decision\n\nReview HEAD: %s\n\nVERDICT: MAYBE\n' "$sha_40" >"${verdict_bad_dir}/decision-${short_40}.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$verdict_bad_dir" >"${tmp_root}/proj-verdict-bad.out" 2>&1; then
    fail 'unparseable verdict projected successfully'
fi
require_match 'decision verdict unparseable' "${tmp_root}/proj-verdict-bad.out"
# pointer without a canonical report → conflict
pointer_bad_dir="${tmp_root}/legacy-pointer-bad"
mkdir -p "$pointer_bad_dir"
printf 'review_head\t%s\n' "$sha_40" >"${pointer_bad_dir}/review.tsv"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${pointer_bad_dir}/validation.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$pointer_bad_dir" >"${tmp_root}/proj-pointer-bad.out" 2>&1; then
    fail 'pointer without a canonical report projected successfully'
fi
require_match 'validation pointer without a canonical report' "${tmp_root}/proj-pointer-bad.out"
# orphan evidence with no R → conflict (L6 does not apply)
orphan_dir="${tmp_root}/legacy-orphan"
mkdir -p "$orphan_dir"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$sha_40" >"${orphan_dir}/decision-${short_40}.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$orphan_dir" >"${tmp_root}/proj-orphan.out" 2>&1; then
    fail 'orphan evidence without R projected successfully'
fi
require_match 'orphan evidence with no review.tsv' "${tmp_root}/proj-orphan.out"
# unreadable review_head → conflict
badhead_dir="${tmp_root}/legacy-badhead"
mkdir -p "$badhead_dir"
printf 'review_head\tnot-a-sha\n' >"${badhead_dir}/review.tsv"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$badhead_dir" >"${tmp_root}/proj-badhead.out" 2>&1; then
    fail 'unreadable review_head projected successfully'
fi
require_match 'review.tsv review_head unreadable' "${tmp_root}/proj-badhead.out"
# multiple decision archives bound to review_head → conflict
multi_dec_dir="${tmp_root}/legacy-multi-dec"
mkdir -p "$multi_dec_dir"
printf 'review_head\t%s\n' "$sha_40" >"${multi_dec_dir}/review.tsv"
printf '# Report\n\nReview HEAD: %s\n\nRESULT: PASS\n' "$sha_40" >"${multi_dec_dir}/validation-${short_40}.md"
printf 'Latest validation report: validation-%s.md\n' "$short_40" >"${multi_dec_dir}/validation.md"
printf '# Decision\n\nReview HEAD: %s\n\nVERDICT: APPROVE\n' "$sha_40" >"${multi_dec_dir}/decision-${short_40}.md"
printf '# Decision\n\nReview HEAD: %s\n\nVERDICT: APPROVE\n' "$sha_40" >"${multi_dec_dir}/decision-other.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$multi_dec_dir" >"${tmp_root}/proj-multi-dec.out" 2>&1; then
    fail 'multiple bound decision archives projected successfully'
fi
require_match 'multiple decision archives bound to review_head' "${tmp_root}/proj-multi-dec.out"

printf '%s\n' '41. creation intent helpers and stage machine'
intent_root="${tmp_root}/intent-root"
mkdir -p "${intent_root}/runs/proj-id"
sha40='0000000000000000000000000000000000000000'
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id s1-run repository=/x state_root=/y worktree_root=/z profile=pi-cursor gate_adapter=cursor session_name=agent-arena-x base_sha='"$sha40"' branch=agent-arena/pi/s1-run writer_worktree=/w writer_adapter_path=/a gate_adapter_path=/g
    intent="$(arena_creation_intent_path "$2/runs" proj-id s1-run)"
    [[ "$(head -1 "$intent")" == "$(printf "run_id\t%s" s1-run)" ]] || exit 9
    [[ "$(grep -c run_id "$intent")" == 1 ]] || exit 9
    arena_creation_intent_read "$2/runs" proj-id s1-run
    [[ "${ARENA_INTENT_run_id}" == s1-run ]] || exit 9
    stage="$(arena_creation_intent_stage "$2/runs" proj-id s1-run)"
    [[ "$stage" == S1 ]] || exit 9
' _ "$source_root" "$intent_root" || fail 'S1 not detected or run_id header missing'
# S2: empty run dir
mkdir -p "${intent_root}/runs/proj-id/s2-run"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id s2-run
    stage="$(arena_creation_intent_stage "$2/runs" proj-id s2-run)"
    [[ "$stage" == S2 ]] || exit 9
' _ "$source_root" "$intent_root" || fail 'S2 not detected'
# S3: non-empty run dir without manifest
mkdir -p "${intent_root}/runs/proj-id/s3-run"
printf x >"${intent_root}/runs/proj-id/s3-run/junk"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id s3-run
    stage="$(arena_creation_intent_stage "$2/runs" proj-id s3-run)"
    [[ "$stage" == S3 ]] || exit 9
' _ "$source_root" "$intent_root" || fail 'S3 not detected'
# S6: state present + intent remains
mkdir -p "${intent_root}/runs/proj-id/s6-run"
printf 'writer_worktree\t%s\n' "$project" >"${intent_root}/runs/proj-id/s6-run/manifest.tsv"
printf 'schema_version\t1\nstate_revision\t1\nrun_status\tactive\nphase\tintake\nresponsible_party\twriter\nreason_code\tnone\nreason_detail\t\nverdict\t\nvalidation_result\t\ncheckpoint_round\t0\ncheckpoint_sha\t\nwaiting_since\t1\nlast_transition_at\t1\nlast_transition_actor\tsystem\nlast_transition_action\tstart\nvalidation_digest\t\n' >"${intent_root}/runs/proj-id/s6-run/run-state.tsv"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id s6-run
    stage="$(arena_creation_intent_stage "$2/runs" proj-id s6-run)"
    [[ "$stage" == S6 ]] || exit 9
' _ "$source_root" "$intent_root" || fail 'S6 not detected'
# precheck: S1 intent + foreign caller exits 5 with retry
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id s1-run submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-s1.out" 2>&1; then
    fail 'precheck passed a foreign caller through S1'
fi
require_match 'retry: agent-arena start s1-run' "${tmp_root}/precheck-s1.out"
# precheck: S3 + status caller exits 2 with the abort protocol
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id s3-run status
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-s3.out" 2>&1; then
    fail 'precheck passed status through S3'
fi
require_match 'interrupted start stage S3' "${tmp_root}/precheck-s3.out"

# precheck: run lock held by a live owner → exit 4
mkdir -p "${intent_root}/runs/proj-id/lock-live/.run-lock"
printf 'pid=%s\ntoken=live\ncreated_at=1\n' "$$" >"${intent_root}/runs/proj-id/lock-live/.run-lock/owner"
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id lock-live submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-run-live.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 4 ]] || fail "live run lock did not exit 4 (rc=$precheck_rc)"
require_match 'transition in progress' "${tmp_root}/precheck-run-live.out"
# precheck: metadata-less fresh run-dir lock (grace window) → exit 4
mkdir -p "${intent_root}/runs/proj-id/lock-fresh/.run-lock"
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id lock-fresh submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-run-fresh.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 4 ]] || fail "metadata-less fresh run-dir lock did not exit 4 (rc=$precheck_rc)"
require_match 'transition in progress' "${tmp_root}/precheck-run-fresh.out"
# precheck: metadata-less stale run-dir lock is ignored → intent path runs (exit 5)
mkdir -p "${intent_root}/runs/proj-id/lock-stale/.run-lock"
touch -t 200001010000 "${intent_root}/runs/proj-id/lock-stale/.run-lock"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id lock-stale
' _ "$source_root" "$intent_root" || fail 'stale lock intent write failed'
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id lock-stale submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-run-stale.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 5 ]] || fail "stale metadata-less run lock blocked precheck (rc=$precheck_rc)"
require_match 'retry: agent-arena start lock-stale' "${tmp_root}/precheck-run-stale.out"
# precheck: metadata-less stale run-dir lock under GNU-style stat failure
# (stdout contamination + exit 1 on -f) must still be ignored → exit 5, not 4
mkdir -p "${intent_root}/runs/proj-id/lock-stale-gnu/.run-lock"
touch -t 200001010000 "${intent_root}/runs/proj-id/lock-stale-gnu/.run-lock"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id lock-stale-gnu
' _ "$source_root" "$intent_root" || fail 'stale-gnu lock intent write failed'
precheck_rc=''
if PATH="$gnu_stat_bin:$PATH" ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id lock-stale-gnu submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-run-stale-gnu.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 5 ]] || \
    fail "stale metadata-less run lock under GNU-style stat failure blocked precheck (rc=$precheck_rc)"
require_match 'retry: agent-arena start lock-stale-gnu' "${tmp_root}/precheck-run-stale-gnu.out"
# precheck: parent creation lock held by a live owner → exit 4
mkdir -p "${intent_root}/runs/proj-id/.parent-lock"
printf 'pid=%s\ntoken=live\ncreated_at=1\n' "$$" >"${intent_root}/runs/proj-id/.parent-lock/owner"
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id plock-live submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-parent-live.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 4 ]] || fail "live parent lock did not exit 4 (rc=$precheck_rc)"
require_match 'transition in progress' "${tmp_root}/precheck-parent-live.out"
rm -rf "${intent_root}/runs/proj-id/.parent-lock"
# precheck: metadata-less fresh parent lock (grace window) → exit 4
mkdir -p "${intent_root}/runs/proj-id/.parent-lock"
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id plock-fresh submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-parent-fresh.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 4 ]] || fail "metadata-less fresh parent lock did not exit 4 (rc=$precheck_rc)"
require_match 'transition in progress' "${tmp_root}/precheck-parent-fresh.out"
rm -rf "${intent_root}/runs/proj-id/.parent-lock"
# precheck: metadata-less stale parent lock is ignored → intent path runs (exit 5)
mkdir -p "${intent_root}/runs/proj-id/.parent-lock"
touch -t 200001010000 "${intent_root}/runs/proj-id/.parent-lock"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id plock-stale
' _ "$source_root" "$intent_root" || fail 'stale parent intent write failed'
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id plock-stale submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-parent-stale.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 5 ]] || fail "stale metadata-less parent lock blocked precheck (rc=$precheck_rc)"
require_match 'retry: agent-arena start plock-stale' "${tmp_root}/precheck-parent-stale.out"
rm -rf "${intent_root}/runs/proj-id/.parent-lock"
# precheck: parent lock with a dead owner is ignored → intent path runs (exit 5)
mkdir -p "${intent_root}/runs/proj-id/.parent-lock"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"${intent_root}/runs/proj-id/.parent-lock/owner"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" proj-id plock-dead
' _ "$source_root" "$intent_root" || fail 'plock-dead intent write failed'
precheck_rc=''
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_precheck_intents "$2/runs" proj-id plock-dead submit
' _ "$source_root" "$intent_root" >"${tmp_root}/precheck-parent-dead.out" 2>&1; then
    precheck_rc=0
else
    precheck_rc=$?
fi
[[ "$precheck_rc" == 5 ]] || fail "dead-owner parent lock blocked precheck (rc=$precheck_rc)"
require_match 'retry: agent-arena start plock-dead' "${tmp_root}/precheck-parent-dead.out"
rm -rf "${intent_root}/runs/proj-id/.parent-lock"

printf '%s\n' '42. start creation intent, T1/T1r recovery, and lock ordering'
# (a) a completed start leaves no creation intent and no parent lock
intent_check_run='intent-clean'
run_arena start "$intent_check_run" --repo "$project" --no-attach >/dev/null
intent_check_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path "*/${intent_check_run}/manifest.tsv" -exec dirname {} \;)"
repo_id="$(basename "$(dirname "$intent_check_dir")")"
[[ ! -e "${state_root}/runs/${repo_id}/.creating-${intent_check_run}" ]] || \
    fail 'creation intent left behind'
[[ ! -e "${state_root}/runs/${repo_id}/.parent-lock" ]] || fail 'parent lock left behind'
require_match $'checkpoint_round\t0' <(cat "${intent_check_dir}/run-state.tsv")
# (b) S5 recovery: manifest+worktree present, state missing, intent present
# → start commits state round=0; the run lock covers the session re-check
# and the tmuxp load and is released afterwards.
s5_run='s5-recover'
run_arena start "$s5_run" --repo "$project" --no-attach >/dev/null
s5_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path "*/${s5_run}/manifest.tsv" -exec dirname {} \;)"
s5_repo="$(basename "$(dirname "$s5_dir")")"
printf '%s\n' "run_id=${s5_run}" >"${state_root}/runs/${s5_repo}/.creating-${s5_run}"
rm -f "${s5_dir}/run-state.tsv"
: >"$fake_tmuxp_log"
FAKE_TMUXP_LOCK_CHECK="${s5_dir}/.run-lock" \
    run_arena start "$s5_run" --repo "$project" --no-attach >/dev/null
require_match $'phase\tintake' <(cat "${s5_dir}/run-state.tsv")
[[ ! -e "${state_root}/runs/${s5_repo}/.creating-${s5_run}" ]] || fail 'S5 intent not removed'
require_match 'lock-present=' "$fake_tmuxp_log"
[[ ! -e "${s5_dir}/.run-lock" ]] || fail 'S5 run lock not released'
# (c) parameter mismatch on retry fails closed (exit 2)
s5b_run='s5-mismatch'
run_arena start "$s5b_run" --repo "$project" --no-attach >/dev/null
s5b_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path "*/${s5b_run}/manifest.tsv" -exec dirname {} \;)"
s5b_repo="$(basename "$(dirname "$s5b_dir")")"
printf '%s\n' "run_id=${s5b_run}" >"${state_root}/runs/${s5b_repo}/.creating-${s5b_run}"
rm -f "${s5b_dir}/run-state.tsv"
# rewrite the intent with a differing profile, then retry must exit 2
printf 'run_id\t%s\nprofile\tcodex-cursor\n' "$s5b_run" >"${state_root}/runs/${s5b_repo}/.creating-${s5b_run}"
if run_arena start "$s5b_run" --repo "$project" --no-attach >"${tmp_root}/s5b.out" 2>&1; then
    fail 'mismatched intent retry succeeded'
fi
require_match 'differ' "${tmp_root}/s5b.out"
# (d) S6: state present + intent remains → start removes intent
s6_run='s6-recover'
run_arena start "$s6_run" --repo "$project" --no-attach >/dev/null
s6_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path "*/${s6_run}/manifest.tsv" -exec dirname {} \;)"
s6_repo="$(basename "$(dirname "$s6_dir")")"
printf '%s\n' "run_id=${s6_run}" >"${state_root}/runs/${s6_repo}/.creating-${s6_run}"
run_arena start "$s6_run" --repo "$project" --no-attach >/dev/null
[[ ! -e "${state_root}/runs/${s6_repo}/.creating-${s6_run}" ]] || fail 'S6 intent not removed'
# (e) S3: non-empty run dir without manifest → start exits 2 with the abort protocol
s3_run='s3-abort'
mkdir -p "${state_root}/runs/${repo_id}/${s3_run}"
printf x >"${state_root}/runs/${repo_id}/${s3_run}/junk"
printf 'run_id\t%s\n' "$s3_run" >"${state_root}/runs/${repo_id}/.creating-${s3_run}"
if run_arena start "$s3_run" --repo "$project" --no-attach >"${tmp_root}/s3.out" 2>&1; then
    fail 'S3 start succeeded'
fi
require_match 'interrupted start stage S3' "${tmp_root}/s3.out"
# (f) S1 retry with a drifted base SHA fails closed (exit 2)
s1_run='s1-mismatch'
s1_base="$(git -C "$project" rev-parse HEAD)"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" "$3" "$4" \
        "repository=$5" "state_root=$2" "worktree_root=$6" \
        "profile=pi-cursor" "gate_adapter=cursor" \
        "session_name=agent-arena-$3-$4" "base_sha=$7" \
        "branch=agent-arena/pi/$4" "writer_worktree=$6/$3/$4/writer" \
        "writer_adapter_path=$1/adapters/pi.sh" \
        "gate_adapter_path=$1/adapters/gate-cursor.sh"
' _ "$source_root" "$state_root" "$repo_id" "$s1_run" "$project" "$worktree_base" "$s1_base" || \
    fail 'S1 intent fixture write failed'
printf '%s\n' fixture >>"${project}/README.md"
git -C "$project" add README.md
git -C "$project" commit -m 'test: drift the base SHA' >/dev/null
s1_exit=0
run_arena start "$s1_run" --repo "$project" --no-attach >"${tmp_root}/s1-mismatch.out" 2>&1 || s1_exit=$?
[[ "$s1_exit" == 2 ]] || fail "S1 mismatched retry did not fail closed (exit ${s1_exit})"
require_match 'differ' "${tmp_root}/s1-mismatch.out"
# (g) arena_creation_intent_read tolerates both line forms: the run_id TSV
# header, bare key<TAB>value lines, and key=value lines all bind.
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    runs_root="$2/runs"
    mkdir -p "${runs_root}/proj-mixed"
    intent="$(arena_creation_intent_path "$runs_root" proj-mixed mixed-run)"
    printf "run_id\tmixed-run\n" >"$intent"
    printf "repository\t/x\n" >>"$intent"
    printf "profile=pi-cursor\n" >>"$intent"
    arena_creation_intent_read "$runs_root" proj-mixed mixed-run
    [[ "${ARENA_INTENT_run_id}" == mixed-run ]] || exit 9
    [[ "${ARENA_INTENT_repository}" == /x ]] || exit 9
    [[ "${ARENA_INTENT_profile}" == pi-cursor ]] || exit 9
' _ "$source_root" "$tmp_root" || fail 'mixed-form creation intent not parsed'

printf '%s\n' '43. submit transitions T2/T3/T4 and legacy L-T3'
trans_run='trans-submit'
run_arena start "$trans_run" --repo "$project" --no-attach >/dev/null
trans_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f \
    -name manifest.tsv -path "*/${trans_run}/manifest.tsv" -exec dirname {} \;)"
[[ -n "$trans_run_dir" ]] || fail 'start did not create the trans-submit run'
trans_repo="$(basename "$(dirname "$trans_run_dir")")"
trans_writer="$(manifest_value "${trans_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' t2 >"${trans_writer}/t2.txt"
git -C "$trans_writer" add t2.txt
git -C "$trans_writer" commit -m 'feat: t2' >/dev/null
trans_head="$(git -C "$trans_writer" rev-parse HEAD)"
# T2: new-SHA submit from intake commits the submitted state
run_arena submit "$trans_run" >/dev/null
trans_state="${trans_run_dir}/run-state.tsv"
require_match $'phase\tsubmitted' <(cat "$trans_state")
require_match $'responsible_party\treviewer' <(cat "$trans_state")
require_match $'reason_code\treview_pending' <(cat "$trans_state")
require_match $'run_status\tactive' <(cat "$trans_state")
require_match $'checkpoint_round\t1' <(cat "$trans_state")
require_match $'state_revision\t2' <(cat "$trans_state")
require_match $'checkpoint_sha\t'"$trans_head" <(cat "$trans_state")
require_match $'last_transition_actor\twriter' <(cat "$trans_state")
require_match $'last_transition_action\tsubmit' <(cat "$trans_state")
[[ -z "$(awk -F $'\t' '$1 == "verdict" { print $2 }' "$trans_state")" ]] || \
    fail 'T2 kept a verdict'
[[ -z "$(awk -F $'\t' '$1 == "validation_result" { print $2 }' "$trans_state")" ]] || \
    fail 'T2 kept a validation_result'
[[ -z "$(awk -F $'\t' '$1 == "validation_digest" { print $2 }' "$trans_state")" ]] || \
    fail 'T2 kept a validation_digest'
first_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "$trans_state")"
first_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "$trans_state")"
[[ -n "$first_waiting" && "$first_waiting" != unknown ]] || fail 'T2 did not reset waiting_since'
first_state_hash="$(shasum -a 256 "$trans_state" | awk '{print $1}')"
# T3: same-SHA submit is a zero-write retry
run_arena submit "$trans_run" >/dev/null
second_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "$trans_state")"
second_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "$trans_state")"
second_state_hash="$(shasum -a 256 "$trans_state" | awk '{print $1}')"
[[ "$first_revision" == "$second_revision" ]] || fail 'T3 same-SHA submit wrote state'
[[ "$first_waiting" == "$second_waiting" ]] || fail 'T3 same-SHA submit reset waiting_since'
[[ "$first_state_hash" == "$second_state_hash" ]] || fail 'T3 same-SHA submit changed the state file'
# T4: same SHA after CHANGES_REQUESTED is rejected. validate/decision state
# commits land in later tasks, so fabricate the decided tuple they would
# produce (evidence comes from the real validate + decision run above).
run_arena validate "$trans_run" >/dev/null 2>&1
run_arena decision "$trans_run" --verdict CHANGES_REQUESTED --summary s --next n --no-relay >/dev/null
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tFAIL\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\twriter\nlast_transition_action\tsubmit\nvalidation_digest\t%s\n' \
    "$first_revision" "$trans_head" "$first_waiting" "$first_waiting" \
    "$(printf y | shasum -a 256 | awk '{print $1}')" >"${trans_state}.t4"
mv "${trans_state}.t4" "$trans_state"
t4_exit=0
run_arena submit "$trans_run" >"${tmp_root}/t4.out" 2>&1 || t4_exit=$?
[[ "$t4_exit" == 2 ]] || fail "T4 same-SHA submit did not exit 2 (exit ${t4_exit})"
require_match 'must submit a new SHA' "${tmp_root}/t4.out"
[[ ! -e "${trans_run_dir}/.run-lock" ]] || fail 'T4 rejection left the run lock held'
# submit wires the precheck: a live run lock wins with exit 4
mkdir -p "${trans_run_dir}/.run-lock"
printf 'pid=%s\ntoken=foreign\ncreated_at=1\n' "$$" >"${trans_run_dir}/.run-lock/owner"
lock_exit=0
run_arena submit "$trans_run" >"${tmp_root}/t4-lock.out" 2>&1 || lock_exit=$?
[[ "$lock_exit" == 4 ]] || fail "submit did not exit 4 on a live run lock (exit ${lock_exit})"
require_match 'transition in progress' "${tmp_root}/t4-lock.out"
rm -rf "${trans_run_dir}/.run-lock"
# an interrupted creation intent is owned by start: foreign submit exits 5
printf 'run_id\t%s\n' "$trans_run" >"${state_root}/runs/${trans_repo}/.creating-${trans_run}"
intent_exit=0
run_arena submit "$trans_run" >"${tmp_root}/t4-intent.out" 2>&1 || intent_exit=$?
[[ "$intent_exit" == 5 ]] || fail "submit did not exit 5 on an interrupted creation intent (exit ${intent_exit})"
require_match 'retry: agent-arena start trans-submit' "${tmp_root}/t4-intent.out"
rm -f "${state_root}/runs/${trans_repo}/.creating-${trans_run}"
# L6: a legacy run with no evidence materializes v1 submitted (round 1)
lt3_run='legacy-lt3'
lt3_dir="${state_root}/runs/${trans_repo}/${lt3_run}"
mkdir -p "$lt3_dir"
awk -F $'\t' -v dir="$lt3_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-lt3" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-lt3" }
    $1 == "session_name" { $2 = "agent-arena-legacy-lt3" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${trans_run_dir}/manifest.tsv" >"${lt3_dir}/manifest.tsv"
run_arena submit "$lt3_run" >/dev/null
require_match $'phase\tsubmitted' <(cat "${lt3_dir}/run-state.tsv")
require_match $'state_revision\t1' <(cat "${lt3_dir}/run-state.tsv")
require_match $'checkpoint_round\t1' <(cat "${lt3_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$trans_head" <(cat "${lt3_dir}/run-state.tsv")
require_match $'last_transition_actor\twriter' <(cat "${lt3_dir}/run-state.tsv")
require_match $'last_transition_action\tsubmit' <(cat "${lt3_dir}/run-state.tsv")
[[ -n "$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${lt3_dir}/run-state.tsv")" ]] || \
    fail 'L6 materialization did not set waiting_since'
lt3_review_hash="$(shasum -a 256 "${lt3_dir}/review.tsv" | awk '{print $1}')"
# L-T3: drop the state file and resubmit the same SHA → materialize v1 with
# the L5 projection (round unknown), no evidence changes
rm -f "${lt3_dir}/run-state.tsv"
run_arena submit "$lt3_run" >/dev/null
require_match $'phase\tsubmitted' <(cat "${lt3_dir}/run-state.tsv")
require_match $'state_revision\t1' <(cat "${lt3_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${lt3_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$trans_head" <(cat "${lt3_dir}/run-state.tsv")
require_match $'last_transition_actor\twriter' <(cat "${lt3_dir}/run-state.tsv")
require_match $'last_transition_action\tsubmit' <(cat "${lt3_dir}/run-state.tsv")
[[ "$(shasum -a 256 "${lt3_dir}/review.tsv" | awk '{print $1}')" == "$lt3_review_hash" ]] || \
    fail 'L-T3 changed the review evidence'
lt3_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${lt3_dir}/run-state.tsv")"
lt3_transition_at="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${lt3_dir}/run-state.tsv")"
[[ -n "$lt3_waiting" && "$lt3_waiting" == "$lt3_transition_at" ]] || \
    fail 'L-T3 did not set waiting_since to last_transition_at'
# Illegal persisted-v1 states fail closed (exit 2) BEFORE the evidence phase
# can rewrite review.tsv or delete the validation/decision pointers.
# (1) completed run with a NEW SHA: exit 2; evidence and state byte-identical.
[[ -f "${trans_run_dir}/validation.md" ]] || fail 'completed-submit fixture lacks validation.md'
[[ -f "${trans_run_dir}/decision.md" ]] || fail 'completed-submit fixture lacks decision.md'
cp "${trans_run_dir}/review.tsv" "${tmp_root}/completed-review.tsv"
cp "${trans_run_dir}/validation.md" "${tmp_root}/completed-validation.md"
cp "${trans_run_dir}/decision.md" "${tmp_root}/completed-decision.md"
printf '%s\n' comp2 >"${trans_writer}/comp2.txt"
git -C "$trans_writer" add comp2.txt
git -C "$trans_writer" commit -m 'feat: comp2' >/dev/null
comp_head="$(git -C "$trans_writer" rev-parse HEAD)"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tcompleted\nphase\tdecided\nresponsible_party\tnone\nreason_code\tnone\nreason_detail\t\nverdict\tAPPROVE\nvalidation_result\tPASS\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t\nlast_transition_at\t%s\nlast_transition_actor\thuman\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$first_revision" "$trans_head" "$first_waiting" \
    "$(printf y | shasum -a 256 | awk '{print $1}')" >"${trans_state}.completed"
mv "${trans_state}.completed" "$trans_state"
completed_state_hash="$(shasum -a 256 "$trans_state" | awk '{print $1}')"
completed_exit=0
run_arena submit "$trans_run" >"${tmp_root}/completed-submit.out" 2>&1 || completed_exit=$?
[[ "$completed_exit" == 2 ]] || fail "completed-run submit did not exit 2 (exit ${completed_exit})"
require_match 'illegal submit from completed/decided/none/none' "${tmp_root}/completed-submit.out"
cmp -s "${tmp_root}/completed-review.tsv" "${trans_run_dir}/review.tsv" || \
    fail 'completed-run submit rewrote review.tsv'
cmp -s "${tmp_root}/completed-validation.md" "${trans_run_dir}/validation.md" || \
    fail 'completed-run submit changed validation.md'
cmp -s "${tmp_root}/completed-decision.md" "${trans_run_dir}/decision.md" || \
    fail 'completed-run submit changed decision.md'
[[ "$(shasum -a 256 "$trans_state" | awk '{print $1}')" == "$completed_state_hash" ]] || \
    fail 'completed-run submit changed the state file'
[[ ! -e "${trans_run_dir}/.run-lock" ]] || fail 'completed-run rejection left the run lock held'
# (2) submitted/reviewer/review_pending with a NEW SHA: exit 2, no rewrite of review.tsv.
printf '%s\n' comp3 >"${trans_writer}/comp3.txt"
git -C "$trans_writer" add comp3.txt
git -C "$trans_writer" commit -m 'feat: comp3' >/dev/null
comp3_head="$(git -C "$trans_writer" rev-parse HEAD)"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tsubmitted\nresponsible_party\treviewer\nreason_code\treview_pending\nreason_detail\t\nverdict\t\nvalidation_result\t\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\twriter\nlast_transition_action\tsubmit\nvalidation_digest\t\n' \
    "$first_revision" "$trans_head" "$first_waiting" "$first_waiting" >"${trans_state}.submitted-new"
mv "${trans_state}.submitted-new" "$trans_state"
submitted_new_exit=0
run_arena submit "$trans_run" >"${tmp_root}/submitted-new.out" 2>&1 || submitted_new_exit=$?
[[ "$submitted_new_exit" == 2 ]] || fail "new-SHA submit from submitted/reviewer did not exit 2 (exit ${submitted_new_exit})"
require_match 'illegal submit from active/submitted/reviewer/review_pending' "${tmp_root}/submitted-new.out"
cmp -s "${tmp_root}/completed-review.tsv" "${trans_run_dir}/review.tsv" || \
    fail 'new-SHA submit from submitted/reviewer rewrote review.tsv'
[[ ! -e "${trans_run_dir}/.run-lock" ]] || fail 'submitted-new rejection left the run lock held'
# (3) a legacy projection that does not admit this submit exits 2 before the
# evidence phase materializes anything.
illegit_run='legacy-illegal'
illegit_dir="${state_root}/runs/${trans_repo}/${illegit_run}"
mkdir -p "$illegit_dir"
awk -F $'\t' -v dir="$illegit_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-illegal" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-illegal" }
    $1 == "session_name" { $2 = "agent-arena-legacy-illegal" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${trans_run_dir}/manifest.tsv" >"${illegit_dir}/manifest.tsv"
printf 'review_head\t%s\n' "$sha40" >"${illegit_dir}/review.tsv"
illegit_review_hash="$(shasum -a 256 "${illegit_dir}/review.tsv" | awk '{print $1}')"
illegit_exit=0
run_arena submit "$illegit_run" >"${tmp_root}/legacy-illegal.out" 2>&1 || illegit_exit=$?
[[ "$illegit_exit" == 2 ]] || fail "illegal legacy submit did not exit 2 (exit ${illegit_exit})"
require_match 'legacy projection submitted/reviewer/review_pending does not admit this submit' "${tmp_root}/legacy-illegal.out"
[[ ! -e "${illegit_dir}/run-state.tsv" ]] || fail 'illegal legacy submit materialized state'
[[ "$(shasum -a 256 "${illegit_dir}/review.tsv" | awk '{print $1}')" == "$illegit_review_hash" ]] || \
    fail 'illegal legacy submit rewrote review.tsv'

printf '%s\n' '44. validate op-token CAS and exit 10 on recorded FAIL'
val_run='val-cas'
run_arena start "$val_run" --repo "$project" --no-attach >/dev/null
val_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${val_run}/manifest.tsv" -exec dirname {} \;)"
val_writer="$(manifest_value "${val_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' v >"${val_writer}/v.txt"
git -C "$val_writer" add v.txt
git -C "$val_writer" commit -m 'feat: v' >/dev/null
run_arena submit "$val_run" >/dev/null
# PASS: submitted -> validated, digest binds the canonical report
run_arena validate "$val_run" >"${tmp_root}/val-pass.out"
require_match 'RESULT: PASS' "${tmp_root}/val-pass.out"
require_match $'phase\tvalidated' <(cat "${val_run_dir}/run-state.tsv")
require_match $'reason_code\tdecision_pending' <(cat "${val_run_dir}/run-state.tsv")
val_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${val_run_dir}/run-state.tsv")"
val_short="${val_sha:0:12}"
require_match $'validation_digest\t'"$(shasum -a 256 "${val_run_dir}/validation-${val_short}.md" | awk '{print $1}')" \
    <(cat "${val_run_dir}/run-state.tsv")
# a tampered snapshot writes ONLY the diagnostic report and does not touch state
val_review="$(manifest_value "${val_run_dir}/review.tsv" review_worktree)"
printf '%s\n' tampered >"${val_review}/tampered.txt"
val_state_before="$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')"
val_report_before="$(shasum -a 256 "${val_run_dir}/validation-${val_short}.md" | awk '{print $1}')"
val_tamper_exit=0
run_arena validate "$val_run" >"${tmp_root}/val-tampered.out" 2>&1 || val_tamper_exit=$?
[[ "$val_tamper_exit" == 2 ]] || fail "tampered validate exited $val_tamper_exit, expected 2"
require_match 'RESULT: FAIL' "${val_run_dir}/validation-${val_short}.diagnostic.md"
[[ "$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')" == "$val_state_before" ]] || \
    fail 'tampered validate changed the state file'
[[ "$(shasum -a 256 "${val_run_dir}/validation-${val_short}.md" | awk '{print $1}')" == "$val_report_before" ]] || \
    fail 'tampered validate rotated or replaced the canonical report'
rm -f "${val_review}/tampered.txt"
# revalidate: WS preserved, revision bumps
val_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${val_run_dir}/run-state.tsv")"
val_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
run_arena validate "$val_run" >/dev/null
require_match $'waiting_since\t'"${val_waiting}" <(cat "${val_run_dir}/run-state.tsv")
val_new_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
[[ "$val_new_revision" -gt "$val_revision" ]] || fail 'revalidate did not bump revision'
# a pending decision archive blocks validate at the first lock: exit 5 and
# the gate never runs (no new report rotation). The decision now commits
# state, so capture the pre-decision tuple first and restore it afterwards
# to simulate the evidence-first crash window (archive present, state lost).
cp "${val_run_dir}/run-state.tsv" "${tmp_root}/val-pre-decision-state.tsv"
run_arena decision "$val_run" --verdict CHANGES_REQUESTED --summary s --next n --no-relay >/dev/null
require_match $'verdict\tCHANGES_REQUESTED' <(cat "${val_run_dir}/run-state.tsv")
require_match $'responsible_party\twriter' <(cat "${val_run_dir}/run-state.tsv")
require_match $'reason_code\tchanges_requested' <(cat "${val_run_dir}/run-state.tsv")
cp "${tmp_root}/val-pre-decision-state.tsv" "${val_run_dir}/run-state.tsv"
val_state_before_refusal="$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')"
val_refusal_exit=0
run_arena validate "$val_run" >"${tmp_root}/val-refusal.out" 2>&1 || val_refusal_exit=$?
[[ "$val_refusal_exit" == 5 ]] || fail "validate with a pending decision archive exited $val_refusal_exit, expected 5"
require_match 'pending decision residue' "${tmp_root}/val-refusal.out"
[[ "$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')" == "$val_state_before_refusal" ]] || \
    fail 'pending-archive refusal changed the state file'
[[ ! -e "${val_run_dir}/validation-${val_short}.r2.md" ]] || \
    fail 'pending-archive refusal ran the gate and rotated the canonical report'
# the crash-window simulation above restored the pre-decision state; the
# decided tuple the decision produced must be present for the next submit
# to be a legal T2, so fabricate it exactly as the decision would commit
val_digest="$(awk -F $'\t' '$1 == "validation_digest" { print $2 }' "${val_run_dir}/run-state.tsv")"
val_waiting_after="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${val_run_dir}/run-state.tsv")"
val_transition_after="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${val_run_dir}/run-state.tsv")"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tPASS\ncheckpoint_round\t1\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\treviewer\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$val_new_revision" "$val_sha" "$val_waiting_after" "$val_transition_after" "$val_digest" \
    >"${val_run_dir}/.run-state-fabricated"
mv "${val_run_dir}/.run-state-fabricated" "${val_run_dir}/run-state.tsv"
# a fresh checkpoint whose snapshot carries the failing validation script
printf '%s\n' f >"${val_writer}/f.txt"
cat >"${val_writer}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "${val_writer}/.agent-arena/validate.sh"
git -C "$val_writer" add f.txt .agent-arena/validate.sh
git -C "$val_writer" commit -m 'feat: f' >/dev/null
run_arena submit "$val_run" >/dev/null
# FAIL: the gate runs, the result is recorded, and validate exits 10
val_fail_exit=0
run_arena validate "$val_run" >"${tmp_root}/val-fail.out" 2>&1 || val_fail_exit=$?
[[ "$val_fail_exit" == 10 ]] || fail "validate FAIL exited $val_fail_exit, expected 10"
require_match 'RESULT: FAIL' "${tmp_root}/val-fail.out"
require_match $'validation_result\tFAIL' <(cat "${val_run_dir}/run-state.tsv")
# CAS-stale: while the gate runs, a legal submit bumps the state revision;
# the background validate must exit 3 and leave canonical report, pointer,
# and state exactly as the submit left them (no report for the new round).
# decision state commits land in a later task, so the decided tuples here
# are fabricated exactly as above; every submit transition is a real T2.
stale_fail_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_fail_short="${stale_fail_sha:0:12}"
stale_fail_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_fail_round="$(awk -F $'\t' '$1 == "checkpoint_round" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_fail_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_fail_transition="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_fail_digest="$(awk -F $'\t' '$1 == "validation_digest" { print $2 }' "${val_run_dir}/run-state.tsv")"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tFAIL\ncheckpoint_round\t%s\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\treviewer\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$stale_fail_revision" "$stale_fail_round" "$stale_fail_sha" "$stale_fail_waiting" \
    "$stale_fail_transition" "$stale_fail_digest" \
    >"${val_run_dir}/.run-state-fabricated"
mv "${val_run_dir}/.run-state-fabricated" "${val_run_dir}/run-state.tsv"
# the slow checkpoint: its validation script announces the gate start and
# then waits for the test to release it, so the submit below is guaranteed
# to land while the gate is running (no timing races, no long sleeps)
printf '%s\n' slow >"${val_writer}/slow.txt"
cat >"${val_writer}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${VAL_SLOW_MARKER:?}"
slow_gate_wait=0
while [[ ! -e "${VAL_SLOW_GO:?}" ]]; do
    slow_gate_wait=$((slow_gate_wait + 1))
    [[ "$slow_gate_wait" -lt 600 ]] || exit 1
    sleep 0.1
done
exit 0
EOF
chmod 755 "${val_writer}/.agent-arena/validate.sh"
git -C "$val_writer" add slow.txt .agent-arena/validate.sh
git -C "$val_writer" commit -m 'feat: slow' >/dev/null
run_arena submit "$val_run" >/dev/null
slow_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${val_run_dir}/run-state.tsv")"
slow_short="${slow_sha:0:12}"
slow_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
[[ ! -e "${val_run_dir}/validation-${slow_short}.md" ]] || \
    fail 'slow checkpoint already has a validation report'
stale_prior_report_hash="$(shasum -a 256 "${val_run_dir}/validation-${stale_fail_short}.md" | awk '{print $1}')"
val_slow_marker="${tmp_root}/val-slow-marker"
val_slow_go="${tmp_root}/val-slow-go"
rm -f "$val_slow_marker" "$val_slow_go"
VAL_SLOW_MARKER="$val_slow_marker" VAL_SLOW_GO="$val_slow_go" \
    run_arena validate "$val_run" >"${tmp_root}/val-stale.out" 2>&1 &
stale_validate_pid=$!
stale_gate_waits=0
while [[ ! -e "$val_slow_marker" ]]; do
    if ! kill -0 "$stale_validate_pid" 2>/dev/null; then
        fail 'background validate exited before the gate ran'
    fi
    stale_gate_waits=$((stale_gate_waits + 1))
    [[ "$stale_gate_waits" -lt 600 ]] || fail 'slow validation gate never started'
    sleep 0.1
done
# while the gate runs, the decision on the slow checkpoint completes
# (fabricated T8 tuple) and the writer submits a new checkpoint: the state
# revision legally moves past the background validate's baseline
stale_decided_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_decided_transition="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_decided_round="$(awk -F $'\t' '$1 == "checkpoint_round" { print $2 }' "${val_run_dir}/run-state.tsv")"
printf 'schema_version\t1\nstate_revision\t%s\nrun_status\tactive\nphase\tdecided\nresponsible_party\twriter\nreason_code\tchanges_requested\nreason_detail\t\nverdict\tCHANGES_REQUESTED\nvalidation_result\tPASS\ncheckpoint_round\t%s\ncheckpoint_sha\t%s\nwaiting_since\t%s\nlast_transition_at\t%s\nlast_transition_actor\treviewer\nlast_transition_action\tdecision\nvalidation_digest\t%s\n' \
    "$((slow_revision + 1))" "$stale_decided_round" "$slow_sha" "$stale_decided_waiting" \
    "$stale_decided_transition" "$(printf y | shasum -a 256 | awk '{print $1}')" \
    >"${val_run_dir}/.run-state-fabricated"
mv "${val_run_dir}/.run-state-fabricated" "${val_run_dir}/run-state.tsv"
printf '%s\n' stale >"${val_writer}/stale.txt"
git -C "$val_writer" add stale.txt
git -C "$val_writer" commit -m 'feat: stale' >/dev/null
run_arena submit "$val_run" >/dev/null
stale_new_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${val_run_dir}/run-state.tsv")"
stale_new_short="${stale_new_sha:0:12}"
stale_post_state="$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')"
stale_post_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
[[ "$stale_post_revision" -gt "$slow_revision" ]] || \
    fail 'mid-gate submit did not bump the state revision'
[[ ! -e "${val_run_dir}/validation.md" ]] || \
    fail 'submit kept the validation pointer for the new round'
: >"$val_slow_go"
stale_validate_status=0
wait "$stale_validate_pid" || stale_validate_status=$?
[[ "$stale_validate_status" == 3 ]] || \
    fail "CAS-stale validate exited $stale_validate_status, expected 3"
require_match 'state moved during validation; result discarded, re-run validate' \
    "${tmp_root}/val-stale.out"
# exit 3 leaves canonical report, pointer, and state exactly as the submit
# left them: no report for the new round, no stale report, no temp residue
[[ "$(shasum -a 256 "${val_run_dir}/run-state.tsv" | awk '{print $1}')" == "$stale_post_state" ]] || \
    fail 'exit-3 validate changed the state file'
[[ ! -e "${val_run_dir}/validation.md" ]] || \
    fail 'exit-3 validate rewrote the validation pointer'
[[ ! -e "${val_run_dir}/validation-${stale_new_short}.md" ]] || \
    fail 'exit-3 validate published a report for the new round'
[[ ! -e "${val_run_dir}/validation-${slow_short}.md" ]] || \
    fail 'exit-3 validate published a stale report for the slow checkpoint'
[[ -z "$(find "${val_run_dir}" -maxdepth 1 -name '.validation.*.tmp' -print -quit)" ]] || \
    fail 'exit-3 validate left its temporary report'
[[ ! -e "${val_run_dir}/.run-lock" ]] || \
    fail 'exit-3 validate left the run lock held'
[[ "$(shasum -a 256 "${val_run_dir}/validation-${stale_fail_short}.md" | awk '{print $1}')" == "$stale_prior_report_hash" ]] || \
    fail 'exit-3 validate rotated or replaced the prior canonical report'

printf '%s\n' '45. validate dead-owner-only temp cleanup'
val_temp_run='val-temp'
run_arena start "$val_temp_run" --repo "$project" --no-attach >/dev/null
val_temp_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${val_temp_run}/manifest.tsv" -exec dirname {} \;)"
[[ -n "$val_temp_dir" ]] || fail 'start did not create the val-temp run'
val_temp_writer="$(manifest_value "${val_temp_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' t >"${val_temp_writer}/t.txt"
git -C "$val_temp_writer" add t.txt
git -C "$val_temp_writer" commit -m 'feat: t' >/dev/null
run_arena submit "$val_temp_run" >/dev/null
run_arena validate "$val_temp_run" >/dev/null
# a dead owner's op-token temporary is removed on the next validate
dead_owner_temp="${val_temp_dir}/.validation.validate.999999999.1.tmp"
printf '%s\n' dead >"$dead_owner_temp"
run_arena validate "$val_temp_run" >/dev/null
[[ ! -e "$dead_owner_temp" ]] || fail 'validate kept a dead owner temporary'
# a live owner's op-token temporary is left alone
live_owner_temp="${val_temp_dir}/.validation.validate.$$.1.tmp"
printf '%s\n' live >"$live_owner_temp"
run_arena validate "$val_temp_run" >/dev/null
[[ -f "$live_owner_temp" ]] || fail 'validate removed a live owner temporary'

printf '%s\n' '46. decision transitions T6-T8/T6r, archive metadata, and L-T6'
dec_run='dec-meta'
run_arena start "$dec_run" --repo "$project" --no-attach >/dev/null
dec_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${dec_run}/manifest.tsv" -exec dirname {} \;)"
dec_writer="$(manifest_value "${dec_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' d >"${dec_writer}/d.txt"
git -C "$dec_writer" add d.txt
git -C "$dec_writer" commit -m 'feat: d' >/dev/null
run_arena submit "$dec_run" >/dev/null
run_arena validate "$dec_run" >/dev/null
cp "${dec_run_dir}/run-state.tsv" "${tmp_root}/dec-pre-decision-state.tsv"
dec_pre_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${dec_run_dir}/run-state.tsv")"
dec_pre_digest="$(awk -F $'\t' '$1 == "validation_digest" { print $2 }' "${dec_run_dir}/run-state.tsv")"
# T6: APPROVE lands in active/decided/human/approval_pending and the archive
# carries the state metadata recorded at decision time
run_arena decision "$dec_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'run_status\tactive' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'reason_code\tapproval_pending' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'state_revision\t'"$((dec_pre_revision + 1))" <(cat "${dec_run_dir}/run-state.tsv")
dec_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${dec_run_dir}/run-state.tsv")"
archive="${dec_run_dir}/decision-${dec_sha:0:12}.md"
require_match "State revision: ${dec_pre_revision}" <(cat "$archive")
require_match "Validation digest: ${dec_pre_digest}" <(cat "$archive")
require_match "State revision: " <(cat "$archive")
require_match "Validation digest: " <(cat "$archive")
dec_post_state="$(shasum -a 256 "${dec_run_dir}/run-state.tsv" | awk '{print $1}')"
# duplicate: the state is aligned with the archive, so re-deciding is
# rejected as an illegal transition with zero writes
dup_exit=0
run_arena decision "$dec_run" --verdict APPROVE --summary again --next again --no-relay \
    >"${tmp_root}/dec-dup.out" 2>&1 || dup_exit=$?
[[ "$dup_exit" == 2 ]] || fail "duplicate decision exited $dup_exit, expected 2"
require_match 'illegal transition from active/decided/human/approval_pending' "${tmp_root}/dec-dup.out"
[[ "$(shasum -a 256 "${dec_run_dir}/run-state.tsv" | awk '{print $1}')" == "$dec_post_state" ]] || \
    fail 'duplicate decision changed the state file'
[[ ! -e "${dec_run_dir}/.run-lock" ]] || fail 'duplicate decision left the run lock held'
# T6r: archive-only residue (pre-decision state restored, verdict empty)
# completes the commit with every guard re-checked
cp "${tmp_root}/dec-pre-decision-state.tsv" "${dec_run_dir}/run-state.tsv"
run_arena decision "$dec_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'verdict\tAPPROVE' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'reason_code\tapproval_pending' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'state_revision\t'"$((dec_pre_revision + 1))" <(cat "${dec_run_dir}/run-state.tsv")
# owning mismatch: the same residue with a hand-edited archive digest is a
# conflict — exit 2, no transition, no pointer rewrite
cp "${tmp_root}/dec-pre-decision-state.tsv" "${dec_run_dir}/run-state.tsv"
dec_wrong_vd="$(printf z | shasum -a 256 | awk '{print $1}')"
awk -v vd="$dec_wrong_vd" '{ if ($1 == "Validation" && $2 == "digest:") { $3 = vd } print }' \
    "$archive" >"${tmp_root}/dec-archive-wrong-vd"
cp "${tmp_root}/dec-archive-wrong-vd" "$archive"
dec_mismatch_state="$(shasum -a 256 "${dec_run_dir}/run-state.tsv" | awk '{print $1}')"
dec_mismatch_exit=0
run_arena decision "$dec_run" --verdict APPROVE --summary ok --next go --no-relay \
    >"${tmp_root}/dec-mismatch.out" 2>&1 || dec_mismatch_exit=$?
[[ "$dec_mismatch_exit" == 2 ]] || fail "owning-mismatch decision exited $dec_mismatch_exit, expected 2"
require_match 'does not match the current state' "${tmp_root}/dec-mismatch.out"
[[ "$(shasum -a 256 "${dec_run_dir}/run-state.tsv" | awk '{print $1}')" == "$dec_mismatch_state" ]] || \
    fail 'owning-mismatch decision changed the state file'
[[ ! -e "${dec_run_dir}/.run-lock" ]] || fail 'owning-mismatch decision left the run lock held'
# L-T6: a legacy run whose archive carries the v0.4 baseline metadata
# (State revision: 0) completes the missing decision.md and materializes v1
lt6_run='legacy-lt6'
lt6_repo="$(basename "$(dirname "$dec_run_dir")")"
lt6_dir="${state_root}/runs/${lt6_repo}/${lt6_run}"
mkdir -p "$lt6_dir"
awk -F $'\t' -v dir="$lt6_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-lt6" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-lt6" }
    $1 == "session_name" { $2 = "agent-arena-legacy-lt6" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${dec_run_dir}/manifest.tsv" >"${lt6_dir}/manifest.tsv"
cp "${dec_run_dir}/review.tsv" "${lt6_dir}/review.tsv"
cp "${dec_run_dir}/validation.md" "${lt6_dir}/validation.md"
cp "${dec_run_dir}/validation-${dec_sha:0:12}.md" "${lt6_dir}/validation-${dec_sha:0:12}.md"
cat >"${lt6_dir}/decision-${dec_sha:0:12}.md" <<EOF
# Agent Arena Gate Decision

Run: legacy-lt6

Review HEAD: ${dec_sha}

VERDICT: APPROVE

State revision: 0
Validation digest: ${dec_pre_digest}

## Summary

legacy residue

## Findings

- No additional findings.

## Next Step for Writer

go
EOF
run_arena decision "$lt6_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'state_revision\t1' <(cat "${lt6_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${lt6_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${lt6_dir}/run-state.tsv")
require_match $'reason_code\tapproval_pending' <(cat "${lt6_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${lt6_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${lt6_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$dec_sha" <(cat "${lt6_dir}/run-state.tsv")
require_match $'validation_digest\t'"$dec_pre_digest" <(cat "${lt6_dir}/run-state.tsv")
[[ -f "${lt6_dir}/decision.md" ]] || fail 'L-T6 did not complete decision.md'
# L4: a legacy validated run with no archive records its first decision in
# the same commit, with the archive carrying the State revision: 0 baseline
l4_run='legacy-l4'
l4_dir="${state_root}/runs/${lt6_repo}/${l4_run}"
mkdir -p "$l4_dir"
awk -F $'\t' -v dir="$l4_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-l4" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-l4" }
    $1 == "session_name" { $2 = "agent-arena-legacy-l4" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${dec_run_dir}/manifest.tsv" >"${l4_dir}/manifest.tsv"
cp "${dec_run_dir}/review.tsv" "${l4_dir}/review.tsv"
cp "${dec_run_dir}/validation.md" "${l4_dir}/validation.md"
cp "${dec_run_dir}/validation-${dec_sha:0:12}.md" "${l4_dir}/validation-${dec_sha:0:12}.md"
run_arena decision "$l4_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'state_revision\t1' <(cat "${l4_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${l4_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${l4_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${l4_dir}/run-state.tsv")
require_match 'State revision: 0' <(cat "${l4_dir}/decision-${dec_sha:0:12}.md")
require_match "Validation digest: ${dec_pre_digest}" <(cat "${l4_dir}/decision-${dec_sha:0:12}.md")
[[ -f "${l4_dir}/decision.md" ]] || fail 'L4 first migration did not write decision.md'
# T8: BLOCKED lands in blocked/decided/human/block_resolution_required
block_run='dec-blocked'
run_arena start "$block_run" --repo "$project" --no-attach >/dev/null
block_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${block_run}/manifest.tsv" -exec dirname {} \;)"
block_writer="$(manifest_value "${block_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' b >"${block_writer}/b.txt"
git -C "$block_writer" add b.txt
git -C "$block_writer" commit -m 'feat: b' >/dev/null
run_arena submit "$block_run" >/dev/null
run_arena validate "$block_run" >/dev/null
run_arena decision "$block_run" --verdict BLOCKED --summary blocked --next escalate --no-relay >/dev/null
require_match $'run_status\tblocked' <(cat "${block_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${block_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${block_run_dir}/run-state.tsv")
require_match $'reason_code\tblock_resolution_required' <(cat "${block_run_dir}/run-state.tsv")
require_match $'verdict\tBLOCKED' <(cat "${block_run_dir}/run-state.tsv")
block_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${block_run_dir}/run-state.tsv")"
require_match 'State revision: ' <(cat "${block_run_dir}/decision-${block_sha:0:12}.md")
require_match 'Validation digest: ' <(cat "${block_run_dir}/decision-${block_sha:0:12}.md")

printf '%s\n' '47. escalate and resolve transitions T9-T13, legacy first migrations, and resume respawn'
export FAKE_TMUX_MODE=offline
export FAKE_TMUX_PANES=normal
er_run='er-run'
run_arena start "$er_run" --repo "$project" --no-attach >/dev/null
er_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${er_run}/manifest.tsv" -exec dirname {} \;)"
er_writer="$(manifest_value "${er_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' e >"${er_writer}/e.txt"
git -C "$er_writer" add e.txt
git -C "$er_writer" commit -m 'feat: e' >/dev/null
run_arena submit "$er_run" >/dev/null
# T9: escalate from submitted/reviewer (legal)
run_arena escalate "$er_run" --reason-code reviewer_unreachable --reason 'pane dead' >/dev/null
require_match $'run_status\tblocked' <(cat "${er_run_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${er_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_code\treviewer_unreachable' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_detail\tpane dead' <(cat "${er_run_dir}/run-state.tsv")
require_match $'last_transition_actor\thuman' <(cat "${er_run_dir}/run-state.tsv")
require_match $'last_transition_action\tescalate' <(cat "${er_run_dir}/run-state.tsv")
[[ ! -e "${er_run_dir}/.run-lock" ]] || fail 'escalate left the run lock held'
# duplicate escalate: idempotent zero-write
er_rev="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${er_run_dir}/run-state.tsv")"
er_ws="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${er_run_dir}/run-state.tsv")"
run_arena escalate "$er_run" --reason-code reviewer_unreachable --reason 'again' >"${tmp_root}/er-dup.out"
require_match 'already escalated' "${tmp_root}/er-dup.out"
[[ "$er_rev" == "$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${er_run_dir}/run-state.tsv")" ]] || fail 'duplicate escalate wrote state'
[[ "$er_ws" == "$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${er_run_dir}/run-state.tsv")" ]] || fail 'duplicate escalate reset waiting_since'
[[ ! -e "${er_run_dir}/.run-lock" ]] || fail 'duplicate escalate left the run lock held'
# T12: recover with an unreachable reviewer pane refuses without a transition
# (offline tmux: has-session fails) and prints the two-step prerequisite
if run_arena resolve "$er_run" --action recover --reason 'try' >"${tmp_root}/recover.out" 2>&1; then
    fail 'recover with unreachable pane succeeded'
fi
require_match 'resume' "${tmp_root}/recover.out"
require_match "agent-arena resume ${er_run}" "${tmp_root}/recover.out"
[[ "$er_rev" == "$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${er_run_dir}/run-state.tsv")" ]] || fail 'refused recover wrote state'
[[ ! -e "${er_run_dir}/.run-lock" ]] || fail 'refused recover left the run lock held'
# T13: cancel -> canceled/phase-kept/none/none with empty waiting_since
run_arena resolve "$er_run" --action cancel --reason 'abandoned' >/dev/null
require_match $'run_status\tcanceled' <(cat "${er_run_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${er_run_dir}/run-state.tsv")
require_match $'responsible_party\tnone' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_code\tnone' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_detail\tabandoned' <(cat "${er_run_dir}/run-state.tsv")
require_match $'waiting_since\t' <(cat "${er_run_dir}/run-state.tsv")
require_match $'last_transition_action\tresolve-cancel' <(cat "${er_run_dir}/run-state.tsv")
[[ ! -e "${er_run_dir}/.run-lock" ]] || fail 'cancel left the run lock held'
# T10: resolve approve after a reviewer APPROVE -> completed/decided/none/none
ap_run='ap-run'
run_arena start "$ap_run" --repo "$project" --no-attach >/dev/null
ap_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${ap_run}/manifest.tsv" -exec dirname {} \;)"
ap_writer="$(manifest_value "${ap_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' a >"${ap_writer}/a.txt"
git -C "$ap_writer" add a.txt
git -C "$ap_writer" commit -m 'feat: a' >/dev/null
run_arena submit "$ap_run" >/dev/null
run_arena validate "$ap_run" >/dev/null
run_arena decision "$ap_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
run_arena resolve "$ap_run" --action approve >/dev/null
require_match $'run_status\tcompleted' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'responsible_party\tnone' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'reason_code\tnone' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'validation_result\tPASS' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'waiting_since\t' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'last_transition_action\tresolve-approve' <(cat "${ap_run_dir}/run-state.tsv")
[[ ! -e "${ap_run_dir}/.run-lock" ]] || fail 'approve left the run lock held'
# T11: reject requires --reason and lands in active/decided/writer/
# human_changes_requested with the verdict kept
rj_run='rj-run'
run_arena start "$rj_run" --repo "$project" --no-attach >/dev/null
rj_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${rj_run}/manifest.tsv" -exec dirname {} \;)"
rj_writer="$(manifest_value "${rj_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' r >"${rj_writer}/r.txt"
git -C "$rj_writer" add r.txt
git -C "$rj_writer" commit -m 'feat: r' >/dev/null
run_arena submit "$rj_run" >/dev/null
run_arena validate "$rj_run" >/dev/null
run_arena decision "$rj_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
rj_pre_rev="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${rj_run_dir}/run-state.tsv")"
if run_arena resolve "$rj_run" --action reject >"${tmp_root}/rj.out" 2>&1; then
    fail 'reject without --reason succeeded'
fi
[[ "$rj_pre_rev" == "$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${rj_run_dir}/run-state.tsv")" ]] || \
    fail 'reject without --reason wrote state'
run_arena resolve "$rj_run" --action reject --reason 'needs rework' >/dev/null
require_match $'run_status\tactive' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'responsible_party\twriter' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'reason_code\thuman_changes_requested' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'reason_detail\tneeds rework' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'last_transition_action\tresolve-reject' <(cat "${rj_run_dir}/run-state.tsv")
[[ ! -e "${rj_run_dir}/.run-lock" ]] || fail 'reject left the run lock held'
# spec addition (1): escalate while human is responsible for another reason
# is an illegal transition (exit 2). block_run is blocked/decided/human/
# block_resolution_required from section 46.
bl_exit=0
run_arena escalate "$block_run" --reason-code reviewer_unreachable --reason x \
    >"${tmp_root}/bl-esc.out" 2>&1 || bl_exit=$?
[[ "$bl_exit" == 2 ]] || fail "escalate from block_resolution_required exited ${bl_exit}, expected 2"
require_match 'illegal transition' "${tmp_root}/bl-esc.out"
[[ ! -e "${block_run_dir}/.run-lock" ]] || fail 'refused escalate left the run lock held'
# spec addition (2): recover on a formal BLOCKED exits 2 even with a
# reachable reviewer pane
export FAKE_TMUX_MODE=relay
export FAKE_TMUX_PANES=normal
bl_exit=0
run_arena resolve "$block_run" --action recover --reason x \
    >"${tmp_root}/bl-rec.out" 2>&1 || bl_exit=$?
[[ "$bl_exit" == 2 ]] || fail "recover on formal BLOCKED exited ${bl_exit}, expected 2"
require_match 'operational escalation' "${tmp_root}/bl-rec.out"
[[ ! -e "${block_run_dir}/.run-lock" ]] || fail 'refused recover left the run lock held'
export FAKE_TMUX_MODE=offline
# spec addition (3): approve from BLOCKED exits 2 (v1 has no manual override)
bl_exit=0
run_arena resolve "$block_run" --action approve >"${tmp_root}/bl-app.out" 2>&1 || bl_exit=$?
[[ "$bl_exit" == 2 ]] || fail "approve from BLOCKED exited ${bl_exit}, expected 2"
require_match 'reviewer APPROVE' "${tmp_root}/bl-app.out"
# T11 from block_resolution_required: reject with the BLOCKED verdict kept
run_arena resolve "$block_run" --action reject --reason 'fix the block' >/dev/null
require_match $'run_status\tactive' <(cat "${block_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${block_run_dir}/run-state.tsv")
require_match $'responsible_party\twriter' <(cat "${block_run_dir}/run-state.tsv")
require_match $'reason_code\thuman_changes_requested' <(cat "${block_run_dir}/run-state.tsv")
require_match $'verdict\tBLOCKED' <(cat "${block_run_dir}/run-state.tsv")
[[ ! -e "${block_run_dir}/.run-lock" ]] || fail 'BLOCKED reject left the run lock held'
# AC8: legacy L5 (submitted/reviewer) admits escalate as its first migration
leg_repo="$(basename "$(dirname "$block_run_dir")")"
leg_er_run='legacy-l5-escalate'
leg_er_dir="${state_root}/runs/${leg_repo}/${leg_er_run}"
mkdir -p "$leg_er_dir"
awk -F $'\t' -v dir="$leg_er_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-l5-escalate" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-l5-escalate" }
    $1 == "session_name" { $2 = "agent-arena-legacy-l5-escalate" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${block_run_dir}/manifest.tsv" >"${leg_er_dir}/manifest.tsv"
cp "${block_run_dir}/review.tsv" "${leg_er_dir}/review.tsv"
run_arena escalate "$leg_er_run" --reason-code reviewer_unreachable --reason 'legacy dead pane' >/dev/null
require_match $'state_revision\t1' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'run_status\tblocked' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'reason_code\treviewer_unreachable' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${leg_er_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$block_sha" <(cat "${leg_er_dir}/run-state.tsv")
# AC8: legacy L1 (decided/human/approval_pending, plain v0.3 archive) admits
# resolve approve as its first migration
leg_ap_run='legacy-l1-approve'
leg_ap_dir="${state_root}/runs/${leg_repo}/${leg_ap_run}"
mkdir -p "$leg_ap_dir"
awk -F $'\t' -v dir="$leg_ap_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-l1-approve" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-l1-approve" }
    $1 == "session_name" { $2 = "agent-arena-legacy-l1-approve" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${block_run_dir}/manifest.tsv" >"${leg_ap_dir}/manifest.tsv"
cp "${block_run_dir}/review.tsv" "${leg_ap_dir}/review.tsv"
cp "${block_run_dir}/validation.md" "${leg_ap_dir}/validation.md"
cp "${block_run_dir}/validation-${block_sha:0:12}.md" "${leg_ap_dir}/validation-${block_sha:0:12}.md"
cat >"${leg_ap_dir}/decision-${block_sha:0:12}.md" <<EOF
# Agent Arena Gate Decision

Run: legacy-l1-approve

Review HEAD: ${block_sha}

VERDICT: APPROVE

## Summary

legacy approve

## Findings

- No additional findings.

## Next Step for Writer

go
EOF
run_arena resolve "$leg_ap_run" --action approve >/dev/null
require_match $'state_revision\t1' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'run_status\tcompleted' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'responsible_party\tnone' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'reason_code\tnone' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'validation_result\tPASS' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$block_sha" <(cat "${leg_ap_dir}/run-state.tsv")
require_match $'waiting_since\t' <(cat "${leg_ap_dir}/run-state.tsv")
# AC8: legacy L5 (submitted/reviewer) first-migration escalate on a
# hand-built review.tsv fixture (L-T3 pattern, no decision evidence) ->
# materializes v1 blocked/human/reviewer_unreachable, phase submitted,
# sticky unknown round, revision 1.
l5f_run='legacy-l5-escalate-recover'
l5f_dir="${state_root}/runs/${leg_repo}/${l5f_run}"
mkdir -p "$l5f_dir"
awk -F $'\t' -v dir="$l5f_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-l5-escalate-recover" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-l5-escalate-recover" }
    $1 == "session_name" { $2 = "agent-arena-legacy-l5-escalate-recover" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${block_run_dir}/manifest.tsv" >"${l5f_dir}/manifest.tsv"
l5f_sha='2222222222222222222222222222222222222222'
printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
    "$l5f_sha" "$project" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')" >"${l5f_dir}/review.tsv"
[[ ! -e "${l5f_dir}/run-state.tsv" ]] || fail 'legacy L5 fixture was not state-absent'
run_arena escalate "$l5f_run" --reason-code reviewer_unreachable --reason 'legacy dead pane' >/dev/null
require_match $'state_revision\t1' <(cat "${l5f_dir}/run-state.tsv")
require_match $'run_status\tblocked' <(cat "${l5f_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${l5f_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${l5f_dir}/run-state.tsv")
require_match $'reason_code\treviewer_unreachable' <(cat "${l5f_dir}/run-state.tsv")
require_match $'reason_detail\tlegacy dead pane' <(cat "${l5f_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${l5f_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$l5f_sha" <(cat "${l5f_dir}/run-state.tsv")
require_match $'last_transition_actor\thuman' <(cat "${l5f_dir}/run-state.tsv")
require_match $'last_transition_action\tescalate' <(cat "${l5f_dir}/run-state.tsv")
l5f_ws="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${l5f_dir}/run-state.tsv")"
l5f_lta="$(awk -F $'\t' '$1 == "last_transition_at" { print $2 }' "${l5f_dir}/run-state.tsv")"
[[ -n "$l5f_ws" && "$l5f_ws" == "$l5f_lta" ]] || \
    fail 'legacy escalate did not set waiting_since to last_transition_at'
[[ ! -e "${l5f_dir}/.run-lock" ]] || fail 'legacy escalate left the run lock held'
# T12 success: recover from the escalated legacy state above with a
# reachable reviewer pane (relay tmux) -> active/submitted/reviewer/
# review_pending, blocked flag cleared, revision bumped.
export FAKE_TMUX_MODE=relay
export FAKE_TMUX_PANES=normal
run_arena resolve "$l5f_run" --action recover --reason 'pane back' >/dev/null
require_match $'state_revision\t2' <(cat "${l5f_dir}/run-state.tsv")
require_match $'run_status\tactive' <(cat "${l5f_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${l5f_dir}/run-state.tsv")
require_match $'responsible_party\treviewer' <(cat "${l5f_dir}/run-state.tsv")
require_match $'reason_code\treview_pending' <(cat "${l5f_dir}/run-state.tsv")
require_match $'reason_detail\tpane back' <(cat "${l5f_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${l5f_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$l5f_sha" <(cat "${l5f_dir}/run-state.tsv")
require_match $'last_transition_actor\thuman' <(cat "${l5f_dir}/run-state.tsv")
require_match $'last_transition_action\tresolve-recover' <(cat "${l5f_dir}/run-state.tsv")
l5f_ws="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${l5f_dir}/run-state.tsv")"
[[ -n "$l5f_ws" ]] || fail 'recover did not reset waiting_since'
[[ ! -e "${l5f_dir}/.run-lock" ]] || fail 'recover left the run lock held'
export FAKE_TMUX_MODE=offline
# resume respawns a dead reviewer pane INSIDE the run lock
rs_run='rs-respawn'
run_arena start "$rs_run" --repo "$project" --no-attach >/dev/null
rs_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${rs_run}/manifest.tsv" -exec dirname {} \;)"
export FAKE_TMUX_MODE=relay
export FAKE_TMUX_PANES=reviewer-dead
export FAKE_TMUX_LOCK_CHECK="${rs_run_dir}/.run-lock"
: >"$fake_tmux_log"
set +e
run_arena resume "$rs_run" --repo "$project" >"${tmp_root}/rs-resume.out" 2>&1
rs_status=$?
set -e
echo "rs-resume-status=${rs_status}" >>"${tmp_root}/rs-resume.out"
cp "$fake_tmux_log" /tmp/rs-tmux.log 2>/dev/null || true
cp "${tmp_root}/rs-resume.out" /tmp/rs-resume.out 2>/dev/null || true
require_match 'respawn-pane -k -t %13 exec' "$fake_tmux_log"
require_match 'reviewer' "$fake_tmux_log"
require_match 'respawn-lock-present' "$fake_tmux_log"
[[ ! -e "${rs_run_dir}/.run-lock" ]] || fail 'resume left the run lock held'
unset FAKE_TMUX_LOCK_CHECK
export FAKE_TMUX_PANES=normal
export FAKE_TMUX_MODE=offline

printf '%s\n' '48. repair-state candidates and intent three-state recovery'
rp_repo_dir="${state_root}/runs/${leg_repo}"
rp_manifest_src="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv | head -1)"
rp_head='2222222222222222222222222222222222222222'
rp_old_head='3333333333333333333333333333333333333333'
rp_make_manifest() {
    local dir="$1" run="$2"
    awk -F $'\t' -v dir="$dir" -v run="$run" 'BEGIN { OFS = FS }
        $1 == "run_id" { $2 = run }
        $1 == "branch" { $2 = "agent-arena/pi/" run }
        $1 == "session_name" { $2 = "agent-arena-" run }
        $1 == "writer_session_dir" { $2 = dir "/writer-session" }
        { print }' "$rp_manifest_src" >"${dir}/manifest.tsv"
}
rp_review_tsv() {
    printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
        "$1" "$project" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')"
}
rp_candidates() {
    ARENA_SOURCE_ROOT="$source_root" bash -c '
        set -euo pipefail
        source "$1/lib/state.sh"
        arena_state_repair_candidates "$2"
    ' _ "$source_root" "$1" 2>/dev/null
}
rp_first_token() {
    local out="$1"
    sed -n 's/^repair-candidate \([0-9a-f]\{12\}\) ->.*/\1/p' "$out" | head -1
}
# (1) conflict fixture: a decision archive bound to a differing SHA yields
# exactly one repair-candidate; refusal-only conflicts print none; a stale
# token is rejected with 'stale'.
rp_run='repair-dec-conflict'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$rp_old_head" >"${rp_dir}/decision-${rp_old_head}.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-cand.out"
require_match 'repair-candidate' "${tmp_root}/rp-cand.out"
require_match 'active/submitted/reviewer/review_pending revision 1 checkpoint 222222222222' "${tmp_root}/rp-cand.out"
[[ "$(grep -c '^repair-candidate ' "${tmp_root}/rp-cand.out")" == 1 ]] || \
    fail 'conflict fixture did not print exactly one candidate'
rp_token="$(rp_first_token "${tmp_root}/rp-cand.out")"
[[ "$rp_token" =~ ^[0-9a-f]{12}$ ]] || fail 'candidate token is not 12 hex digits'
if run_arena repair-state "$rp_run" --candidate deadbeefdeadbeef --reason 'x' >"${tmp_root}/rp-stale.out" 2>&1; then
    fail 'repair-state accepted a stale token'
fi
require_match 'stale' "${tmp_root}/rp-stale.out"
[[ ! -e "${rp_dir}/run-state.tsv" ]] || fail 'stale repair wrote a state file'
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'stale repair left an intent'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'stale repair left the run lock held'
# refusal-only: orphan evidence with no review.tsv prints no candidate
rp_run='repair-orphan-refusal'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "4444444444444444444444444444444444444444" >"${rp_dir}/decision-4444444444444444444444444444444444444444.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-ref.out"
require_no_match 'repair-candidate' "${tmp_root}/rp-ref.out"
# refusal-only: pointer without a canonical report prints no candidate
rp_run='repair-pointer-refusal'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf '%s\n' 'Latest validation report: validation-aaaaaaaaaaaa.md' >"${rp_dir}/validation.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-ref2.out"
require_no_match 'repair-candidate' "${tmp_root}/rp-ref2.out"
# (2) a fresh candidate token executes the repair: the orphan decision is
# tombstoned under orphaned/, v1 state written, intent removed.
rp_dir="${rp_repo_dir}/repair-dec-conflict"
run_arena repair-state repair-dec-conflict --candidate "$rp_token" --reason 'tombstone orphan decision' >"${tmp_root}/rp-accept.out" 2>&1 || \
    fail 'fresh repair candidate token was rejected'
[[ ! -e "${rp_dir}/decision-${rp_old_head}.md" ]] || fail 'orphan decision archive was not tombstoned'
rp_orphan="$(find "${rp_dir}/orphaned" -maxdepth 1 -type f 2>/dev/null | head -1)"
[[ -n "$rp_orphan" ]] || fail 'no tombstoned file under orphaned/'
[[ "$(basename "$rp_orphan")" == "decision-${rp_old_head}.md."* ]] || fail "unexpected tombstone name $(basename "$rp_orphan")"
require_match $'state_revision\t1' <(cat "${rp_dir}/run-state.tsv")
require_match $'run_status\tactive' <(cat "${rp_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${rp_dir}/run-state.tsv")
require_match $'responsible_party\treviewer' <(cat "${rp_dir}/run-state.tsv")
require_match $'reason_code\treview_pending' <(cat "${rp_dir}/run-state.tsv")
require_match $'reason_detail\ttombstone orphan decision' <(cat "${rp_dir}/run-state.tsv")
require_match $'checkpoint_round\tunknown' <(cat "${rp_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$rp_head" <(cat "${rp_dir}/run-state.tsv")
require_match $'last_transition_actor\tsystem' <(cat "${rp_dir}/run-state.tsv")
require_match $'last_transition_action\trepair-state' <(cat "${rp_dir}/run-state.tsv")
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'repair-state left the intent behind'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'repair-state left the run lock held'
rp_candidates "$rp_dir" >"${tmp_root}/rp-post.out"
require_no_match 'repair-candidate' "${tmp_root}/rp-post.out"
# (3a) intent with the state still at the original baseline: the owner
# continues the tombstone/commit sequence from the intent (the stale token
# is irrelevant).
rp_run='repair-intent-continue'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$rp_old_head" >"${rp_dir}/decision-${rp_old_head}.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-a-cand.out"
rp_a_token="$(rp_first_token "${tmp_root}/rp-a-cand.out")"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    run_dir="$2"
    arena_state_repair_candidates "$run_dir" "$3"
    [[ "$ARENA_REPAIR_MATCH" == 1 ]] || exit 9
    now="$(date +%s)"
    arena_state_repair_pairs "$now" "$now" "intent reason" "$ARENA_REPAIR_TARGET_REVISION"
    arena_state_repair_verify "$run_dir" || exit 9
    arena_repair_intent_write "$run_dir" "$ARENA_REPAIR_BASELINE_STRING" "$ARENA_REPAIR_EVIDENCE_DIGEST" \
        "$3" "intent reason" "$ARENA_REPAIR_TARGET_DIGEST" "$ARENA_REPAIR_PAYLOAD_X1F" "" "$ARENA_REPAIR_TOMBSTONES" "1700000000"
' _ "$source_root" "$rp_dir" "$rp_a_token" || fail 'could not pre-write the repair intent'
run_arena repair-state "$rp_run" --candidate deadbeefdeadbeef --reason 'x' >"${tmp_root}/rp-a.out" 2>&1 || \
    fail 'intent recovery (a) rejected the repair'
[[ ! -e "${rp_dir}/decision-${rp_old_head}.md" ]] || fail 'intent recovery did not tombstone the orphan'
[[ -e "${rp_dir}/orphaned/decision-${rp_old_head}.md.1700000000" ]] || fail 'intent recovery tombstone landed in the wrong place'
require_match $'reason_detail\tintent reason' <(cat "${rp_dir}/run-state.tsv")
require_match $'state_revision\t1' <(cat "${rp_dir}/run-state.tsv")
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'intent recovery left the intent behind'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'intent recovery left the run lock held'
# (3b) intent with the state already at the target digest: zero-write
# finish removes the intent and rewrites nothing.
rp_run='repair-intent-committed'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$rp_old_head" >"${rp_dir}/decision-${rp_old_head}.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-b-cand.out"
rp_b_token="$(rp_first_token "${tmp_root}/rp-b-cand.out")"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    run_dir="$2"
    arena_state_repair_candidates "$run_dir" "$3"
    [[ "$ARENA_REPAIR_MATCH" == 1 ]] || exit 9
    now="$(date +%s)"
    arena_state_repair_pairs "$now" "$now" "intent reason" "$ARENA_REPAIR_TARGET_REVISION"
    arena_state_repair_verify "$run_dir" || exit 9
    arena_state_write "$run_dir" "${ARENA_REPAIR_PAIRS[@]}"
    arena_repair_intent_write "$run_dir" "$ARENA_REPAIR_BASELINE_STRING" "$ARENA_REPAIR_EVIDENCE_DIGEST" \
        "$3" "intent reason" "$ARENA_REPAIR_TARGET_DIGEST" "$ARENA_REPAIR_PAYLOAD_X1F" "" "$ARENA_REPAIR_TOMBSTONES" "1700000000"
' _ "$source_root" "$rp_dir" "$rp_b_token" || fail 'could not pre-write the committed repair intent'
rp_b_before="$(shasum -a 256 "${rp_dir}/run-state.tsv" | awk '{print $1}')"
run_arena repair-state "$rp_run" --candidate "$rp_b_token" --reason 'x' >"${tmp_root}/rp-b.out" 2>&1 || \
    fail 'intent recovery (b) rejected the repair'
require_match 'repair already committed' "${tmp_root}/rp-b.out"
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'zero-write finish left the intent'
rp_b_after="$(shasum -a 256 "${rp_dir}/run-state.tsv" | awk '{print $1}')"
[[ "$rp_b_after" == "$rp_b_before" ]] || fail 'zero-write finish rewrote the state file'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'zero-write finish left the run lock held'
# (3c) hand-altered state under an intent fails closed (exit 2), keeping
# the intent for inspection.
rp_run='repair-intent-tampered'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$rp_old_head" >"${rp_dir}/decision-${rp_old_head}.md"
rp_candidates "$rp_dir" >"${tmp_root}/rp-c-cand.out"
rp_c_token="$(rp_first_token "${tmp_root}/rp-c-cand.out")"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    run_dir="$2"
    arena_state_repair_candidates "$run_dir" "$3"
    [[ "$ARENA_REPAIR_MATCH" == 1 ]] || exit 9
    now="$(date +%s)"
    arena_state_repair_pairs "$now" "$now" "intent reason" "$ARENA_REPAIR_TARGET_REVISION"
    arena_state_repair_verify "$run_dir" || exit 9
    arena_repair_intent_write "$run_dir" "$ARENA_REPAIR_BASELINE_STRING" "$ARENA_REPAIR_EVIDENCE_DIGEST" \
        "$3" "intent reason" "$ARENA_REPAIR_TARGET_DIGEST" "$ARENA_REPAIR_PAYLOAD_X1F" "" "$ARENA_REPAIR_TOMBSTONES" "1700000000"
' _ "$source_root" "$rp_dir" "$rp_c_token" || fail 'could not pre-write the tampered repair intent'
printf 'tampered\n' >"${rp_dir}/run-state.tsv"
rp_c_exit=0
run_arena repair-state "$rp_run" --candidate "$rp_c_token" --reason 'x' >"${tmp_root}/rp-c.out" 2>&1 || rp_c_exit=$?
[[ "$rp_c_exit" == 2 ]] || fail "tampered-state recovery exited ${rp_c_exit}, expected 2"
require_match 'failing closed' "${tmp_root}/rp-c.out"
[[ -e "${rp_dir}/.repair.intent" ]] || fail 'fail-closed path removed the intent'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'fail-closed path left the run lock held'
# (4) corrupted state file: the candidate is bound to the corrupted-file
# digest; repair-state audit-copies and replaces it with a fresh valid v1
# projection (revision 1).
rp_run='repair-corrupt-replace'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
{
    printf 'schema_version\t1\n'
    printf 'state_revision\t1\n'
    printf 'run_status\tbogus\n'
    printf 'phase\tintake\n'
    printf 'responsible_party\twriter\n'
    printf 'reason_code\tnone\n'
    printf 'reason_detail\t\n'
    printf 'verdict\t\n'
    printf 'validation_result\t\n'
    printf 'checkpoint_round\t0\n'
    printf 'checkpoint_sha\t\n'
    printf 'waiting_since\t1\n'
    printf 'last_transition_at\t1\n'
    printf 'last_transition_actor\tsystem\n'
    printf 'last_transition_action\tstart\n'
    printf 'validation_digest\t\n'
} >"${rp_dir}/run-state.tsv"
rp_k_bad="$(shasum -a 256 "${rp_dir}/run-state.tsv" | awk '{print $1}')"
rp_candidates "$rp_dir" >"${tmp_root}/rp-k-cand.out"
rp_k_token="$(rp_first_token "${tmp_root}/rp-k-cand.out")"
[[ -n "$rp_k_token" ]] || fail 'corrupted-state fixture printed no repair candidate'
run_arena repair-state "$rp_run" --candidate "$rp_k_token" --reason 'replace corrupted state' >"${tmp_root}/rp-k.out" 2>&1 || \
    fail 'corrupted-state replacement was rejected'
rp_k_audit="$(find "$rp_dir" -maxdepth 1 -name 'run-state.tsv.corrupt.*' -type f | head -1)"
[[ -n "$rp_k_audit" ]] || fail 'corrupted state file was not audit-copied'
[[ "$(shasum -a 256 "$rp_k_audit" | awk '{print $1}')" == "$rp_k_bad" ]] || fail 'audit copy differs from the corrupted file'
[[ "$(shasum -a 256 "${rp_dir}/run-state.tsv" | awk '{print $1}')" != "$rp_k_bad" ]] || fail 'corrupted state file was not replaced'
require_match $'state_revision\t1' <(cat "${rp_dir}/run-state.tsv")
require_match $'run_status\tactive' <(cat "${rp_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${rp_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$rp_head" <(cat "${rp_dir}/run-state.tsv")
require_match $'reason_detail\treplace corrupted state' <(cat "${rp_dir}/run-state.tsv")
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_read "$2"
' _ "$source_root" "$rp_dir" || fail 'replacement state file does not validate'
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'corrupt replacement left the intent behind'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'corrupt replacement left the run lock held'
# a future schema version has no recovery path: no candidate is printed
rp_run='repair-future-schema'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'schema_version\t99\n' >"${rp_dir}/run-state.tsv"
rp_candidates "$rp_dir" >"${tmp_root}/rp-future.out"
require_no_match 'repair-candidate' "${tmp_root}/rp-future.out"
# .diagnostic.md files are audit-only: the projection's Val scan never
# picks them up as canonical evidence (Task 6 deferred this exclusion here).
rp_run='repair-diag-exclusion'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
printf 'Review HEAD: %s\nRESULT: FAIL\n' "$rp_head" >"${rp_dir}/validation-${rp_head:0:12}.diagnostic.md"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == submitted && -z "$ARENA_PROJECTED_CONFLICTS" ]] || exit 9
' _ "$source_root" "$rp_dir" || fail 'diagnostic report leaked into the Val scan'
rm "${rp_dir}/review.tsv"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == intake && -z "$ARENA_PROJECTED_CONFLICTS" ]] || exit 9
' _ "$source_root" "$rp_dir" || fail 'diagnostic report leaked into the orphan scan'
# valid-v1 evidence-conflict: checkpoint_sha disagrees with review.tsv (no
# owning command can recover) -> candidate, then repair bumps the revision
# and preserves waiting_since (same responsible party and reason).
rp_run='repair-v1-conflict'
rp_dir="${rp_repo_dir}/${rp_run}"
mkdir -p "$rp_dir"
rp_make_manifest "$rp_dir" "$rp_run"
rp_review_tsv "$rp_head" >"${rp_dir}/review.tsv"
{
    printf 'schema_version\t1\n'
    printf 'state_revision\t1\n'
    printf 'run_status\tactive\n'
    printf 'phase\tsubmitted\n'
    printf 'responsible_party\treviewer\n'
    printf 'reason_code\treview_pending\n'
    printf 'reason_detail\t\n'
    printf 'verdict\t\n'
    printf 'validation_result\t\n'
    printf 'checkpoint_round\tunknown\n'
    printf 'checkpoint_sha\t1111111111111111111111111111111111111111\n'
    printf 'waiting_since\t111\n'
    printf 'last_transition_at\t222\n'
    printf 'last_transition_actor\twriter\n'
    printf 'last_transition_action\tsubmit\n'
    printf 'validation_digest\t\n'
} >"${rp_dir}/run-state.tsv"
rp_candidates "$rp_dir" >"${tmp_root}/rp-v-cand.out"
rp_v_token="$(rp_first_token "${tmp_root}/rp-v-cand.out")"
[[ -n "$rp_v_token" ]] || fail 'valid-v1 evidence conflict printed no repair candidate'
run_arena repair-state "$rp_run" --candidate "$rp_v_token" --reason 'checkpoint head drift' >"${tmp_root}/rp-v.out" 2>&1 || \
    fail 'valid-v1 conflict repair was rejected'
require_match $'state_revision\t2' <(cat "${rp_dir}/run-state.tsv")
require_match $'checkpoint_sha\t'"$rp_head" <(cat "${rp_dir}/run-state.tsv")
require_match $'waiting_since\t111' <(cat "${rp_dir}/run-state.tsv")
require_match $'reason_detail\tcheckpoint head drift' <(cat "${rp_dir}/run-state.tsv")
require_match $'phase\tsubmitted' <(cat "${rp_dir}/run-state.tsv")
[[ ! -e "${rp_dir}/.repair.intent" ]] || fail 'valid-v1 repair left the intent behind'
[[ ! -e "${rp_dir}/.run-lock" ]] || fail 'valid-v1 repair left the run lock held'

printf '%s\n' '49. status and list oracles'
# one-sentence diagnosis for a normal v1 run
or_run='or-run'
run_arena start "$or_run" --repo "$project" --no-attach >/dev/null
or_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${or_run}/manifest.tsv" -exec dirname {} \;)"
or_repo="$(basename "$(dirname "$or_run_dir")")"
or_writer="$(manifest_value "${or_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' o >"${or_writer}/o.txt"
git -C "$or_writer" add o.txt
git -C "$or_writer" commit -m 'feat: o' >/dev/null
run_arena submit "$or_run" >/dev/null
find "${or_run_dir}" -type f | sort >"${tmp_root}/or-files-before.list"
run_arena status "$or_run" >"${tmp_root}/or-status.out"
require_match 'waiting on reviewer for review_pending' "${tmp_root}/or-status.out"
require_match 'tmux session: not running' "${tmp_root}/or-status.out"
require_match 'release: agent-arena validate or-run' "${tmp_root}/or-status.out"
# status is zero-write: the run directory gains no files
find "${or_run_dir}" -type f | sort >"${tmp_root}/or-files-after.list"
cmp -s "${tmp_root}/or-files-before.list" "${tmp_root}/or-files-after.list" || \
    fail 'status wrote files into the run directory'
# status/list never return 3 or 10
run_arena status "$or_run" >/dev/null 2>&1 || { ec=$?; [[ "$ec" == 3 || "$ec" == 10 ]] && fail "status returned $ec"; }
# usage errors remain exit 1 for both oracles
run_arena status >/dev/null 2>&1 || { ec=$?; [[ "$ec" == 1 ]] || fail "status usage exited $ec"; }
run_arena list --bogus >/dev/null 2>&1 || { ec=$?; [[ "$ec" == 1 ]] || fail "list usage exited $ec"; }
# legacy conflict: status prints the conflict list plus the same repair
# candidate the helper computes, with the discarded-evidence list
or_conf_run='or-conflict'
or_conf_dir="${state_root}/runs/${or_repo}/${or_conf_run}"
mkdir -p "$or_conf_dir"
awk -F $'\t' -v dir="$or_conf_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "or-conflict" }
    $1 == "branch" { $2 = "agent-arena/pi/or-conflict" }
    $1 == "session_name" { $2 = "agent-arena-or-conflict" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${or_run_dir}/manifest.tsv" >"${or_conf_dir}/manifest.tsv"
cp "${or_run_dir}/review.tsv" "${or_conf_dir}/review.tsv"
or_conf_old='3333333333333333333333333333333333333333'
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "$or_conf_old" >"${or_conf_dir}/decision-${or_conf_old}.md"
rp_candidates "$or_conf_dir" >"${tmp_root}/or-cand.out"
or_token="$(rp_first_token "${tmp_root}/or-cand.out")"
[[ "$or_token" =~ ^[0-9a-f]{12}$ ]] || fail 'oracle candidate token is not 12 hex digits'
set +e
run_arena status or-conflict >"${tmp_root}/or-conflict.out" 2>&1
or_conflict_exit=$?
set -e
[[ "$or_conflict_exit" == 2 ]] || fail "status conflict exited $or_conflict_exit, expected 2"
require_match 'legacy evidence conflicts:' "${tmp_root}/or-conflict.out"
require_match 'decision archive bound to differing SHA' "${tmp_root}/or-conflict.out"
require_match "repair-candidate ${or_token} ->" "${tmp_root}/or-conflict.out"
require_match 'discarded evidence' "${tmp_root}/or-conflict.out"
require_match "decision-${or_conf_old}.md" "${tmp_root}/or-conflict.out"
rm -rf "$or_conf_dir"
# refusal-only conflict (orphan evidence without review.tsv): the conflict
# prints, no repair-candidate line, exit 2
or_ref_run='or-refusal'
or_ref_dir="${state_root}/runs/${or_repo}/${or_ref_run}"
mkdir -p "$or_ref_dir"
awk -F $'\t' -v dir="$or_ref_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "or-refusal" }
    $1 == "branch" { $2 = "agent-arena/pi/or-refusal" }
    $1 == "session_name" { $2 = "agent-arena-or-refusal" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${or_run_dir}/manifest.tsv" >"${or_ref_dir}/manifest.tsv"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "4444444444444444444444444444444444444444" >"${or_ref_dir}/decision-4444444444444444444444444444444444444444.md"
set +e
run_arena status or-refusal >"${tmp_root}/or-refusal.out" 2>&1
or_refusal_exit=$?
set -e
[[ "$or_refusal_exit" == 2 ]] || fail "status refusal exited $or_refusal_exit, expected 2"
require_match 'legacy evidence conflicts:' "${tmp_root}/or-refusal.out"
require_match 'orphan evidence with no review.tsv' "${tmp_root}/or-refusal.out"
require_no_match 'repair-candidate' "${tmp_root}/or-refusal.out"
require_no_match 'discarded evidence' "${tmp_root}/or-refusal.out"
rm -rf "$or_ref_dir"
# remove the leftovers that still carry anomalies (an orphan conflict, a
# future-schema corrupt state, a fail-closed repair intent, a refusal-only
# pointer conflict, and the section-42 creation-intent mismatch) so the
# list aggregation below sees a clean runs root
rm -rf "${rp_repo_dir}/repair-orphan-refusal" "${rp_repo_dir}/repair-future-schema" "${rp_repo_dir}/repair-intent-tampered" "${rp_repo_dir}/repair-pointer-refusal"
rm -rf "${state_root}/runs/${s5b_repo}/s5-mismatch" "${state_root}/runs/${s5b_repo}/.creating-s5-mismatch"
# corrupted state file: status fails closed with exit 2 and the
# corruption message, without touching the file
cp "${or_run_dir}/run-state.tsv" "${tmp_root}/or-state-backup.tsv"
{ cat "${or_run_dir}/run-state.tsv"; printf 'run_status\tactive\n'; } >"${or_run_dir}/run-state.tsv.corrupt"
mv "${or_run_dir}/run-state.tsv.corrupt" "${or_run_dir}/run-state.tsv"
or_corrupt_hash="$(shasum -a 256 "${or_run_dir}/run-state.tsv" | awk '{print $1}')"
set +e
run_arena status "$or_run" >"${tmp_root}/or-corrupt.out" 2>&1
or_corrupt_exit=$?
set -e
[[ "$or_corrupt_exit" == 2 ]] || fail "status corrupt exit $or_corrupt_exit, expected 2"
require_match 'corrupted state file' "${tmp_root}/or-corrupt.out"
[[ "$(shasum -a 256 "${or_run_dir}/run-state.tsv" | awk '{print $1}')" == "$or_corrupt_hash" ]] || \
    fail 'status modified the corrupted state file'
mv "${tmp_root}/or-state-backup.tsv" "${or_run_dir}/run-state.tsv"
chmod 600 "${or_run_dir}/run-state.tsv"
# creation intent with no live owner: S6 -> exit 5 retry:start (owned by
# start), S4 -> the manual abort protocol with exit 2
printf 'run_id\t%s\n' "$or_run" >"${state_root}/runs/${or_repo}/.creating-${or_run}"
set +e
run_arena status "$or_run" >"${tmp_root}/or-creation-intent.out" 2>&1
or_creation_exit=$?
set -e
[[ "$or_creation_exit" == 5 ]] || fail "status creation intent exited $or_creation_exit, expected 5"
require_match 'incomplete transition; retry: agent-arena start or-run' "${tmp_root}/or-creation-intent.out"
mv "$or_writer" "${or_writer}.moved"
set +e
run_arena status "$or_run" >"${tmp_root}/or-creation-s4.out" 2>&1
or_creation_s4_exit=$?
set -e
[[ "$or_creation_s4_exit" == 2 ]] || fail "status creation intent S4 exited $or_creation_s4_exit, expected 2"
require_match 'interrupted start stage S4' "${tmp_root}/or-creation-s4.out"
mv "${or_writer}.moved" "$or_writer"
rm -f "${state_root}/runs/${or_repo}/.creating-${or_run}"
# repair intent with no live lock: exit 5 with the exact retry, before any
# ordinary state parse
printf 'baseline\tabsent\nevidence\t%s\ntoken\t%s\nreason\ttest oracle\ntarget_digest\t%s\ntarget_payload\tplaceholder\naudit_copy\t\nmove_map\t\nstamp\t%s\n' \
    "$(printf x | shasum -a 256 | awk '{print $1}')" "aaaaaaaaaaaa" \
    "$(printf y | shasum -a 256 | awk '{print $1}')" "$(date +%s)" \
    >"${or_run_dir}/.repair.intent"
set +e
run_arena status "$or_run" >"${tmp_root}/or-repair-intent.out" 2>&1
or_repair_exit=$?
set -e
[[ "$or_repair_exit" == 5 ]] || fail "status repair intent exited $or_repair_exit, expected 5"
require_match 'incomplete transition; retry: agent-arena repair-state or-run --candidate <token> --reason "..."' "${tmp_root}/or-repair-intent.out"
rm -f "${or_run_dir}/.repair.intent"
# live lock: 'transition in progress' exit 4 always wins
mkdir -p "${or_run_dir}/.run-lock"
printf 'pid=%s\ntoken=test-live-owner\ncreated_at=%s\n' "$$" "$(date +%s)" >"${or_run_dir}/.run-lock/owner"
set +e
run_arena status "$or_run" >"${tmp_root}/or-lock.out" 2>&1
or_lock_exit=$?
set -e
[[ "$or_lock_exit" == 4 ]] || fail "status live lock exited $or_lock_exit, expected 4"
require_match 'transition in progress' "${tmp_root}/or-lock.out"
rm -rf "${or_run_dir}/.run-lock"
# list fixed columns, the authoritative or-run row, and a legacy row that
# carries the read-only projection
run_arena list >"${tmp_root}/or-list.out"
require_match 'REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY' "${tmp_root}/or-list.out"
require_match 'or-run' "${tmp_root}/or-list.out"
or_row="$(awk '$2 == "or-run" { print; exit }' "${tmp_root}/or-list.out")"
[[ -n "$or_row" ]] || fail 'list has no or-run row'
[[ "$(list_column "$or_row" 6)" == submitted ]] || \
    fail 'list or-run row does not report phase submitted'
[[ "$(list_column "$or_row" 10)" == state ]] || \
    fail 'list or-run row is not authoritative state'
[[ "$(list_column "$or_row" 11)" == '' ]] || fail 'list or-run row carries an anomaly'
or_legacy_run='legacy-list-row'
or_legacy_dir="${state_root}/runs/${or_repo}/${or_legacy_run}"
mkdir -p "$or_legacy_dir"
awk -F $'\t' -v dir="$or_legacy_dir" 'BEGIN { OFS = FS }
    $1 == "run_id" { $2 = "legacy-list-row" }
    $1 == "branch" { $2 = "agent-arena/pi/legacy-list-row" }
    $1 == "session_name" { $2 = "agent-arena-legacy-list-row" }
    $1 == "writer_session_dir" { $2 = dir "/writer-session" }
    { print }' "${or_run_dir}/manifest.tsv" >"${or_legacy_dir}/manifest.tsv"
cp "${or_run_dir}/review.tsv" "${or_legacy_dir}/review.tsv"
run_arena list >"${tmp_root}/or-legacy-list.out"
or_legacy_row="$(awk '$2 == "legacy-list-row" { print; exit }' "${tmp_root}/or-legacy-list.out")"
[[ -n "$or_legacy_row" ]] || fail 'list has no legacy-list-row row'
[[ "$(list_column "$or_legacy_row" 6)" == submitted ]] || \
    fail 'legacy list row does not project phase submitted'
[[ "$(list_column "$or_legacy_row" 7)" == reviewer ]] || \
    fail 'legacy list row does not project party reviewer'
[[ "$(list_column "$or_legacy_row" 10)" == legacy ]] || \
    fail 'legacy list row is not marked legacy'
[[ "$(list_column "$or_legacy_row" 11)" == '' ]] || fail 'legacy list row carries an anomaly'
# legacy status: read-only projection with the diagnosis sentence
run_arena status "$or_legacy_run" >"${tmp_root}/or-legacy-status.out"
require_match 'legacy / inferred, not persisted' "${tmp_root}/or-legacy-status.out"
require_match 'waiting on reviewer for review_pending since unknown' "${tmp_root}/or-legacy-status.out"
# list aggregation: one live-locked run plus normal runs -> exit 4, and the
# locked row is marked in-progress
mkdir -p "${or_run_dir}/.run-lock"
printf 'pid=%s\ntoken=test-live-owner\ncreated_at=%s\n' "$$" "$(date +%s)" >"${or_run_dir}/.run-lock/owner"
set +e
run_arena list >"${tmp_root}/or-aggregate.out" 2>&1
or_aggregate_exit=$?
set -e
[[ "$or_aggregate_exit" == 4 ]] || fail "list aggregation exited $or_aggregate_exit, expected 4"
or_locked_row="$(awk '$2 == "or-run" { print; exit }' "${tmp_root}/or-aggregate.out")"
[[ -n "$or_locked_row" ]] || fail 'aggregated list has no or-run row'
[[ "$(list_column "$or_locked_row" 11)" == in-progress ]] || \
    fail 'locked or-run row is not marked in-progress'
rm -rf "${or_run_dir}/.run-lock"

printf '%s\n' '50. lock reclamation: two concurrent claimers, exactly one wins'
lock_root="${tmp_root}/reap-locks"
mkdir -p "$lock_root"
mkdir -p "$lock_root/one"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"$lock_root/one/owner"
# two backgrounded claimers race the same dead lock; exactly one may win
for claim in claim-a claim-b; do
    ARENA_SOURCE_ROOT="$source_root" bash -c '
        set -euo pipefail
        source "$1/lib/lock.sh"
        arena_lock_acquire "$2" "$3" >/dev/null 2>&1 && exit 0 || exit 1
    ' _ "$source_root" "$lock_root/one" "$claim" &
done
wait
wins=0
for claim in claim-a claim-b; do
    token="$(ARENA_SOURCE_ROOT="$source_root" bash -c '
        set -euo pipefail
        source "$1/lib/lock.sh"
        arena_lock_owner_token "$2"
    ' _ "$source_root" "$lock_root/one" 2>/dev/null)"
    [[ "$token" == "$claim" ]] && wins=$((wins + 1))
done
[[ "$wins" == 1 ]] || fail "expected exactly one winner, got $wins"
# owner carries last_seen_at after acquire and arena_lock_touch refreshes it
lock_winner="$(ARENA_SOURCE_ROOT="$source_root" bash -c '
    source "$1/lib/lock.sh"
    arena_lock_owner_token "$2"
' _ "$source_root" "$lock_root/one")"
[[ -n "$lock_winner" ]] || fail 'no lock winner recorded'
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    grep -q "^last_seen_at=" "$2/owner" || exit 9
    arena_lock_touch "$2" "$3" || exit 10
    grep -q "^last_seen_at=" "$2/owner" || exit 11
' _ "$source_root" "$lock_root/one" "$lock_winner" || fail 'last_seen_at contract broken'
# token mismatch on touch fails (no refresh)
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_touch "$2" wrong-token && exit 9 || exit 0
' _ "$source_root" "$lock_root/one" || fail 'touch with wrong token succeeded'
# reclamation raced by a second claimer: fails closed with exit 4, owner untouched
mkdir -p "$lock_root/two"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"$lock_root/two/owner"
set +e
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    # occupy the would-be tombstone path (same shell, same $$) with a FILE
    # so the mv cannot complete; the claimer must fail closed with exit 4
    touch "$2.reap.blocker.$$"
    arena_lock_acquire "$2" blocker && exit 9
' _ "$source_root" "$lock_root/two" >/dev/null 2>&1
reap_exit=$?
set -e
[[ "$reap_exit" == 4 ]] || fail "reclamation race exited $reap_exit, expected 4"
grep -q "^token=dead$" "$lock_root/two/owner" ||     fail 'failed reclamation mutated the owner'
rm -f "$lock_root/two.reap.blocker."*


printf '%s\n' '51. approval mode config, switch, drift, and intent binding'
git -C "$project" status --porcelain=v1 --untracked-files=all >&2 || true
sleep 1
git -C "$project" status --porcelain=v1 --untracked-files=all >&2 || true
# init template carries approval_mode with the risk comment
require_match 'approval_mode="human"' "${project}/.agent-arena/project.conf"
require_match 'approval_mode' "${project}/.agent-arena/project.conf"
# strict parser still rejects unknown keys
cat >"${tmp_root}/bad.conf" <<'EOF'
project_name="x"
validation_script=".agent-arena/validate.sh"
bogus_key="y"
EOF
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/config.sh"
    arena_load_project_config "$2"
' _ "$source_root" "$tmp_root/bad.conf" 2>/dev/null; then
    fail 'config parser accepted an unknown key'
fi
# start snapshots the effective mode into the manifest
run_arena start mode-run --repo "$project" --no-attach >/dev/null
mode_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -name manifest.tsv -path '*/mode-run/manifest.tsv' -exec dirname {} \;)"
require_match $'mode\thuman' <(cat "${mode_dir}/manifest.tsv")
require_match $'mode_actor\tsystem' <(cat "${mode_dir}/manifest.tsv")
require_match $'mode_updated_at\t' <(cat "${mode_dir}/manifest.tsv")
# status shows Mode plus the extended oracle lines
run_arena status mode-run >"${tmp_root}/mode-status.out"
require_match 'Mode: human' "${tmp_root}/mode-status.out"
require_match 'Verdict: not recorded' "${tmp_root}/mode-status.out"
require_match 'Validation result: not run' "${tmp_root}/mode-status.out"
require_match 'Last transition at: ' "${tmp_root}/mode-status.out"
# start --mode auto overrides the config for the run
run_arena start mode-auto-run --repo "$project" --mode auto --no-attach >/dev/null
mode_auto_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -name manifest.tsv -path '*/mode-auto-run/manifest.tsv' -exec dirname {} \;)"
require_match $'mode\tauto' <(cat "${mode_auto_dir}/manifest.tsv")
# --mode with an illegal value dies at parse time (before any preflight)
if run_arena start mode-bad-run --repo "$project" --mode bogus --no-attach >"${tmp_root}/mode-bad.out" 2>&1; then
    fail 'start --mode bogus succeeded'
fi
require_match 'invalid --mode' "${tmp_root}/mode-bad.out"
# mode switch: human -> auto under the run lock, recorded with actor
run_arena mode mode-run auto >/dev/null
require_match $'mode\tauto' <(cat "${mode_dir}/manifest.tsv")
require_match $'mode_actor\thuman' <(cat "${mode_dir}/manifest.tsv")
# unchanged switch is idempotent
run_arena mode mode-run auto >"${tmp_root}/mode-unchanged.out"
require_match 'unchanged' "${tmp_root}/mode-unchanged.out"
# drift: manifest mode != project.conf mode shows the warning marker.
# start first (config still human -> manifest human, repo clean), then flip
# the config and observe the marker via status (status reads config directly).
run_arena start mode-drift-run --repo "$project" --no-attach >/dev/null
printf 'approval_mode="auto"\n' >>"${project}/.agent-arena/project.conf"
run_arena status mode-drift-run >"${tmp_root}/mode-drift3.out"
require_match 'Mode: human (config: auto) ⚠' "${tmp_root}/mode-drift3.out"
git -C "$project" checkout -- .agent-arena/project.conf
git -C "$project" update-index --refresh >/dev/null 2>&1 || true
# matching config after restore shows the marker for the auto-manifest run
run_arena status mode-auto-run >"${tmp_root}/mode-drift4.out"
require_match 'Mode: auto (config: human) ⚠' "${tmp_root}/mode-drift4.out"
# intent binding: interrupted start retried after a mode change fails closed
mode_bind_run='mode-bind-run'
run_arena start "$mode_bind_run" --repo "$project" --no-attach >/dev/null
mode_bind_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -name manifest.tsv -path "*/${mode_bind_run}/manifest.tsv" -exec dirname {} \;)"
mode_bind_repo="$(basename "$(dirname "$mode_bind_dir")")"
mode_bind_base="$(git -C "$project" rev-parse HEAD)"
rm -f "${mode_bind_dir}/run-state.tsv"
# bind an intent with mode=human using the same resolved paths start uses
# (arena_abs_dir resolves /var -> /private/var on macOS), so only the mode
# differs when the retry passes --mode auto
mode_bind_repo_path="$(CDPATH='' cd -- "$project" && pwd -P)"
mode_bind_worktree_base="$(CDPATH='' cd -- "$worktree_base" && pwd -P)"
mode_bind_state_root="$(CDPATH='' cd -- "$state_root" && pwd -P)"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_creation_intent_write "$2/runs" "$3" "$4" \
        "repository=$5" "state_root=$2" "worktree_root=$6" \
        "profile=pi-cursor" "gate_adapter=cursor" \
        "session_name=agent-arena-$3-$4" "base_sha=$7" \
        "branch=agent-arena/pi/$4" "writer_worktree=$6/$3/$4/writer" \
        "writer_adapter_path=$1/adapters/pi.sh" \
        "gate_adapter_path=$1/adapters/gate-cursor.sh" \
        "mode=human"
' _ "$source_root" "$mode_bind_state_root" "$mode_bind_repo" "$mode_bind_run" "$mode_bind_repo_path" "$mode_bind_worktree_base" "$mode_bind_base" || \
    fail 'mode intent fixture failed'
# retry with --mode auto differs from the bound intent mode=human -> fail closed
if run_arena start "$mode_bind_run" --repo "$project" --mode auto --no-attach >"${tmp_root}/mode-bind.out" 2>&1; then
    fail 'mode-drifted interrupted start retry succeeded'
fi
require_match 'differ' "${tmp_root}/mode-bind.out"
require_match 'mode' "${tmp_root}/mode-bind.out"
# terminal runs refuse the switch (full loop on mode-run then switch)
mode_writer="$(manifest_value "${mode_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' m >"${mode_writer}/m.txt"
git -C "$mode_writer" add m.txt
git -C "$mode_writer" commit -qm 'feat: m'
run_arena submit mode-run >/dev/null
run_arena validate mode-run >/dev/null
run_arena decision mode-run --verdict APPROVE --summary ok --next done --no-relay >/dev/null
run_arena resolve mode-run --action approve --reason done >/dev/null
require_match $'run_status\tcompleted' <(cat "${mode_dir}/run-state.tsv")
if run_arena mode mode-run auto >"${tmp_root}/mode-terminal.out" 2>&1; then
    fail 'mode switch on a terminal run succeeded'
fi
require_match 'terminal' "${tmp_root}/mode-terminal.out"


printf '%s\n' 'tests: ok'
