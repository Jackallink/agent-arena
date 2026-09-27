# Spec: orphan-run cancel (dead writer, never submitted)

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `lib/resolve.sh`, `tests/run.sh` §72; no JSON schema change
- Discovered by: s2ui/live8 dogfooding — real operational gap, not hypothetical

## 1. Problem

A run that reached the implementation phase (`phase=intake`,
`responsible_party=writer`, `reason_code=none` — the state bootstrap leaves
after the final artifact accept) has **no sanctioned human exit** when the
writer session dies without submitting:

- `escalate` requires `responsible_party=reviewer` with phase
  submitted/validated — not reachable from here.
- `resolve --action cancel` requires human responsibility — refused with
  "resolve requires human responsibility (current: writer)".
- `repair-state` re-projects from evidence and preserves the party —
  still writer.
- The stage-phase cancel path (v0.7 §10.9) only covers phase
  intent/spec/plan.

live8 was parked in exactly this state after the tmux server cleanup;
only an out-of-band state-file hand-edit could close it, which violates
the audit discipline the state machine exists to enforce.

## 2. Rule (orphan cancel)

`resolve RUN_ID --action cancel --reason "..."` is additionally admitted
when ALL of:

1. `action=cancel` with a `--reason` (cancel always requires one);
2. `responsible_party=writer`;
3. `phase=intake` (bootstrap'd implementation holding — artifact stages
   keep the dedicated stage-cancel path);
4. `reason_code=none` (the writer-owned resting state; anything else
   means a gate is pending and must resolve normally first);
5. the manifest's `tmux_session` does not exist (tmux absent ⇒ no writer
   can be alive ⇒ counts as gone; a live session ⇒ refused).

The delta is the ordinary cancel delta (`run_status=canceled`,
`responsible_party=none`, reason text recorded, actor=human) committed
through the same locked, revision-bumped path. The run directory and the
writer worktree are kept for audit/manual inspection — unlike stage-phase
cancel, an implementation run owns real artifacts.

## 3. Refusals (actionable, not silent)

- Writer-owned, phase=intake, reason=none, **live tmux session**:
  refuse with `writer session still alive (tmux: <name>); relay the
  writer or stop its session first`.
- Writer-owned but any other phase/reason: the existing generic
  human-responsibility refusal (unchanged).
- Legacy-projected runs: unchanged (projections never yield writer).

## 4. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-O1 | orphan cancel (writer/intake/none + gone session) succeeds with the ordinary cancel delta | §72a |
| AC-O2 | same state but live tmux session is refused with the actionable message | §72b (tmux guard-skip) |
| AC-O3 | human-party cancel behavior unchanged (no regression) | existing cancel assertions (§ / §70b) |

## 5. Non-goals

- No auto-detection/notification of dead writers (relay/health work).
- No change to escalate/recover/repair-state semantics.
- No JSON schema change; `status --json` already reflects the delta.
