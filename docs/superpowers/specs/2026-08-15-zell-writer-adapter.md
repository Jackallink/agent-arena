---
status: live-tested
created: '2026-08-15'
owner: 'local owner'
drift: implementation matches the contract; live smoke (2026-08-15) added the approval=auto-execute capability claim, found an upstream zell 0.4.0-rc.1 bug (--print resume crashes, interactive resume unaffected), and exposed a pre-existing validate exit-2 sentinel collision (fixed, §60). Details in the plan's smoke record.
---

# Agent Arena v0.5: Zell writer adapter

## Summary and scope

Add **Zell** (`zell`, verified locally at 0.4.0-rc.1) as the fifth writer in the
closed profile library: `zell-cursor` explicitly, plus the generic
`zell-GATE` combination (`zell-opencode`) through the existing
`arena_profile_split` fallback. Cursor and OpenCode remain the only formal
gates; this change adds no gate.

In scope: `adapters/zell.sh` (probe/capabilities/launch), profile
registration, fake-CLI hermetic tests (§58), doctor visibility, README
deployment matrix.

Out of scope: a Zell gate adapter (an independent formal-gate policy is not
verified), provider/model selection automation (the operator's `zell
config`/`auth` decides the provider; the adapter exposes only
`ARENA_ZELL_MODEL`), and any live behavior claim beyond the CLI's own
`--help` contract.

## CLI contract audit (read-only, no live inference)

From `zell --help` only:

| Arena requirement | Zell surface | Decision |
| --- | --- | --- |
| Exact session binding (fail-closed) | `--session-id <id>` — "Use or create an exact session ID" | Bind `agent-arena-${ARENA_RUN_ID}` (pi-equivalent use-or-create semantics) |
| Session storage | `--session-dir <dir>` | Arena writer session dir |
| No "latest" selection | `--continue/-c`, `--resume/-r` (interactive picker), `--fork` | Never passed; forbidden-flag tests |
| System prompt injection | `--append-system-prompt <text>` | Writer policy prompt |
| Display name | `--name, -n` | `Agent Arena Zell ${RUN_ID}` |
| Working directory | No `-C` flag | `cd` to the writer worktree (agy precedent) |
| Defense in depth | `--no-extensions`, `--no-skills`, `--no-prompt-templates`, `--no-themes` | Passed on launch; suppression of auto-discovered resources only — **not** OS/network isolation |
| OS sandbox | none in help | `sandbox=none`; no isolation claim |
| Approval semantics | no approval-mode flag in help | Live smoke: write/bash auto-execute in both headless and interactive modes → `approval=auto-execute` (same prompt-bound trust model as pi; not a sandbox) |

## Writer-specific rules (mirrors the writer implementation matrix)

- `cd` to the writer worktree; launch args are a whitelist (`--session-dir`,
  `--session-id`, `--name`, `--append-system-prompt`, the four suppression
  flags, optional `--model`).
- Never `--continue`, `--resume`, `--fork`, `--print` in writer launch; no
  bypass flag exists in the CLI and none may be added by Arena.
- Resume is by explicit `--session-id` only (use-or-create); the adapter
  declares `automatic_resume=true` on the same basis as pi (exact-id
  rebinding), never a provider-side "latest" choice.
- Context files (AGENTS.md) discovery stays on: the writer must read project
  instructions.

## Acceptance criteria and test mapping

| AC | Requirement | Test |
| --- | --- | --- |
| z1 | `zell-cursor` resolves; unknown/missing writer fails closed before worktree/tmux creation | §58 profile resolution (existing §16/§17 patterns) |
| z2 | Launch runs in the writer worktree with exact session id/dir/name and the policy prompt (submit/relay text) | §58 argv/cwd assertions via fake `zell` |
| z3 | Defense-in-depth flags present; resume/fork/print flags absent; `assert_no_dangerous_writer_flags` clean | §58 |
| z4 | Capabilities declare `explicit_session_id=true`, `session_dir=true`, `resume_by_id=true`, `automatic_resume=true`, `sandbox=none`, and no `approval=` line | §58 |
| z5 | Relay label `Zell`; manifest rows (`writer_adapter`, profile, label) correct | §58 + existing §20-style relay checks |
| z6 | Doctor lists `profile:zell-cursor` when the CLI is available | §58 doctor line |

## Validation matrix

| Gate | Required evidence | Status |
| --- | --- | --- |
| Profile resolution | §58 + full suite green | pending (this change) |
| Writer launch | Fake binary captures argv/cwd/flags for zell | pending |
| tmuxp / packaging | `tmuxp-smoke.sh`, `package.sh --check` | pending |
| Manual live smoke | S1–S4 recorded 2026-08-15 (see the plan's smoke record) | **Passed** |

## Non-claims

- No Zell gate adapter; Zell is a writer only.
- No OS-level or network isolation claim: the suppression flags are config
  hygiene, not a sandbox; tool auto-execution is prompt-bound, not gated.
- No claim about providers or models: the operator's zell config decides
  (smoke ran on the operator's default deepseek provider).
- Upstream bug non-claim: `zell --print` resuming an existing `--session-id`
  aborts (bus error in `restoreSessionSettings`, zell 0.4.0-rc.1); interactive
  resume is unaffected, so Arena writer resumes (TUI) are safe, and the Arena
  adapter never uses `--print` for writer launch.
