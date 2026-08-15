---
status: planned
created: '2026-08-15'
owner: 'local owner'
---

# Agent Arena v0.5: Autopilot approval modes (human/auto)

## Summary and scope

v0.4 established one authoritative answer to "who is next, waiting on what, since
when, and how is it released" (`run-state.tsv`, T1–T14, run locks, legacy
projection, status/list oracles). The review loop (writer submits → reviewer
validates → decides) is fully automatable, but two design stops keep a run from
completing unattended: an APPROVE decision parks in `decided/human/
approval_pending` until a human runs `resolve --action approve`, and stalled
states (blocked, unreachable panes, writer idleness) need a human operator.

v0.5 adds an **approval-mode switch** (`human` | `auto`) and an **autopilot
orchestrator** that, in `auto` mode, performs the approval step and turns every
stalled path into an observable alert. In `human` mode (default) behavior is
unchanged except for richer alerting. **The v0.4 state machine, command
semantics, and wire contract are not modified**; autopilot is an ordinary caller
of `resolve`/`escalate`/`status` and keeps its own observation files.

**Capability promise (normative):** in `auto` mode, a run whose reviewer records
`APPROVE` with `validation_result=PASS` reaches `completed` unattended; every
other non-terminal state is either observed silently or reported with a
non-zero exit code (stop-and-alarm). Autopilot never self-heals: it does not
merge, push, cancel, reject, or silently restart model panes.

In scope: approval-mode config and run-level switching; `autopilot` command
(`--once` and `--watch`); pane-liveness × state two-dimensional scanning;
autopilot exit-code protocol; heartbeat and action logs; relay throttling;
approve-delay cooling window; repo whitelist; the lock-reclamation fix that
autopilot concurrency requires. Out of scope (v0.6 or later): extending the
`list` row contract with a MODE column; per-run approval policy overrides
(profile/repo/round-based); gate trust-prompt pre-authorization
(automatic `resume` remains opt-in and best-effort); append-only journal;
post-completed delivery hooks.

## Walkthrough round 1: user stories and acceptance criteria

The v0.5 design was reviewed by five expert roles (security, state-machine,
SRE, product, QA) in a three-round whiteboard walkthrough with cross-debate;
full findings and rulings are in
`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/00-findings-summary.md`.

User stories:

- **US1 (human, default):** operator runs `start`; every approval needs an
  explicit human `resolve --action approve`. `autopilot --watch` only observes
  and alerts (a run parked in `approval_pending` or `blocked` exits 6 in
  `--once` mode so cron can page the operator).
- **US2 (auto, unattended):** operator configures `approval_mode=auto` (or
  `start --mode auto`), starts `autopilot --watch`, and leaves. An APPROVE+PASS
  run completes by itself after the cooling window; stalled runs page via exit 6.
- **US3 (handover):** operator switches a running run between modes with
  `agent-arena mode RUN_ID human|auto` (locked, audited); config changes alone
  never change a live run (drift shows as a warning, not a silent switch).
- **US4 (stall visibility):** a dead reviewer/writer pane or a long-stalled
  state is reported (escalate or exit 6), never silently ignored.

### Acceptance criteria (v05-AC)

- **v05-AC1** `approval_mode` parses from `project.conf` (`human` default, strict
  parser, invalid values die with the legal-value list); `start` snapshots it
  into the run manifest (`mode` + `mode_updated_at`); legacy manifests without
  the field read as `human`.
- **v05-AC2** `agent-arena mode RUN_ID human|auto` switches a live run under the
  run lock, records the switch (actor + timestamp), and `status` shows
  `Mode: <mode>` plus `(config: <mode>) ⚠` when the manifest and project.conf
  disagree.
- **v05-AC3** `mode` is part of the T1r creation-intent derived inputs: an
  interrupted `start` retried after an `approval_mode` change fails closed
  (exit 2), like the existing parameter-drift rules.
- **v05-AC4** `autopilot --once` in auto mode approves a run parked in
  `decided/human/approval_pending` with `verdict=APPROVE` and
  `validation_result=PASS`, but only after `--approve-delay` seconds since the
  decision; the resulting state records `last_transition_actor=system`,
  `last_transition_action=resolve-approve`, and `reason_detail` carrying the
  autopilot instance token; repeated scans are idempotent (already-`completed`
  is a benign race, logged not counted).
- **v05-AC5** `autopilot --once` in human mode performs zero state mutations
  and still exits 6 when a run needs a human (approval_pending, blocked,
  corrupt/conflict/incomplete).
- **v05-AC6** autopilot is single-instance per state root: a second instance
  exits 4 with the owner pid; the lock liveness check requires `pid alive AND
  last_seen fresh (< 3×interval)`, and reclamation is atomic
  (rename-to-tombstone) with a two-claimer fixture test.
- **v05-AC7** scanning uses the `status` oracle per run (exit codes 0/2/4/5)
  as the only read path; live lock (4) is deferred (skip this round, no
  counting); legacy runs and interrupted-start intent stages are skipped.
- **v05-AC8** pane-liveness × state matrix: reviewer pane dead in
  `submitted`/`validated` (auto mode) auto-escalates via T9
  (`reviewer_unreachable`); writer pane dead in `changes_requested`/
  `human_changes_requested` alerts (exit 6); stalled states (waiting longer
  than per-state defaults) alert (exit 6).
- **v05-AC9** relay reminders are throttled per run per reason
  (`last_relay_at`, default `--relay-after 30` minutes) and carry an
  `[autopilot]` prefix; repeats within the window are logged as
  `skipped (throttled)`.
- **v05-AC10** `cancel`/`reject` are never issued by autopilot;
  `block_resolution_required` always exits 6; `--resume-attempts` defaults to 0
  and, when enabled, each spawn is recorded as `unconfirmed` and still exits 6
  until the blocked state clears.
- **v05-AC11** v0.4 regression keeps zero semantic drift: the 50 sections pass
  with an explicit assertion-update list (config parser accepts
  `approval_mode`; `status` gains a `Mode:` line; manifest gains mode rows), and
  new hermetic sections 50–53 cover v05-AC1–AC10.

## Walkthrough round 2: contracts

### Mode configuration contract

`project.conf` (strict parser, unknown lines die):

```text
project_name="..."
validation_script=".agent-arena/validate.sh"
approval_mode=human|auto     # init writes `human` with a risk comment
```

Run manifest gains two rows written by `start` (and updated only by
`agent-arena mode` under the run lock, atomic mktemp+mv):

```text
mode    human|auto
mode_updated_at    <epoch>
```

`agent-arena mode RUN_ID human|auto`:
- requires the run lock (exit 4 while held by a live owner);
- refuses on terminal runs (`completed`/`canceled`, exit 2);
- rewrites `mode` and `mode_updated_at`, prints the new mode;
- appends one line to `autopilot.log` (`mode` action) so human switches are
  auditable alongside autopilot actions.

Drift display: `status` prints `Mode: <manifest mode>` and, when the manifest
mode differs from the current `project.conf` `approval_mode`,
`Mode: <manifest mode> (config: <config mode>) ⚠`. The manifest snapshot is
authoritative for autopilot; config changes affect only new runs.

### resolve audit pass-through

`agent-arena resolve RUN_ID --action approve [--actor human|system] [--reason "..."]`:
- `--actor` defaults to `human` (v0.4 behavior); autopilot passes `system`
  (already a legal `last_transition_actor` value — zero wire-contract change);
- `--reason` on approve is preserved into `reason_detail` when provided
  (today's approve branch clears it; human approve without `--reason` stays
  empty);
- action stays `resolve-approve` (already a legal
  `last_transition_action` value).

### autopilot command surface

```text
agent-arena autopilot [--once] [--interval SECONDS=30] [--approve-delay SECONDS=300]
                       [--relay-after MINUTES=30] [--resume-attempts N=0]
                       [--repo PATH] [--all-repos] [--state-root PATH]
```

- `--watch` (default) loops forever; `--once` runs one scan and exits.
- Scope: `--repo PATH` (default: the repository of the current directory) or
  `--all-repos` (explicit, logged). Runs outside the scope are never touched.
- A per-state-root autopilot lock (`.autopilot-lock` in the state root, owner
  metadata + `last_seen_at` refreshed after every scan) serializes instances.

### Action matrix (state × mode × pane liveness)

| State (authoritative) | pane | human mode | auto mode |
|---|---|---|---|
| decided/human/approval_pending, APPROVE+PASS | any | alert (exit 6) | after `--approve-delay`: resolve approve (actor=system) |
| decided/human/approval_pending, other | any | alert | alert (guard mismatch = error) |
| blocked/human/block_resolution_required | any | alert | alert, never act |
| blocked/human/reviewer_unreachable | dead | alert | alert; if `--resume-attempts>0` and attempts remain: resume (result=unconfirmed), still exit 6 |
| submitted/reviewer/review_pending | **dead** | alert | escalate (T9) then alert; if already escalated → alert |
| validated/reviewer/decision_pending | **dead** | alert | escalate (T9) then alert |
| submitted/reviewer/review_pending | live | observe | observe |
| validated/reviewer/decision_pending | live | observe | observe |
| active/writer/changes_requested | live, idle > relay-after | relay reminder (throttled) | relay reminder (throttled) |
| active/writer/changes_requested | **dead** | alert | alert |
| active/writer/human_changes_requested | (same as changes_requested) | — | — |
| intake / decided/writer / other active | any | observe | observe |
| completed / canceled | any | skip | skip |
| corrupt / conflict / incomplete (status 2/5) | — | error (exit 6) | error (exit 6) |
| live lock (status 4) | — | defer | defer |

Every unlisted state defaults to observe (zero side effects).

### autopilot exit-code protocol (command-level; distinct from the v0.4 run-level protocol)

| Code | Meaning |
|---|---|
| 0 | scan complete, no action needed |
| 4 | autopilot lock busy (another instance) — normal when watch+cron coexist |
| 5 | incomplete/residue encountered |
| 6 | at least one run needs a human (approval_pending, blocked, stall, corrupt/conflict) |

Aggregation priority `6 > 5 > 4 > 0` (mirrors the `list` model). Benign races
(state moved / lock momentarily busy / residue skipped) are logged with a
`benign-race`/`deferred` result and never enter the aggregate code.

`--once` prints a per-run TSV summary to stdout (same schema as the action log:
`run_id mode state action result`) for cron consumption.

### Lock protocol (Task 0 fix)

`arena_lock_acquire` dead-owner reclamation becomes atomic: rename the lock
directory to a tombstone (`mv <lock> <lock>.reap.<token>`) — exactly one
claimer wins the rename — then rebuild; a failed rebuild exits 4 (retry), never
continues. Owner metadata may carry `last_seen_at`; autopilot liveness is
`pid alive AND last_seen fresh (< 3×interval)`. All v0.4 lock semantics
(60s metadata-less grace, dead-PID recovery, token-matched release) are
preserved.

### Observation files (never authoritative)

- `autopilot.tsv`: one row per instance (`instance=host:pid:nonce`,
  `last_scan_at`, `scanned`, `acted`, `errors`, `last_seen_at`, `scope`).
  Watch and cron instances each own a row; staleness is per row.
- `autopilot.log`: append-only TSV `timestamp run_id mode state action result`
  with result in `acted|deferred|benign-race|needs-human|error|skipped-throttled|unconfirmed`.
- Both files are best-effort observation; the audit chain remains
  `run-state.tsv` + SHA-bound decision/validation archives. Every autopilot
  action carries `--reason "autopilot <instance> <scan-ts>"` so log rows,
  heartbeat rows, and state records correlate three ways.

### Key path traces

- **Auto approval:** `watch`/`--once` → per-run `status` (exit 0, state
  decided/human/approval_pending, APPROVE+PASS) → check `--approve-delay`
  elapsed since `last_transition_at` → `resolve RUN_ID --action approve
  --actor system --reason "autopilot <instance> <ts>"` under the run lock →
  state `completed`, actor=system, reason_detail set → log row (acted) →
  heartbeat refresh.
- **Pane dead (auto):** `status` diagnosis shows reviewer pane unreachable in
  submitted/validated → `escalate RUN_ID --reason-code reviewer_unreachable
  --reason "autopilot <instance>"` (T9 legal) → state blocked →
  next round: alert (exit 6); optional resume attempts recorded `unconfirmed`.
- **Relay reminder:** changes_requested older than `--relay-after` and no
  `last_relay_at` in the window → `relay RUN_ID --to writer
  --message "[autopilot] ..."` (`--from` stays at the default `human`; the
  v0.4 from-enum is unchanged and the `[autopilot]` prefix identifies the
  real sender) → record `last_relay_at` in autopilot observation → repeats
  throttled.

## Walkthrough round 3: errors and edge cases

- Live lock during scan or action: defer (skip round, no counting, no alert).
- Benign races (another process completed the run first; state moved between
  read and act): guard rejects with 2 — logged `benign-race`, not an error.
- Watch crashed (SIGKILL): lock owner pid dead or `last_seen` stale →
  next instance reclaims atomically (Task 0 fix); PID reuse cannot pin the
  lock forever.
- Clock jumps / laptop sleep: staleness and timeout checks tolerate jitter
  (interval comparisons, never exact deltas); wake-up may fire timeouts once —
  throttles bound the blast radius; documented accepted risk.
- Crash between resolve commit and log append: state is authoritative; the log
  row may be missing — correlation via `reason` instance token.
- watch + cron `--once` coexist: `--once` exits 4 (normal); README documents
  the deployment matrix (watch for attended, cron `--once` for unattended;
  avoid both).
- `--resume-attempts>0`: spawn result recorded `unconfirmed`; blocked state
  stays until a human confirms the trust prompt; exit 6 persists.
- Terminal runs, legacy runs, intent stages (S1–S6), and runs outside the
  scope are never touched.

## Testing strategy (hermetic only)

Extends `tests/run.sh` with sections 50–53 (fake CLIs, temporary Git repos,
private tmux sockets; no model/network):

- §50 mode config/switch/drift/intent binding (v05-AC1/AC2/AC3, §38-style
  manifest assertions; strict parser keeps rejecting unknown lines).
- §51 autopilot `--once` auto approval (v05-AC4): end-to-end APPROVE+PASS →
  `completed`; asserts actor=system, action=resolve-approve, reason_detail
  token; approve-delay enforced; idempotent rescan (benign race logged).
- §52 human mode + alerting (v05-AC5/AC10): zero mutations; exit 6 on
  approval_pending/blocked; cancel/reject never issued; resume-attempts
  unconfirmed path.
- §53 lock/heartbeat/throttle (v05-AC6/AC8/AC9): two-claimer reclamation
  fixture; last_seen staleness; pane-dead escalate; relay throttle window;
  exit-code aggregation priority 6>5>4>0.

v0.4 sections 1–49 keep zero semantic drift; the assertion-update list
(config parser + `Mode:` line + manifest rows) is recorded in the plan.

## Drift, risk, and rollback

**Drift from v0.4:** no wire-contract or T-matrix change. `resolve` gains an
optional `--actor` (default `human`) and preserves `--reason` on approve —
both values (`system`, `resolve-approve`) already exist in the v0.4 enum.
`project.conf` gains `approval_mode`; manifests gain `mode`/`mode_updated_at`
(unknown rows were already tolerated in manifests; state-file 16-key contract
is untouched). `status` gains one `Mode:` line (existing assertions are
grep-based; the plan lists the updated assertions). `lib/lock.sh` reclamation
becomes atomic — behavior-compatible for all existing tests.

**Trust-model note (normative):** auto mode removes the only non-AI approval
step from the audit chain. This is an explicit trust-model downgrade, bounded
by: opt-in config + run-level `start --mode auto`; approve guard requires
APPROVE+PASS; `--approve-delay` cooling window; every action recorded with an
instance-token reason; cancel/reject/BLOCKED never automatic; and the v0.4
baseline that same-UID processes could already run `resolve` by hand. Auto
mode is documented as suitable for repos with strict validation scripts and
low risk.

**Non-promise table (normative):** autopilot does not deliver code (no
merge/push; `completed` is an Arena state, not a delivery), does not wake
writers (relay reminders are best-effort), does not bypass trust prompts, and
does not self-heal panes by default.

**Risk:** unattended stalls (writer unresponsive, pane dead, BLOCKED) are
reported, not fixed — MTBF of full autonomy is bounded by model-pane
liveness. A misconfigured `approval_mode=auto` in a risky repo auto-approves
validated checkpoints; mitigations above.

**Rollback:** uninstall autopilot (`autopilot` command absent or unused) and
set `approval_mode=human` — v0.5-written states remain readable by v0.4
(actor/action values stay in the v0.4 enums). The lock fix is
behavior-compatible; no state migration is needed.
