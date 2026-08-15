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


## Gate 4 evidence — v0.4.0 run state authority (2026-08-15)

- Credential/tracked-file scan clean: 57 tracked files, no sensitive file names
  (.env/.pem/.key/secret/credential/id_rsa) and no credential patterns
  (GitHub/OpenAI/AWS tokens, private-key headers, api_key/password/token
  assignments); test lock tokens are fixture placeholders only.
- Hermetic validation: `tests/run.sh` 50 sections green (v0.3 regression §1–37
  plus run-state §38–49), tmuxp smoke, CLI contract smoke, `package.sh --check`,
  and `bash -n` all green.
- Review: detached snapshot tag `review/run-state-v0.4` (commit `2b2a5f3`)
  re-verified green; PR #2 merged into `main` (fast-forward `2b2a5f3`), branch
  deleted after merge.
- Release: `v0.4.0` tag on `main` (`e3656a8` release commit);
  https://github.com/Jackallink/agent-arena/releases/tag/v0.4.0 with
  `dist/agent-arena-0.4.0.tar.gz` (sha256
  `0731bedec86c068387267e57ca007f87f381ffee99a7d50654b3d8f1b51cbfa5`) and the
  checksum file attached.
- Conclusion: source publication and archive release gates complete for v0.4.0.
- Real-Cursor gate smoke (2026-08-15, authenticated `agent` 2026.08.11-e8db854,
  evidence archived under the state directory):
  1. Full T-matrix lifecycle in a real Git/tmuxp environment with the writer
     adapter stubbed: `start` (intake/writer/none) → writer checkpoint →
     `submit` (submitted/reviewer/review_pending, detached review snapshot
     created) → `status` oracle one-sentence diagnosis → `validate`
     (validated/decision_pending, `RESULT: PASS` published) → `decision
     APPROVE` (decided/human/approval_pending) → `resolve approve`
     (completed/none/none). A second run exercised `escalate`
     (blocked/human/reviewer_unreachable); `resolve recover` correctly
     refused while the reviewer pane was unreachable and succeeded after
     `resume` (active/submitted/reviewer/review_pending). `list` printed the
     fixed oracle columns with `AUTHORITY=state` for both runs.
  2. In the detached review snapshot, the real Cursor headless run executed
     `./.agent-arena-gate validate er-run` → exit 0, `RESULT: PASS`, with the
     SHA-bound validation report published and the pointer updated.
  3. Drift D5 (new): `echo blocked > policy-test.txt` executed and created the
     file under `--sandbox enabled` despite the deny list (v0.3's D2 fix does
     not hold on this agent build — redirection writes bypass the Shell
     denials). The post-run snapshot integrity check reported
     `Integrity: FAILED` and `status` failed closed, so the audit chain
     stayed closed; README documents the non-guarantee. No code change is
     needed for the hermetic contract; a future adapter pass may add
     sandbox-level write blocks.
  4. Archive install smoke: `dist/agent-arena-0.4.0.tar.gz` checksum
     verified; `packaging/install.sh --prefix <tmp>` installed; the installed
     `agent-arena` ran `doctor` and `help` (escalate/resolve/repair-state/
     list present) and completed a fresh lifecycle in a real Git repo
     (init → start → submit → status → list) with correct run-state rows.


## Gate 4 evidence — v0.5.0 autopilot approval modes (2026-08-15)

- Credential/tracked-file scan clean: 77 tracked files, no sensitive file
  names or credential patterns.
- Hermetic validation: `tests/run.sh` 56 sections green (v0.4 §0–49 zero
  semantic drift + §50–55), tmuxp smoke, CLI contract smoke, `package.sh
  --check`, and `bash -n` all green.
- Design review: multi-expert walkthrough (5 roles, 3 rounds, debate) +
  Gate-1 second round with all rulings applied, recorded in
  `docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/`.
- Review: detached snapshot tag `review/autopilot-v0.5` (commit `66258b3`)
  re-verified green; PR #3 merged into `main` (fast-forward `66258b3`);
  branch deleted after merge.
- Release: `v0.5.0` tag on `main` (`a52d4d9` release commit);
  https://github.com/Jackallink/agent-arena/releases/tag/v0.5.0 with
  `dist/agent-arena-0.5.0.tar.gz` (sha256
  `5e1c04f57a7c1ddf3908dba7bb489046f44d8640c3409924a60c4c127db2413c`) and the checksum file attached.
- Conclusion: source publication and archive release gates complete for v0.5.0.
- v0.5.1 patch (2026-08-15): `help` lists `mode`/`autopilot` (dispatch gap
  fix); `packaging/package.sh` emits relative-path checksums so `shasum -c`
  works from any directory. Full two-model unattended live loop recorded
  (real Pi writer + real Cursor reviewer + autopilot; evidence archived).
  Release `v0.5.1` tag (`5e999d9`); archive
  `dist/agent-arena-0.5.1.tar.gz` (sha256
  `896ee9af581ec8fd77d16bc3a58175337471a5630180c04ab9f5aa0e88a9fd27`).
- Live autopilot demo (2026-08-15, independent temp repo, evidence archived
  under the state directory): real authenticated Cursor model ran the gate in
  the detached review snapshot — `./.agent-arena-gate validate live-demo` →
  exit 0 `RESULT: PASS`, then `decision --verdict APPROVE` recorded the
  SHA-bound archive; the run parked at decided/human/approval_pending; the
  real `autopilot --once` (auto mode, `--approve-delay 0`) auto-approved it —
  `completed`, `last_transition_actor=system`,
  `action=resolve-approve`, `reason_detail=autopilot <instance> <ts>` — with
  heartbeat (`autopilot.tsv` scanned=1 acted=1 errors=0) and action log
  (`approval_pending resolve-approve acted`).
- Full two-model unattended loop (2026-08-15, independent temp repo, evidence
  archived as `full-live-pi-cursor-autopilot.log`): the real Pi CLI
  (v0.84.2, headless) created `feature.txt`, committed `feat: live demo
  feature` (5b90585), and ran `agent-arena submit live-demo`; the real
  authenticated Cursor agent ran the gate wrapper (`validate` → exit 0
  `RESULT: PASS`, `decision --verdict APPROVE` recorded against
  5b90585c000b); the real `autopilot --once` (auto mode) approved the run to
  `completed` with actor=system and an instance-token reason. This completes
  the unattended loop end-to-end with two different real model CLIs (Pi
  writer + Cursor reviewer) plus the autopilot automation.
