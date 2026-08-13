# Agent Arena v0.1 implementation plan

## Gate record

- Gate 1 — spec audit: complete. Scope, non-scope, ACs, trace, and error paths are
  recorded in `../specs/2026-08-13-agent-arena-v1.md`.
- Gate 2 — TDD kickoff: complete. AC-to-test mapping is in the spec; tests are
  hermetic and precede the implementation checks.
- Gate 3 — drift check: complete. The spec, adapter policy, and hermetic tests are
  aligned; the Cursor policy smoke remains a first-authenticated-run manual check.
- Gate 4 — local handoff gate: pending authenticated Cursor policy smoke. Lifecycle,
  tmuxp, packaging, syntax, and whitespace validation passed. Public release remains
  out of scope until a license is chosen.

## Steps

1. Add the standalone command, configuration contract, and safety primitives.
2. Implement Pi/Cursor adapters and generic run/checkpoint/validation/decision flow.
3. Add tmuxp template and direct safe relay.
4. Run hermetic lifecycle, relay, and packaging tests.
5. Update spec status and record validation evidence before handoff. Documentation
   is complete; authenticated Cursor smoke evidence remains pending.

## Pending Gate 4 evidence

Required before the specification status becomes `complete`: in a disposable clean
repository, start and submit a run; confirm the installed Cursor CLI loads the
generated `.cursor/cli.json`, permits only gate validation/decision/relay/status,
and rejects writes, `git commit`, and network actions. Record the date, Cursor CLI
version, command, result, and any drift here.
