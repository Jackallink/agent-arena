---
status: planned
created: '2026-08-13'
owner: 'local owner'
---

# Agent Arena v0.4: Run state authority

## Summary and scope

Give every run one authoritative answer to "who is next, waiting on what,
since when, and how is it released". A per-run `run-state.tsv` becomes the
single source of truth for the current responsible party and waiting state.
Existing evidence files (`review.tsv`, validation reports, decision records)
remain flow evidence but no longer reverse-derive responsibility. `status`
becomes read-only diagnostics; `list` reads the same authority. Two new
human commands enter: `escalate` (raise a stuck run to human) and `resolve`
(human disposition: approve/reject/recover/cancel).

In scope: the state file model, the full transition matrix, the two human
commands, legacy compatibility (read-only projection + first-write
migration), the run lock, and the hermetic test matrix. Out of scope: a
heartbeat file (future, separate observation file), an append-only journal
(future iteration), multi-agent collaboration beyond the writer-gate pair,
and any change to the gate/writer adapter contracts.

## Walkthrough round 1: user stories and acceptance criteria

1. As an operator, `status` tells me in one sentence who the run is waiting
   on, what for, since when, and which command releases it — including
   whether the reviewer pane is currently unreachable.
2. As an operator of a stuck run (dead reviewer pane, no progress), I can
   explicitly escalate it to human, then recover or cancel it with recorded
   reasons.
3. As a human approver, a reviewer APPROVE lands in `approval_pending` and
   only my `resolve --action approve` completes the run; I can also reject
   it back to the writer.
4. As an auditor, every responsibility handoff is recorded (actor, action,
   timestamp) and old runs without a state file are visibly marked as
   inferred, never silently rewritten by a read.

| ID | Acceptance criterion | Test intent |
| --- | --- | --- |
| AC1 | `start` writes schema-v1 state `active / intake / writer / none / round=0`. | lifecycle fixture |
| AC2 | `submit` with a new SHA moves to `active / submitted / reviewer / review_pending`, increments `checkpoint_round`, binds `checkpoint_sha`, and clears validation/verdict; same-SHA submit is idempotent (no round bump, no `waiting_since` reset). | submit fixture (first, repeated, same-SHA retry) |
| AC3 | `validate` PASS and FAIL both move to `active / validated / reviewer / decision_pending` with `validation_result` recorded; snapshot-integrity or infrastructure failure performs no state transition. | validation fixture incl. FAIL and tampered snapshot |
| AC4 | `decision APPROVE` → `active / decided / human / approval_pending`; `CHANGES_REQUESTED` → `active / decided / writer / changes_requested`; `BLOCKED` → `blocked / decided / human / block_resolution_required`. | decision matrix fixture |
| AC5 | `escalate` is allowed only from `responsible_party=reviewer` with phase `submitted` or `validated`; requires `--reason-code` and `--reason`; moves to `blocked / human / reviewer_unreachable` (phase unchanged); repeating when already `blocked/human/reviewer_unreachable` returns "already escalated" without resetting `waiting_since`; escalating while human is responsible for any other reason is an illegal transition. | escalate fixture |
| AC6 | `resolve` is allowed only when `responsible_party=human`; actions map per `phase+reason_code`: approve (only after reviewer APPROVE) → `completed / decided / none / none`; reject → `active / decided / writer / human_changes_requested` (writer must submit a new SHA); recover → restores the pre-escalation reviewer wait (`submitted`→`review_pending`, `validated`→`decision_pending`) and only handles operational escalation, never a formal BLOCKED verdict; cancel → `canceled / phase-kept / none / none`. BLOCKED admits only reject or cancel in v1 (no manual override approval). `reject`/`recover`/`cancel` require `--reason`. | resolve matrix fixture |
| AC7 | `waiting_since` resets when the responsible party or reason changes; idempotent operations, same-SHA submit, and same-party revalidate do not reset it. | waiting-since fixture |
| AC8 | Legacy runs (no `run-state.tsv`): `status`/`list` use a read-only projection labeled `legacy / inferred, not persisted` and perform zero writes; the first successful transition command performs derive + migration + the new transition under the same lock and writes exactly one v1 file; contradictory or insufficient evidence refuses to guess (status lists the conflicts); legacy APPROVE shows `legacy_human_disposition_unknown` because the old flow cannot prove human acceptance; legacy `checkpoint_round` is `unknown`. | legacy fixtures (projection, migration, conflicts, approve) |
| AC9 | A corrupted state file, an unknown higher `schema_version`, duplicate keys, or an invalid enum value fails closed — never falls back to legacy derivation. `repair-state` accepts only a status-printed, evidence-verified candidate state; it is not an arbitrary state writer. | corruption/hostile-file fixtures |
| AC10 | All transitions run under a run lock: metadata carries PID, a unique owner token, and creation time; release requires the token match; `status` seeing a live lock prints `transition in progress` instead of misreporting an intermediate state; `validate` captures `state_revision+checkpoint_sha` under the lock, runs the gate outside the lock, and CAS-publishes on re-acquire so long validations never block `escalate`; `start` takes a parent-directory creation lock. | lock fixtures (owner token, stale PID, CAS publish, transition-in-progress read) |
| AC11 | Evidence is written before the state file; `run-state.tsv` replacement (mktemp+mv, mode 600) is the commit point; a crash between evidence and commit is recovered by the next retry recognizing the same evidence and completing the commit; relay and reviewer-pane respawn run best-effort after the state commit and lock release. | crash-injection and retry fixtures |
| AC12 | `status` prints the one-sentence diagnosis (who, what, since when, pane reachability, release command) and `list` reads the authoritative state; both are zero-write. | status/list fixtures |
| AC13 | Existing v0.3 suites (38 sections) stay green with the state file added. | full regression |

## Walkthrough round 2: state file model

`<run_dir>/run-state.tsv`, mode 600, atomically replaced (mktemp+mv). The
state file is the only authority for "whose turn next"; evidence files keep
their existing roles.

| Field | Meaning |
| --- | --- |
| `schema_version` | state-file schema version (this release: 1) |
| `state_revision` | optimistic concurrency version; +1 per transition, checked before write |
| `run_status` | `active \| blocked \| completed \| canceled` |
| `phase` | `intake \| submitted \| validated \| decided` — where the checkpoint lifecycle stands (`decided` is not run completion) |
| `responsible_party` | `writer \| reviewer \| human \| none` — who must act next |
| `reason_code` | `none \| review_pending \| decision_pending \| approval_pending \| changes_requested \| human_changes_requested \| reviewer_unreachable \| block_resolution_required \| legacy_human_disposition_unknown` |
| `reason_detail` | the mandatory free-text `--reason` (current/most recent only; not an audit log) |
| `verdict` | nullable: `APPROVE \| CHANGES_REQUESTED \| BLOCKED` |
| `validation_result` | `PASS \| FAIL \| ` (empty) |
| `checkpoint_round` | review round; 0 for a new run, +1 on each new-SHA submit; `unknown` for legacy runs where history is unrecoverable |
| `checkpoint_sha` | the SHA bound to the current checkpoint evidence |
| `waiting_since` | epoch seconds of the current wait start |
| `last_transition_at` | epoch seconds of the last transition |
| `last_transition_actor` | `writer \| reviewer \| human \| <command-name>` |
| `last_transition_action` | e.g. `submit`, `validate`, `decision`, `escalate`, `resolve-approve` |

No `recovery_command` field: the release command is derived safely from
`phase+reason_code+run_status` at read time. No `last_heartbeat_at` in v1:
a future heartbeat is a separate observation file, not a state-field
placeholder.

## Walkthrough round 2: transition matrix

| Trigger | New state |
| --- | --- |
| `start` (new run) | `active / intake / writer / none / round=0` |
| `submit` (new SHA) | `active / submitted / reviewer / review_pending`; round+1; bind `checkpoint_sha`; clear validation/verdict |
| `submit` (same SHA) | idempotent retry/repair: no round bump, no waiting reset |
| `validate` PASS or FAIL | `active / validated / reviewer / decision_pending`; `validation_result` recorded |
| `validate` integrity/infrastructure failure | no state transition |
| `decision APPROVE` | `active / decided / human / approval_pending` |
| `decision CHANGES_REQUESTED` | `active / decided / writer / changes_requested` (writer fixes, then submits a new SHA directly — no fabricated `intake` hop) |
| `decision BLOCKED` | `blocked / decided / human / block_resolution_required` |
| `escalate` | phase unchanged; `blocked / human / reviewer_unreachable` |
| `resolve --action approve` | `completed / decided / none / none` (only after a reviewer APPROVE) |
| `resolve --action reject` | `active / decided / writer / human_changes_requested` (writer must submit a new SHA) |
| `resolve --action recover` | operational recovery only: `submitted`→`review_pending`, `validated`→`decision_pending`, back to `reviewer`; never applies to a formal BLOCKED verdict |
| `resolve --action cancel` | `canceled / phase-kept / none / none` |

A project validation script returning non-zero is a legitimate `FAIL`
(result recorded, `decision_pending`). Snapshot-integrity or tooling
failure is not a project result and must not move state.

## Walkthrough round 2: command surface

```bash
agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..."
agent-arena resolve  RUN_ID --action approve|reject|recover|cancel --reason "..."
agent-arena status   RUN_ID      # read-only, one-sentence diagnosis
agent-arena list                 # reads authoritative state
agent-arena init-state|repair-state RUN_ID  # escape hatches only
```

- `escalate` (v1): only from `responsible_party=reviewer` with phase
  `submitted` or `validated`; both `--reason-code` and `--reason` required;
  idempotent only in the exact `blocked/human/reviewer_unreachable` state
  (returns "already escalated", does not reset `waiting_since`); human-
  responsible for any other reason is an illegal transition. `escalate`
  and `resolve` are thin parsers sharing one constrained transition
  function.
- `resolve`: only when `responsible_party=human`; action set constrained by
  `phase+reason_code` (mapping above); `reject`/`recover`/`cancel` require
  `--reason`; BLOCKED admits only reject or cancel in v1.
- `waiting_since` resets only when party or reason changes.
- `status` and `list` read the authoritative state; legacy runs use the
  read-only projection only. Legacy APPROVE displays
  `legacy_human_disposition_unknown`.

## Walkthrough round 3: atomicity, compatibility, and the lock

"State transition + original action as one atomic pair" is restated as:
**serialized under the lock; evidence first; `run-state.tsv` replacement
is the commit point; failure recoverable idempotently.** Concretely:

- No claim of single-transaction atomicity across Git worktrees and
  multiple files.
- If a crash lands after evidence write and before state commit, the next
  retry recognizes the same evidence and completes the commit.
- relay and reviewer-pane respawn are best-effort and run after state
  commit and lock release.
- `validate` captures `state_revision` + `checkpoint_sha` under the lock,
  runs the gate outside the lock, re-acquires, and CAS-publishes the
  result — a long validation never blocks `escalate`.
- Lock metadata: PID, unique owner token, creation time; release requires
  the token match; stale-lock handling checks the PID.
- `start` takes a parent-directory creation lock.
- `status` seeing a live lock prints `transition in progress`, never
  misreports an intermediate state as a conflict.
- Legacy first-write commands derive + migrate + transition in memory and
  write exactly one v1 file.
- Corrupted state file, unknown higher schema, duplicate keys, or invalid
  enums fail closed; no fallback to legacy derivation.
- `repair-state` accepts only a status-printed, evidence-verified candidate
  state.

## Walkthrough round 3: errors and edge cases

Illegal transitions are rejected with the current responsible party and
the allowed actions. Contradictory legacy evidence lists conflicts in
`status` and points to `repair-state`. Duplicate escalate is idempotent;
other human-responsible escalates are illegal. resolve on BLOCKED with
approve/recover is rejected with the allowed set. A live lock during
`status` reports in-progress rather than conflict.

## Testing strategy (hermetic only)

Fake CLIs and temporary repositories; no model or network call. Must-cover
paths:

- first round, legacy `unknown` round, same-SHA retry
- validation FAIL, repeated validation, integrity failure no-transition
- each resolve action's exact post-state and terminal `party=none`
- fault injection at "evidence written, state not committed" for
  submit/validate/decision + retry recognition
- legacy APPROVE, legacy BLOCKED, stale pointer files, contradictory
  evidence
- corrupted v1 file, future schema, duplicate fields, symlinked state file
- `status`/`list` zero-write guarantees and reads during transitions
- lock liveness: live lock, dead PID, owner-token mismatch, cross-process
  concurrency, CAS publish for validate
- full v0.3 regression (38 sections) with the state file in place

## Drift, risk, and rollback

Drift from v0.3: responsibility was implicit (derived from evidence files);
v0.4 makes it explicit and authoritative. Risk: the state file is a second
source of truth that can disagree with evidence files — the commit-point
ordering (evidence first, state last) plus fail-closed reads bound that
disagreement to crash windows the retry protocol resolves. Rollback:
remove `run-state.tsv` from a run directory to return it to legacy
projection behavior (no evidence is touched); state transitions are
reversible only through the documented resolve/escalate actions.
