# Agent Arena

Agent Arena is a standalone, local-first terminal workflow for a single coding
writer and a separate review, validation, and decision gate. `tmuxp` creates the
four panes; Git worktrees enforce the handoff boundary; `tmux` relays short
messages directly between the agents.

Version 0.1 supports **Pi** as the writer and **Cursor Agent** as the reviewer.
Codex, OpenCode, and Gemini are detected by `doctor` but intentionally remain
unsupported until each adapter has passed permission and session-resume tests.

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
/Users/jakeliu/Workspace/agent-arena/bin/agent-arena start tui-sink --repo .
```

`start` refuses a dirty integration worktree. It creates a writable Pi worktree.
Pi commits a checkpoint and runs `agent-arena submit RUN_ID`; Cursor then receives
a detached review snapshot, runs the configured validation gate, writes a
SHA-bound decision, and relays the next step to Pi.

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
```

Relay delivery is direct but best effort: tmux cannot know whether an interactive
model is mid-turn. The decision record, not a pane message, is the audit truth.

## Cursor policy boundary

Formal Cursor review runs in normal interactive mode so it can invoke only the
generated gate wrapper for `validate`, `decision`, `relay`, and `status`. It does
not use `--force`, `--yolo`, or plan mode. Version 0.1 deliberately refuses a
checkpoint that tracks `.cursor/cli.json` or `.agent-arena-gate`: Cursor's array
layering cannot be proven to preserve both a project policy and Arena's deny-first
gate. Keep those paths untracked for an Arena run, or use a future adapter that
supports a verified policy merge. Before relying on the gate, complete the manual
authenticated Cursor smoke recorded in the implementation plan.

See [the v0.1 spec](docs/superpowers/specs/2026-08-13-agent-arena-v1.md) for the
workflow, boundaries, and acceptance criteria.
