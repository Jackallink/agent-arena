#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
arena="${source_root}/bin/agent-arena"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-arena-tmuxp-smoke.XXXXXX")"
tmux_socket_root="$(mktemp -d /tmp/agent-arena-tmux.XXXXXX)"
session_name=''

cleanup() {
    if [[ -n "$session_name" ]]; then
        TMUX_TMPDIR="$tmux_socket_root" tmux kill-session -t "=${session_name}" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_root" "$tmux_socket_root"
}
trap cleanup EXIT

for command_name in git tmux tmuxp pi agent; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'skip: missing %s\n' "$command_name"
        exit 0
    }
done

project="${tmp_root}/project"
mkdir -p "$project"
git -C "$project" init --initial-branch=main >/dev/null
git -C "$project" config user.name 'Agent Arena Smoke'
git -C "$project" config user.email 'agent-arena@example.test'
printf '%s\n' fixture >"${project}/README.md"
git -C "$project" add README.md
git -C "$project" commit -m 'test: create fixture' >/dev/null

ARENA_STATE_ROOT="${tmp_root}/state" ARENA_WORKTREE_ROOT="${tmp_root}/worktrees" \
    "$arena" init --repo "$project" >/dev/null
cat >"${project}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "${project}/.agent-arena/validate.sh"
git -C "$project" add .agent-arena
git -C "$project" commit -m 'test: add adapter' >/dev/null

TMUX_TMPDIR="$tmux_socket_root" ARENA_TEST_MODE=1 \
    ARENA_STATE_ROOT="${tmp_root}/state" ARENA_WORKTREE_ROOT="${tmp_root}/worktrees" \
    "$arena" start tmuxp-smoke --repo "$project" --no-attach >/dev/null
manifest="$(find "${tmp_root}/state/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/tmuxp-smoke/manifest.tsv')"
session_name="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "$manifest")"
[[ -n "$session_name" ]] || {
    printf '%s\n' 'missing tmux session name from run manifest' >&2
    exit 1
}
TMUX_TMPDIR="$tmux_socket_root" tmux has-session -t "=${session_name}"
pane_count="$(TMUX_TMPDIR="$tmux_socket_root" tmux list-panes -s -t "=${session_name}" | wc -l | tr -d ' ')"
[[ "$pane_count" == 4 ]] || {
    printf 'expected 4 panes, got %s\n' "$pane_count" >&2
    exit 1
}
expected_roles=$'control\ttest\nreviewer\ttest\nvalidation\ttest\nwriter\ttest'
pane_roles=''
for ((attempt = 0; attempt < 30; attempt += 1)); do
    pane_roles="$(TMUX_TMPDIR="$tmux_socket_root" tmux list-panes -s -t "=${session_name}" -F $'#{@agent_arena_role}\t#{@agent_arena_mode}' | sort)"
    [[ "$pane_roles" == "$expected_roles" ]] && break
    sleep 0.2
done
[[ "$pane_roles" == "$expected_roles" ]] || {
    printf 'unexpected pane roles/modes:\n%s\n' "$pane_roles" >&2
    exit 1
}
printf '%s\n' 'tmuxp smoke: ok'
