# Release Notes

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
