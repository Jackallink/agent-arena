# Spec: TUI run detail screen (Enter drills into one run)

- Date: 2026-09-27
- Status: implemented (same day)
- Scope: `ui/src/model.rs`, `ui/src/main.rs`, `tests/run.sh` §78, README
- Context: the run list renders one digest line per run; everything else
  the status oracle knows (checkpoint, validation, decision, worktree,
  session) required leaving the TUI for `status` or the state files.
  `Enter` already did a fresh status fetch but compressed it to a
  one-line notice plus a writer-pane jump. The detail screen keeps the
  fresh-fetch discipline and gives the oracle output a full screen.
  Thin-client rule unchanged: the screen renders `status --json` — the
  TUI never reads run directories.

## 1. Enter opens the detail screen

- Fresh `status --json` for the selected run (same resolution as `o` and
  the gate keys; never the auto-refresh cache). Oracle error → notice,
  no screen.
- Content = `model::render_detail(&doc)`:
  - every `fields` entry as `key  value`, keys sorted (serde_json::Map
    iteration is sorted), empty values skipped;
  - `panes  reviewer=<bool> writer=<bool>`;
  - the pipeline chain via `stage_chain()` when the document carries a
    `stages` array.
- Full-screen bordered screen titled `RUN — detail  (w writer pane, Esc
  back)`. `j`/`k`/`PageUp`/`PageDown` scroll, `Esc`/`q` back to the
  list. List scans stay paused while the screen is open (same rule as
  the artifact viewer).
- The one-line notice + jump that `Enter` used to perform is replaced by
  this screen; the jump moves inside it (§2). Footer hint becomes
  `Enter detail`.

## 2. `w` jumps to the writer pane from the detail screen

- Non-empty `tmux_session` field → the same inert window-focus spawn the
  list Enter used (`jump_writer_pane` under a suspended terminal).
- Empty/absent session → refusal rendered as the screen's bottom-border
  title (`no tmux session recorded for RUN`); the screen stays open.
  Any next keypress clears it. A refused jump never closes the screen.

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-D1 | `render_detail` is deterministic: fields sorted, empties skipped, panes line, stage chain when present; error-path documents render minimally | cargo unit tests |
| AC-D2 | `Enter` opens the detail screen with fresh data: a gate action taken through the CLI is visible without restarting the TUI | §78 (tmux smoke) |
| AC-D3 | `w` jumps when a session is recorded; refusal keeps the screen open with the bottom-border notice | §78 (tmux smoke) |
| AC-D4 | list keys and the artifact viewer/gate keys are unchanged; footer hint updated | existing cargo tests + §69/§74–§77 |

## 4. Non-goals

- Editing anything from the detail screen (mode switch, decision entry
  stay on the list keymap / CLI).
- Cross-run navigation inside the screen (Esc back to the list first).
- Attaching the run's tmux session from the TUI (nested-attach target
  semantics unresolved — future work).
