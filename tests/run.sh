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

printf '%s\n' '1. doctor'
run_arena doctor >"${tmp_root}/doctor.out"
require_match 'cursor' "${tmp_root}/doctor.out"
require_match 'profile:pi-cursor' "${tmp_root}/doctor.out"
require_match 'profile:codex-cursor' "${tmp_root}/doctor.out"
require_match 'profile:opencode-cursor' "${tmp_root}/doctor.out"
require_match 'profile:agy-cursor' "${tmp_root}/doctor.out"

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
    ARENA_CURSOR_WORKSPACE="$review_worktree" \
    ARENA_CURSOR_PHASE=review \
    ARENA_RUN_ID=run-one \
    ARENA_RUN_DIR="$run_dir" \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/cursor.sh" launch
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
    ARENA_CURSOR_WORKSPACE="$writer_worktree" \
    ARENA_CURSOR_PHASE=intake \
    ARENA_RUN_ID=run-one \
    ARENA_RUN_DIR="$run_dir" \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/cursor.sh" launch
require_match "--workspace ${writer_worktree} --mode plan" "$fake_agent_log"

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
require_match 'RESULT: FAIL' "${drift_run_dir}/validation-${drift_short_sha}.md"
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
    ARENA_CURSOR_WORKSPACE="$codex_review_worktree" \
    ARENA_CURSOR_PHASE=review \
    ARENA_RUN_ID=profile-codex \
    ARENA_RUN_DIR="$codex_run_dir" \
    ARENA_WRITER_LABEL=Codex \
    ARENA_COMMAND="$arena" \
    "${source_root}/adapters/cursor.sh" launch
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
run_arena decision run-pane-dead --verdict APPROVE --summary 'approved' \
    --next 'continue' --no-relay >/dev/null
[[ -f "${pane_dead_run_dir}/validation.md" ]] || fail 'validation pointer missing before resubmit'
[[ -f "${pane_dead_run_dir}/decision.md" ]] || fail 'decision pointer missing before resubmit'
pane_dead_head="$(manifest_value "${pane_dead_run_dir}/review.tsv" review_head)"
pane_dead_short="${pane_dead_head:0:12}"
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

printf '%s\n' '29. list reports runs with derived state'
run_arena list >"${tmp_root}/list.out"
require_match 'run-one' "${tmp_root}/list.out"
require_match 'run-pane-dead' "${tmp_root}/list.out"
require_match 'pi-cursor' "${tmp_root}/list.out"
require_match 'DECIDED' "${tmp_root}/list.out"
require_match 'SUBMITTED' "${tmp_root}/list.out"
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
run_arena start run-opencode-gate --repo "$project" --profile pi-opencode --no-attach >/dev/null
ocg_manifest="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/run-opencode-gate/manifest.tsv' -exec dirname {} \;)/manifest.tsv"
[[ "$(manifest_value "$ocg_manifest" gate_adapter)" == 'opencode' ]] || \
    fail 'pi-opencode did not record gate_adapter=opencode'
[[ "$(manifest_value "$ocg_manifest" profile)" == 'pi-opencode' ]] || \
    fail 'pi-opencode did not record the combined profile'
expect_failure run_arena start run-opencode-gate --repo "$project" --profile pi-opencode --gate cursor --no-attach

printf '%s\n' 'tests: ok'
