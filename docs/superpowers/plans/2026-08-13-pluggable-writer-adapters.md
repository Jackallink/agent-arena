# Pluggable writer adapters implementation plan

## Gate record

- Gate 1 — spec audit: **complete**. The canonical scope, profile limits, and
  three-round walkthrough are in
  `../specs/2026-08-13-pluggable-writer-adapters.md`.
- Gate 2 — TDD kickoff: **complete**. Fake-CLI profile/lifecycle tests were
  added before adapter handoff and passed on 2026-08-13.
- Gate 3 — drift check: **complete**. Code, test, and documentation names agree:
  writers are Pi/Codex/OpenCode/Gemini and Cursor remains the sole formal gate.
- Gate 4 — release gate: **pending manual authenticated smoke evidence**. The
  hermetic, tmuxp, packaging, and no-model CLI checks passed; no live
  model/provider-network test has been run or claimed by this plan.

This plan is review-ready for code review. It must not move to `complete` merely
because adapters are locally detected; an operator must record the manual smoke
evidence below first.

## Steps

1. **Complete (read-only evidence only):** audit installed Codex, OpenCode, and
   Gemini command/session/permission contracts without starting a model. Record
   restrictions and non-claims in the spec; do not infer live behavior.
2. **Complete:** add a closed profile resolver and backward-compatible
   manifest fields for `pi-cursor`, `codex-cursor`, `opencode-cursor`, and
   `gemini-cursor`. Keep Cursor as the sole formal gate.
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
| `gemini-cursor` | `cd` to the writer worktree; initial ID and explicit resume must be distinguished; never `--worktree`, `--yolo`, or automatic trust bypass. | Cursor only |

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
| Manual smoke | An authorized operator records authenticated provider/permission/session observations without placing credentials or transcripts in Git. | Cursor gate smoke completed 2026-08-13 (v0.1 plan Gate 4 evidence). Codex and OpenCode writer live smokes completed 2026-08-13 (disposable worktrees, real authenticated CLIs; each created the requested file with exact content and left the workspace otherwise untouched). Gemini live smoke blocked on 2026-08-13 by provider endpoint unavailability; retry when reachable. Pi's live behavior is exercised continuously as the daily driver. |

Store command output, findings, drift, and rollback notes in the private run-state
audit location. Do not record credentials, raw provider transcripts, or secrets in
this repository.

## Writer live smoke evidence (2026-08-13)

Disposable `/tmp/arena-writer-smoke/{codex,opencode,gemini}` repositories, real
authenticated CLIs, headless mode, one minimal task each: create `smoke.txt`
containing exactly `smoke-ok`, then report `git status --porcelain`.

| Writer | Command | Result | Drift notes |
| --- | --- | --- | --- |
| Codex 0.146.0 | `codex exec -C <wt> --sandbox workspace-write` | exit 0; `smoke.txt` content exact; status shows only `?? smoke.txt` | `--ask-for-approval` is interactive-only (absent from `exec`); sandbox is the headless enforcement. |
| OpenCode 1.18.11 | `opencode run --pure --agent arena_writer --dir <wt>` with generated policy env | exit 0; edit allowed; content exact; workspace otherwise untouched | webfetch/websearch deny not exercised (model attempted no network). |
| Gemini 0.46.0 | `gemini -p ... --extensions none --allowed-mcp-server-names <sentinel> --approval-mode=auto_edit` | blocked: provider endpoint unreachable (`fetch failed sending request`; custom `GOOGLE_GEMINI_BASE_URL`) | `--approval-mode=auto_edit` silently downgrades to `default` in untrusted folders; headless needs `--skip-trust` (interactive flow uses the human trust prompt). Retry when the endpoint is reachable. |
