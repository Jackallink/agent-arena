# Plan — s2ui: expose and render pipeline stage chains

## Objective
Add a top-level `stages` array to `status RUN --json` for pipeline runs and
render that chain in the `ui/` TUI run detail view. Keep `stages` absent for
non-pipeline runs, error-path documents, and `list --json`.

## Key files
`lib/status.sh` (oracle), `ui/src/model.rs` (strict serde + render helper),
`ui/src/main.rs` (TUI rendering), `tests/run.sh` (hermetic Bash gates).

## Steps
### 1. Emit `stages` from the Bash oracle — `lib/status.sh`
- Add `ARENA_STATUS_STAGES=''` beside the other status globals.
- Add `arena_status_build_stages()`: no-op unless `status_json == 1` and
  `ARENA_MANIFEST_PIPELINE` is non-empty; iterate the comma list in manifest
  order, map each stage via `arena_manifest_stage_index`, and emit
  `{"name":<stage>,"status":<ARENA_STAGE_STATUS[idx]>,"attempts":<int>}`.
  Coerce non-numeric attempts to `0`; escape name/status via
  `arena_json_string`.
- Call it in the success path inside the `[[ -f run-state.tsv ]]` block, just
  before `arena_status_finish 0`.
- In `arena_status_finish`, when `ARENA_STATUS_STAGES` is non-empty insert
  `,"stages":[...]` after `"fields":{...}` in the success printf only. Leave
  the error printf and the EXIT-trap document untouched.

### 2. Keep absence guarantees
- Non-pipeline: helper no-ops on empty `ARENA_MANIFEST_PIPELINE`.
- Error paths: helper is never called, so error docs omit `stages`.
- `list --json`: untouched (`lib/list.sh` unchanged).

### 3. Extend the Rust strict model — `ui/src/model.rs`
- Add `StageStatus { name: String, status: String, attempts: u64 }` with
  `#[serde(deny_unknown_fields)]`.
- Add `#[serde(default)] pub stages: Option<Vec<StageStatus>>` to
  `StatusDoc` (absent docs parse; present docs stay strict).
- Add `pub fn stage_chain(&self) -> Option<String>` mapping each stage to
  `"{name} {status}"` and joining with `" -> "`.

### 4. Render the chain — `ui/src/main.rs`
- In the `status_cache` draw block, render a second `Paragraph` in the
  `chunks[2]` second row when `stage_chain()` returns `Some`; skip on `None`.
- No new spawns or CLI actions (thin-client rule unchanged).

### 5. Add tests
- `ui/src/model.rs`: unit tests parse `status` docs with and without
  `stages`, and assert `stage_chain()` ordering and `" -> "` join.
- `tests/run.sh`: new section `71. status --json stage chain and list --json
  unchanged` (before the final `tests: ok`):
  - Start `s2ui` with `--pipeline intent,spec,plan`; append verbatim
    `stage_intent_status=accepted`, `stage_intent_attempts=3`,
    `stage_spec_status=awaiting_accept`, `stage_spec_attempts=1`.
  - Assert the exact `"stages":[...]` substring in `status --json`.
  - Start a non-pipeline run; assert `status --json` has no `"stages"`.
  - Corrupt `s2ui` state (duplicate `phase`); assert exit 2 + no `"stages"`.
  - Assert `list --json` has no `"stages"` (AC7).

## AC-to-test mapping
- AC1/AC2/AC3: Bash §71 exact `stages` substring + verbatim statuses.
- AC4/AC5: Bash §71 absent-case + corrupt-case assertions.
- AC6: stage names/statuses go through `arena_json_string`.
- AC7: Bash §71 `require_no_match '"stages"'` on `list --json`.
- AC8/AC9: Rust `stage_chain` unit tests (present/absent).
- AC10/AC11: Rust `parse_status` tests with and without `stages`.
- AC12/AC13/AC14: no spawn changes; `set -euo pipefail` kept; tests hermetic.

## Validation gates
```bash
bash tests/run.sh
bash tests/tmuxp-smoke.sh
bash packaging/package.sh --check
(cd ui && cargo test)
```

## Rollback
Revert `lib/status.sh`, `ui/src/model.rs`, `ui/src/main.rs`, and the new
`tests/run.sh` §71. The change is additive: older documents without `stages`
remain strict-parseable, and `list --json` is untouched, so rollback has no
migration or persisted-state impact.
