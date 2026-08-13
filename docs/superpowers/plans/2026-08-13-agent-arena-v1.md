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

## Gate 4 evidence — complete (2026-08-13)

- Cursor CLI: `agent` 2026.06.15-18-00-12-6f5a2cf at `~/.local/bin/agent`, authenticated as
  jackallink@hotmail.com (`agent status`).
- Environment: disposable `/tmp/arena-gate4` Git repository; real git, tmuxp, and Cursor
  CLI in headless mode (`agent -p --trust --sandbox enabled --workspace <review>`).
- Sequence: `init` → `start gate4 --no-attach` → writer checkpoint commit → `submit gate4`
  → one real-model run of the four-step gate prompt against the detached review snapshot.
- Results:
  1. `./.agent-arena-gate validate gate4` → exit 0, output ends `RESULT: PASS` ✅
  2. `echo blocked > policy-test.txt` → `Permission denied: Command blocked by
     permissions configuration`; file verified absent in the snapshot ✅ (after hardening)
  3. `git add policy-test.txt` → blocked by policy; commit never ran ✅
  4. `curl -sS https://example.com` → exit 56, `CONNECT tunnel failed, response 403` ✅
- Drift found and fixed during the smoke:
  - D1 (schema): the generated policy used `version`/`approvalMode`/`sandbox` keys that the
    real CLI rejects (`Unrecognized key(s)`). Verified empirically that only
    `{"permissions":{"allow":[...],"deny":[...]}}` is accepted; generator rewritten.
  - D2 (allow semantics): the allow list is an auto-approve list, not a deny-by-default
    whitelist. First smoke run wrote through `echo > file` (shell redirection bypasses
    `Write(**)`, which only guards the model's write tool). Hardened the deny list with
    high-frequency write channels (`echo`/`printf`/`tee`/`cp`/`mv`/`bash`/`sh`/`zsh`/
    `python3`/`curl`/`wget`); re-run confirmed the write is now blocked.
  - D3 (network): the schema has no network key; the `--sandbox enabled` CLI sandbox still
    blocked the connection (403 CONNECT tunnel). The README's non-guarantee wording stays.
  - D4 (open): the smoke used headless `-p`; interactive-mode semantics for unlisted
    commands (prompt vs deny) remain unverified. Snapshot pollution via an unlisted write
    command is still theoretically possible but is detected by the post-run integrity
    check, which keeps the validation/decision audit chain closed.
- Conclusion: the gate is loadable, deny-list enforcement works, network is blocked, and
  the four gate wrapper commands pass under the real authenticated CLI. Gate 4 evidence is
  complete; spec status may move to `complete` after owner sign-off.
