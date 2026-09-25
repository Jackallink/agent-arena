# Zell writer adapter implementation plan

## Gate record

- Gate 1 — spec audit: **complete**. Canonical contract and read-only CLI
  audit in `../specs/2026-08-15-zell-writer-adapter.md`.
- Gate 2 — TDD kickoff: **complete**. §58 written first and failed against the
  unregistered profile (`unknown writer 'zell' in profile 'zell-cursor'`, then
  `unknown writer adapter 'zell'` at `arena_profile_branch`), then green after
  implementation.
- Gate 3 — drift check: **complete**. All three closed-set registration points
  updated (explicit `zell-cursor` case, fallback label, `arena_profile_list`,
  `arena_profile_branch`); capabilities contract matches the spec (no
  `approval=` line); forbidden flags (`--continue/--resume/--fork/--print`)
  asserted absent.
- Gate 4 — release gate: **pending** the authorized live smoke (headless +
  Arena end-to-end). Hermetic gates green: `tests/run.sh` 59 sections,
  `tmuxp-smoke.sh`, `cli-contract-smoke.sh`, `package.sh --check`, `bash -n`.

## Steps

1. **Write the failing tests (§58)** — fake `zell` binary (pi-style argv
   logger), `FAKE_ZELL_LOG`/`ARENA_ZELL_BIN` in `run_writer_adapter`,
   profile resolution through `start` (fail-closed on unknown), launch
   argv/cwd/policy-prompt assertions, forbidden flags (`--continue`,
   `--resume`, `--fork`, `--print`) plus the shared dangerous-flag list,
   capabilities contract, relay label, doctor line.
2. **Run the suite to verify §58 fails** (no `adapters/zell.sh`, no profile).
3. **Implement** `adapters/zell.sh` (probe/capabilities/launch per the spec's
   whitelist) and register `zell-cursor` + fallback label `Zell` in
   `lib/profile.sh`.
4. **Run tests to green**, then the full gates: `tests/run.sh`,
   `tmuxp-smoke.sh`, `cli-contract-smoke.sh`, `package.sh --check`, `bash -n`.
5. **Docs**: README deployment matrix row, doctor note, adapters/README
   writer list.
6. **Commit** `feat: zell writer adapter` and record gate evidence here.

## AC → test mapping

See the spec's table (z1–z6 → §58 subsections).

## Assertion-update list (v0.5 zero-drift check)

- `run_writer_adapter` gains `FAKE_ZELL_LOG`/`ARENA_ZELL_BIN` — additive,
  existing callers untouched.
- doctor output gains one `profile:zell-cursor` line when the fake CLI is on
  PATH — any exact-output assertions in §1 must be widened, not rewritten.
- No state-file, manifest-schema, or exit-code changes.
