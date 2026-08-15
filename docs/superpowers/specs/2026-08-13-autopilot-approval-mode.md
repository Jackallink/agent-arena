---
status: review-ready
created: '2026-08-15'
owner: 'local owner'
drift: implementation matches the contracts in this spec (mode config/switch, status read-path extension, resolve/escalate --actor, autopilot matrix and exit codes 0/4/6, observation files). The v0.4 state machine and wire contract are unchanged; the assertion-update list (config parser, Mode:/Verdict:/Validation result:/Last transition at:/pane lines, manifest mode rows, lock reclamation) is recorded in the plan.
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

**Read-path contract (normative):** autopilot's only read path per run is the
`status` oracle (v05-AC7). To carry the data the action matrix needs, `status`
output is extended with four lines (all additive; existing grep-based
assertions are unaffected): `Verdict: APPROVE|CHANGES_REQUESTED|BLOCKED` (or
`not recorded`), `Validation result: PASS|FAIL` (or `not run`),
`Last transition at: <epoch>` (the approve-delay anchor), and a writer-pane
liveness line (`writer pane: unreachable;` when the writer pane is dead or the
tmux session is gone — symmetric with the existing reviewer line).

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
  parser, invalid values die with the legal-value list); `start --mode auto`
  overrides it per run (flag precedence > config, validated against the same
  enum); `start` snapshots the effective mode into the run manifest (`mode` +
  `mode_updated_at`); legacy manifests without the field read as `human`.
- **v05-AC2** `agent-arena mode RUN_ID human|auto` switches a live run under the
  run lock and records the switch in the manifest (`mode_actor` +
  `mode_updated_at` rows, atomic mktemp+mv); terminal runs are refused (exit
  2); `status` shows `Mode: <mode>` plus `(config: <mode>) ⚠` when the
  manifest and project.conf disagree. A missing/unreadable project.conf
  never dies `status`: the drift marker is simply omitted.
- **v05-AC3** `mode` is part of the T1r creation-intent derived inputs: an
  interrupted `start` retried after an `approval_mode` change fails closed
  (exit 2), like the existing parameter-drift rules.
- **v05-AC4** `autopilot --once` in auto mode approves a run parked in
  `decided/human/approval_pending` with `verdict=APPROVE` and
  `validation_result=PASS` (both read from the extended `status` output), but
  only after `--approve-delay` seconds since `Last transition at` (the
  decision time); while inside the cooling window the run is **observed, not
  alerted** (contributes exit 0); the resulting state records
  `last_transition_actor=system`, `last_transition_action=resolve-approve`,
  and `reason_detail` carrying the autopilot instance token; repeated scans
  are idempotent (already-`completed` is a benign race, logged not counted).
- **v05-AC5** `autopilot --once` in human mode performs zero state mutations
  and still exits 6 when a run needs a human (approval_pending, blocked,
  corrupt/conflict/incomplete).
- **v05-AC6** autopilot is single-instance per state root: a second instance
  exits 4 with the owner pid; the lock liveness check requires `pid alive AND
  last_seen fresh (< 3×interval)`, and reclamation is atomic
  (rename-to-tombstone) with a two-claimer fixture test.
- **v05-AC7** scanning uses the `status` oracle per run as the only read path,
  with this exit-code mapping: `0` parse the extended output; `2` corrupt /
  legacy conflict → error (exit 6); `4` live lock → defer (skip this round,
  no counting); `5` incomplete → creation-intent stages (S1–S6) and legacy
  residue are skipped silently, repair-intent residue and other incomplete
  states are errors (exit 6); `1` (unexpected) → error (exit 6). `status`
  never returns 3 or 10.
- **v05-AC8** pane-liveness × state matrix (below) with three pane states:
  live / dead / session-down (no tmux session). Reviewer pane dead or
  session-down in `submitted`/`validated` (auto mode) auto-escalates via T9
  (`reviewer_unreachable`); writer pane dead or session-down in
  `changes_requested`/`human_changes_requested` alerts (exit 6); a `blocked`
  run alerts regardless of pane state. Stall detection: a run waiting longer
  than the per-state threshold below alerts (exit 6).
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

`project.conf` (strict parser, unknown lines die; `approval_mode` is a bare
`key=value` line like the existing keys):

```text
project_name="..."
validation_script=".agent-arena/validate.sh"
approval_mode=human|auto     # init writes `human` with a risk comment
```

Run manifest gains three rows written by `start` (and updated only by
`agent-arena mode` under the run lock, atomic mktemp+mv). Because
`arena_read_manifest` fails closed on unknown keys, `lib/common.sh`'s reader
and writer are extended in the same change (v05-AC11 assertion-update list):

```text
mode    human|auto
mode_actor    system|human|<adapter>   # start → system; mode command → human or the CLI actor
mode_updated_at    <epoch>
```

`start --mode auto` sets the effective mode for the run (precedence over
`project.conf`), is validated against the same enum, and is bound into the
creation intent like every other derived input (v05-AC3).

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

### resolve/escalate audit pass-through

`agent-arena resolve RUN_ID --action approve [--actor human|system] [--reason "..."]`:
- `--actor` defaults to `human` (v0.4 behavior); autopilot passes `system`
  (already a legal `last_transition_actor` value — zero wire-contract change);
- `--reason` on approve is preserved into `reason_detail` when provided
  (today's approve branch clears it; human approve without `--reason` stays
  empty);
- action stays `resolve-approve` (already a legal
  `last_transition_action` value).

`agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..." [--actor human|system]`:
- same `--actor` semantics; today `escalate.sh` hard-codes
  `last_transition_actor='human'` on both paths, so autopilot's automatic T9
  escalation would be recorded as a human action — the flag fixes that
  (actor=system for autopilot; default remains human).

### autopilot command surface

```text
agent-arena autopilot [--once] [--interval SECONDS=30] [--approve-delay SECONDS=300]
                       [--relay-after MINUTES=30] [--resume-attempts N=0]
                       [--repo PATH] [--all-repos] [--rounds N] [--state-root PATH]
```

- `--watch` (default) loops forever; `--once` runs one scan and exits;
  `--rounds N` runs N scans then exits (hermetic-test hook for the watch loop;
  N=1 behaves like `--once`).
- Scope: `--repo PATH` (default: the repository of the current directory) or
  `--all-repos` (explicit, logged). Runs outside the scope are never touched.
  `--repo` accepts either a repository path or a repo id.
- `--watch` prints one summary line per round to stdout (`<ts> scanned=<n>
  acted=<n> needs-human=<n> errors=<n>`); `--once` prints the per-run TSV rows
  plus the same summary line.
- A per-state-root autopilot lock (`.autopilot-lock` in the state root, owner
  metadata + `last_seen_at` refreshed after every scan) serializes instances.
  `last_seen_at` liveness applies only to the autopilot lock; v0.4 lock
  semantics are untouched.

### Action matrix (state × mode × pane liveness × stall)

Pane states: `live` (role pane present, not dead, input on), `dead` (pane dead
or missing), `down` (no tmux session at all). Stall = waiting longer than the
per-state threshold; the clock is `waiting_since` from the extended `status`
output. Thresholds are pinned defaults (not configurable in v0.5):

| State (authoritative) | pane | stalled | human mode | auto mode |
|---|---|---|---|---|
| decided/human/approval_pending, APPROVE+PASS | any | inside `--approve-delay` | observe (exit 0) | observe (exit 0) |
| decided/human/approval_pending, APPROVE+PASS | any | after `--approve-delay` | alert (exit 6) | resolve approve (actor=system), log acted |
| decided/human/approval_pending, other guard | any | any | alert | alert (guard mismatch = error) |
| blocked/human/block_resolution_required | any | any | alert | alert, never act |
| blocked/human/reviewer_unreachable | any | any | alert | alert; if `--resume-attempts>0` and attempts remain: resume (result=unconfirmed), still exit 6 |
| submitted/reviewer/review_pending | **dead/down** | — | alert | escalate (T9, actor=system), then alert |
| validated/reviewer/decision_pending | **dead/down** | — | alert | escalate (T9, actor=system), then alert |
| submitted/reviewer/review_pending | live | ≤ 30 min | observe | observe |
| submitted/reviewer/review_pending | live | > 30 min | alert | alert |
| validated/reviewer/decision_pending | live | ≤ 30 min | observe | observe |
| validated/reviewer/decision_pending | live | > 30 min | alert | alert |
| active/writer/changes_requested | live | ≤ `--relay-after` | observe | observe |
| active/writer/changes_requested | live | > `--relay-after` | relay reminder (throttled) | relay reminder (throttled) |
| active/writer/changes_requested | **dead/down** | any | alert | alert |
| active/writer/human_changes_requested | (same rows as changes_requested) | — | — | — |
| active/decided/writer/* | any | any | observe | observe |
| active/intake or other active | any | any | observe | observe |
| completed / canceled | any | — | skip | skip |
| corrupt / conflict (status 2) | — | — | error (exit 6) | error (exit 6) |
| incomplete (status 5: repair intent / other) | — | — | error (exit 6) | error (exit 6) |
| creation-intent stages S1–S6 / legacy residue (status 5) | — | — | skip (zero side effects) | skip (zero side effects) |
| live lock (status 4) | — | — | defer | defer |

Every unlisted state defaults to observe (zero side effects).

### autopilot exit-code protocol (command-level; distinct from the v0.4 run-level protocol)

| Code | Meaning |
|---|---|
| 0 | scan complete, no action needed (all runs observed, completed, or inside a cooling window) |
| 4 | autopilot lock busy (another instance) — normal when watch+cron coexist |
| 6 | at least one run needs a human or has an anomaly (approval_pending outside the cooling window, blocked, stall, pane-dead, corrupt/conflict/incomplete) |

Aggregation priority `6 > 4 > 0`. Benign races (state moved / lock
momentarily busy / intent stages / legacy residue skipped / already
completed) are logged with a `benign-race`/`deferred` result and never enter
the aggregate code. There is deliberately **no exit 5** in the autopilot
protocol: v0.4's exit 5 semantics (incomplete transition) are consumed inside
the per-run mapping above.

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
  Watch and cron instances each own a row; staleness is per row; the file
  keeps only the most recent row per instance (a crashed instance's row is
  overwritten on its next scan — observation only).
- `autopilot.log`: append-only TSV `timestamp run_id mode state action result`
  with result in `acted|deferred|benign-race|needs-human|error|skipped-throttled|unconfirmed`.
  Rotated at 1 MB (`.1`, `.2`, keep 3) — rotation never blocks a scan.
- `autopilot-throttle.tsv` (relay throttle + resume counters): one row per run
  per reason: `run_id reason last_relay_at resume_attempts`.
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
  avoid both). US2's "start `autopilot --watch` and leave" is replaced by the
  cron `--once` deployment in unattended scenarios.
- `--resume-attempts>0`: spawn result recorded `unconfirmed`; blocked state
  stays until a human confirms the trust prompt; exit 6 persists.
- Terminal runs, legacy runs, intent stages (S1–S6), and runs outside the
  scope are never touched.

## Testing strategy (hermetic only)

Extends `tests/run.sh` with sections 50–55 (fake CLIs, temporary Git repos,
private tmux sockets; no model/network):

- §50 mode config/switch/drift/intent binding (v05-AC1/AC2/AC3, §38-style
  manifest assertions; strict parser keeps rejecting unknown lines; manifest
  reader accepts the new rows; `start --mode auto` precedence; `mode` command
  lock/terminal refusals).
- §51 autopilot `--once` auto approval (v05-AC4): end-to-end APPROVE+PASS →
  `completed`; asserts actor=system, action=resolve-approve, reason_detail
  token; approve-delay enforced (window = observe/exit 0; after = act);
  idempotent rescan (benign race logged).
- §52 human mode + alerting (v05-AC5/AC10): zero mutations; exit 6 on
  approval_pending/blocked; cancel/reject never issued; resume-attempts
  unconfirmed path; stall thresholds (backdated `waiting_since` → exit 6);
  pane-dead rows (fake tmux `reviewer-dead`/`dead`/no-session shapes);
  status exit-code mapping incl. exit 1 → error and S1–S6 skip.
- §53 lock/heartbeat/throttle (v05-AC6/AC8/AC9): two-claimer reclamation with
  genuinely concurrent claimers (backgrounded subshells + wait); last_seen
  staleness (dead pid + fresh last_seen = live; stale = reclaimed); relay
  throttle window (fake tmux send-keys count); exit-code aggregation priority
  6>4>0; `--rounds 2` watch-loop termination; log rotation boundary.

v0.4 sections 1–49 keep zero semantic drift; the assertion-update list
(config parser + `Mode:` line + manifest rows) is recorded in the plan.

## Drift, risk, and rollback

**Drift from v0.4:** no wire-contract or T-matrix change. `resolve` and
`escalate` gain an optional `--actor` (default `human`) and `resolve` preserves
`--reason` on approve — all values (`system`, `resolve-approve`) already exist
in the v0.4 enums. `project.conf` gains `approval_mode`; manifests gain
`mode`/`mode_actor`/`mode_updated_at` — because `arena_read_manifest` fails
closed on unknown keys, `lib/common.sh`'s reader/writer are extended in the
same change (the state-file 16-key contract is untouched; v0.4.0 binaries
cannot read v0.5 manifests — rollback means keeping the v0.5 binary and
disabling autopilot, not downgrading the binary). `status` gains `Mode:`,
`Verdict:`, `Validation result:`, `Last transition at:`, and writer-pane
lines (additive; existing assertions are grep-based; the plan lists the
updated assertions). `lib/lock.sh` reclamation becomes atomic —
behavior-compatible for all existing tests.

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
