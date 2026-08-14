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
| AC1 | `start` writes schema-v1 state `active / intake / writer / none / round=0` with `state_revision=1`, protected by a creation marker written before any worktree/manifest and removed last; an interrupted start (marker present, state missing) is recovered by the T1r retry and is never projected as legacy. | lifecycle fixture incl. interrupted-start retry |
| AC2 | `submit` with a new SHA follows the from/guard/to/delta table (round increment or sticky `unknown`, SHA binding, verdict/validation cleared); same-SHA submit from `submitted` is an idempotent zero-write retry; same-SHA submit while the writer is responsible (`changes_requested` or `human_changes_requested`) is rejected with "must submit a new SHA". | submit fixture (first, repeated, same-SHA retry, same-SHA-after-reject) |
| AC3 | `validate` from `submitted/reviewer/review_pending` (and revalidate from `validated/reviewer/decision_pending`) records PASS/FAIL and moves to `validated / reviewer / decision_pending` via lock-capture → gate → CAS-publish; snapshot-integrity or infrastructure failure performs no transition; a CAS failure leaves state and pointers untouched and exits with the stale-result code. | validation fixture incl. FAIL, tampered snapshot, CAS stale |
| AC4 | `decision` from `validated/reviewer/decision_pending` maps the three verdicts to their exact target states; APPROVE requires `validation_result=PASS`. | decision matrix fixture |
| AC5 | `escalate` is allowed only from `responsible_party=reviewer` with phase `submitted` or `validated`; requires `--reason-code` and `--reason`; moves to `blocked / human / reviewer_unreachable` (phase unchanged); repeating in that exact state returns "already escalated" with zero write; escalating while human is responsible for any other reason is an illegal transition. | escalate fixture |
| AC6 | `resolve` is allowed only when `responsible_party=human`; per action: approve (only after reviewer APPROVE) → `completed / decided / none / none`; reject → `active / decided / writer / human_changes_requested` (writer must submit a new SHA); recover → requires the reviewer pane reachable as a precondition, else refuses with the two-step prerequisite (`resume` + trust confirm) and only handles operational escalation (never a formal BLOCKED verdict); cancel → `canceled / phase-kept / none / none`. BLOCKED admits only reject or cancel in v1. `reject`/`recover`/`cancel` require `--reason`. Terminal actions change Arena state only: no merge, push, worktree cleanup, or tmux teardown. `resume` respawns a dead reviewer pane in a live session. | resolve matrix fixture incl. unreachable-pane recover refusal and resume respawn |
| AC7 | `waiting_since` resets only when the responsible party or reason changes; zero-write operations are exactly: same-SHA submit retry (T3) and duplicate escalate. `validate` is always a fresh execution (never zero-write); from `validated` it preserves `waiting_since`. Terminal states have empty `waiting_since`. | waiting-since fixture incl. fresh revalidate |
| AC8 | Legacy runs (no `run-state.tsv`, no creation marker): `status`/`list` use the mutually exclusive projection rows L1–L6 (decision precedence, binding by evidence SHA, conflict conditions), labeled `legacy`, zero writes; the first successful transition command projects + migrates + transitions in one lock-internal commit (no TOCTOU); L4/L5 admit `escalate` and L1/L3 admit their resolve action sets as first migrations; contradictory evidence refuses to guess (status lists conflicts + repair candidates); legacy `checkpoint_round` is sticky `unknown`; legacy `validate` CAS baseline = state-absent + evidence digest + checkpoint_sha. | legacy fixtures (projection rows, precedence, conflicts, first-migration escalate/resolve, sticky round, repair candidates) |
| AC9 | A corrupted state file, unknown higher `schema_version`, duplicate or missing or unknown keys, invalid enums, or an illegal field combination fails closed — never falls back to legacy derivation. `repair-state --candidate TOKEN --reason` accepts only a token that `status` printed, bound to the current evidence digest, re-validated under the lock; stale or foreign candidates are rejected. There is no `init-state`. | corruption/hostile-file and repair-token fixtures |
| AC10 | All transitions run under a run lock: metadata carries PID, a unique owner token, and creation time; release requires the token match; `status` seeing a live lock prints `transition in progress` and exits with the lock code; `validate` captures `state_revision`+`checkpoint_sha` under the lock, runs the gate outside the lock, re-acquires, and CAS-publishes; `start` takes a parent-directory creation lock. | lock fixtures (owner token, stale PID, CAS publish, in-progress read) |
| AC11 | Evidence is written before the state file; `run-state.tsv` replacement (mktemp+mv, mode 600) is the commit point. Crash recovery per command: submit/decision retries recognize the same evidence digest and complete the commit; validate recovers by re-execution (always-fresh; residue shapes: report-only, report+pointer, state-aligned all re-run cleanly). The CAS critical section writes report → pointer → state in fixed order, and a crash between any two files is covered by those rules (the lock does not claim multi-file atomicity). A run with evidence-first residue is reported by `status` as `incomplete transition` with the exact retry command and exit code 5; relay and reviewer-pane respawn run best-effort after the state commit and lock release. | crash-injection, retry, incomplete-transition fixtures |
| AC12 | `status` prints the one-sentence diagnosis (who, what, since when, pane reachability, release command) and `list` reads the authoritative state; both are zero-write; outputs and exit codes for terminal, corrupt, legacy-conflict, live-lock, incomplete-transition, and missing-pane cases are per the output protocol table; `validate` exits 0 on PASS and 10 on a recorded FAIL (never 1, which stays usage); `list` aggregates run-level anomalies by numeric priority 5 > 4 > 3 > 2 > 0. | status/list output-and-exit-code fixtures |
| AC13 | The complete v0.3 regression suite passes, except the one explicitly adapted assertion: the integrity-failure validation report now lives at the diagnostic path (`.diagnostic.md`) instead of the canonical report name. | full regression |

## Walkthrough round 2: state file wire contract

`<run_dir>/run-state.tsv`, mode 600, atomically replaced (mktemp+mv).
Every line is `key<TAB>value` with a trailing LF. CR is rejected. The key
set is exactly the sixteen keys below; each appears exactly once, in any
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
| `reason_code` | `none \| review_pending \| decision_pending \| approval_pending \| changes_requested \| human_changes_requested \| reviewer_unreachable \| block_resolution_required` (`legacy_human_disposition_unknown` is a display-only label for legacy projections, never persisted) | no |
| `reason_detail` | no TAB/CR/LF/control characters; at most 256 characters | yes |
| `verdict` | `APPROVE \| CHANGES_REQUESTED \| BLOCKED` | yes |
| `validation_result` | `PASS \| FAIL` | yes |
| `validation_digest` | empty or 64 lowercase hex — sha256 of the canonical report content for the CURRENT checkpoint. Lifecycle: empty before the first validation of the current SHA; non-empty from the first validation and PRESERVED across `validated`, `decided`, `blocked`, `completed`, and `canceled`; cleared only by T2 (new-SHA submit) | yes |
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

Creation intent (parent-level, covers the mkdir window): `start` writes
`<runs_root>/<repo_id>/.creating-<run_id>` (mode 600; content = the full
start parameters as TSV) before creating the run directory, and removes
it only after the state file is committed. Marker-present recovery
follows the T1r stage table below.

Legal field-combination invariants, layered by `run_status` (a state
violating any of them is corrupted and fails closed):

```text
active:
  intake    → RP=writer, RC=none, V empty, VR empty, VD empty, CS empty,
               CR=0, WS non-empty
  submitted → RP=reviewer, RC=review_pending, V empty, VR empty, VD empty,
               CS non-empty, CR non-zero-or-unknown, WS non-empty
  validated → RP=reviewer, RC=decision_pending, V empty, VR non-empty,
               VD non-empty, CS non-empty, WS non-empty
  decided   → CS non-empty, VD non-empty, WS non-empty, and one of:
                RP=human  RC=approval_pending        → V=APPROVE ∧ VR=PASS
                RP=writer RC=changes_requested       → V=CHANGES_REQUESTED
                RP=writer RC=human_changes_requested → V in {APPROVE, BLOCKED}
blocked:  RP=human, WS non-empty, and one of:
            PH in {submitted, validated} ∧ RC=reviewer_unreachable
              (inherits the source-phase V/VR/VD/CS constraints)
            PH=decided ∧ RC=block_resolution_required ∧ V=BLOCKED
              ∧ CS non-empty ∧ VD non-empty
completed: PH=decided, RP=none, RC=none, V=APPROVE, VR=PASS, VD non-empty,
           WS empty
canceled:  RP=none, RC=none, WS empty, PH in {submitted, validated, decided}
           (V/VR/VD/CS inherited from the pre-cancel state)

WS, when non-empty and not `unknown` → WS <= last_transition_at
```

Only terminal states (`completed`, `canceled`) require an empty
`waiting_since`; `blocked` is a waiting state and keeps a non-empty
`waiting_since`. (VD = `validation_digest`.)

## Walkthrough round 2: transition matrix (from → guard → to → delta → retry)

Field shorthand: RS=run_status, PH=phase, RP=responsible_party,
RC=reason_code, V=verdict, VR=validation_result, CR=checkpoint_round,
CS=checkpoint_sha, WS=waiting_since, RD=reason_detail. Every transition
increments `state_revision` and updates `last_transition_at/actor/action`
unless marked zero-write. `RD` is cleared on every transition that does not
carry its own `--reason`.

| # | Command | From | Guard | To | Retry |
| --- | --- | --- | --- | --- | --- |
| T1 | `start` (new run) | no state file, no creation intent; run dir absent | clean integration root; probes pass; write the parent-level creation intent BEFORE `mkdir run_dir` | RS=active, PH=intake, RP=writer, RC=none, V/VR/VD/CS empty, CR=0, WS=now; intent removed last | intent present but state missing = interrupted start (T1r stages, below) |
| T1r | `start` (interrupted retry) | creation intent present; state missing | stage table below | write the T1 state (round=0) exactly once, keep valid existing artifacts, remove the intent, continue normal resume | a crashed T1 is never mistaken for a legacy run |

Creation intent (parent-level, covers the mkdir window): `start` writes
`<runs_root>/<repo_id>/.creating-<run_id>` (mode 600; content = the full
start parameters as TSV: run_id, repository, state_root, worktree_root,
profile, gate_adapter, session_name) before creating the run directory,
and removes it only after the state file is committed. Interrupted-start
stages and their recovery (checked in this order):

```text
S1 intent-only (run_dir absent)            → re-run start (clean re-entry)
S2 empty run_dir, no manifest/worktree     → re-run start (recreates; the
                                              empty private dir is Arena's own
                                              and may be replaced)
S3 run_dir non-empty but manifest missing  → fail closed (unexpected partial
                                              state; human inspects, then
                                              repair-state or manual cleanup)
S4 manifest present, worktree missing      → fail closed (same as S3)
S5 manifest + worktree present, no state   → commit the T1 state (round=0),
                                              remove intent, continue resume
S6 state present, intent remains           → delete the intent (crashed removal)
```
| T2 | `submit` (new SHA) | `(RS=active, PH=intake, RP=writer, RC=none)` or `(RS=active, PH=decided, RP=writer, RC=changes_requested)` or `(RS=active, PH=decided, RP=writer, RC=human_changes_requested)` | clean writer tree; HEAD descends from base; HEAD != current CS | RS=active, PH=submitted, RP=reviewer, RC=review_pending, V/VR/VD empty, CS=new SHA, CR: 0→1, N→N+1, `unknown` stays `unknown`, WS=now | evidence written (review.tsv with new SHA) but state not committed → retry recognizes same SHA and commits |
| T3 | `submit` (same SHA) | PH=submitted, RP=reviewer, CS=same SHA | snapshot recreated/intact as needed | zero-write (no round bump, no WS reset) | — |
| T4 | `submit` (same SHA, rejected) | RP=writer, RC in {changes_requested, human_changes_requested}, CS unchanged | — | rejected: "writer must submit a new SHA" | — |
| T5 | `validate` | `(PH=submitted, RP=reviewer, RC=review_pending)` or `(PH=validated, RP=reviewer, RC=decision_pending)` — validate ALWAYS executes the project script fresh; no zero-write replay path exists | snapshot intact; review.tsv head == CS; project script runs (exit non-zero is a legitimate FAIL) | from `submitted`: RS=active, PH=validated, RP=reviewer, RC=decision_pending, WS=now (reason changed); from `validated`: PH/RP/RC unchanged, **WS preserved**, state_revision+1, transition fields updated; both: VR=result, VD=new report digest | CAS-publish (below); snapshot-integrity or infrastructure failure = no transition, diagnostic-only report (`.diagnostic.md`, never the canonical path or pointer); crash recovery for validate is simply re-running validate (idempotent: residues are cleaned, the old canonical report is rotated per the v0.3 rotation rule, and the CAS publishes a fresh report+pointer+state) |
| T6 | `decision APPROVE` | PH=validated, RP=reviewer, RC=decision_pending | VR=PASS; writer HEAD == review HEAD == CS; no existing decision for CS | RS=active, PH=decided, RP=human, RC=approval_pending, V=APPROVE, WS=now | decision archive written but state not committed → retry recognizes same archive and commits |
| T7 | `decision CHANGES_REQUESTED` | same as T6 | no PASS requirement | RS=active, PH=decided, RP=writer, RC=changes_requested, V=CHANGES_REQUESTED, WS=now | same as T6 |
| T8 | `decision BLOCKED` | same as T6 | — | RS=blocked, PH=decided, RP=human, RC=block_resolution_required, V=BLOCKED, WS=now | same as T6 |
| T9 | `escalate` | RP=reviewer, PH in {submitted, validated} | `--reason-code reviewer_unreachable` (v1 only) and `--reason` present | RS=blocked, PH unchanged, RP=human, RC=reviewer_unreachable, WS=now, RD=reason | already `blocked/human/reviewer_unreachable` → "already escalated", zero-write; human responsible for any other reason → illegal transition |
| T10 | `resolve approve` | RP=human, PH=decided, RC=approval_pending | V=APPROVE | RS=completed, PH=decided, RP=none, RC=none, WS empty | — |
| T11 | `resolve reject` | RP=human, PH=decided, RC in {approval_pending, block_resolution_required} | `--reason` present | RS=active, PH=decided, RP=writer, RC=human_changes_requested, V kept, WS=now | — |
| T12 | `resolve recover` | RP=human, RS=blocked, RC=reviewer_unreachable | `--reason` present; reviewer pane verified reachable (live pane in reviewer-agent mode) — otherwise refuse without transition and print the two-step prerequisite: `agent-arena resume RUN_ID` (respawns a dead reviewer pane in a live session) then confirm the trust prompt in the pane, then re-run recover | RS=active, RP=reviewer, RC: submitted→review_pending, validated→decision_pending, PH unchanged, WS=now | — |
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
successful CAS publish. Per-command canonical evidence sameness tuples
(computed under the lock; a matching tuple = retry, a differing tuple at
the same canonical path = conflict):

```text
submit   → (review.tsv: review_head, gate_adapter, gate_policy_path,
            policy_hash, wrapper_hash) and the review worktree intact
validate → (checkpoint_sha, sha256 of the canonical report file content)
            = the state's validation_digest when published
decision → (checkpoint_sha, sha256 of the decision archive file content)
```

Crash-window recovery per command, boundary by boundary. The CAS
critical section performs three file writes in fixed order — canonical
report (via rotation of the old one), `validation.md` pointer, state file
— and a crash can land between any two; the lock does NOT make them a
single atomic write, so each residue is handled explicitly:

- `submit` — review.tsv already carries the new SHA → retry commits the state.
- `validate` — all three residue shapes (report-only; report+pointer;
  state-aligned) recover the same way: re-running `validate` cleans stale
  `.validation.*` temporaries, rotates the old canonical report, and
  CAS-publishes a fresh report+pointer+state. A `validate` crash never
  needs a commit-only path because the command is idempotent by
  re-execution.
- `decision` — archive exists with a matching digest → commit the state; an
  archive with a differing digest (e.g. a different verdict for the same
  SHA) is a conflict, rejected without transition.

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
agent-arena resume   RUN_ID      # enhanced: respawns a dead reviewer pane in a live session
```

`resume` enhancement (prerequisite for recover): when the tmux session
exists but the reviewer pane is dead, `resume` respawns it from the run's
manifest gate adapter (the same respawn `submit` performs); the pane then
shows the gate's trust prompt, and the human confirms it to make the pane
reachable. `resolve --action recover`'s reachability check uses the same
live-pane test as relay (role=reviewer, mode=reviewer-agent, not dead,
input on).

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
| 0 | normal (including legacy projection and a legitimately recorded validation FAIL) | one-sentence diagnosis: "waiting on <party> for <reason_code> since <time>; <pane reachability>; release: <command>" plus the detailed section |
| 1 | usage / argument error (command-level, never a run state) | usage text |
| 2 | illegal transition, corrupted state file, legacy evidence conflict, invalid enum/combination | the conflict list and the allowed actions (legacy conflicts point to `repair-state`) |
| 3 | stale result (CAS failure) | "state moved during validation; result discarded, re-run validate" |
| 4 | live lock | `transition in progress` (never misreported as a conflict) |
| 5 | incomplete transition (evidence-first residue) | `incomplete transition; retry: <command>` |
| 10 | validation FAIL, successfully recorded (the gate ran and the project script exited non-zero; distinct from usage=1) | the report output ends `RESULT: FAIL` |

`list` aggregates per-run anomalies by numeric priority: it returns the
highest exit code observed across runs in the order 5 > 4 > 3 > 2 > 0
(run-level codes), while its own usage errors remain 1. `validate` returns
0 on PASS and 10 on FAIL; 3/4/5/2 take precedence over 10 when they
occur.

## Walkthrough round 2: key path traces

`CLI → handler → lock/evidence → state commit → relay/output → exit code`
for each transition command:

- `submit`: parse → find run → acquire lock → **re-project legacy state inside the lock** (legacy run) → writer-tree checks → write review snapshot + review.tsv (evidence) → commit state (T2/T3/T4) → release lock → best-effort pane respawn and notes → exit 0/2/4/5.
- `validate`: parse → find run → acquire lock → **re-project legacy state inside the lock** → capture revision+SHA (legacy baseline: state-absent + evidence digest + checkpoint_sha) → release lock → clean stale temporaries → run gate → temporary report → re-acquire → CAS → promote report + pointer + commit state (T5) → release → print report → exit 0/10/2/3/4/5.
- `decision`: parse → find run → acquire lock → **re-project legacy state inside the lock** → integrity + writer-head checks → write decision archive (evidence) → commit state (T6–T8) → release → best-effort relay → exit 0/2/4/5.
- `escalate`: parse (both reason fields) → find run → acquire lock → **legacy run: project inside the lock, migrate to v1, and apply T9 in the same commit when the projection satisfies the T9 guard (legacy SUBMITTED/VALIDATED with a dead reviewer is therefore a legal first migration via escalate)** → guard T9 → commit state → release → exit 0/2/4.
- `resolve`: parse (action + reason policy) → find run → acquire lock → **legacy run: project inside the lock, migrate to v1, and apply the action in the same commit; legacy disposition maps into the guards: `legacy_human_disposition_unknown` + V=APPROVE admits approve/reject/cancel; a projected legacy BLOCKED admits reject/cancel** → guard T10–T13 (recover: pane reachability check inside the lock) → commit state → release → exit 0/2/4.
- `start`: parse → probes → parent creation lock → write parent creation intent → mkdir run_dir → worktree/manifest → commit state (T1) → remove intent → release → tmuxp load → exit 0/2/4; interrupted-start stages S1–S6 per T1r.
- `resume`: parse → find run → acquire lock → project/migrate legacy if needed → verify manifest/worktree → session exists: respawn a dead reviewer pane from the manifest gate adapter; session absent: recreate it → release → attach → exit 0/2/4. The gate trust prompt after a respawn is a HUMAN prompt — Arena cannot verify its confirmation, so recover's reachability check remains the pane-liveness test.
- `repair-state`: parse → find run → acquire lock → re-compute the evidence digest → parse the candidate payload → verify the legal-combination invariants → write v1 state (state_revision=1 for a first file, otherwise +1; last_transition_at=now; actor=system; action=repair-state; reason_detail=--reason; dynamic fields materialized) → release → exit 0/2/4.
- Legacy first real migrations always write `state_revision=1`.

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

### Legacy projection table (read-only; zero writes; lock-internal on transition commands)

Evidence keys: `R` = review.tsv with `review_head`; `Val` = canonical
validation report + pointer bound to `review_head`; `Dec` = decision
archive bound to `review_head`. Matching is by the binding SHA inside the
evidence, never by filename alone. Rows are mutually exclusive; the first
matching row wins.

| # | Condition | Semantic projected state (guards match this) | Display label |
| --- | --- | --- | --- |
| L1 | `Dec` exists, bound to `review_head`, verdict APPROVE; canonical report must exist and bind to `review_head` (v0.3 required it) — VR=report RESULT, VD=sha256(report) | `decided / human / approval_pending / APPROVE / VR=PASS` | `legacy_human_disposition_unknown` (human acceptance unprovable in v0.3 evidence) |
| L2 | `Dec` exists, bound, verdict CHANGES_REQUESTED; VR/VD computed from the canonical report when present, empty otherwise | `decided / writer / changes_requested / CHANGES_REQUESTED` | `legacy` |
| L3 | `Dec` exists, bound, verdict BLOCKED; VR/VD computed from the canonical report when present, empty otherwise | `blocked / human / block_resolution_required / BLOCKED` | `legacy` |
| L4 | no `Dec`; `Val` exists and is bound to `review_head` | `validated / reviewer / decision_pending / VR=report RESULT, VD=sha256(report)` | `legacy` |
| L5 | no `Dec`, no `Val`; `R` exists | `submitted / reviewer / review_pending / CS=review_head` | `legacy` |
| L6 | no `R` AND no orphan evidence (no Val/Dec pointers, reports, or decision files of any kind) | `intake / writer / none / round=unknown` | `legacy` |

Conflict conditions (any one → the projection is refused; `status` lists
each conflict and points to `repair-state`; transition commands refuse):

- `Dec` exists but its bound SHA differs from `review_head`
- `Val` pointer exists but the canonical report is missing or its binding
  SHA differs from `review_head`
- `Dec` exists but the verdict cannot be parsed
- `Val` report exists but `RESULT` is neither PASS nor FAIL
- evidence sets disagree on `review_head` (e.g. pointer files bound to
  different SHAs than `review.tsv`)
- L1 with a missing or unparseable canonical report
- orphan evidence (any Val/Dec file) with no `R` (L6 does not apply)

`Dec` takes precedence over `Val` (a checkpoint with a decision is
`decided`/`blocked`, never re-projected to `validated`). Legacy-derived
`waiting_since`/`last_transition_at` are `unknown`; legacy
`checkpoint_round` is sticky `unknown`. Legacy first migrations write
`state_revision=1`.

Legacy first-migration actions: any transition command on a legacy run
projects inside the lock, migrates the projection to v1, and applies the
corresponding T-row guard and transition in one commit. The semantic
projected states feed the guards directly — L1 admits
`resolve approve/reject/cancel` (T10/T11/T13 guards see
`decided/human/approval_pending`), L3 admits `resolve reject/cancel`, and
L4/L5 admit `escalate` (T9 guard sees `submitted`/`validated` with
`reviewer`). Legacy `validate` uses a CAS baseline of state-absent +
evidence digest + checkpoint_sha.

### repair-state candidate contract

`status` on a conflict prints, per suggested candidate, one line:

```text
repair-candidate <TOKEN> -> <one-line target state description>
```

`TOKEN` = first 12 hex of sha256(evidence digest of the run + the exact
canonical target-state line). `repair-state RUN_ID --candidate TOKEN
--reason "..."` acquires the lock, re-computes the evidence digest and the
candidate line, verifies the candidate satisfies the legal-combination
invariants, and writes it (state_revision=1 for a first file, otherwise
+1; last_transition_at=now; actor=system; action=repair-state;
reason_detail=--reason). A stale digest or a foreign token is rejected
with exit 2. The command accepts only a token that the current `status`
would print.

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
- validation PASS/FAIL from both legal sources (submitted and validated),
  `waiting_since` preserved on revalidate, validate-always-fresh semantics
  (all three residue shapes recover by re-running), integrity failure
  no-transition + diagnostic-only report path, CAS stale result, exit 0 vs
  10 vs 3 precedence
- decision matrix incl. APPROVE-without-PASS rejection
- escalate idempotence, illegal escalate from other human states, legacy
  first-migration escalate
- every resolve action's exact post-state, terminal `party=none` + empty
  `waiting_since`, recover refused on unreachable pane + two-step
  prerequisite output, recover refused on formal BLOCKED, legacy
  first-migration resolve, resume respawn of a dead reviewer pane
- fault injection at "evidence written, state not committed" for
  submit/validate/decision + retry recognition via sameness tuples +
  `incomplete transition` status reporting
- legacy projection rows L1–L6 incl. decision precedence, VR/VD computed
  from canonical reports, each conflict condition, sticky round,
  lock-internal projection (no TOCTOU), conflict→candidate table rows
  (candidate accepted when fresh, stale rejected, foreign rejected,
  refusal-only conflicts), corrupted-state policy (repair never rewrites
  corrupted files; manual-removal recovery path)
- interrupted-start intent stages S1–S6 vs legacy discrimination
- corrupted v1 file, future schema, duplicate/missing/unknown keys,
  invalid enums, illegal field combinations (per the layered invariants),
  symlinked state file
- lock liveness: live lock, dead PID, owner-token mismatch, cross-process
  concurrency, CAS publish, parent-directory creation lock
- output-and-exit-code protocol rows 0–5 and 10; `list` aggregation
  priority
- full v0.3 regression suite with the one adapted diagnostic-path
  assertion

## Drift, risk, and rollback

Drift from v0.3: responsibility was implicit (derived from evidence
files); v0.4 makes it explicit and authoritative. Two deliberate behavior
changes over v0.3: (1) snapshot-integrity or infrastructure failures write
a diagnostic-only report (`validation-<sha>.diagnostic.md`), never the
canonical report path or pointer, and never move state — the v0.3
regression test asserting a FAIL report after an integrity failure is
adapted to the diagnostic path; (2) `validate` exits 10 on a recorded
project FAIL instead of propagating the script status, keeping exit 1 for
usage. Risk: the state file is a second source of truth that can disagree
with evidence files — the commit-point ordering (evidence first, state
last), the sameness tuples, and the incomplete-transition reporting bound
that disagreement to crash windows the retry protocol resolves. Rollback:
after the first v0.4 state transition a run has no semantically lossless
downgrade (completed, canceled, escalate, and resolve states have no
legacy evidence equivalent). Recovery from a bad v0.4 rollout therefore
means stopping new transitions and keeping v0.4 read-only interpretation
available — never deleting the authoritative state file, which would let
finished runs "resurrect" in the legacy projection.
