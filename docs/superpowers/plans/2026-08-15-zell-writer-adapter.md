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
  Arena end-to-end). Hermetic gates green: `tests/run.sh` 59 sections
  (including §59 coverage for the legacy-manifest `-` state fallback added in
  the cleanup pass — a coverage-only section, green on first run),
  `tmuxp-smoke.sh`, `cli-contract-smoke.sh`, `package.sh --check`, `bash -n`.

## Authorized-operator live smoke checklist (Gate 4)

Recorded by an authorized operator; store output in the private state
directory, never in Git (no credentials, no provider transcripts).

| # | Step | Command sketch | Record |
| --- | --- | --- | --- |
| S1 | Headless zell sanity, disposable repo | `zell --print --no-extensions --no-skills --no-prompt-templates --no-themes --session-dir <tmp> --session-id agent-arena-smoke 'create smoke.txt containing exactly smoke-ok, then run git status --porcelain'` | exit code; exact file content; status shows only the new file; nothing outside the cwd touched |
| S2 | Interactive approval behavior | same task in the TUI inside a tmux pane; answer prompts as they appear | how edit/shell approvals present (this decides whether an `approval=` capability line may be added later); whether `--session-id` rebind resumes the exact session on a second launch |
| S3 | Arena end-to-end | isolated repo + state root; `agent-arena start zell-live --repo ... --writer zell --gate cursor --no-attach`; drive the writer to a checkpoint, then `submit` → `validate` → `decision` | adapter argv as seen by the provider; worktree isolation respected; relay labels correct; snapshot/decision integrity OK |
| S4 | Unattended tail (optional) | same run with `--mode auto`, `autopilot --once --approve-delay 0` | auto-approve with actor=system, run reaches `completed` |
| S5 | Record | fill the table below; set Gate 4; only then claim `live-tested` | drift notes + rollback note (uninstall/ignore the profile) |

| Writer | Command | Result | Drift notes |
| --- | --- | --- | --- |
| Zell (pending) | — | — | — |

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
