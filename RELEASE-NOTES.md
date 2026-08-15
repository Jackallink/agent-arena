# Release Notes

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
