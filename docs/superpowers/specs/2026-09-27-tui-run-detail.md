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

- Real-machine verification (2026-09-28, tmux via a real attached
  client): the original verb `tmux select-window -t <session>` NEVER
  moves a client — it only retargets the current window inside its own
  session, so from the dashboard pane it was a silent no-op. The verb
  is `tmux switch-client -t <session>`.
- Inside tmux (`TMUX` set): the current client switches into the run's
  session (writer/gate panes). Return path is the standard tmux one:
  prefix-s / `tmux switch-client -t <dashboard-session>`; a plain
  detach drops the client out of tmux entirely.
- Outside tmux: refusal rendered as the screen's bottom-border title
  (`not inside tmux; attach manually: tmux attach -t <session>`); the
  screen stays open. The other refusal — a run with no recorded session
  (error-path documents) — renders `no tmux session recorded for RUN`
  the same way. Any next keypress clears either. A refused jump never
  closes the screen. Foreground attach from the TUI remains a non-goal
  (see §4).

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
  semantics + unbounded takeover; the manual path via the recorded
  session name stays the sanctioned route unless real usage proves
  otherwise).
