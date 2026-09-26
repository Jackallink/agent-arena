# Intent — s2ui: expose and render pipeline stage chains

## Problem
The dashboard TUI lists pipeline runs (created via `--pipeline`), but the run
detail view only reports generic status. An operator cannot see where a run
sits in its artifact chain (intent → spec → plan) because `status RUN --json`
carries no per-stage data.

## Desired outcome
- Extend `status RUN --json` with a top-level `stages` array for pipeline
  runs. Each element is `{"name": "<stage>", "status": "<manifest status>",
  "attempts": <int>}`, in manifest pipeline order (intent → spec → plan).
- Render the chain in the TUI run detail view, e.g.
  `intent accepted -> spec awaiting_accept -> plan pending`.
- Omit `stages` for non-pipeline runs and for error-path documents.
- Leave `list --json` unchanged.

## Constraints
- Stage `status` must be the exact values stored under
  `stage_<name>_status` in the manifest (`pending`, `generating`,
  `awaiting_accept`, `accepted`, `failed`); `attempts` comes from
  `stage_<name>_attempts`. Do not translate these to run-state reason codes
  (e.g. `awaiting_stage_accept` is not a stage status).
- JSON contract stays v1 and remains strict-serde parseable: the `stages`
  key is optional in the UI model, so older and error-path documents still
  parse.
- Thin-client rule: the TUI reads only the oracle JSON and still spawns only
  the existing non-destructive CLI actions.
- Bash 3.2 / macOS-compatible, `set -euo pipefail`, no `eval`; tests are
  hermetic (no live model or network).

## Success criteria
- Bash (`tests/run.sh`): a pipeline run's `status --json` emits `stages` with
  the correct per-stage name/status/attempts; a non-pipeline run omits the
  `stages` key; the document stays valid JSON with escaping rules intact.
- Cargo (`ui`): the stage-chain renderer produces
  `intent accepted -> spec awaiting_accept -> plan pending`; strict `status`
  parsing accepts both a present `stages` array and its absence.
- All gates stay green: `bash tests/run.sh`, `bash tests/tmuxp-smoke.sh`,
  `bash packaging/package.sh --check`, and `cargo test` in `ui/`.
