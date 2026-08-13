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

fake_bin="${tmp_root}/fake-bin"
mkdir -p "$fake_bin"
fake_tmux_log="${tmp_root}/tmux.log"
fake_tmuxp_log="${tmp_root}/tmuxp.log"
fake_agent_log="${tmp_root}/agent.log"
cat >"${fake_bin}/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${fake_bin}/agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_AGENT_LOG:?}"
exit 0
EOF
cat >"${fake_bin}/tmuxp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_TMUXP_LOG:?}"
exit 0
EOF
cat >"${fake_bin}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
case "$command_name" in
    has-session)
        [[ "${FAKE_TMUX_MODE:-offline}" != offline ]] && exit 0
        exit 1
        ;;
    list-panes)
        [[ "${FAKE_TMUX_MODE:-offline}" == relay ]] || exit 1
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
        ARENA_STATE_ROOT="$state_base" \
        ARENA_WORKTREE_ROOT="$worktree_base" \
        "$arena" "$@"
}

printf '%s\n' '1. doctor'
run_arena doctor >"${tmp_root}/doctor.out"
require_match 'pi               enabled' "${tmp_root}/doctor.out"
require_match 'cursor           enabled' "${tmp_root}/doctor.out"
require_match 'codex            planned' "${tmp_root}/doctor.out"

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
[[ -d "$writer_worktree" ]] || fail 'start did not create writer worktree'
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
require_match '"approvalMode": "allowlist"' "${review_worktree}/.cursor/cli.json"
require_match '"networkAccess": "user_config_only"' "${review_worktree}/.cursor/cli.json"
require_match '"networkAllowlist": []' "${review_worktree}/.cursor/cli.json"
require_match '"Write(**)"' "${review_worktree}/.cursor/cli.json"
require_match '"Delete(**)"' "${review_worktree}/.cursor/cli.json"
require_match '"Shell(git commit *)"' "${review_worktree}/.cursor/cli.json"
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
ARENA_RUN_DIR="$run_dir" run_arena status run-one >"${tmp_root}/inherited-status.out"
require_match "Run: run-one" "${tmp_root}/inherited-status.out"

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

printf '%s\n' '16. local package and protected install'
bash "${source_root}/packaging/test.sh" >"${tmp_root}/package.out"
require_match 'package test: ok' "${tmp_root}/package.out"

printf '%s\n' 'tests: ok'
