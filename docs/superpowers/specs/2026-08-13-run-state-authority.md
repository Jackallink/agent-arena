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

In scope: the state file model (wire contract included), the full
transition matrix with source states and guards, the two human commands,
legacy compatibility (read-only projection + first-write migration +
repair candidate contract), the run lock, CAS validation publishing,
crash-retry observability, and the hermetic test matrix. Out of scope: a
heartbeat file (future, separate observation file), an append-only journal
(future iteration; the state file records the current handoff and the most
recent transition only), multi-agent collaboration beyond the
writer-gate pair, and any change to the gate/writer adapter contracts.
After the first v0.4 state transition a run has no semantically lossless
downgrade path (see rollback).

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
4. As an auditor, the current responsibility handoff and the most recent
   transition are visible; old runs without a state file are visibly marked
   as inferred, never silently rewritten by a read.

| ID | Acceptance criterion | Test intent |
| --- | --- | --- |
| AC1 | `start` writes schema-v1 state `active / intake / writer / none / round=0` with `state_revision=1`. | lifecycle fixture |
| AC2 | `submit` with a new SHA follows the from/guard/to/delta table (round increment or sticky `unknown`, SHA binding, verdict/validation cleared); same-SHA submit from `submitted` is an idempotent zero-write retry; same-SHA submit while the writer is responsible (`changes_requested` or `human_changes_requested`) is rejected with "must submit a new SHA". | submit fixture (first, repeated, same-SHA retry, same-SHA-after-reject) |
| AC3 | `validate` from `submitted/reviewer/review_pending` (and revalidate from `validated/reviewer/decision_pending`) records PASS/FAIL and moves to `validated / reviewer / decision_pending` via lock-capture → gate → CAS-publish; snapshot-integrity or infrastructure failure performs no transition; a CAS failure leaves state and pointers untouched and exits with the stale-result code. | validation fixture incl. FAIL, tampered snapshot, CAS stale |
| AC4 | `decision` from `validated/reviewer/decision_pending` maps the three verdicts to their exact target states; APPROVE requires `validation_result=PASS`. | decision matrix fixture |
| AC5 | `escalate` is allowed only from `responsible_party=reviewer` with phase `submitted` or `validated`; requires `--reason-code` and `--reason`; moves to `blocked / human / reviewer_unreachable` (phase unchanged); repeating in that exact state returns "already escalated" with zero write; escalating while human is responsible for any other reason is an illegal transition. | escalate fixture |
| AC6 | `resolve` is allowed only when `responsible_party=human`; per action: approve (only after reviewer APPROVE) → `completed / decided / none / none`; reject → `active / decided / writer / human_changes_requested` (writer must submit a new SHA); recover → requires the reviewer pane reachable as a precondition, else refuses with the recovery command, and only handles operational escalation (never a formal BLOCKED verdict); cancel → `canceled / phase-kept / none / none`. BLOCKED admits only reject or cancel in v1. `reject`/`recover`/`cancel` require `--reason`. Terminal actions change Arena state only: no merge, push, worktree cleanup, or tmux teardown. | resolve matrix fixture incl. unreachable-pane recover refusal |
| AC7 | `waiting_since` resets only when the responsible party or reason changes; idempotent operations, same-SHA submit, and same-party revalidate are zero-write. Terminal states have empty `waiting_since`. | waiting-since fixture |
| AC8 | Legacy runs (no `run-state.tsv`): `status`/`list` use the read-only projection table below, labeled `legacy / inferred, not persisted`, zero writes; the first successful transition command derives + migrates + transitions in memory and writes exactly one v1 file; contradictory evidence refuses to guess (status lists conflicts); legacy APPROVE shows `legacy_human_disposition_unknown`; legacy `checkpoint_round` is sticky `unknown` (never incremented — the SHA is the real identity); allowed legacy resolve actions: approve/reject/cancel for legacy APPROVE, reject/cancel for legacy BLOCKED. | legacy fixtures (projection, migration, conflicts, approve, sticky round) |
| AC9 | A corrupted state file, unknown higher `schema_version`, duplicate or missing or unknown keys, invalid enums, or an illegal field combination fails closed — never falls back to legacy derivation. `repair-state --candidate TOKEN --reason` accepts only a token that `status` printed, bound to the current evidence digest, re-validated under the lock; stale or foreign candidates are rejected. There is no `init-state`. | corruption/hostile-file and repair-token fixtures |
| AC10 | All transitions run under a run lock: metadata carries PID, a unique owner token, and creation time; release requires the token match; `status` seeing a live lock prints `transition in progress` and exits with the lock code; `validate` captures `state_revision`+`checkpoint_sha` under the lock, runs the gate outside the lock, re-acquires, and CAS-publishes; `start` takes a parent-directory creation lock. | lock fixtures (owner token, stale PID, CAS publish, in-progress read) |
| AC11 | Evidence is written before the state file; `run-state.tsv` replacement (mktemp+mv, mode 600) is the commit point; after a crash between evidence and commit, the next retry recognizes the same evidence and completes the commit; a run with evidence-first residue is reported by `status` as `incomplete transition` with the exact retry command and a dedicated exit code; relay and reviewer-pane respawn run best-effort after the state commit and lock release. | crash-injection, retry, incomplete-transition fixtures |
| AC12 | `status` prints the one-sentence diagnosis (who, what, since when, pane reachability, release command) and `list` reads the authoritative state; both are zero-write; outputs and exit codes for terminal, corrupt, legacy-conflict, live-lock, incomplete-transition, and missing-pane cases are per the output protocol table. | status/list output-and-exit-code fixtures |
| AC13 | The complete v0.3 regression suite passes with the state file in place. | full regression |

## Walkthrough round 2: state file wire contract

`<run_dir>/run-state.tsv`, mode 600, atomically replaced (mktemp+mv).
Every line is `key<TAB>value` with a trailing LF. CR is rejected. The key
set is exactly the fifteen keys below; each appears exactly once, in any
order. A missing key, a duplicate key, or an unknown key is a corrupted
file and fails closed. Empty values are allowed only for the fields marked
nullable, encoded as the key followed by TAB and immediately LF.

| Key | Validation | Nullable |
| --- | --- | --- |
| `schema_version` | literal `1` | no |
| `state_revision` | positive integer; starts at 1; +1 per semantic transition; idempotent no-ops are zero-write | no |
| `run_status` | `active \| blocked \| completed \| canceled` | no |
| `phase` | `intake \| submitted \| validated \| decided` | no |
| `responsible_party` | `writer \| reviewer \| human \| none` | no |
| `reason_code` | `none \| review_pending \| decision_pending \| approval_pending \| changes_requested \| human_changes_requested \| reviewer_unreachable \| block_resolution_required \| legacy_human_disposition_unknown` | no |
| `reason_detail` | no TAB/CR/LF/control characters; at most 256 characters | yes |
| `verdict` | `APPROVE \| CHANGES_REQUESTED \| BLOCKED` | yes |
| `validation_result` | `PASS \| FAIL` | yes |
| `checkpoint_round` | non-negative integer or `unknown` (sticky: once `unknown`, stays `unknown`; the SHA is the real identity) | no |
| `checkpoint_sha` | empty or 40 lowercase hex | yes |
| `waiting_since` | epoch seconds or `unknown` (legacy-derived); empty in terminal states | yes |
| `last_transition_at` | epoch seconds | no |
| `last_transition_actor` | `writer \| reviewer \| human \| system` (command names go into the action) | no |
| `last_transition_action` | `start \| submit \| validate \| decision \| escalate \| resolve-approve \| resolve-reject \| resolve-recover \| resolve-cancel \| repair-state` | no |

No `recovery_command` field: the release command is derived safely from
`phase+reason_code+run_status` at read time. No `last_heartbeat_at` in v1:
a future heartbeat is a separate observation file, not a state-field
placeholder.

Legal field-combination invariants (a state violating any of them is
corrupted and fails closed):

```text
intake    → RS=active,  RP=writer,   RC=none,           V empty, VR empty, CS empty
submitted → RS=active,  RP=reviewer, RC=review_pending, CS non-empty
validated → RS=active,  RP=reviewer, RC=decision_pending, VR non-empty, CS non-empty
decided   → V non-empty, and one of:
              RP=human  RC=approval_pending
              RP=writer RC=changes_requested | human_changes_requested
blocked   → RP=human, RC in {reviewer_unreachable, block_resolution_required}
completed/canceled → RP=none, RC=none, WS empty
active RS → WS non-empty; non-active RS → WS empty
WS, when non-empty and not `unknown` → WS <= last_transition_at
```

## Walkthrough round 2: transition matrix (from → guard → to → delta → retry)

Field shorthand: RS=run_status, PH=phase, RP=responsible_party,
RC=reason_code, V=verdict, VR=validation_result, CR=checkpoint_round,
CS=checkpoint_sha, WS=waiting_since, RD=reason_detail. Every transition
increments `state_revision` and updates `last_transition_at/actor/action`
unless marked zero-write. `RD` is cleared on every transition that does not
carry its own `--reason`.

| # | Command | From | Guard | To | Retry |
| --- | --- | --- | --- | --- | --- |
| T1 | `start` (new run) | no state file; run dir absent | clean integration root; probes pass | RS=active, PH=intake, RP=writer, RC=none, V/VR/CS empty, CR=0, WS=now | — |
| T2 | `submit` (new SHA) | PH in {intake, validated, decided}; RP=writer (intake) or per current state | clean writer tree; HEAD descends from base; HEAD != current CS | RS=active, PH=submitted, RP=reviewer, RC=review_pending, V/VR empty, CS=new SHA, CR: 0→1, N→N+1, `unknown` stays `unknown`, WS=now | evidence written (review.tsv with new SHA) but state not committed → retry recognizes same SHA and commits |
| T3 | `submit` (same SHA) | PH=submitted, RP=reviewer, CS=same SHA | snapshot recreated/intact as needed | zero-write (no round bump, no WS reset) | — |
| T4 | `submit` (same SHA, rejected) | RP=writer, RC in {changes_requested, human_changes_requested}, CS unchanged | — | rejected: "writer must submit a new SHA" | — |
| T5 | `validate` | PH=submitted or validated, RP=reviewer | snapshot intact; review.tsv head == CS; project script runs (exit non-zero is a legitimate FAIL) | RS=active, PH=validated, RP=reviewer, RC=decision_pending, VR=result, WS=now (reason changed) | CAS-publish (below); snapshot-integrity or infrastructure failure = no transition, report still written as evidence |
| T6 | `decision APPROVE` | PH=validated, RP=reviewer, RC=decision_pending | VR=PASS; writer HEAD == review HEAD == CS; no existing decision for CS | RS=active, PH=decided, RP=human, RC=approval_pending, V=APPROVE, WS=now | decision archive written but state not committed → retry recognizes same archive and commits |
| T7 | `decision CHANGES_REQUESTED` | same as T6 | no PASS requirement | RS=active, PH=decided, RP=writer, RC=changes_requested, V=CHANGES_REQUESTED, WS=now | same as T6 |
| T8 | `decision BLOCKED` | same as T6 | — | RS=blocked, PH=decided, RP=human, RC=block_resolution_required, V=BLOCKED, WS=now | same as T6 |
| T9 | `escalate` | RP=reviewer, PH in {submitted, validated} | `--reason-code reviewer_unreachable` (v1 only) and `--reason` present | RS=blocked, PH unchanged, RP=human, RC=reviewer_unreachable, WS=now, RD=reason | already `blocked/human/reviewer_unreachable` → "already escalated", zero-write; human responsible for any other reason → illegal transition |
| T10 | `resolve approve` | RP=human, PH=decided, RC=approval_pending | V=APPROVE | RS=completed, PH=decided, RP=none, RC=none, WS empty | — |
| T11 | `resolve reject` | RP=human, PH=decided, RC in {approval_pending, block_resolution_required} | `--reason` present | RS=active, PH=decided, RP=writer, RC=human_changes_requested, V kept, WS=now | — |
| T12 | `resolve recover` | RP=human, RS=blocked, RC=reviewer_unreachable | `--reason` present; reviewer pane verified reachable (live pane in reviewer-agent mode) — otherwise refuse without transition and print the prerequisite recovery command | RS=active, RP=reviewer, RC: submitted→review_pending, validated→decision_pending, PH unchanged, WS=now | — |
| T13 | `resolve cancel` | RP=human, RC in {approval_pending, block_resolution_required, reviewer_unreachable} | `--reason` present | RS=canceled, PH unchanged, RP=none, RC=none, WS empty | — |

Terminal actions (T10–T13) change Arena state only: no merge, push,
worktree removal, or tmux teardown. `resolve` with an action outside the
allowed set for the current `phase+reason_code` is rejected with the
current responsible party and the allowed actions.

## Walkthrough round 2: CAS validation publishing and crash-retry observability

`validate` (T5):

1. Acquire the run lock; capture `state_revision` and `checkpoint_sha`.
2. Run the gate and write the report to a temporary path (never the
   canonical `validation-<sha>.md`).
3. Re-acquire the lock; compare `state_revision` and `checkpoint_sha`
   against the capture. On match (CAS success): atomically promote the
   temporary report to canonical evidence (report file + `validation.md`
   pointer) and commit the state transition in the same critical section.
   On mismatch (CAS failure): delete the temporary report, update neither
   pointer nor state, and exit with the stale-result code (3).

A temporary validation report becomes canonical evidence only through a
successful CAS publish. Evidence sameness keys per command: `submit` →
`review.tsv` `review_head`; `validate` → canonical report bound to
`checkpoint_sha`; `decision` → `decision-<sha>.md` archive. Retry logic: if
the evidence for the intended transition already exists and matches the
captured `checkpoint_sha`, the retry completes the state commit without
duplicating the evidence; evidence that matches a different SHA is a
conflict, not a retry.

A run whose evidence is newer than its state file (evidence-first crash
residue) is reported by `status` as `incomplete transition` with the exact
retry command and exit code 5.

## Walkthrough round 2: command surface

```bash
agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..."
agent-arena resolve  RUN_ID --action approve|reject|recover|cancel --reason "..."
agent-arena status   RUN_ID      # read-only, one-sentence diagnosis
agent-arena list                 # reads authoritative state
agent-arena repair-state RUN_ID --candidate TOKEN --reason "..."
```

- `escalate` and `resolve` are thin parsers sharing one constrained
  transition function; the state machine never trusts a caller-provided
  `--to`.
- `repair-state`: `--candidate TOKEN` is a token printed by `status` for a
  specific evidence conflict; it binds a candidate state to the current
  evidence digest; the command re-validates that digest under the lock and
  rejects stale or foreign tokens. It is an escape hatch, not an arbitrary
  state writer. There is no `init-state`.
- `status` and `list` are zero-write; legacy runs use the read-only
  projection only.

### Output and exit-code protocol

| Exit | Meaning | `status` output |
| --- | --- | --- |
| 0 | normal (including legacy projection) | one-sentence diagnosis: "waiting on <party> for <reason_code> since <time>; <pane reachability>; release: <command>" plus the detailed section |
| 1 | usage / argument error | usage text |
| 2 | illegal transition, corrupted state file, legacy evidence conflict, invalid enum/combination | the conflict list and the allowed actions (legacy conflicts point to `repair-state`) |
| 3 | stale result (CAS failure) | "state moved during validation; result discarded, re-run validate" |
| 4 | live lock | `transition in progress` (never misreported as a conflict) |
| 5 | incomplete transition (evidence-first residue) | `incomplete transition; retry: <command>` |

`list` mirrors the same exit codes for its authoritative-state column and
prints `legacy` for projected runs.

## Walkthrough round 2: key path traces

`CLI → handler → lock/evidence → state commit → relay/output → exit code`
for each transition command:

- `submit`: parse → find run → legacy derive if needed → acquire lock →
  writer-tree checks → write review snapshot + review.tsv (evidence) →
  commit state (T2/T3/T4) → release lock → best-effort pane respawn and
  notes → exit 0/2/4/5.
- `validate`: parse → find run → legacy derive → acquire lock, capture
  revision+SHA → release lock → run gate → temporary report → re-acquire
  → CAS → promote report + commit state (T5) → release → print report →
  exit 0/2/3/4/5.
- `decision`: parse → find run → legacy derive → acquire lock → integrity
  + writer-head checks → write decision archive (evidence) → commit state
  (T6–T8) → release → best-effort relay → exit 0/2/4/5.
- `escalate`: parse (both reason fields) → find run → acquire lock →
  guard T9 → commit state → release → exit 0/2/4.
- `resolve`: parse (action + reason policy) → find run → acquire lock →
  guard T10–T13 (recover: pane reachability check inside the lock) →
  commit state → release → exit 0/2/4.

## Walkthrough round 3: atomicity, compatibility, and the lock

- Serialized under the lock; evidence first; `run-state.tsv` replacement
  is the commit point; recovery is idempotent by evidence-sameness keys.
  No single-transaction claim across Git worktrees and multiple files.
- relay and reviewer-pane respawn are best-effort, after state commit and
  lock release.
- Lock metadata: PID, unique owner token, creation time; release requires
  the token match; stale-lock handling verifies the PID.
- `start` takes a parent-directory creation lock.
- `status` seeing a live lock prints `transition in progress` (exit 4),
  never an intermediate state as a conflict.
- Legacy first-write commands derive + migrate + transition in memory and
  write exactly one v1 file.
- Corrupted, future-schema, duplicate-key, invalid-enum, or
  illegal-combination state files fail closed; no fallback to legacy
  derivation.

### Legacy projection table (read-only; zero writes)

Evidence keys: `R` = review.tsv with `review_head`; `Val` = validation
report bound to `review_head`; `Dec` = decision archive bound to
`review_head`; `M` = manifest. Projection:

| Evidence | Projected state |
| --- | --- |
| no R | `intake / writer / none / round=unknown` |
| R, no Val, no Dec | `submitted / reviewer / review_pending / CS=review_head` |
| R + Val(PASS or FAIL) bound to review_head | `validated / reviewer / decision_pending` |
| R + Dec APPROVE | `decided / human / legacy_human_disposition_unknown / APPROVE` |
| R + Dec CHANGES_REQUESTED | `decided / writer / changes_requested` |
| R + Dec BLOCKED | `blocked / human / block_resolution_required / BLOCKED` |
| pointer stale, report missing for review_head, or conflicting verdicts | conflict: `status` lists the exact conflicts and points to `repair-state`; transition commands refuse |

Legacy-derived `waiting_since`/`last_transition_at` are `unknown`; legacy
`checkpoint_round` is sticky `unknown`. Allowed resolve actions on legacy
projections: approve/reject/cancel for legacy APPROVE; reject/cancel for
legacy BLOCKED; escalate/recover applies only after the run is migrated.

## Walkthrough round 3: errors and edge cases

Illegal transitions report the current responsible party and the allowed
actions. Contradictory legacy evidence lists conflicts and points to
`repair-state`. Duplicate escalate is idempotent (zero-write); other
human-responsible escalates are illegal. resolve with an out-of-set action
is rejected with the allowed set. recover with a dead reviewer pane
refuses without transition and prints the prerequisite command. approve
and cancel never touch Git remotes, worktrees, or tmux sessions.

## Testing strategy (hermetic only)

Fake CLIs and temporary repositories; no model or network call. Must-cover
paths:

- first round, legacy sticky-`unknown` round, same-SHA retry, same-SHA
  after reject rejection
- validation PASS/FAIL, repeated validation, integrity failure
  no-transition, CAS stale result
- decision matrix incl. APPROVE-without-PASS rejection
- escalate idempotence, illegal escalate from other human states
- every resolve action's exact post-state, terminal `party=none` + empty
  `waiting_since`, recover refused on unreachable pane, recover refused on
  formal BLOCKED
- fault injection at "evidence written, state not committed" for
  submit/validate/decision + retry recognition + `incomplete transition`
  status reporting
- legacy projection table row by row, conflicts, legacy resolve action
  sets, sticky round
- corrupted v1 file, future schema, duplicate/missing/unknown keys,
  invalid enums, illegal field combinations, symlinked state file
- repair-state token: fresh accepted, stale rejected, foreign rejected
- lock liveness: live lock, dead PID, owner-token mismatch, cross-process
  concurrency, CAS publish, parent-directory creation lock
- output-and-exit-code protocol rows 0–5
- full v0.3 regression suite

## Drift, risk, and rollback

Drift from v0.3: responsibility was implicit (derived from evidence
files); v0.4 makes it explicit and authoritative. Risk: the state file is
a second source of truth that can disagree with evidence files — the
commit-point ordering (evidence first, state last), the sameness keys, and
the incomplete-transition reporting bound that disagreement to crash
windows the retry protocol resolves. Rollback: after the first v0.4 state
transition a run has no semantically lossless downgrade (completed,
canceled, escalate, and resolve states have no legacy evidence
equivalent). Recovery from a bad v0.4 rollout therefore means stopping new
transitions and keeping v0.4 read-only interpretation available — never
deleting the authoritative state file, which would let finished runs
"resurrect" in the legacy projection.
