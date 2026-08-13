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
| Manual smoke | An authorized operator records authenticated provider/permission/session observations without placing credentials or transcripts in Git. | Not run |

Store command output, findings, drift, and rollback notes in the private run-state
audit location. Do not record credentials, raw provider transcripts, or secrets in
this repository.
