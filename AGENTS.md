# Repository Guidelines

## Scope and Workflow

Scope: all contributions to Agent Arena, a reusable tmuxp workflow for paired coding agents. Inheritance: follow the baseline rules in `~/.codex/AGENTS.md` and `RTK.md`. Override: this file adds project conventions; direct instructions and more-local `AGENTS.md` files win on conflict. Evidence Path: canonical specifications live in `docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`, and each run's audit records live outside Git under the configured state directory.

Use the strict SDD/TDD flow: update the applicable spec first, map acceptance criteria to tests, and record drift plus risk/rollback before handoff. Do not claim support for an agent CLI until its adapter has deterministic tests.

## Structure

- `bin/agent-arena`: global-command entry point.
- `lib/`: orchestration, run state, validation, decision, and relay logic.
- `adapters/`: provider-specific launch and capability declarations.
- `templates/tmuxp/`: reusable four-pane session template.
- `tests/`: hermetic Bash tests; never call a live model or network.
- `packaging/`: local install, uninstall, and archive scripts.

Project-specific settings belong in `<project>/.agent-arena/`; secrets, session transcripts, logs, and worktrees do not.

## Style and Validation

Write Bash compatible with macOS Bash 3.2 and Linux Bash. Use `set -euo pipefail`, four-space indentation, `snake_case` function names, quoted expansions, and no `eval`. Prefer `rtk <command>` for concise shell output. Run:

```bash
bash tests/run.sh
bash tests/tmuxp-smoke.sh
bash packaging/package.sh --check
```

## Safety and Handoff

One writer owns one isolated Git worktree. Reviewers receive a detached committed snapshot; they never merge, push, reset, or bypass approval controls. Relays are best-effort hints; SHA-bound decision records and validation reports are the audit source of truth. Keep commits concise and imperative (for example, `feat: add pi adapter`). PRs link the spec, AC-to-test mapping, validation evidence, drift, and rollback note.
