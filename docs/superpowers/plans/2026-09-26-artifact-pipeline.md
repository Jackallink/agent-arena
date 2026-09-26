# Plan: v0.7 Artifact Pipeline (intent → spec → plan → implementation)

- Spec: `docs/superpowers/specs/2026-09-26-artifact-pipeline.md` (walkthrough-closed, Gate 0 verified)
- Date: 2026-09-26 · Gates below follow the repo SDD flow (failing tests → implement → gates)

## Verified baseline facts (recon + Gate 0)

- `run-state.tsv` has a CLOSED key set (unknown key = corruption): phase enum at `lib/state.sh:91`, reason_code at :93, action at :110, plus per-phase legal-combination invariants :115-210.
- `manifest.tsv` is the identity record; `mode.sh` sets the awk-upsert-under-lock mutation precedent; reader dies on unknown keys → must extend reader for `pipeline` + `stage_<s>_*` keys.
- `arena_lock_acquire` ALREADY reclaims dead owners (`lib/lock.sh:78-100`) — F4 needs only the `stage_<s>_recovered_at` manifest audit key.
- start.sh is one-shot: creation-intent staging S1–S6 (NOTE: pre-existing "intent" = crash-recovery vocabulary, unrelated to the intent artifact stage), worktree add, state T1, manifest, tmuxp. Pipeline mode splits this (F3).
- Tests fake adapters via `ARENA_ZELL_BIN` etc. + `ARENA_TEST_MODE=1` (tests/run.sh:82+).
- Gate 0: fresh `-p` session ids work; resume crashes (jihulab 327) → attempt-suffixed ids; `--append-system-prompt` text-only → `@file` attachments; stdout JSONL malformed (326) → never parse.

## State machine design (delta to state.sh)

Phases `intent|spec|plan` insert before intake; `bootstrap` (final artifact accept) lands on
existing intake invariants untouched. New reason_codes: `awaiting_stage_start`,
`awaiting_stage_accept`, `stage_generating`, `stage_failed`. New actions: `stage`,
`artifact`, `bootstrap`.

Legal active-stage combos (all: verdict/VR/VD/CS empty, CR=0):

| phase | party | reason | waiting_since |
|---|---|---|---|
| intent/spec/plan | human | awaiting_stage_start | set |
| intent/spec/plan | human | awaiting_stage_accept | set |
| intent/spec/plan | none | stage_generating | empty |
| intent/spec/plan | human | stage_failed | set |

Canceled run in a stage phase: same emptiness as intake-side of canceled.

## Manifest design (delta to common.sh)

Reader: `pipeline` key + indexed-array stage fields (`ARENA_STAGE_STATUS[i]` etc., i∈0..2 for
intent/spec/plan) — generic `stage_<name>_<field>` case branches with stage→index dispatch;
unknown stage name or field dies as corruption. Writer: `pipeline` key at start (pipeline mode).
Mutation: `arena_manifest_upsert run_dir key value...` (awk, mode precedent; caller holds lock).
New keys: `pipeline`, per stage: `status{pending,generating,awaiting_accept,accepted,failed}`,
`digest`, `accepted_at`, `agent`, `model`, `attempts`, `reject_summary`, `sandbox`, `recovered_at`.

## Component map

| Component | File | Notes |
|---|---|---|
| roles config | `lib/roles_conf.sh` (new) | global `${ARENA_CONFIG_HOME:-~/.config}/agent-arena/roles.conf` → project `<repo>/.agent-arena/roles.conf`, later wins; keys `<stage>_adapter/_model/_prompt`; fail fast path:line; `headless_stage=true` capability gate → missing ⇒ stage disabled (doctor warns) |
| stage cmd | `lib/stage.sh` (new) | phase guard; intent requires `--prompt-text/--prompt-file` (F1); lock acquire (dead-owner reclaim free) + `recovered_at` audit; roles resolve; adapter `stage-launch` exec; harvest = exit code + draft existence; S1→S2/S3; exit 0 on harvest regardless |
| artifact cmd | `lib/artifact.sh` (new) | guards (F6): draft exists, stage==phase; accept: sha256 → rename → manifest → next phase or bootstrap → hint (F2); reject: summary + stay; hints on stdout |
| start changes | `lib/start.sh` | `--from-intent FILE` (F7: non-empty, ≤64KB, UTF-8 iconv probe), `--pipeline LIST` (none/lean/full/commas; F5 validation); pipeline mode: run dir + manifest(pipeline, no worktree fields yet) + state S0/S2; v0.6 path byte-identical |
| bootstrap | `lib/bootstrap.sh` (new) | `arena_implementation_bootstrap RUN` — worktree add/dirty-check/probes/session/tmuxp/state→intake/seed `docs/arena/<run-id>/` (idempotent, refuses if manifest has writer_worktree); called by final accept; start.sh v0.6 path inlines the same function |
| adapter stage-launch | `adapters/zell.sh` | new `stage-launch` command: seatbelt profile (realpath run dir + TMPDIR; `ARENA_STAGE_SANDBOX_BIN` overridable, missing ⇒ loud soft warning + `sandbox=soft`), argv per spec §9, `@file` attachments, fresh attempt-suffixed session id |
| cancel privilege | `lib/resolve.sh` (cancel path) | stage-phase cancel: kill live stage PID (owner of `.run-lock` when phase generating) then proceed; non-bootstrap runs skip worktree teardown |
| doctor | `lib/doctor.sh` | advisory roles.conf summary + headless_stage declarations + skipped stages |
| json | `lib/list.sh`, `lib/status.sh` | additive `pipeline` (row array / fields flat string); v0.6-shaped runs byte-identical |
| TUI | `ui/` | `n` wizard (run_id→repo→profile→pipeline→[intent text]→models free text), phase display, `#[serde(default)] pipeline`, keymap table + tests |

## Guards for implementation-phase commands

`submit/validate/decision/relay/mode/autopilot/repair-state/escalate/resolve` see phase
`intent|spec|plan`: must refuse with a clear message (verify each one's existing phase guards;
add explicit stage-phase refusal where they currently pass-through). Status/list/tui render.

## Gates

- **Gate 1 — failing tests first**: §62 v0.6 regression; §63 roles.conf; §64 stage argv+harvest
  (fake zell via `ARENA_ZELL_BIN`, `ARENA_STAGE_SANDBOX_BIN=/nonexistent` for determinism);
  §65 accept/reject/guards; §66 from-intent; §67 seeding; §68 seatbelt (skip-guarded macOS);
  §69 TUI dispatch/keymap + cargo; §70 cancel/lock; §61 JSON compat extension. All red on
  current main, all green before Gate 2 closes.
- **Gate 2 — bash core**: implement components above; 62→70 sections green; `bash tests/run.sh`
  full suite green; shellcheck-clean style (repo conventions).
- **Gate 3 — TUI**: cargo test/clippy `-D warnings`; headless tmux smoke of the `n` wizard
  (input sequence → confirm line verbatim argv → spawn → run appears); non-tty refusal intact.
- **Gate 4 — live + release**: live zell stage pass (intent→spec→plan on scratch repo, human
  gates via CLI, writer first commit carries `docs/arena/<run-id>/`, TUI lean-run creation);
  tmuxp smoke; package.sh + build-ui.sh --check; RELEASE-NOTES; version 0.7.0.

## Test → AC map

Spec §12 AC1..AC14 → §62..§70 (§63 also carries AC11/AC13; §64 AC3+AC12; §65 AC4+AC13;
§66 AC5+AC13; §70 AC10+AC14) + §61 extension (AC9) + cargo (AC8) + Gate 4 live (L1–L4).

## Risks

| Risk | Mitigation |
|---|---|
| start.sh refactor breaks v0.6 recovery paths (S1–S6 creation intents) | v0.6 path keeps inline logic by calling bootstrap unchanged; §62 regression locks byte-identical behavior |
| state invariants get a stage hole | new combos enumerated above; state reader dies on anything else |
| adapter stage-launch hermeticity | fake zell argv contract; sandbox bin override for determinism |
| bootstrap called twice | manifest writer_worktree presence guard + run lock |
