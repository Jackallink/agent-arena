---
status: draft
created: '2026-08-15'
owner: 'local owner'
drift: none (spec precedes implementation; §58 tests written first per the plan)
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
| Approval semantics | no approval-mode flag in help | **No `approval=` capability line**; unverified abilities are not declared |

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
| Manual live smoke | An authorized operator records an authenticated zell headless + Arena end-to-end observation (no credentials/transcripts in Git) | **open** — support is not "live-tested" until recorded |

## Non-claims

- No Zell gate adapter; Zell is a writer only.
- No OS-level or network isolation claim: the suppression flags are config
  hygiene, not a sandbox.
- No approval-behavior claim until the live smoke records it.
- No claim about providers or models: the operator's zell config decides.
