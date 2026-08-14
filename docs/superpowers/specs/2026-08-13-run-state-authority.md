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
| AC1 | `start` writes schema-v1 state `active / intake / writer / none / round=0` with `state_revision=1`, protected by a parent-level creation intent written before any worktree/manifest and removed last; the intent binds the derived creation inputs (base SHA, writer branch, adapter paths, worktree path) and a retry whose parameters differ fails closed. Interrupted starts are RELIABLY CLASSIFIED, with partial auto-recovery: stages S1/S2/S5/S6 recover automatically on re-running `start`; stages S3/S4 fail closed with an explicit manual abort protocol printed by `status` (inspect the run directory; if only Arena-created artifacts, remove the directory, the intent, the Git worktree registration, and the writer branch, then re-run `start` — Arena never removes them automatically). An interrupted v0.4 start is never projected as legacy. | lifecycle fixture incl. interrupted-start stages |
| AC2 | `submit` with a new SHA follows the from/guard/to/delta table (round increment or sticky `unknown`, SHA binding, verdict/validation cleared); same-SHA submit from a PERSISTED-v1 `submitted` state is an idempotent zero-write retry (T3); same-SHA submit while the writer is responsible (`changes_requested` or `human_changes_requested`) is rejected with "must submit a new SHA"; a legacy same-SHA submit materializes v1 via L-T3 (inherited T3 guards, no zero-write). | submit fixture (first, repeated, same-SHA retry, same-SHA-after-reject, L-T3) |
| AC3 | `validate` from `submitted/reviewer/review_pending` (and revalidate from `validated/reviewer/decision_pending`) records PASS/FAIL and moves to `validated / reviewer / decision_pending` via the op-token protocol: first-lock pending-archive refusal (exit 5, gate never runs), triple baseline `state_revision`+`checkpoint_sha`+archive-`absent`, gate outside the lock, CAS-publish; snapshot-integrity or infrastructure failure performs no transition; a CAS failure leaves state and pointers untouched and exits 3 (stale) or 5 (archive appeared). | validation fixture incl. FAIL, tampered snapshot, CAS stale, pre-existing pending archive |
| AC4 | `decision` from `validated/reviewer/decision_pending` maps the three verdicts to their exact target states; APPROVE requires `validation_result=PASS`. | decision matrix fixture |
| AC5 | `escalate` is allowed only from `responsible_party=reviewer` with phase `submitted` or `validated`; requires `--reason-code` and `--reason`; moves to `blocked / human / reviewer_unreachable` (phase unchanged); repeating in that exact state returns "already escalated" with zero write; escalating while human is responsible for any other reason is an illegal transition. | escalate fixture |
| AC6 | `resolve` is allowed only when `responsible_party=human`; per action: approve (only after reviewer APPROVE) → `completed / decided / none / none`; reject → `active / decided / writer / human_changes_requested` (writer must submit a new SHA); recover → requires the reviewer pane reachable as a precondition, else refuses with the two-step prerequisite (`resume` + trust confirm) and only handles operational escalation (never a formal BLOCKED verdict); cancel → `canceled / phase-kept / none / none`. BLOCKED admits only reject or cancel in v1. `reject`/`recover`/`cancel` require `--reason`. Terminal actions change Arena state only: no merge, push, worktree cleanup, or tmux teardown. `resume` respawns a dead reviewer pane in a live session. | resolve matrix fixture incl. unreachable-pane recover refusal and resume respawn |
| AC7 | `waiting_since` resets only when the responsible party or reason changes; zero-write operations are exactly: persisted-v1 same-SHA submit retry (T3), duplicate escalate, and the T14 state-equals-target intent cleanup. `validate` is always a fresh execution (never zero-write); from `validated` it preserves `waiting_since`. A valid-v1 repair preserves `waiting_since` when the candidate's party and reason match the current state. Terminal states have empty `waiting_since`. | waiting-since fixture incl. fresh revalidate |
| AC8 | Legacy runs (no `run-state.tsv`, no creation intent): `status`/`list` use the mutually exclusive projection rows L1–L6 (decision precedence, binding by evidence SHA, L1–L3 REQUIRE a matching, parseable canonical validation report — missing report = conflict; conflict conditions listed), labeled `legacy`, zero writes; the first successful transition command projects + migrates + transitions in one lock-internal commit (no TOCTOU); L4/L5 admit `escalate` and L1/L3 admit their resolve action sets as first migrations; `resume` never migrates legacy (in-memory projection only); contradictory evidence refuses to guess (status lists conflicts + repair candidates); legacy `checkpoint_round` is sticky `unknown`; legacy `validate` CAS baseline = state-absent + evidence digest + checkpoint_sha. | legacy fixtures (projection rows, precedence, mandatory-report conflicts, first-migration escalate/resolve, sticky round, repair candidates) |
| AC9 | A corrupted state file, unknown higher `schema_version`, duplicate or missing or unknown keys, invalid enums, or an illegal field combination fails closed — never falls back to legacy derivation. Recovery from a corrupted file is a CONTROLLED replacement with no authority gap (copy to `run-state.tsv.corrupt.<timestamp>` first, then atomically replace with a fresh v1 projection; the corrupt-replacement revision resets to 1); a future schema version has no recovery path (upgrade Arena). `repair-state --candidate TOKEN --reason` accepts only a token that `status` printed, bound to the evidence digest AND the current state baseline (absent / valid digest+revision / corrupted-file digest), re-validated under the lock; stale or foreign candidates are rejected. There is no `init-state`. | corruption/hostile-file, controlled-replacement, and repair-token fixtures |
| AC10 | All transitions run under a run lock: metadata carries PID, a unique owner token, and creation time; release requires the token match; the mkdir→metadata window is covered by a grace rule (no metadata + mtime > 60s = stale; within 60s = live, exit 4); `status` seeing a live lock prints `transition in progress` and exits with the lock code; `validate` captures the triple baseline (state_revision+checkpoint_sha+archive-absence) under the lock, runs the gate outside the lock, re-acquires, and CAS-publishes; `start` takes a parent-directory creation lock. | lock fixtures (owner token, stale PID, mkdir-window grace, CAS publish, in-progress read) |
| AC11 | Evidence is written before the state file; `run-state.tsv` replacement (mktemp+mv, mode 600) is the commit point. Validate uses the op-token protocol (lock-captured revision+SHA, lock-external gate writing only its own token-named temporary, lock-internal CAS publish with archive-COPY + atomic canonical replace; temp cleanup only for dead-owner tokens) and is exempt from the generic digest-conflict rule. Decision archives carry `State revision` + `Validation digest` metadata; publication order archive → `decision.md` atomic → state; T6r completes archive-only residue and re-checks PASS and HEAD guards against the CURRENT state. Residue rule: owning command + matching sameness tuple executes the recovery; an owning command with a mismatching tuple exits 2 (evidence conflict); any foreign command refuses with exit 5 and the exact retry command. Validate's first-lock check treats a pre-existing pending decision archive as foreign residue (exit 5, gate not run); the CAS archive component may only ever be the literal `absent`. `status` reports `incomplete transition` with exit code 5; transition-triggered side effects (submit's reviewer-pane respawn, decision's relay) run best-effort after the state commit and lock release — the `resume` path respawns INSIDE the lock instead (checkpoint race closed). | crash-injection, retry, incomplete-transition, residue-ownership fixtures |
| AC12 | `status` prints the one-sentence diagnosis plus the per-scenario lines (terminal, missing tmux session, dead reviewer pane, legacy conflict with repair candidates, live lock, incomplete transition, corrupted file); `list` prints fixed columns `REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY`, sorted by the (REPOSITORY, RUN_ID) composite key; both are zero-write; `status`/`list` return only 0/1/2/4/5 (never 3 or 10); `validate` exits 0 on PASS and 10 on a recorded FAIL; `list` aggregates run-level anomalies by priority 5 > 4 > 2 > 0. | status/list output-and-exit-code fixtures |
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
               CS non-empty, CR positive-or-unknown, WS non-empty
  validated → RP=reviewer, RC=decision_pending, V empty, VR non-empty,
               VD non-empty, CS non-empty, CR positive-or-unknown,
               WS non-empty
  decided   → CS non-empty, CR positive-or-unknown, VD non-empty,
               WS non-empty, and one of:
                RP=human  RC=approval_pending        → V=APPROVE ∧ VR=PASS
                RP=writer RC=changes_requested       → V=CHANGES_REQUESTED
                                                        ∧ VR non-empty
                RP=writer RC=human_changes_requested → V=APPROVE ∧ VR=PASS
                                                        or V=BLOCKED
                                                        ∧ VR non-empty
blocked:  RP=human, WS non-empty, and one of:
            PH in {submitted, validated} ∧ RC=reviewer_unreachable
              (inherits the source-phase V/VR/VD/CS constraints)
            PH=decided ∧ RC=block_resolution_required ∧ V=BLOCKED
              ∧ VR non-empty ∧ CS non-empty ∧ VD non-empty
completed: PH=decided, RP=none, RC=none, V=APPROVE, VR=PASS, VD non-empty,
           CS non-empty, WS empty
canceled:  RP=none, RC=none, WS empty, one of (fully enumerated, no
           inheritance):
             PH=submitted → CS non-empty, V/VR/VD empty
             PH=validated → CS/VR/VD non-empty, V empty
             PH=decided   → CS/VD non-empty, and one of:
                              V=APPROVE ∧ VR=PASS
                              V=BLOCKED ∧ VR non-empty

All non-intake states require a non-empty `checkpoint_sha` and
`checkpoint_round` positive-or-unknown.

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
| T1r | `start` (interrupted retry) | creation intent present (state present OR missing — stage table decides) | stage table below | write the T1 state (round=0) exactly once, keep valid existing artifacts, remove the intent, continue normal resume | a crashed T1 is never mistaken for a legacy run |

Creation intent (parent-level, covers the mkdir window): `start` writes
`<runs_root>/<repo_id>/.creating-<run_id>` (mode 600; content = the full
start parameters as TSV: run_id, repository, state_root, worktree_root,
profile, gate_adapter, session_name) before creating the run directory,
and removes it only after the state file is committed. The intent also
binds the DERIVED creation inputs so a retry cannot silently re-create a
different run: base SHA, writer branch name, resolved writer/gate
adapter paths, and the writer worktree path — a retry whose parameters
or derived inputs differ from the intent fails closed (exit 2).
Interrupted-start stages and their recovery (checked in this order):

```text
S1 intent-only (run_dir absent)            → re-run start (clean re-entry)
S2 empty run_dir, no manifest/worktree     → re-run start (recreates; the
                                              empty private dir is Arena's own
                                              and may be replaced)
S3 run_dir non-empty but manifest missing  → fail closed: `status` prints the
                                              manual abort protocol — inspect
                                              <run_dir>; if only Arena-created
                                              artifacts, remove the directory,
                                              the creation intent, the Git
                                              worktree registration
                                              (`git worktree remove <path>`,
                                              then `git worktree prune` if the
                                              worktree exists but its directory
                                              is gone), and the writer branch
                                              (`git branch -D
                                              agent-arena/<adapter>/<run_id>`
                                              only after confirming no manifest
                                              references it), then re-run start
S4 manifest present, worktree missing      → fail closed: same manual abort
                                              protocol as S3
S5 manifest + worktree present, no state   → commit the T1 state (round=0),
                                              remove intent, continue resume
S6 state present, intent remains           → delete the intent (crashed removal)
```
| T2 | `submit` (new SHA) | `(RS=active, PH=intake, RP=writer, RC=none)` or `(RS=active, PH=decided, RP=writer, RC=changes_requested)` or `(RS=active, PH=decided, RP=writer, RC=human_changes_requested)` | clean writer tree; HEAD descends from base; HEAD != current CS | RS=active, PH=submitted, RP=reviewer, RC=review_pending, V/VR/VD empty, CS=new SHA, CR: 0→1, N→N+1, `unknown` stays `unknown`, WS=now | evidence written (review.tsv with new SHA) but state not committed → retry recognizes same SHA and commits |
| T3 | `submit` (same SHA) | PH=submitted, RP=reviewer, CS=same SHA | snapshot recreated/intact as needed | zero-write (no round bump, no WS reset) | — |
| T4 | `submit` (same SHA, rejected) | RP=writer, RC in {changes_requested, human_changes_requested}, CS unchanged | — | rejected: "writer must submit a new SHA" | — |
| T5 | `validate` | `(PH=submitted, RP=reviewer, RC=review_pending)` or `(PH=validated, RP=reviewer, RC=decision_pending)` — validate ALWAYS executes the project script fresh; no zero-write replay path exists | snapshot intact; review.tsv head == CS; project script runs (exit non-zero is a legitimate FAIL) | from `submitted`: RS=active, PH=validated, RP=reviewer, RC=decision_pending, WS=now (reason changed); from `validated`: PH/RP/RC unchanged, **WS preserved**, state_revision+1, transition fields updated; both: VR=result, VD=new report digest | CAS-publish via the validation op-token protocol (below); snapshot-integrity or infrastructure failure = no transition, diagnostic-only report (`.diagnostic.md`, never the canonical path or pointer); crash recovery for validate is safe/convergent re-execution (below) |
| T6 | `decision APPROVE` | PH=validated, RP=reviewer, RC=decision_pending | VR=PASS; writer HEAD == review HEAD == CS; **no existing decision archive for CS** | RS=active, PH=decided, RP=human, RC=approval_pending, V=APPROVE, WS=now | see T6r |
| T6r | `decision` (commit-only retry) | PH=validated, RP=reviewer, RC=decision_pending, state V empty; decision archive exists for CS | archive `State revision` == current `state_revision` AND archive `Validation digest` == current state `validation_digest`; verdict matches the intended decision; bound SHA == CS; ALL normal guards re-checked (APPROVE requires current VR=PASS; writer HEAD == review HEAD == CS) | first complete any missing `decision.md` (atomic replace), then commit the state per the matched verdict (T6/T7/T8 target) | archive with differing verdict/digest/metadata → owning mismatch: conflict, exit 2; state already aligned → duplicate decision rejected; a fresh validate superseding the archive is prevented at the source: validate refuses (exit 5) while a pending unaligned decision archive exists |
| L-T3 | `submit` (legacy first migration, same SHA) | legacy run; projection row L5 (submitted, same SHA); no state file | review.tsv exists and matches the submitted SHA; the T3 guards are inherited: the review snapshot is recreated/verified intact and the submit sameness tuple matches (review_head, gate_adapter, gate_policy_path, policy/wrapper hashes) | materialize v1 with the L5 projection (revision 1, round `unknown`, WS=now) — the state file is written, no evidence changes, no zero-write T3 applies | the v0.4 creation of state is the commit point |
| L-T6 | `decision` (legacy first migration, v0.4 archive residue) | legacy run; no state file; decision archive carries v0.4 metadata with `State revision: 0` (the legacy-baseline encoding — 0 means "written while no state file existed") | projection row L1–L3 satisfied; archive `Validation digest` consistent with the projected validation report; ALL corresponding T6/T7/T8 current-state guards are inherited and re-checked: writer HEAD == review HEAD == CS, verdict valid, APPROVE requires PASS, snapshot intact, and the decision sameness tuple matches | complete any missing `decision.md` first, then materialize v1 with the projected semantic state plus the archive verdict (revision 1, WS=now) | an archive WITHOUT v0.4 metadata is plain v0.3 evidence — it never routes through L-T6; subsequent `resolve` first migrations still apply to it via the L1–L3 projections |
| T7 | `decision CHANGES_REQUESTED` | same as T6 | no PASS requirement | RS=active, PH=decided, RP=writer, RC=changes_requested, V=CHANGES_REQUESTED, WS=now | same as T6 |
| T8 | `decision BLOCKED` | same as T6 | — | RS=blocked, PH=decided, RP=human, RC=block_resolution_required, V=BLOCKED, WS=now | same as T6 |
| T9 | `escalate` | RP=reviewer, PH in {submitted, validated} | `--reason-code reviewer_unreachable` (v1 only) and `--reason` present | RS=blocked, PH unchanged, RP=human, RC=reviewer_unreachable, WS=now, RD=reason | already `blocked/human/reviewer_unreachable` → "already escalated", zero-write; human responsible for any other reason → illegal transition |
| T10 | `resolve approve` | RP=human, PH=decided, RC=approval_pending | V=APPROVE | RS=completed, PH=decided, RP=none, RC=none, WS empty | — |
| T11 | `resolve reject` | RP=human, PH=decided, RC in {approval_pending, block_resolution_required} | `--reason` present | RS=active, PH=decided, RP=writer, RC=human_changes_requested, V kept, WS=now | — |
| T12 | `resolve recover` | RP=human, RS=blocked, RC=reviewer_unreachable | `--reason` present; reviewer pane verified reachable (live pane in reviewer-agent mode) — otherwise refuse without transition and print the two-step prerequisite: `agent-arena resume RUN_ID` (respawns a dead reviewer pane in a live session) then confirm the trust prompt in the pane, then re-run recover | RS=active, RP=reviewer, RC: submitted→review_pending, validated→decision_pending, PH unchanged, WS=now | — |
| T13 | `resolve cancel` | RP=human, RC in {approval_pending, block_resolution_required, reviewer_unreachable} | `--reason` present | RS=canceled, PH unchanged, RP=none, RC=none, WS empty | — |

Resolve actions (T10–T13; T11/T12 are NOT terminal — only T10 and T13 end the run)
change Arena state only: no merge, push, worktree removal, or tmux
teardown. `resolve` with an action outside the allowed set for the current
`phase+reason_code` is rejected with the current responsible party and
the allowed actions.

## Walkthrough round 2: CAS validation publishing and crash-retry observability

`validate` (T5) uses a dedicated validation op-token protocol; validate
is EXEMPT from the generic "differing digest = conflict" rule:

1. Acquire the run lock; FIRST check for a pending decision archive on
   the current SHA: if an archive exists and the state is not aligned
   with it, refuse immediately with exit 5 (complete the decision retry
   first) WITHOUT running the gate. Then capture the CAS baseline =
   (`state_revision`, `checkpoint_sha`, decision-archive ABSENCE — the
   archive component of the baseline may only ever be the literal
   `absent` from this point on); allocate an op-token and its temporary
   report path `.validation.<token>.tmp` (token embeds PID + a nonce).
2. Release the lock; run the gate; write ONLY this op-token's temporary
   file (the gate never writes a canonical path).
3. Re-acquire the lock; compare the FULL baseline against the current
   values, with exactly three ordered outcomes: (a) an archive appeared
   AND `state_revision` is unchanged — the decision wrote evidence only,
   a pending residue → exit 5 (complete the decision retry first); (b)
   `state_revision` changed — the decision completed, stale → exit 3;
   (c) the triple baseline matches — CAS success: promote the temporary
   report to canonical — archive-COPY first (cp the old canonical to a
   `validation-<sha>.rN` temporary then mv that into place, so a crash
   never leaves a truncated `.rN`), then atomically replace the
   canonical report (mktemp+mv), then the pointer, then commit the state
   — and remove this op-token's temporary. Outcomes (a) and (b) also
   remove only this op-token's temporary and update neither pointer nor
   state.
4. Temporary cleanup: a lock holder may delete a `.validation.*.tmp`
   only when the owner PID in the token is confirmed dead (kill -0
   fails); its own temporary is always removed.

A temporary validation report becomes canonical evidence only through a
successful CAS publish. Per-command canonical evidence sameness tuples
(computed under the lock; a matching tuple = retry, a differing tuple at
the same canonical path = conflict; validate follows its own protocol
above and is not covered by this rule):

```text
submit   → (review.tsv: review_head, gate_adapter, gate_policy_path,
            policy_hash, wrapper_hash) and the review worktree intact
decision → (checkpoint_sha, verdict, sha256 of the decision archive
            content, archive metadata: state_revision + validation_digest)
```

The decision archive carries two v0.4 metadata lines —
`State revision: N` and `Validation digest: <vd>` — recorded from the
state at decision time; T6r re-checks them against the CURRENT state. A
fresh validate cannot supersede a pending archive: the validate CAS
baseline includes the archive digest-or-absence, so validate refuses (exit
5) while an unaligned archive exists — the archive only goes stale if the
state legitimately advanced past it, which T6r rejects. Publication
order for decision evidence: decision archive (mktemp+mv) →
`decision.md` atomic replace → `run-state.tsv`. T6r completes
archive-only residue (archive present, `decision.md` or state missing).

Crash-window recovery per command, boundary by boundary. Publication
order for validate evidence is archive-COPY then atomic replace, so the
canonical report path NEVER becomes empty. The lock does NOT make the
multi-file write atomic, so each residue is handled explicitly:

- `submit` — review.tsv already carries the new SHA → retry commits the state.
- `validate` — all residue shapes (temporary-only; report-only; report+
  pointer; state-aligned) recover the same way: safe/convergent
  re-execution per the op-token protocol above.
- `decision` — normal path (T6–T8) requires NO existing decision archive;
  T6r completes archive-only or archive+pointer residue; an archive with
  a differing verdict or digest is a conflict, rejected without
  transition; state already aligned with the archive is a duplicate
  decision, rejected.

Evidence-first residue rule with precise exit codes: an OWNING command
whose sameness tuple MATCHES executes the recovery (submit for
review.tsv; decision for decision archives via T6r; repair-state per its
candidate contract; legacy first migrations via L-T3/L-T6); an OWNING
command with a MISMATCHING tuple has a genuine evidence conflict and
exits 2; any FOREIGN command hitting the residue exits 5 with the exact
retry command. It never walks through foreign residue.

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

Per-scenario `status` output lines (beyond the diagnosis sentence):

- terminal (`completed`/`canceled`): `state: <run_status>; verdict: <verdict>` (no pane check, no release command)
- missing tmux session: `tmux session: not running` (pane reachability noted as N/A)
- reviewer pane dead: `reviewer pane: unreachable` plus the escalate/recover two-step
- legacy conflict: `legacy evidence conflicts:` followed by one line per conflict, then repair-candidate lines (if any)
- live lock / incomplete transition / corrupted file: the protocol lines above

`list` aggregates per-run anomalies by numeric priority 5 > 4 > 2 > 0,
while its own usage errors remain 1. Exit codes 3 (stale CAS) and 10
(recorded FAIL) are returned ONLY by transition commands — `status` and
`list` never return them. `validate` returns 0 on PASS
and 10 on FAIL; 3/4/5/2 take precedence over 10 when they occur.

## Walkthrough round 2: key path traces

`CLI → handler → lock/evidence → state commit → relay/output → exit code`
for each transition command:

- `submit`: parse → find run → acquire lock → **re-project legacy state inside the lock** (legacy run) → writer-tree checks → write review snapshot + review.tsv (evidence) → commit state (T2/T3/T4) → release lock → best-effort pane respawn and notes → exit 0/2/4/5.
- `validate`: parse → find run → acquire lock → **re-project legacy state inside the lock** → first-lock pending-archive check (exit 5 without running the gate) → clean dead-owner temporaries (lock holder only, owner PID dead) → capture the triple baseline (state_revision + checkpoint_sha + archive-absence; legacy baseline: state-absent + evidence digest + checkpoint_sha) → allocate the op-token temporary → release lock → run gate (writes ONLY the token temporary) → re-acquire → CAS → promote report + pointer + commit state (T5) → remove own temporary → release → print report → exit 0/10/2/3/4/5.
- `decision`: parse → find run → acquire lock → **re-project legacy state inside the lock** → integrity + writer-head checks → write decision archive (evidence) → commit state (T6–T8) → release → best-effort relay → exit 0/2/4/5.
- `escalate`: parse (both reason fields) → find run → acquire lock → **legacy run: project inside the lock, migrate to v1, and apply T9 in the same commit when the projection satisfies the T9 guard (legacy SUBMITTED/VALIDATED with a dead reviewer is therefore a legal first migration via escalate)** → guard T9 → commit state → release → exit 0/2/4.
- `resolve`: parse (action + reason policy) → find run → acquire lock → **legacy run: project inside the lock, migrate to v1, and apply the action in the same commit; legacy disposition maps into the guards: `legacy_human_disposition_unknown` + V=APPROVE admits approve/reject/cancel; a projected legacy BLOCKED admits reject/cancel** → guard T10–T13 (recover: pane reachability check inside the lock) → commit state → release → exit 0/2/4.
- `start`: parse → probes → parent creation lock → write parent creation intent → mkdir run_dir → worktree/manifest → **acquire the run lock BEFORE the state commit** → commit state (T1) → remove intent (inside the run lock) → release the parent lock → **re-check under the run lock whether the tmux session already exists (skip load if it does)** → tmuxp load (session creation under the run lock) → release the run lock → exit 0/2/4; interrupted-start stages S1–S6 per T1r use the same lock ordering (S5's state commit is under the run lock). Every command except `start` (including `resume`) refuses while a creation intent exists without a live owner (exit 5, retry: start); only `status` and `list` additionally distinguish S3/S4 with exit 2 and the abort protocol — no transition may enter a half-created run. `resume` refuses while a creation intent exists and creates or respawns the session under the SAME run lock, so a concurrent start and resume can never create the tmux session twice; a tmuxp-load failure releases the run lock and the next retry re-enters through the resume path.
- `resume`: parse → find run → **refuse while a creation intent exists without a live owner** (exit 5, retry: start — same as every command except `start`) → acquire lock → **legacy run: in-memory projection only (read-only, no state write — resume is not a transition; there is no T-row and no `last_transition_action` for it)** → verify manifest/worktree → **respawn a dead reviewer pane INSIDE the lock** (session exists) or recreate the session (session absent) → release lock → attach → exit 0/2/4. Respawn-inside-the-lock closes the checkpoint race: a concurrent submit cannot change the reviewer target between the check and the respawn. The gate trust prompt after a respawn is a HUMAN prompt — Arena cannot verify its confirmation, so recover's reachability check remains the pane-liveness test.
- `repair-state`: parse → find run → acquire lock → if an intent exists, THE OWNER recovers per the three-state rule (a: continue, b: zero-write finish, c: fail closed) instead of exiting 5 → re-compute the evidence digest → parse the candidate payload → verify the legal-combination invariants → write the repair intent (original state baseline + evidence baseline + candidate + tombstone move map) → audit-copy a corrupt file if any → tombstone orphan evidence per the move map → write v1 state (revision rules per T14) → remove the intent → release → exit 0/2/4; a crash anywhere after the intent re-executes from the intent.
- Legacy first real migrations always write `state_revision=1`.
- `status`: parse → find run → check in priority order: (1) LIVE LOCK
  (run or parent creation lock with a live owner) — `transition in
  progress`, exit 4, always wins; (2) parent creation intent with no
  live owner — stages S1/S2/S5/S6 report `incomplete transition; retry:
  start` (exit 5, recovery owned by `start`); stages S3/S4 report the
  manual abort protocol (exit 2), and ONLY `status`, `list`, and `start`
  take the exit-2 path — every OTHER command (including `resume`) treats
  any creation intent without a live owner as exit 5 + retry `start`; (3) repair intent with
  no live lock — `incomplete transition; retry: repair-state`, exit 5,
  before any ordinary state parse; (4) ordinary parse: read state file or
  (legacy: project read-only, lock-free; no state write) → check tmux
  session and pane liveness (observation only) → print the diagnosis
  sentence + per-scenario lines → exit per the protocol table (never 3
  or 10). `list` and every transition command perform the same priority
  check; a foreign command hitting a repair intent exits 5, while the
  owning `repair-state` recovers per the three-state rule.
- `list`: enumerate `<runs_root>/*/*/manifest.tsv` → per run read the
  authoritative state (or legacy projection) → print one row per run with
  FIXED columns: `REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY
  REASON_CODE WAITING_SINCE AUTHORITY ANOMALY` (AUTHORITY ∈ `state`,
  `legacy`; ANOMALY ∈ empty, `corrupt`, `conflict`, `in-progress`,
  `incomplete`) → rows sorted by the composite key
  (REPOSITORY, RUN_ID) because run IDs can repeat across repositories →
  aggregate anomalies per priority 5 > 4 > 2 > 0 → exit accordingly
  (never 3 or 10; usage errors remain 1).

## Walkthrough round 3: atomicity, compatibility, and the lock

- Serialized under the lock; evidence first; `run-state.tsv` replacement
  is the commit point. Recovery is idempotent by evidence-sameness keys
  for submit/decision/repair (non-validate commands); validate recovery is
  safe/convergent re-execution via the op-token protocol. No
  single-transaction claim across Git worktrees and multiple files.
- transition-triggered side effects (relay, submit's reviewer-pane
  respawn) are best-effort, after state commit and lock release; the
  `resume` respawn runs inside the lock (see the resume trace).
- Lock metadata: PID, unique owner token, creation time; release requires
  the token match; stale-lock handling verifies the PID. The metadata file
  itself is published atomically (same-directory temp + mv); a leftover
  temp is treated exactly like absent metadata. The mkdir → metadata window
  is covered by a grace rule: no metadata and mtime older than 60 seconds =
  stale, removable by any contender; no metadata and mtime within 60
  seconds = considered live, contenders wait or exit 4. The run lock and
  the parent creation lock share this rule.
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
evidence, never by filename alone. A PRECHECK runs BEFORE the row
matching and diagnoses, in order: (a) report-without-pointer — classified
as a validate-owned residue (exit 5, retry: validate) ONLY when `R`
exists, the report parses, and it binds to the current `review_head`;
otherwise it is a conflict; (b) pending decision archive with no state —
decision-owned residue ONLY when the archive carries v0.4 metadata with
`State revision: 0`; a plain v0.3 decision continues into rows L1–L3;
(c) the conflict conditions below. Only a run passing the precheck
reaches the rows. Rows are mutually exclusive; the first
matching row wins.

| # | Condition | Semantic projected state (guards match this) | Display label |
| --- | --- | --- | --- |
| L1 | `Dec` exists, bound to `review_head`, verdict APPROVE; canonical validation report MUST exist, bind to `review_head`, parse, and carry `RESULT: PASS` (v0.3 required it) — VR=report RESULT, VD=sha256(report) | `decided / human / approval_pending / APPROVE / VR=PASS` | `legacy_human_disposition_unknown` (human acceptance unprovable in v0.3 evidence) |
| L2 | `Dec` exists, bound, verdict CHANGES_REQUESTED; canonical validation report MUST exist, bind, and parse — VR/VD computed from it | `decided / writer / changes_requested / CHANGES_REQUESTED` | `legacy` |
| L3 | `Dec` exists, bound, verdict BLOCKED; canonical validation report MUST exist, bind, and parse — VR/VD computed from it | `blocked / human / block_resolution_required / BLOCKED` | `legacy` |
| L4 | no `Dec`; `Val` exists and is bound to `review_head` | `validated / reviewer / decision_pending / VR=report RESULT, VD=sha256(report)` | `legacy` |
| L5 | no `Dec`, no `Val`, and no report or pointer artifacts of any kind; `R` exists | `submitted / reviewer / review_pending / CS=review_head` | `legacy` |
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
- L1–L3 with a missing, unparseable, or unbound canonical validation
  report (for L1 additionally: RESULT is not PASS)

A canonical validation report WITHOUT its pointer is a validate-owned
residue (exit 5, retry: validate, no repair candidate) ONLY under the
precheck's exact conditions: `R` exists, the report parses, and it binds
to the current `review_head`; otherwise it is a repair conflict (exit 2).
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

`TOKEN` = first 12 hex of sha256(evidence digest of the run + the current
state baseline + the exact canonical candidate payload). The state
baseline binds the token to what repair will build on: state absent →
the literal `absent`; valid v1 state → its digest + revision; corrupted
state file → the corrupted-file digest (revision is untrusted and
goes through the reset rule). The canonical payload serializes the
candidate's STATIC fields as key=value in the wire-table order joined by
`;`, with dynamic metadata written as placeholders so the hash never
depends on values repair-state fills in later:
`state_revision=@revision`, `waiting_since=@now`,
`last_transition_at=@now`, `last_transition_actor=system`,
`last_transition_action=repair-state`, `reason_detail=@reason`; all
other fields hold their concrete target values. Conflict → candidate
table:

| Conflict | Candidate (target state) |
| --- | --- |
| Dec bound to a SHA differing from `review_head` | L-row projection ignoring the orphan Dec (discarded evidence listed in `status`) |
| Val pointer/report bound to a differing SHA | L-row projection ignoring the orphan Val (safe tombstone) |
| Val pointer exists but the canonical report is missing | no safe candidate — refusal only (the pointer names evidence that cannot be inspected) |
| evidence sets disagree on `review_head` | projection keyed on `review.tsv`'s `review_head`, discarded evidence listed |
| L1/L2/L3 with missing or unparseable canonical validation report | no safe candidate — refusal only |
| verdict unparseable / RESULT illegal / `review.tsv` itself unreadable | no safe candidate — refusal only |
| orphan evidence with no `R` | no safe candidate — refusal only |

`repair-state` (T14) is intent-first; the full protocol lives in the T14
matrix row below.

| T14 | `repair-state` | legacy conflict (status-printed candidate), corrupted state file (candidate bound to the corrupted-file digest), or valid-v1 state with conflicting evidence | token re-computed and matched under the lock; candidate satisfies the invariants | repair intent first — atomic write of `<run_dir>/.repair.intent` carrying: the ORIGINAL STATE baseline encoded as `absent` | `valid:<digest>:<revision>` | `corrupt:<raw-digest>` (a corrupted file whose revision cannot be trusted is identified by its raw digest), the original evidence baseline digest, the token, the `--reason`, the materialized target values (concrete `waiting_since`/`last_transition_at`/target state digest), the audit-copy target (if a corrupt file), and the complete tombstone move map → audit-copy the corrupt file if any → tombstone orphan evidence per the move map → write v1 state (state_revision=1 for a first file or after a corrupt-file replacement, otherwise current+1; checkpoint_round=0 when recovering to `intake` with no evidence — NEVER legacy `unknown`); dynamic fields from placeholders → remove the intent last | retry-from-intent semantics, three states: (a) state equals the ORIGINAL baseline → a crash landed before the commit; continue the tombstone/commit sequence; (b) state equals the target digest → remove the intent and finish (zero-write completion); (c) anything else → FAIL CLOSED (never re-derive or bump `current+1`). A crash at ANY point after the intent (including every tombstone boundary and the state-committed/intent-left shape) re-executes from the intent, never from the stale token |

The valid-v1 evidence-conflict source covers a state file that parses
but contradicts the evidence, restricted to cases where the evidence
clearly leads or directly contradicts non-terminal flow fields AND the
residue precheck has already run: owning-command sameness recovery
(submit retry, T6r, L-T3/L-T6, validate re-execution) always takes
precedence, and T14 accepts only the genuine conflicts no owning
command can recover — verdict
empty while a decision archive exists, `validation_result`/`digest`
disagreeing with the canonical report, or `checkpoint_sha` disagreeing
with `review.tsv`. Its candidate is the status-printed projection
re-derived from the evidence (same candidate rules as legacy conflicts),
the target delta is `state_revision=current+1`, and discarded orphan
evidence follows the same tombstone move map. Dynamic-field rule for
this source: `waiting_since` is PRESERVED when the candidate's
responsible party and reason equal the current state's; otherwise it
materializes as `@now`. TERMINAL states (`completed`, `canceled`) are
never candidates: a terminal run whose state contradicts evidence is
refused (fail closed, no candidate) — evidence projection can never
resurrect a finished run.

Corrupted-state policy: a state file with a missing/non-positive
`state_revision`, a future `schema_version`, duplicate/missing/unknown
keys, invalid enums, or illegal combinations fails closed (exit 2).
Recovery is a CONTROLLED replacement with no authority gap: under the
lock, first copy the corrupted file to `run-state.tsv.corrupt.<timestamp>`
(audit copy), then atomically replace the state file (mktemp+mv) with a
fresh v1 projection — the authoritative path is never empty. The
replacement is driven by a repair candidate whose token is bound to the
CORRUPTED file's digest, so only the projection `status` derived for
that exact file content is accepted. A future schema version has no
recovery path: the operator must upgrade Arena (downgrade is rejected).

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
  `waiting_since` preserved on revalidate, op-token protocol (FIRST-lock
  pending-archive refusal exit 5 — gate never runs; triple baseline
  revision+SHA+archive-absence; token-named temporaries written outside
  the lock; CAS publish; dead-owner-only cleanup), validate exempt from
  digest-conflict, safe/convergent re-execution recovery, archive-COPY +
  atomic canonical replace (no truncated .rN), integrity failure
  no-transition + diagnostic-only report path, CAS stale result, exit 0
  vs 10 vs 3 vs 5 precedence
- decision matrix incl. APPROVE-without-PASS rejection, archive metadata
  (`State revision` + `Validation digest`) re-checked in T6r, the validate
  CAS baseline including the archive digest-or-absence (a pending archive
  forces validate to exit 5 — cross-crash validate/decision interleaving
  fixture), normal (no archive) vs T6r commit-only retry, archive →
  decision.md → state publication order, conflict and duplicate rejection,
  residue ownership (owning+matching recovers; owning+mismatching exits 2;
  foreign exits 5), legacy first migrations L-T3 (inherited T3 guards) and
  L-T6 (`State revision: 0` baseline encoding, decision.md completed
  first, ALL T6/T7/T8 current-state guards re-checked incl.
  writer-head-drift rejection)
- escalate idempotence, illegal escalate from other human states, legacy
  first-migration escalate
- every resolve action's exact post-state, terminal `party=none` + empty
  `waiting_since`, recover refused on unreachable pane + two-step
  prerequisite output, recover refused on formal BLOCKED, legacy
  first-migration resolve, resume respawn of a dead reviewer pane
- fault injection at "evidence written, state not committed" for
  submit/validate/decision + retry recognition via sameness tuples +
  `incomplete transition` status reporting
- legacy projection rows L1–L6 incl. decision precedence, L1–L3
  mandatory matching parseable report (L1 additionally RESULT=PASS;
  missing = conflict), report-without-pointer as validate-owned residue
  (exit 5, no repair candidate), each conflict condition, sticky round,
  lock-internal projection (no TOCTOU),
  conflict→candidate table rows (placeholder payload @reason/@revision/
  @now; orphan evidence tombstoned under `orphaned/`; candidate accepted
  when fresh, stale rejected, foreign rejected, refusal-only conflicts),
  repair intent protocol (intent written before any tombstone; crash at
  EVERY multi-file tombstone boundary and the state-committed/intent-left
  shape re-executes from the intent, not the stale token; three-state
  recovery: original baseline → continue, target → zero-write cleanup,
  other → fail closed; only FOREIGN commands exit 5, the owner recovers;
  baseline encodings absent/valid:<digest>:<revision>/corrupt:<raw-digest>),
  valid-v1 evidence-conflict as a T14 source, corrupted-state controlled
  replacement (audit copy inside T14, atomic replace, token bound to
  corrupted-file digest, no authority gap), future-schema refusal, resume
  never migrates legacy, resume respawn inside the lock
- interrupted-start intent stages S1–S6 (S1/S2/S5/S6 auto-recovery;
  S3/S4 manual abort protocol output incl. worktree-registry/branch
  cleanup steps), intent derived-input binding (mismatched retry fails
  closed) vs legacy discrimination, start/resume double-session-creation
  race (both under the shared run lock)
- corrupted v1 file, future schema, duplicate/missing/unknown keys,
  invalid enums, illegal field combinations (per the layered invariants),
  symlinked state file
- lock liveness: live lock, dead PID, owner-token mismatch, partial
  metadata write (temp residue = absent), mkdir-window grace, cross-process
  concurrency, CAS publish, parent-directory creation lock
- output-and-exit-code protocol rows 0–5 and 10; per-scenario status
  lines (terminal, missing session, dead pane, conflict candidates,
  creation-intent stages S1–S6 before state read); `list` fixed row
  contract (REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY
  REASON_CODE WAITING_SINCE AUTHORITY ANOMALY, composite-key sort);
  aggregation priority 5 > 4 > 2 > 0
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
legacy evidence equivalent). Partial tombstone residue (some orphan files moved, intent present) is
recovered by the owning `repair-state` replaying the intent's move map
(idempotent renames); a pending repair intent with a live owner reports
lock code 4, without one reports exit 5. Recovery from a bad v0.4 rollout
therefore means stopping new transitions and keeping v0.4 read-only
interpretation available — never deleting the authoritative state file,
which would let finished runs "resurrect" in the legacy projection.
