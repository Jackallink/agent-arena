---
status: review-ready
created: '2026-08-13'
owner: 'local owner'
---

# Agent Arena v0.1: Pi writer + Cursor gate

## Summary

Build a standalone local tool that starts a tmuxp terminal session in a clean Git
project. Pi is the only writer. Cursor reviews, executes or directs the configured
validation gate, decides, and relays the next step back to Pi. The system is not a
multi-writer pool and does not publish an external release in v0.1.

## Scope

In: `agent-arena` command, project initialization, Pi/Cursor adapters, mandatory
worktree isolation, four-pane tmuxp session, direct safe relay, checkpoint review,
validation report, and SHA-bound decisions. Out: automatic merge/push/cleanup,
credential management, live model calls in tests, and enabled Codex/OpenCode/Gemini
adapters.

## Walkthrough round 1: user stories and acceptance criteria

1. As an operator, I can run `doctor` and see missing prerequisites before a run.
2. As an operator, I can initialize a project without overwriting existing config.
3. As a Pi writer, I get a dedicated branch/worktree only from a clean integration
   tree and can send a concise status message to Cursor.
4. As a Cursor gate, I receive the exact committed Pi checkpoint, run/inspect its
   project-defined validation, record APPROVE/CHANGES_REQUESTED/BLOCKED, and send
   Pi an actionable next step.
5. As an auditor, I can tie a decision and validation report to one SHA even if
   relay delivery fails.

Acceptance criteria:

| ID | Criterion | Test |
| --- | --- | --- |
| AC1 | `doctor` detects Pi/Cursor and labels unimplemented CLIs as planned. | `tests/run.sh: doctor` |
| AC2 | `init` makes only a project config and validation stub, refusing overwrite. | `tests/run.sh: init` |
| AC3 | `start` rejects dirty integration roots and otherwise creates a distinct Pi worktree/run manifest. | `tests/run.sh: run lifecycle` |
| AC4 | `submit` accepts only a clean committed Pi checkpoint, creates a detached review snapshot, and installs a local Cursor allowlist policy. | `tests/run.sh: checkpoint` |
| AC5 | validation records pass/fail against the submitted SHA and rejects dirty or changed-HEAD snapshots. | `tests/run.sh: validation` |
| AC6 | APPROVE requires passed validation; a decision is atomic, SHA-bound, and remains recorded when relay fails. | `tests/run.sh: decision` |
| AC7 | relay accepts only one safe live role pane and rejects controls. | `tests/run.sh: relay` |
| AC8 | the source archive verifies locally without overwriting an installed command. | `tests/run.sh: package` |

## Walkthrough round 2: technical trace

`start` → CLI dispatcher → project config discovery/preflight → clean Git root →
external manifest/state + Pi worktree → exported run environment → `tmuxp load` →
control/Pi/Cursor/validation panes. `submit` → clean Pi HEAD → detached reviewer
worktree → review manifest → Cursor pane respawn. `validate` → clean snapshot →
project validation executable → post-run source-clean/HEAD verification plus
hash-bound generated policy/wrapper verification → report bound to review HEAD.
`decision` → writer and snapshot integrity gate → atomic decision
record → literal tmux relay to the Pi pane. During formal review, Cursor runs in
its normal interactive mode only inside an enabled sandbox plus a locally generated
allowlist policy; its intake pane remains `--mode plan`.

Adapter contract: an adapter declares `probe`, `launch`, `interactive`, `writer`,
`read_only_mode`, `workdir`, `explicit_session_id`, `session_dir`, and
`resume_by_id`. v0.1 enables only `pi` and `cursor`; provider adapters never own
Git worktrees or project validation.

## Walkthrough round 3: integration and errors

Missing CLIs, missing tmuxp, dirty base, existing branch/run, stale head, dirty
review snapshot, failed validation, ambiguous/inactive pane, relay failure, and a
checkpoint that tracks `.cursor/cli.json` or `.agent-arena-gate` all fail closed.
The latter prevents an unverified merge of Cursor permission arrays. A persisted
decision remains valid when relay fails. No command fetches, stashes, resets,
merges, pushes, or removes a worktree.

## Testing and validation

The suite uses temporary Git repositories, fake Pi/Cursor/tmuxp executables, and a
private tmux socket. It must not call a model, network, or user project. Package
checks remain local until a license and release policy exist.

## Drift, risk, and rollback

Drift: the formal Cursor gate uses a sandboxed allowlist instead of `--mode plan`,
because plan mode cannot execute the validation and decision commands. The command
shape and local policy are tested without a model request; a human must confirm the
installed Cursor CLI honors the policy during its first authenticated run. The
deterministic `validate` command remains the authority regardless. Risk: a relay can
interrupt a live terminal; messages are capped, literal, and advisory. Rollback:
stop the tmux session and remove only explicitly named worktrees using normal Git
commands; v0.1 provides no automated destructive cleanup.
