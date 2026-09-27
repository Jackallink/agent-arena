# Spec: TUI artifact viewer (read the draft before gating)

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `lib/artifact.sh`, `ui/src/model.rs`, `ui/src/main.rs`, `tests/run.sh` §75 + §77, README
- Context: v0.7.2 made the gate operable (`g`/`G`) but the human still had
  to leave the TUI to read the draft. Thin-client rule: run data reaches
  the TUI only through `agent-arena` subcommands — so the reader is a new
  oracle verb, not a file read in the UI.

## 1. CLI: `artifact RUN --stage S (--show | --show-previous)`

- `--show`/`--show-previous`/`--accept`/`--reject` are mutually exclusive
  (exactly one of the four).
- Read-only: shares the pipeline/active/stage-in-pipeline guards but
  skips the gate reason_code check and never mutates state.
- `--show` prints the draft (`<run_dir>/<stage>-draft.md`) verbatim to
  stdout, exit 0; missing draft → actionable refusal (`no draft to show:
  <path>`).
- `--show-previous` prints the latest regeneration context
  (`<run_dir>/regen-<stage>.md`: the reject summary plus the rejected
  draft, written by the next `stage` attempt after a reject). Only the
  latest snapshot exists — every regeneration overwrites it, so this is
  a previous-version contrast, not a history browser. Missing file →
  actionable refusal (`no previous draft to show: <path> (written when
  the stage regenerates after a reject?)`).

## 2. TUI: `o` opens the viewer

- Fresh `status --json` → `awaiting_stage()` (same resolution as the gate
  keys; never the auto-refresh cache) → capture `artifact RUN --stage S
  --show` → full-screen bordered viewer titled `RUN/stage-draft.md`.
- Keys inside the viewer: `j`/`Down` line down, `k`/`Up` line up,
  `PageDown`/`PageUp` page, `g` top, `G` bottom, `p` toggle to the
  previous version and back, `/` search, `n`/`N` next/previous match,
  `Esc`/`q` back to the list. The list scan and
  status refresh pause while the viewer is open (static content, no
  subprocess churn).
- Search (`/`, AC-V7/V8 below):
  - `/` opens a modal input rendered in the viewer's bottom border
    (`search: <typed>▌`); while it is open every `Char` key appends,
    `Backspace` pops, `Enter` commits, `Esc` cancels (the viewer stays
    open; the input closes).
  - Commit: case-insensitive substring matches over the currently
    rendered body, one hit per line. An empty input commits as a
    cancel (no state change). No match → bottom-border notice
    `no match: <query>`, no jump. Otherwise jump to the first match at
    or after the current offset (wrap to the first), and the bottom
    border carries `/<query> · match i/n` until replaced.
  - `n`/`N` cycle matches with wrap; without a query they are a
    bottom-border notice. A `p` toggle recomputes the matches against
    the newly rendered body (same query) and snaps to the first match
    at or after the offset.
- `p` (previous-version toggle): first press captures `artifact RUN
  --stage S --show-previous` and renders it under the title
  `RUN/regen-<stage>.md`; the next press returns to the current file.
  Offset resets on every switch. Oracle refusal → notice, the viewer
  stays open on the current file (a keypress must never kill the
  view). The previous content is cached after the first fetch — one
  oracle call per toggle-in, not per keystroke. The viewer is a
  full-screen early-return render, so the list notice area is not
  visible while it is open: the refusal is therefore rendered as the
  viewer's bottom-border title, and the next keypress clears it.
- Oracle error → notice, no viewer. Keymap otherwise unchanged; footer
  hint gains `o view artifact`.

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-V1 | `--show` prints the draft verbatim; missing draft refuses with the path | §75 (CLI part) |
| AC-V2 | `o` opens the viewer with the draft content; scroll keys work; `Esc` returns to the list | §75 (tmux smoke) |
| AC-V3 | argv builder + keymap row; viewer never builds argv from the cache | cargo unit tests |
| AC-V4 | gate keys unchanged; wizard intact | existing cargo tests + §69/§74 |
| AC-V5 | `--show-previous` prints the latest regen context; missing file refuses with the regen-specific hint | §77 (CLI part) |
| AC-V6 | viewer `p` toggles current ↔ previous (title + content swap, offset reset); refusal keeps the viewer open on the current file | §77 (tmux smoke) |
| AC-V7 | `find_matches` is case-insensitive, one hit per line, order-stable | cargo unit tests |
| AC-V8 | `/` input modal renders and commits; match jump + `n`/`N` wrap; no-match and empty-query refusals render on the bottom border; `g`/`G` jump top/bottom | §79 (tmux smoke) |

## 4. Non-goals

- A rejected-drafts *history browser*: only the latest regen context is
  reachable (`regen-<stage>.md` is overwritten by every regeneration —
  older drafts are not on disk to show).
- Line numbers: the paragraph wraps, so a logical line spans multiple
  visual rows and a gutter would misnumber; search jumps make absolute
  positions less relevant.
- Search inside the run-detail screen (short content, fits one screen).
- Syntax highlighting / wrapping toggles.
