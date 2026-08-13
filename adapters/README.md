# Adapter contract

Every adapter is an executable Bash script with:

```text
adapter.sh probe
adapter.sh capabilities
adapter.sh launch
```

`probe` must only inspect local availability. `capabilities` prints stable,
line-oriented capability flags. `launch` receives all paths through `ARENA_*`
environment variables and normally `exec`s the provider CLI. An adapter may wait
for a provider's successful initial exit only when it must atomically publish
verified session state. It
never creates a Git worktree, runs project validation, manages credentials,
merges, pushes, or enables dangerous bypass flags.

The orchestration layer owns worktree isolation and decisions. A provider is a
writer only unless its independent formal-gate policy is verified. Every enabled
provider needs fake-CLI, explicit safety/session, and relay coverage before it is
advertised as supported; authenticated provider-permission behavior remains a
separate release smoke.

## Writer adapters

Writer adapters live at `adapters/<name>.sh` (pi, codex, opencode, agy) and
declare `writer=true` in `capabilities`. They launch the writer CLI inside the
isolated writer worktree with the Arena session directory and a prompt that
prohibits editing the integration worktree, merging, pushing, resetting, and
dangerous permission bypasses.

## Gate adapters

Gate adapters live at `adapters/gate-<name>.sh` and add one command to the
shared contract:

```text
adapter.sh probe
adapter.sh capabilities
adapter.sh launch
adapter.sh policy REVIEW_WORKTREE
```

- `probe` reports local availability of the gate CLI (for Cursor,
  `${ARENA_CURSOR_BIN:-agent}`; for OpenCode, `${ARENA_OPENCODE_BIN:-opencode}`)
  and exits nonzero when it is missing. `doctor` runs it for every gate in the
  matrix and fails only when no gate is available.
- `capabilities` prints `writer=false`, `read_only_mode`, `review_gate`,
  `validation_shell`, and the binding keys `policy_path` and `wrapper_path`
  (paths inside the review snapshot, relative to its root).
- `launch` starts the reviewer in its pane. It reads `ARENA_GATE_WORKSPACE`
  and `ARENA_GATE_PHASE` (`intake` for the advisory pass over the writer
  worktree, `review` for the formal pass over the detached review snapshot)
  plus `ARENA_RUN_ID`, `ARENA_RUN_DIR`, `ARENA_COMMAND`, and
  `ARENA_WRITER_LABEL`, and normally `exec`s the gate CLI.
- `policy REVIEW_WORKTREE` writes the project-level gate policy and the
  universal `.agent-arena-gate` wrapper into the review snapshot (600/700
  perms, mktemp then mv), and prints the three-column TSV binding manifest:

```text
policy<TAB><policy_path><TAB><sha256>
wrapper<TAB><wrapper_path><TAB><sha256>
```

`arena_prepare_gate_policy` validates both SHA-256 hashes and records
`gate_policy_path`, `cursor_policy_hash`, and `gate_wrapper_hash` in the review
manifest; `status`, `validate`, `decision`, and the reviewer pane refuse a
snapshot whose gate files no longer match. The `.agent-arena-gate` wrapper
only execs the Arena command for `status|validate|decision|relay`.

Gate policy caveats:

- The Cursor adapter keeps the v0.2 allowlist policy byte-identical apart from
  the adapter-driven generation path and writes `.cursor/cli.json`.
- The OpenCode adapter writes `opencode.json` with a deny-first `arena_gate`
  agent policy: everything is denied except read, glob, grep, and `bash`. The
  policy layer cannot restrict which command an allowed `bash` permission
  runs, so the wrapper-only bash convention (the generated `.agent-arena-gate`
  wrapper is the only sanctioned bash path) is the enforcement boundary.
  Project config and external skills are disabled for the gate pane.
- Codex and Agy are not gates yet: Codex exposes no project-level policy file
  and Agy's policy is global rather than per project.
