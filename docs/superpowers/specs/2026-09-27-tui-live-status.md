# Spec: TUI live status (auto-refresh)

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `ui/src/main.rs`, `tests/run.sh` §73, README key line; no model/JSON change
- Context: the s2ui stages feature (688f08e) renders the stage chain only
  after a keypress re-enters the loop — the TUI uses a blocking
  `event::read()`, so nothing on screen ever goes stale-to-fresh on its
  own. Correction to earlier claims: actions (a/r/d/l/m/v) already exist;
  the missing piece is purely liveness.

## 1. Rule

- The event loop polls with a 1.5s timeout. A timeout (no input) loops
  back; the existing loop-top re-scan (Normal mode: `list --json` +
  selection clamp + redraw) then acts as the refresh tick.
- `status_cache` (populated by `Enter`) refetches on every Normal-mode
  iteration for its own run_id; if the run no longer exists the cache is
  dropped and the notice line explains it. The two-row status area —
  verdict line + stages chain — therefore tracks reality while the user
  watches.
- Input/Confirm modes never pay a subprocess on tick (existing guard
  kept); ticks there only redraw.

## 2. Keymap

Unchanged: `j`/`k`, `Enter` (status digest + writer-pane jump),
`a`/`r`/`d`/`l`/`m`/`v`, `q`. No new keys in this increment.

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-T1 | verdict/stages in the status row refresh without any keypress after an external state change | §73 (tmux smoke, dedicated state root, single run) |
| AC-T2 | keys unchanged; wizard + spawn behavior intact | existing cargo keymap tests + §69 |
| AC-T3 | Input/Confirm modes do not spawn subprocesses on tick | code guard (matches! Normal), covered by §69 wizard flow |

## 4. Non-goals

- Full detail view (all fields) — the two-row status area suffices for
  v0.7.1; revisit with actions-on-artifacts later.
- Accept/reject artifacts from the TUI (destructive confirm design
  deferred).
- Configurable interval.
