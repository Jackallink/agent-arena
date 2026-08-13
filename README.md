# Agent Arena

Agent Arena is a standalone, local-first terminal workflow for one coding writer
and a separate review, validation, and decision gate. `tmuxp` creates the four
panes; Git worktrees isolate the handoff; `tmux` relays short messages directly
between the agents.

Every profile pairs one writer with one gate. **Cursor Agent** is the default
formal review, validation, and decision gate; `--gate opencode` or a
`WRITER-GATE` profile such as `pi-opencode` selects the OpenCode gate instead.
Pi, Codex, OpenCode, and Agy remain writers only. A direct relay is useful
feedback, but the SHA-bound validation report and decision record remain the
audit truth.

> **Validation status:** v0.2 has hermetic adapter tests, tmuxp smoke coverage,
> and no-model local CLI contract checks. It has not run a live model, used a
> credential, or performed a provider-network/end-to-end permission smoke test.
> `doctor` confirms local prerequisites, not provider-side behavior.

## Location model

```text
agent-arena source     /Users/jakeliu/Workspace/agent-arena
global command         ~/.local/bin/agent-arena
reserved user config   ~/.config/agent-arena/
run state and logs     ~/.local/state/agent-arena/
worktrees              ~/.local/share/agent-arena/worktrees/
project configuration  <repo>/.agent-arena/
```

Only the last location is committed with an application project. The user config
location is reserved for a later profile layer; credentials stay with the individual
CLI's own login, Keychain, or environment configuration.

## Quick start

From a clean Git project:

```bash
/Users/jakeliu/Workspace/agent-arena/bin/agent-arena doctor
/Users/jakeliu/Workspace/agent-arena/bin/agent-arena init --repo .
# Edit .agent-arena/validate.sh to run this project's checks.
/Users/jakeliu/Workspace/agent-arena/bin/agent-arena start tui-sink --repo . --profile pi-cursor
```

Replace `pi-cursor` with `codex-cursor`, `opencode-cursor`, or `agy-cursor`
after its local prerequisites pass `doctor`.
`start` refuses a dirty integration worktree and creates one writable writer
worktree. The writer commits a checkpoint and runs `agent-arena submit RUN_ID`.
Cursor then receives a detached review snapshot, runs the configured validation
gate, writes a SHA-bound decision, and relays the next step to the writer.

## Writer profiles and limitations

| Profile | Writer contract | Session and safety limits |
| --- | --- | --- |
| `pi-cursor` | Pi runs in Arena's writer worktree with an Arena session directory and stable session ID. | It receives no merge, push, reset, or permission-bypass instruction. Resume behavior must remain covered by adapter tests. |
| `codex-cursor` | Codex is targeted at the writer worktree with `workspace-write` sandboxing and on-request approval. | Codex can resume a known session, but does not expose creation-time naming or a session directory; Arena must not promise automatic resume. No `--search`, `--add-dir`, or dangerous bypass flag. |
| `opencode-cursor` | OpenCode starts in the Arena writer worktree with a dedicated writer-agent policy; project configuration and external skills are disabled where supported. | Never use `--auto`. Its CLI exposes session commands but no documented Arena-owned session creation/directory contract, so automatic resume remains unverified. Its permissions are not an OS or network sandbox. |
| `agy-cursor` | Agy (Antigravity CLI) starts after `cd` into the writer worktree with `--prompt-interactive`, `--new-project`, `--sandbox`, and `--mode accept-edits`; the human confirms the interactive trust prompt. | Agy exposes no creation-time session ID or session directory, and its CLI sessions bind to a project workspace, so Arena never promises automatic resume. Never use `--continue`, `--conversation`, or `--dangerously-skip-permissions`. Its terminal-restrictions sandbox is not a no-network guarantee. |

All writer prompts prohibit editing the integration worktree, merging, pushing,
resetting, and dangerous permission bypasses. Git worktrees separate code
handoff, but are not a general operating-system, credential, or network sandbox.
Keep credentials in each CLI's normal login/environment mechanism and never put
them in project config or relay messages.

### Gates

`start RUN_ID --repo PATH --writer pi --gate opencode` splits the two
selection dimensions explicitly; `--writer` and `--gate` require each other
when either is given. `--profile pi-opencode` is the equivalent `WRITER-GATE`
form. `--gate` defaults to `cursor`, so every v0.2 command line behaves
identically, and Cursor remains the default gate.

Each gate is an executable adapter at `adapters/gate-<name>.sh` implementing
the gate adapter contract (see `adapters/README.md`): `probe` reports local
availability, `capabilities` prints declared flags including `policy_path`
and `wrapper_path`, `launch` starts the reviewer in its pane, and `policy`
generates the project-level gate policy inside the review snapshot and prints
the binding manifest (policy path, wrapper path, and both SHA-256 hashes)
that binds the review manifest to those files. The `.agent-arena-gate`
wrapper stays universal: it only execs the Arena command for
`status|validate|decision|relay`.

The OpenCode gate generates `opencode.json` in the review snapshot with a
deny-first `arena_gate` agent policy: everything is denied except read,
glob, grep, and `bash`. The only sanctioned bash use is the generated
`.agent-arena-gate` wrapper, because OpenCode's policy layer cannot restrict
which command an allowed `bash` permission runs — the wrapper-only bash
convention is the enforcement boundary, not an OS sandbox. Project config and
external skills are disabled for the gate pane.

> **Threat model:** all provider CLIs run with the operator's user identity. A
> writer that ignores its prompt can technically invoke the gate commands and
> forge local report files, because the private run directory and the gate CLI
> are reachable by the same user. The gate is therefore a role declaration
> enforced by the gate-side policy and the writer's prompt, not an operating-
> system capability boundary; the human operator remains the ultimate
> authority over decision records.

## Commands

```bash
agent-arena doctor
agent-arena init --repo /path/to/project
agent-arena start RUN_ID --repo /path/to/project
agent-arena submit RUN_ID
agent-arena validate RUN_ID
agent-arena decision RUN_ID --verdict APPROVE --summary "..." --next "..."
agent-arena relay RUN_ID --to writer --from reviewer --message "..."
agent-arena status RUN_ID
agent-arena list
```

Relay delivery is direct but best effort: tmux cannot know whether an interactive
model is mid-turn. Writers can send progress or a question to Cursor; Cursor can
send review feedback and the next step back to the writer. The decision record,
not a pane message, is the audit truth.

## Formal gate adapters

Cursor remains the default formal gate and runs in normal interactive mode so
it can invoke only the generated gate wrapper for `validate`, `decision`,
`relay`, and `status`. It does not use `--force`, `--yolo`, or plan mode.
Select another gate with `--gate` or a `WRITER-GATE` profile; `cursor` and
`opencode` ship adapters. Version 0.1 deliberately refuses a
checkpoint that tracks `.cursor/cli.json` or `.agent-arena-gate`: Cursor's array
layering cannot be proven to preserve both a project policy and Arena's deny-first
gate. Keep those paths untracked for an Arena run, or use a future adapter that
supports a verified policy merge. Before relying on the gate, complete the manual
authenticated Cursor smoke recorded in the implementation plan.

Codex and Agy must not be substituted as gates: Codex exposes no project-level
policy file and Agy's policy is global rather than per project, so each needs
its own design pass. OpenCode is a supported gate only through its adapter's
deny-first project policy and the wrapper-only bash convention. Advisory
review capabilities alone do not establish permission to modify Arena reports
or make a formal decision from an immutable snapshot.

Decisions bind to the checkpoint under review: `decision` requires the writer to
stay exactly on the reviewed HEAD. If the writer commits a new checkpoint before
the reviewer records a decision, the old checkpoint can no longer be decided;
submit the new checkpoint for review instead. The recommended rhythm is writer
waits for the decision before committing the next checkpoint.

## Recovery and cleanup

Agent Arena never fetches, stashes, resets, merges, pushes, or removes
worktrees. `list` shows every recorded run and its derived state. Manual
recovery notes:

- A review snapshot deleted behind Arena's back is recreated automatically by
the next `submit` (stale Git worktree registrations are pruned, never data).
- Orphan worktree registrations from crashed or manually removed runs can be
cleaned with `git worktree prune`; run state and session logs are never removed
by Arena.
- An orphan writer branch can be removed with `git branch -D
agent-arena/<adapter>/<run_id>` after confirming no run manifest references it.
- An interrupted `start` may leave a run directory without a tmux session;
re-running `start` resumes it.

See [the v0.2 writer-profile spec](docs/superpowers/specs/2026-08-13-pluggable-writer-adapters.md)
and [implementation plan](docs/superpowers/plans/2026-08-13-pluggable-writer-adapters.md)
for current acceptance criteria, evidence, risks, and release gates.

## License

This project is available under the [MIT License](LICENSE). Public source
publication is permitted; publishing a GitHub Release or package still requires
the documented Gate 4 evidence.
