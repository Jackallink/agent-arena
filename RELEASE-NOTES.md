# Release Notes

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
