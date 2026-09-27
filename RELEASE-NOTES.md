# Release Notes

## v0.7.8 — viewer search + end jumps (2026-09-27)

### Added

- **`/` search in the artifact viewer** (spec
  `2026-09-27-tui-artifact-viewer` AC-V7/V8): modal input in the bottom
  border; case-insensitive matches jump with wrap; the counter
  (`/query · match i/n`) persists on the bottom border. `n`/`N` cycle;
  the `p` previous-version toggle recomputes matches so one query can
  contrast the rejected draft with the regeneration.
- **`g`/`G` jump top/bottom.**

### Notes

- Line numbers remain a non-goal: wrapped logical lines would
  misnumber.

## v0.7.7 — run detail screen + status JSON trap fix (2026-09-27)

### Added

- **TUI run detail screen** (spec `2026-09-27-tui-run-detail`): `Enter`
  on a run row opens a full-screen render of a fresh `status --json` —
  all fields sorted, pane liveness, stage chain with attempt counts.
  `w` jumps to the writer pane (refusals render on the bottom border,
  never closing the screen). §78 + cargo tests; §73 moved to the new
  Enter contract.

### Fixed

- **`status --json` emitted NOTHING for early dies** (locked runs): the
  EXIT-trap error document crashed on Bash 3.2 (`set -u` + empty array
  expansion), leaving stdout empty — a direct violation of the
  documented "every exit emits the document" contract. Locked runs now
  emit `{"error":"locked"}` with exit 4. Found by the detail-screen
  test itself.

## v0.7.6 — previous-version toggle (2026-09-27)

### Added

- **`artifact --show-previous`** (spec `2026-09-27-tui-artifact-viewer`
  AC-V5): prints the latest regeneration context — the reject summary
  plus the rejected draft, written by the next stage attempt after a
  reject. Read-only, same guard family as `--show`; the four actions
  are mutually exclusive.
- **TUI `p` inside the artifact viewer** (AC-V6): toggles current ↔
  previous with one oracle call per toggle-in; refusals render as the
  viewer's bottom border (the list notice area is not visible while the
  full-screen viewer is open) and never close the view.

### Notes

- The spec's non-goal is narrowed: only the latest regen snapshot is
  reachable — a full rejected-draft history browser remains out of
  scope (older drafts are overwritten on disk).

## v0.7.5 — canceled+intake read-back fix (2026-09-27)

### Fixed

- **canceled runs in the implementation phase are readable again** (found
  by real usage seconds after using the feature): the legal-combination
  invariant covered canceled intent/spec/plan/submitted/validated/decided
  but not `intake` — the exact shape the v0.7.1 orphan cancel writes.
  State written by orphan cancel was well-formed but every oracle
  (status/list/repair) refused it. §72 now re-reads via `status --json`.

### Test robustness

- §61 dashboard dispatch probes hide both source-tree UI binaries
  (debug + release); a repo-local release build previously hijacked the
  hint/PATH branches.

## v0.7.4 — Accepted-artifact viewer (2026-09-27)

### Added

- **`artifact --show` covers accepted artifacts** (spec
  `2026-09-27-artifact-show-accepted`): the working draft wins while it
  exists; otherwise the accepted `<stage>.md` prints. The phase/gate
  checks now gate accept/reject only — accepted artifacts outlive their
  stage phase.
- **TUI `o` falls back to the furthest accepted stage** when no stage is
  awaiting; the viewer title carries the real filename.

### Test additions

- §76: CLI draft-preferred + post-accept view; tmux smoke for the
  accepted title and the inert non-pipeline path. Suite §0–76 green;
  cargo test (22) + clippy `-D warnings` clean.

## v0.7.3 — Artifact viewer (2026-09-27)

The gate is now fully in-dashboard: read the draft, then gate it.

### Added

- **`artifact RUN --stage S --show`** (spec `2026-09-27-tui-artifact-viewer`):
  read-only oracle verb printing the awaiting draft verbatim; skips the
  gate reason_code check, mutually exclusive with accept/reject, refuses
  with the path when no draft exists.
- **TUI `o` viewer**: opens the awaiting draft full-screen (title
  `RUN/stage-draft.md`), j/k line scroll, PgUp/PgDn pages, Escape/q back.
  Resolves the stage from a fresh status fetch — same rule as the gate
  keys — and pauses the tick scans while open.

### Test additions

- §75: CLI verbatim output + no-draft refusal + read-only proof; tmux
  smoke (open, content, Escape back). Suite §0–75 green; cargo test (21) +
  clippy `-D warnings` clean.

## v0.7.2 — TUI artifact gate (2026-09-27)

The artifact pipeline is now operable from the dashboard.

### Added

- **`g` / `G` artifact gate keys** (spec `2026-09-27-tui-artifact-gate`):
  `g` accepts the awaiting artifact, `G` rejects it with a prompted
  summary. The gate target (first `awaiting_accept` stage in manifest
  order) is resolved at keypress time from a fresh `status --json` fetch —
  never from the auto-refresh cache — and every spawn is the verbatim
  `artifact RUN --stage S ...` argv on a confirm line. No awaiting stage
  stays inert with a notice.

### Test additions

- §74 tmux smoke: accept through the confirm line renames the draft and
  records the digest; reject records `stage_intent_reject_summary` and
  re-arms; the gate is inert after consumption. Suite §0–74 green; cargo
  test (20) + clippy `-D warnings` clean.

## v0.7.1 — Live status & orphan-run recovery (2026-09-27)

Patch release born from real dogfooding (run `s2ui` drove both changes).

### Fixed

- **Orphan-run cancel** (spec `2026-09-27-orphan-run-cancel`): a writer-owned
  implementation run whose writer tmux session died (never submitted) had no
  sanctioned human exit — `resolve --action cancel` now admits that shape
  (party=writer, phase=intake, reason=none, session gone) with the ordinary
  cancel delta. Live session still refuses with an actionable message.
  live8 was the stuck run that motivated this; closed with the feature.
- **TUI error-document adoption** (found by the §73 smoke): a tick refetch
  that returned an oracle error document (empty `fields`) used to be
  adopted into the status cache; the last good status is now kept.

### Added

- **TUI live status** (spec `2026-09-27-tui-live-status`): the dashboard
  polls with a 1.5s tick — the run list and the fetched status row
  (verdict + pipeline stage chain) refresh without keypresses, making the
  v0.7.0 stages chain actually watchable. Keymap unchanged; Input/Confirm
  modes still never spawn on tick.
- **`status --json` stage chain** (from run s2ui, merged from the writer
  branch): pipeline runs expose `stages: [{name,status,attempts}]` in
  manifest order; the TUI renders the chain; non-pipeline and error-path
  documents omit the key; `list --json` unchanged.

### Test additions

- §72 (orphan cancel: success + live-session refusal), §73 (tmux smoke:
  no-keypress refresh, field preservation, vanished-run cache drop);
  suite §0–73 green; cargo test + clippy `-D warnings` clean.

## v0.7.0 — Multi-stage artifact pipeline (2026-09-26)

Feature release: pre-implementation runs gain a human-gated artifact
pipeline — intent, spec, and plan artifacts are generated by headless
stage sessions, accepted or rejected by a human gate, and seeded into the
writer worktree before the first implementation commit.

### New capabilities

- **Artifact pipeline state machine**: phases extend to `intent`, `spec`,
  and `plan` before `intake`; new reason codes (`awaiting_stage_start`,
  `awaiting_stage_accept`, `stage_generating`, `stage_failed`); a
  `pipeline` manifest key records the resolved stage list; state revision
  and CR=0 invariants cover every stage phase (evidence-free until
  bootstrap).
- **`stage RUN <intent|spec|plan>`**: launches a fresh headless stage
  session per attempt (session ids suffixed `-a<N>`, no resume — jihulab
  327 safe), composes the template + prior artifacts + `--prompt-text`
  instruction as `@file` attachments, runs under a seatbelt write-boundary
  sandbox (`read,write` tool gate, soft-mode fallback with a visible
  `STAGE SANDBOX UNAVAILABLE` warning), and harvests the draft to
  `awaiting_stage_accept` or `stage_failed`.
- **`artifact RUN --stage S --accept|--reject`**: the human gate. Accept
  hashes the draft (sha256, recorded in the manifest), renames
  `<stage>-draft.md` → `<stage>.md`, and advances the pipeline; the final
  accept bootstraps implementation automatically. Reject returns the stage
  to `pending` with a `reject_summary` fed into the next attempt.
- **`roles.conf` (global + per-repo)**: stage → adapter/model/prompt
  configuration with a `headless_stage` capability gate, `path:line` error
  reporting, and `none|lean|full|intent,spec,plan` depth resolution.
- **`start --pipeline / --from-intent`**: two-phase start — pipeline runs
  create state + pipeline manifest without a worktree until the pipeline
  completes; `--from-intent` seeds the intent draft (validated: size,
  UTF-8, stage membership).
- **Bootstrap**: deferred writer worktree creation on `agent-arena/<profile>/<run>`
  from the committed base, plus seeded `docs/arena/<run-id>/<stage>.md`
  plan files (untracked until the writer's first commit adopts them).
- **Stage-phase cancel**: kills a hung stage lock owner (TERM → KILL) and
  removes the run directory — the only cancel privilege in a pre-worktree
  phase.
- **TUI `n` new-run wizard**: run_id → repo → profile → pipeline depth →
  advisory models (roles.conf hint; models never enter argv), verbatim
  confirm line, Esc/q cancel at every step (spec §11, walkthrough F8).

### Live end-to-end verification (real zell stage sessions, 2026-09-26)

- **Full pipeline (live8)**: `start live8 --pipeline full` → real zell
  headless stages generated intent, spec, and plan drafts; each accepted
  via `artifact --accept` (sha256 recorded); the final accept bootstrapped
  the writer worktree and seeded `docs/arena/live8/{intent,spec,plan}.md`.
- **Lean run (live7)**: intent stage → accept → bootstrap → simulated
  writer first commit carries `docs/arena/live7/intent.md` plus the feature
  change; `submit` produced the SHA-bound checkpoint and reviewer snapshot.
- **TUI lean-run creation (suite §69)**: the `n` wizard drove a real tmux
  session end-to-end — key sequence → verbatim confirm argv → spawn →
  manifest pipeline `intent` → refreshed list row.

### Verification gates

- `bash tests/run.sh` sections 0–70 green (~7 min; §62 v0.6 regression,
  §63 roles.conf, §64 stage argv/harvest, §65 artifact guards, §66
  from-intent, §67 bootstrap, §68 seatbelt skip-guard, §69 TUI + wizard
  smoke).
- `cargo test` + `cargo clippy -- -D warnings` clean; non-tty refusal
  intact.
- `packaging/package.sh --check` and `packaging/build-ui.sh --check`
  verified for 0.7.0 artifacts.

### Known limitations

- Per-stage sandboxing uses the macOS seatbelt profile; on hosts without
  `sandbox-exec` the stage runs with adapter-level tool gating only and a
  visible warning (by design).
- TUI model input is advisory only: per-stage models come from
  `roles.conf`; `start` does not carry model overrides in v0.7.


## v0.6.1 — Dashboard TUI companion (2026-08-15)

Minor feature release: Agent Arena gets a terminal dashboard and a JSON
oracle layer that any future UI consumes.

### New capabilities

- **`agent-arena list --json` / `status RUN --json` (JSON contract v1)**:
  every exit path emits a JSON document on stdout — errors carry an
  `"error"` field, exit codes are unchanged, and human output stays
  byte-identical without the flag. Strings are escaped per RFC 8259.
- **`agent-arena dashboard`**: launches the `ui/` Rust TUI (builds on demand
  with the `cargo build` hint when missing; refuses a non-tty stdin
  instead of blocking).
- **`ui/` Rust + Ratatui thin client**: data only via the `--json` oracles,
  actions only via verbatim `agent-arena` subcommand spawns shown on a
  confirm line (`a` approve, `r` reject, `d` decision, `l` relay, `m` mode
  toggle, `v` validate, Enter writer-pane jump, `q` quit). Destructive
  subcommands are never mapped; the keymap→argv table is unit-tested with
  strict serde (`deny_unknown_fields`) and an unknown mode resolves
  human-safe (never auto-promotes to `auto`).
- **Interactive smoke (headless tmux)**: render, confirm line, prompted
  input, staged decision argv, cancel paths, a real child spawn with
  terminal suspend/restore, and a clean exit — all captured in a tmux
  pane against a real state root (plan Gate 4 evidence).

### Fixes

- **`init`/config escape quoted project names**: a repository directory
  containing `"` or `\\` no longer breaks `project.conf` round-trip.
  (`start` still refuses tmuxp-bound paths containing quotes by design.)
- **`list` corrupt rows render again**: a corrupt `run-state.tsv` used to
  kill the whole row via die-inside-if; list now probes in a subshell and
  reports the row with `anomaly: corrupt` (exit 2 aggregated, unchanged).

### Live end-to-end verification (real zell writer, 2026-09-25)

The dashboard drove a complete real loop — `l` relay delivered the task to a
live zell writer (it created `LIVE.md`, committed, and self-submitted), `v`
validate ran FAIL then PASS across checkpoints, `d` recorded a real
APPROVE decision bound to the resubmitted checkpoint, `a` completed the run,
and `m` toggled approval mode both ways on a second live run. The pass
surfaced and fixed six defects that hermetic tests could not see: a tmux
server-global `ARENA_*` environment leak that rebound spawned CLIs to an
unrelated run (fixed in start.sh and the TUI spawn layer), unparseable
error-path `status --json` documents, swallowed child stderr, a subprocess
per keystroke, a blind mode toggle, and a wrong reject mapping (`decision
--verdict CHANGES_REQUESTED` is the reviewer-phase reject; the CLI has no
REJECT verdict). Details: plan Gate 4.

### Test evidence

- `tests/run.sh`: 62 sections green (§61 covers the JSON oracles, escaping,
  dashboard dispatch, and the `--selftest` probe).
- `cargo test` (ui/): 9 passed; zero warnings.
- `tmuxp smoke`: ok. `packaging/package.sh --check`: OK (archive now
  verified to contain the ui/ dashboard source).

## v0.6.0 — Zell writer adapter (2026-08-15)

Minor feature release: Zell (0.4.0-rc.1) joins as the fifth writer, fully
live-tested, plus one validation-pipeline fix the live smoke exposed.

### New capabilities

- **`zell-cursor` writer profile** (plus generic `zell-opencode` through the
  existing WRITER-GATE fallback): launch binds an exact `--session-id`
  (`agent-arena-<run>`), an Arena session directory, a named session, the
  policy prompt via `--append-system-prompt`, and defense-in-depth
  auto-discovery suppression (`--no-extensions`, `--no-skills`,
  `--no-prompt-templates`, `--no-themes`). Resume rebinds the exact session ID
  only — never `--continue`, `--resume`, or `--fork`.
- **Live-tested evidence (S1–S4, 2026-08-15)**: headless smoke; interactive
  exact-session resume; full Arena loop where the real Zell writer
  auto-created a feature, committed, and ran `submit` itself (~50 s), the real
  authenticated Cursor gate headless-validated `RESULT: PASS`, and
  `autopilot --once` auto-approved the run to `completed` (actor=system,
  instance-token reason).
- **Trust model, stated plainly**: Zell auto-executes write/bash with no
  approval gate (`approval=auto-execute`) — the same prompt-bound model as Pi;
  `sandbox=none`. The suppression flags are config hygiene, not an OS or
  network sandbox.
- Doctor, README (en/zh), and the adapter contract list the new profile.

### Fixes

- **Validation exit-2 sentinel collision** (found by the live smoke): a
  project `validate.sh` exiting 2 collided with `run_gate`'s
  snapshot-integrity sentinel — the run got a diagnostic-only report, no
  state transition, and could not be pushed forward by any reviewer action.
  Project-script failures are now normalized to a canonical FAIL (validate
  exits 10, `VR=FAIL`); the sentinel stays exclusive to real integrity
  failures. Covered by a failing-first test (§60).

### Known upstream issue (recorded, non-blocking)

- `zell --print` resuming an existing `--session-id` aborts (bus error in
  `restoreSessionSettings`, zell 0.4.0-rc.1). Interactive resume — the only
  path Arena writers use — is unaffected and was verified live.

### Verification (2026-08-15)

- Hermetic suite: 60 sections green (§58 zell adapter, §59 legacy
  mode-switch state fallback, §60 exit-2 canonical FAIL), tmuxp smoke, CLI
  contract smoke, package check, and `bash -n` all green.
- Live smoke S1–S4 as above; evidence recorded in
  `docs/superpowers/plans/2026-08-15-zell-writer-adapter.md` (no credentials
  or transcripts in Git).

## v0.5.2 — Patch (2026-08-15)

Patch release after v0.5.1: observation-contract and lock-hygiene fixes found
by a post-release code review of `autopilot`/`mode`. The v0.4/v0.5 state
machine, wire contract, and exit-code protocol are unchanged.

### Fixes

- **Round summary line** (spec contract, previously missing): every
  `autopilot` round now prints `<ts> scanned=<n> acted=<n> needs-human=<n>
  errors=<n>`; `--once` prints it after the per-run TSV rows.
- **Watch stdout discipline**: per-run TSV rows are `--once`-only (cron
  consumption); `--watch`/`--rounds` print only the round summary line.
- **Log rotation**: rotation now keeps three generations oldest-first
  (`.2→.3`, `.1→.2`, `log→.1`); the previous order chained the same content
  and kept one. Shared as `arena_log_rotate` (lib/common.sh), also applied to
  mode-switch rows that previously bypassed rotation.
- **Heartbeat errors counter**: previously always 0; now summed from every
  error-logged scan branch (corrupt, incomplete transition, unexpected exit,
  guard mismatch, failed auto-approve).
- **mode lock hygiene**: `mode` is now trap-disciplined like every other
  `arena_lock_acquire` caller — a terminal-refused switch no longer leaves
  the `.run-lock` behind.
- **mode action-log schema**: mode-switch rows follow the spec schema
  `timestamp run_id mode state action result` (fields 2/3 were swapped).

### Verification (2026-08-15, hermetic, no model/network)

- Hermetic suite: 58 sections green (§0–55 unchanged, §56 round summary /
  watch stdout / rotation / error count, §57 mode lock release / action-log
  schema / rotation), tmuxp smoke, CLI contract smoke, package check, and
  `bash -n` all green.
- New sections were written first and failed against the unfixed binaries
  (TDD), per the fix-pass and cleanup-pass records in
  `docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`.
- No new live smoke: the changes touch stdout/observation files and lock
  release paths only; the v0.5.1 live two-model unattended loop evidence
  remains the authoritative behavioral validation.
- Plan bookkeeping: `pluggable-gate-adapters` plan checkboxes back-filled to
  complete after a Gate-3 artifact re-verification (gate resolution, manifest
  fallback, hash checks, pane dispatch, both gate adapters present).

## v0.5.1 — Patch (2026-08-15)

Patch release after v0.5.0.

### Fixes

- `help` now lists the `mode` and `autopilot` commands (they were dispatched
  but missing from the help text).

### Verification (2026-08-15)

- Hermetic suite unchanged: 56 sections green, tmuxp smoke, CLI contract
  smoke, package check, and `bash -n` all green.
- Live validation (independent temp repo, no development project touched):
  full two-model unattended loop with the real Pi CLI (v0.84.2) as writer
  (created a feature, committed, ran `submit`) and the real authenticated
  Cursor agent as reviewer (`validate` → `RESULT: PASS`, `decision APPROVE`),
  then the real `autopilot --once` auto-approved the run to `completed`
  (actor=system, instance-token reason). Evidence archived under the state
  directory and recorded in the v1 implementation plan.

## v0.5.0 — Autopilot approval modes (2026-08-15)

Human/auto approval modes plus an autopilot orchestrator: the review loop can
now run unattended along the happy path while every stalled path becomes an
observable alert.

### New capabilities

- **Approval modes**: `approval_mode` in `project.conf` (default `human`),
  `start --mode auto` per-run override, and runtime `agent-arena mode RUN_ID
  human|auto` (under the run lock, audited, refused on terminal runs). `status`
  prints `Mode:` and a drift marker when config and manifest disagree.
- **Autopilot**: `agent-arena autopilot --once|--watch` with
  `--interval/--approve-delay/--relay-after/--resume-attempts/--repo/
  --all-repos/--rounds`. In auto mode, APPROVE+PASS checkpoints are approved
  after a cooling window with `actor=system` and an instance-token reason;
  dead reviewer panes auto-escalate (T9); stalls, pane-dead writers, blocked
  runs, and corrupt/conflict/incomplete states alert (exit 6).
- **Oracle extension**: `status` now prints `Verdict:`, `Validation result:`,
  `Last transition at:`, and reviewer/writer pane liveness lines — the only
  read path autopilot uses.
- **Audit**: autopilot exit-code protocol `0/4/6` (needs-human is 6, distinct
  from every v0.4 code); per-instance heartbeats with `last_seen` lock
  liveness; append-only action log with rotation; relay reminders throttled.
- **Foundation fixes**: atomic lock reclamation (rename-to-tombstone,
  two-claimer safe); `resolve`/`escalate --actor human|system`; approve
  `--reason` preserved into `reason_detail`.

### Verification (2026-08-15, hermetic, no model/network)

- Hermetic suite: 56 sections green (v0.4 §0–49 with zero semantic drift plus
  §50–55), tmuxp smoke, CLI contract smoke, and package check green.
- Multi-expert walkthrough (5 roles, 3 rounds, debate) + Gate-1 second round:
  all rulings applied (docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/).
- Review: detached snapshot tag `review/autopilot-v0.5` re-verified green;
  PR #3 merged into `main` at `66258b3` (fast-forward).

### Release gate

- Gate 4 evidence: credential/tracked-file scan clean before this release
  (recorded in `docs/superpowers/plans/2026-08-13-agent-arena-v1.md`).
- Archive checksum: `dist/agent-arena-0.5.0.tar.gz.sha256` (5e1c04f57a7c1ddf3908dba7bb489046f44d8640c3409924a60c4c127db2413c; regenerated after the help-usage fix `70c28ce`).

## v0.4.0 — Run state authority (2026-08-15)

Every run now has one authoritative answer to "who is next, waiting on what,
since when, and how is it released": a per-run `run-state.tsv` becomes the
single source of truth for the current responsible party and waiting state.

### New capabilities

- **Run state authority**: `run-state.tsv` with the full transition matrix
  T1–T14 plus legacy first-write migrations (L-T3/L-T6); field invariants and
  legal-combination checks fail closed on corruption (exit 2).
- **Run lock**: mkdir-based per-run locks with atomic owner metadata
  (PID/token/created_at), a 60s metadata-less grace window, and dead-PID
  recovery; every transition commits under the lock (exit 4 while held).
- **Human commands**: `escalate` (reviewer unreachable → human, exit-5
  idempotent in blocked) and `resolve` (approve/reject/recover/cancel); plus
  `repair-state` with intent-first, crash-recoverable three-state recovery
  for legacy evidence conflicts and corrupted state.
- **Crash observability**: creation-intent stages S1–S6 and repair intents
  make interrupted transitions retryable; non-start commands refuse on a live
  creation intent (exit 5) or the manual abort protocol (exit 2).
- **Oracle commands**: `status` prints a one-sentence diagnosis with the
  exact release command; `list` prints fixed columns
  (REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE
  WAITING_SINCE AUTHORITY ANOMALY) and aggregates anomaly codes by priority
  5 > 4 > 2 > 0. Both are zero-write.
- **Legacy compatibility**: runs without `run-state.tsv` project read-only
  (L1–L6); the first transition migrates inside the run lock. Validate
  publishes reports via CAS with op-token baselines (exit 3 stale, exit 10
  recorded FAIL; integrity failures write `.diagnostic.md` only).

### Verification (2026-08-15, hermetic, no model/network)

- Hermetic suite: 50 test sections green (v0.3 regression §1–37 plus §38–49),
  tmuxp smoke, CLI contract smoke, and package check green.
- Review: detached snapshot tag `review/run-state-v0.4` re-verified green;
  PR #2 merged into `main` at `2b2a5f3` (fast-forward).
- Real-Cursor gate smoke (2026-08-15): full T-matrix lifecycle in a real
  Git/tmuxp environment (start → submit → validate → decision → resolve
  approve → completed; escalate → recover with the reviewer-pane protection
  observed), then the authenticated Cursor headless run executed the gate
  wrapper `validate` end-to-end (`RESULT: PASS`, SHA-bound report published).
  One drift (D5): shell redirection writes bypassed the sandbox denials in
  this agent build; the post-run snapshot integrity check detected the
  pollution and `status` failed closed — audit chain closed (details in
  `docs/superpowers/plans/2026-08-13-agent-arena-v1.md`).

### Release gate

- Gate 4 evidence: credential/tracked-file scan clean before this release
  (recorded in `docs/superpowers/plans/2026-08-13-agent-arena-v1.md`).
- Archive checksum: `dist/agent-arena-0.4.0.tar.gz.sha256`.

## v0.3.0 — Pluggable gate adapters (2026-08-13)

The review/validation/decision gate is now a pluggable adapter, matching the
writer layer. Cursor remains the default gate; OpenCode joins as a second gate
with a deny-first project policy.

### New capabilities

- **Writer-gate free combination**: `--profile WRITER-GATE` (for example
  `pi-opencode`) or explicit `--writer NAME --gate NAME`. v0.2 forms such as
  `pi-cursor` work unchanged.
- **Gate adapter contract**: `probe` / `capabilities` / `launch` / `policy`
  with a three-column binding manifest; the reviewer pane dispatches via the
  run manifest's `gate_adapter`, never a guessed one.
- **OpenCode gate**: generated `opencode.json` gate agent that denies
  edit/webfetch/websearch/task/question/external_directory and allows bash
  only for the gate wrapper; the post-run integrity check closes tampering.
- **Legacy compatibility**: v0.1/v0.2 manifests and review manifests resolve
  to the Cursor gate; no migration needed.
- `doctor` lists every available gate.

### Verification (2026-08-13, all live, authenticated)

- Cursor gate: headless policy enforcement (Gate 4) + interactive
  reviewer-pane end-to-end + two-checkpoint loop (CHANGES_REQUESTED →
  APPROVE) + relay delivery + CLI auto-update compatibility.
- Writers: Pi, Codex, OpenCode, and Agy all verified headless, in interactive
  TUI, and in full Arena end-to-end runs (writer creates, commits, and
  submits on its own).
- Hermetic suite: 38 test sections green, tmuxp smoke, CLI contract smoke,
  and package check green.

### Release gate

- Gate 4 evidence: complete (recorded in
  `docs/superpowers/plans/2026-08-13-agent-arena-v1.md`).
- Source publication: MIT license on file; credential/tracked-file scan
  clean before this release.
- Archive checksum: `dist/agent-arena-0.3.0.tar.gz.sha256`.
