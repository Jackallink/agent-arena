# Pluggable writer adapters implementation plan

## Gate record

- Gate 1 — spec audit: **complete**. The canonical scope, profile limits, and
  three-round walkthrough are in
  `../specs/2026-08-13-pluggable-writer-adapters.md`.
- Gate 2 — TDD kickoff: **complete**. Fake-CLI profile/lifecycle tests were
  added before adapter handoff and passed on 2026-08-13.
- Gate 3 — drift check: **complete**. Code, test, and documentation names agree:
  writers are Pi/Codex/OpenCode/Agy and Cursor remains the sole formal gate.
- Gate 4 — release gate: **pending manual authenticated smoke evidence**. The
  hermetic, tmuxp, packaging, and no-model CLI checks passed; no live
  model/provider-network test has been run or claimed by this plan.

This plan is review-ready for code review. It must not move to `complete` merely
because adapters are locally detected; an operator must record the manual smoke
evidence below first.

## Steps

1. **Complete (read-only evidence only):** audit installed Codex, OpenCode, and
   Agy command/session/permission contracts without starting a model. Record
   restrictions and non-claims in the spec; do not infer live behavior.
2. **Complete:** add a closed profile resolver and backward-compatible
   manifest fields for `pi-cursor`, `codex-cursor`, `opencode-cursor`, and
   `agy-cursor`. Keep Cursor as the sole formal gate.
3. **Complete:** add fake-CLI tests for profile selection, missing
   prerequisites, adapter launch/cwd/unsafe-flag exclusions, pane dispatch,
   bidirectional relay labels, session lifecycle, and legacy manifests.
4. **Complete:** implement the writer adapters and generic private writer
   session wiring. An adapter must fail closed when it cannot prove a safe
   initial/resume transition; it must not select a provider's "latest" session.
5. **Complete:** update README, adapter contract, doctor,
   and validation evidence to distinguish detected, enabled, and live-tested
   states.
6. **Pending:** record the authenticated validation matrix evidence below before
   moving this plan or its spec to `complete`.

## Writer implementation matrix

| Profile | Writer-specific implementation rule | Formal gate |
| --- | --- | --- |
| `pi-cursor` | Preserve the existing private session directory/ID behavior and no-bypass prompt. | Cursor only |
| `codex-cursor` | Use the writer worktree, `workspace-write`, and on-request approval; do not promise automatic session restoration. | Cursor only |
| `opencode-cursor` | Use pure mode and a dedicated writer policy; never `--auto`; treat config/plugin suppression as defense in depth, not OS/network isolation. | Cursor only |
| `agy-cursor` | `cd` to the writer worktree; `--new-project` binds the CLI session to the workspace; never `--continue`, `--conversation`, or `--dangerously-skip-permissions`; no automatic resume. | Cursor only |

The reviewer pane may send direct feedback to the writer and the writer may send
progress to Cursor. Those relays never replace the immutable review snapshot,
validation report, or Cursor decision record.

## Validation matrix and evidence path

| Gate | Required evidence | Status |
| --- | --- | --- |
| Profile resolution | Hermetic tests prove known profiles succeed and unknown/missing writers fail before worktree/tmux creation. | Passed 2026-08-13 |
| Writer launch | Fake binaries capture exact argv, cwd, safety prompt, and forbidden flag absence for all four writers. | Passed 2026-08-13 |
| Session handling | Fixtures distinguish first launch from valid explicit resume; unsupported automatic resume fails safely. | Passed 2026-08-13 |
| Cursor gate | A non-Pi writer follows submit → detached snapshot → SHA-bound formal `validate` and `decision` commands; Cursor remains the designated gate by the generated policy. | Passed 2026-08-13 |
| tmuxp / packaging | `bash tests/tmuxp-smoke.sh` and `bash packaging/package.sh --check` pass. | Passed 2026-08-13 |
| Manual smoke | An authorized operator records authenticated provider/permission/session observations without placing credentials or transcripts in Git. | All live smokes completed 2026-08-13: Cursor gate (headless policy enforcement + interactive reviewer-pane end-to-end), Codex and OpenCode (headless and interactive TUI), Agy (headless, interactive, and full Arena end-to-end), and Pi (headless + full Arena end-to-end, writer completed create/commit/submit on its own). Full details in the evidence section below. |

Store command output, findings, drift, and rollback notes in the private run-state
audit location. Do not record credentials, raw provider transcripts, or secrets in
this repository.

## Writer live smoke evidence (2026-08-13)

Disposable `/tmp/arena-writer-smoke/{codex,opencode}` and `/tmp/agy-writer-smoke` repositories, real
authenticated CLIs, headless mode, one minimal task each: create `smoke.txt`
containing exactly `smoke-ok`, then report `git status --porcelain`.

| Writer | Command | Result | Drift notes |
| --- | --- | --- | --- |
| Codex 0.146.0 | `codex exec -C <wt> --sandbox workspace-write` | exit 0; `smoke.txt` content exact; status shows only `?? smoke.txt` | `--ask-for-approval` is interactive-only (absent from `exec`); sandbox is the headless enforcement. |
| OpenCode 1.18.11 | `opencode run --pure --agent arena_writer --dir <wt>` with generated policy env | exit 0; edit allowed; content exact; workspace otherwise untouched | webfetch/websearch deny not exercised (model attempted no network). |
| Agy 1.1.7 | `agy -p "..." --new-project --sandbox --mode accept-edits` (headless) and `agy -i "..." --new-project --sandbox --mode accept-edits` (interactive, trust prompt confirmed) | exit 0; `smoke.txt` created in the workspace with exact content; `git status` showed only that file. Without `--new-project`, agy binds CLI sessions to its scratch workspace instead of the current directory (drift found during the smoke and fixed in the adapter). Full Arena end-to-end also passed 2026-08-13: a real `start e2e --profile agy-cursor` session had the real agy writer create `feature.txt`, commit it, and run `submit e2e` itself; `validate` → PASS and `decision` → APPROVE completed with `status` reporting `Integrity: OK`. | agy exposes no creation-time session ID; `--continue` and `--conversation` are never passed by the adapter. The retired Gemini 0.46.0 line is removed. |

## Interactive-mode and end-to-end live evidence (2026-08-13, second pass)

| Item | Setup | Result | Notes |
| --- | --- | --- | --- |
| Pi headless | `pi -p "create smoke.txt ..." --session-dir <dir> --session-id agent-arena-smoke --name ...` | exit 0; exact content; session file `YYYY-..._agent-arena-smoke.jsonl` stored under `--session-dir` | Adapter session contract works with the real CLI. |
| Pi full Arena end-to-end | Real `start e2e-pi --profile pi-cursor` session; writer pane drove the real pi TUI (deepseek-v4-pro) | pi created `feature.txt`, committed it, and ran `agent-arena submit e2e-pi` itself; `validate` → PASS; `decision` → APPROVE; `status` → `Integrity: OK` | The pi-cursor profile is now live-verified end to end. |
| Codex interactive TUI | `codex -C <wt> --sandbox workspace-write --ask-for-approval on-request --no-alt-screen` under tmux | Update prompt skipped; trust prompt confirmed; task executed after C-m send; exact file content; commit created; workspace clean | Interactive approval/trust behavior observed; `--no-alt-screen` output works in tmux. |
| OpenCode interactive TUI | `opencode <wt> --pure --agent arena_writer` with generated policy env | `arena_writer` agent loaded (MiniMax provider); task completed in ~10s with exact content and commit | The generated policy agent is selectable and functional interactively. |
| Cursor reviewer-pane end-to-end | Resume of the e2e-pi run; reviewer pane launched the real Cursor gate (`--sandbox enabled --workspace <review>`, review phase prompt) | Trust prompt confirmed (`a`); Cursor ran `./.agent-arena-gate validate` itself (new report rotated to `validation-<sha>.r1.md`), inspected the checkpoint with `git diff`/`git show`, attempted `./.agent-arena-gate decision` and received the fail-closed "a decision already exists" rejection, verified the SHA-bound records, and relayed the handoff to the writer, which acknowledged | The complete interactive gate loop (validate → decision attempt → relay) works with the real authenticated Cursor CLI; duplicate-decision rejection confirms wrapper-level fail-closed behavior. |

## Live verification, third pass (2026-08-13): two-checkpoint gate loop, D4, and CLI version drift

| Item | Setup | Result | Notes |
| --- | --- | --- | --- |
| Codex full Arena end-to-end (two checkpoints) | Real `start e2e-codex --profile codex-cursor`; writer pane drove the real Codex TUI (`--sandbox workspace-write --ask-for-approval on-request`) | Checkpoint 1: created `feature.txt` (v1), committed, ran `submit` itself. Gate: validate PASS → decision `CHANGES_REQUESTED` with finding → **relay delivered into the writer pane** (Codex received it and started working). Checkpoint 2: content updated to v2-feature, committed, resubmitted. Gate: validate PASS → decision `APPROVE`. Both per-SHA validation reports and decisions archived (`decision-75b3a0e…` CHANGES_REQUESTED + `decision-1ff8dc2…` APPROVE); `status` → `Integrity: OK` | The full review-fix-reapprove loop is live-verified. |
| D4 closure: unlisted command in interactive gate | Reviewer-pane Cursor (interactive) asked to run `git branch -a` (not in the allow list) | **Executed successfully** — interactive mode matches headless semantics: the allow list is an auto-approve list, the deny list is the hard boundary, and unlisted commands are not denied by default. Read-only risk only; all write channels remain denied | D4 is now closed with evidence, not assumption. |
| Cursor CLI version drift | The installed `agent` auto-updated from 2026.06.15-18-00-12-6f5a2cf (Gate 4 baseline) to 2026.08.11-e8db854 during the session | The generated `permissions`-only `.cursor/cli.json` still loads; review-phase gate (`--sandbox enabled --workspace <review>`) runs `validate` through the wrapper (report rotated to `validation-<sha>.r1.md`) and inspects SHA-bound records | Policy schema survived a CLI version upgrade; re-run the Gate 4 smoke after future auto-updates. |
| Submit respawn degradation triggered | Both in-pane submits by the sandboxed Codex writer left the reviewer pane on the intake process | External submit respawned the reviewer pane correctly (process changed, review-phase Cursor started). In-pane submits appear to hit the AC11 best-effort degradation (tmux unavailable inside the writer sandbox); the note was not visible in the writer's summary, but the checkpoint, snapshot, reports, and decisions were all correct | AC11's degrade-not-fail path is now exercised in the real world; no core-flow impact. |
