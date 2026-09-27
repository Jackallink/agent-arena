# Spec: TUI artifact viewer (read the draft before gating)

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `lib/artifact.sh`, `ui/src/model.rs`, `ui/src/main.rs`, `tests/run.sh` §75, README
- Context: v0.7.2 made the gate operable (`g`/`G`) but the human still had
  to leave the TUI to read the draft. Thin-client rule: run data reaches
  the TUI only through `agent-arena` subcommands — so the reader is a new
  oracle verb, not a file read in the UI.

## 1. CLI: `artifact RUN --stage S --show`

- Mutually exclusive with `--accept`/`--reject` (exactly one of the three).
- Read-only: shares the pipeline/active/phase/stage-in-pipeline guards but
  skips the gate reason_code check and never mutates state.
- Prints the draft (`<run_dir>/<stage>-draft.md`) verbatim to stdout, exit
  0; missing draft → actionable refusal (`no draft to show: <path>`).

## 2. TUI: `o` opens the viewer

- Fresh `status --json` → `awaiting_stage()` (same resolution as the gate
  keys; never the auto-refresh cache) → capture `artifact RUN --stage S
  --show` → full-screen bordered viewer titled `RUN/stage-draft.md`.
- Keys inside the viewer: `j`/`Down` line down, `k`/`Up` line up,
  `PageDown`/`PageUp` page, `Esc`/`q` back to the list. The list scan and
  status refresh pause while the viewer is open (static content, no
  subprocess churn).
- Oracle error → notice, no viewer. Keymap otherwise unchanged; footer
  hint gains `o view artifact`.

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-V1 | `--show` prints the draft verbatim; missing draft refuses with the path | §75 (CLI part) |
| AC-V2 | `o` opens the viewer with the draft content; scroll keys work; `Esc` returns to the list | §75 (tmux smoke) |
| AC-V3 | argv builder + keymap row; viewer never builds argv from the cache | cargo unit tests |
| AC-V4 | gate keys unchanged; wizard intact | existing cargo tests + §69/§74 |

## 4. Non-goals

- Viewing accepted artifacts (`<stage>.md`) and rejected drafts history.
- Syntax highlighting / wrapping toggles.
