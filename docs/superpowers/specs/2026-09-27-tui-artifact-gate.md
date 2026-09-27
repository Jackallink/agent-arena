# Spec: TUI artifact gate (accept / reject)

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `ui/src/model.rs`, `ui/src/main.rs`, `tests/run.sh` §74, README keys line
- Context: the v0.7.0 artifact gate is CLI-only (`artifact RUN --stage S
  --accept|--reject`); the dashboard could watch the chain (v0.7.1 tick)
  but not operate it. This increment wires the gate into the existing
  thin-client machinery: every spawn is a verbatim argv on a confirm line.

## 1. Keys

- `g` — accept the awaiting artifact: fresh `status --json` fetch for the
  selected run; first stage with `status=awaiting_accept` (manifest order)
  → confirm line with verbatim `artifact RUN --stage S --accept`. No
  awaiting stage → notice `no artifact awaiting accept`; oracle error →
  notice.
- `G` — reject the awaiting artifact: same fetch; awaiting stage → input
  prompt (hint shows the verbatim shape `artifact RUN --stage S --reject
  --summary <type>, Enter submit, Esc cancel`); Enter with non-empty text
  → confirm line with verbatim `artifact RUN --stage S --reject --summary
  <text>`. Empty input keeps the generic guard; Esc cancels.
- All other keys unchanged. Footer hint line gains the `g`/`G` words.

## 2. Machinery (reuse, no new spawn paths)

- `StatusDoc::awaiting_stage()` — pure; first `awaiting_accept` stage.
- `artifact_accept_argv(run_id, stage)` / `artifact_reject_argv(run_id,
  stage, summary)` — pure argv builders; the caller spawns exactly these.
- `PromptKind::ArtifactRejectSummary { stage }` — data-carrying kind so
  the stage name survives until submit (no parallel loop state).
- `action_argv` stays total: the artifact actions are status-dependent
  and return None there.
- The stage name is resolved at keypress time from a fresh fetch — the
  auto-refresh cache is never used to build a gate argv.

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-G1 | `g` on a run with an awaiting stage confirms verbatim accept argv; `y` performs the accept (draft renamed, digest recorded) | §74a (hermetic fake-adapter draft) |
| AC-G2 | `G` prompts for the summary, confirm argv is verbatim, `y` records `stage_<s>_reject_summary` and re-arms | §74b |
| AC-G3 | `g`/`G` with no awaiting stage only set the notice; no spawn | §74c |
| AC-G4 | keymap rows + argv builders + awaiting_stage selection (first in manifest order, None when absent) | cargo unit tests |
| AC-G5 | keymap otherwise unchanged; wizard flow intact | existing cargo tests + §69 |

## 4. Non-goals

- In-TUI artifact reading (scrollable viewer) — the accept hint already
  names the draft path; defer.
- Multi-stage batch operations; the gate is one stage at a time by design
  (human-triggered agent spend).
