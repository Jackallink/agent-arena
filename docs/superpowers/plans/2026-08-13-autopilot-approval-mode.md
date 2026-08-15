# Autopilot Approval Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the v0.5 human/auto approval modes: `approval_mode` config +
run-level `mode` switching, the `autopilot` orchestrator (`--once`/`--watch`),
pane-liveness × state scanning, autopilot exit-code protocol (0/4/5/6),
heartbeat/action observation files, relay throttling, approve-delay cooling,
repo whitelist, and the lock-reclamation fix autopilot concurrency requires.

**Architecture:** No v0.4 wire-contract or T-matrix change. `lib/autopilot.sh`
drives the existing commands (`status` as read oracle, `resolve`/`escalate`/
`relay`/`resume` as actions) and owns observation files. `lib/config.sh` gains
`approval_mode`; `lib/start.sh` snapshots `mode` into the manifest and binds it
into the creation intent; a thin `mode` command (in `lib/arena.sh` dispatch +
a small `lib/mode.sh`) switches live runs under the run lock; `lib/resolve.sh`
gains `--actor` and reason preservation; `lib/lock.sh` reclamation becomes
atomic. Hermetic tests extend `tests/run.sh` (§50–53).

**Tech Stack:** Bash 3.2/macOS + Linux compatible; existing `lib/` conventions;
`tests/run.sh` fake-CLI harness.

## Global Constraints

- Bash compatible with macOS Bash 3.2 and Linux Bash; `set -euo pipefail`;
  four-space indentation; snake_case functions; quoted expansions; no `eval`.
- Hermetic tests only: fake CLIs, temporary Git repos, private tmux sockets;
  never a model or network call.
- Spec: `docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md` — all
  field names, flags, exit codes, the action matrix, and the observation-file
  schemas come verbatim from it.
- v0.4 compatibility: zero semantic drift in the state machine; actor/action
  values stay inside the v0.4 enums (`system`, `resolve-approve`); state-file
  16-key contract untouched; v0.4.0 can read v0.5-written states.
- Design rulings from the multi-expert walkthrough are binding
  (`00-findings-summary.md`): exit 6 (never 2) for "needs human"; actor=system
  (never a new enum); list row contract unchanged; resume default 0;
  observation files never authoritative.

## File Structure

- Create `lib/autopilot.sh` — scan loop, state×pane matrix, actions, exit-code
  aggregation, heartbeat/action log writers, relay throttle state, autopilot
  lock (with `last_seen_at` refresh).
- Create `lib/mode.sh` — `mode RUN_ID human|auto` parser + locked manifest
  rewrite + drift display helper.
- Modify `lib/lock.sh` — atomic rename-to-tombstone reclamation; optional
  `last_seen_at` owner metadata.
- Modify `lib/config.sh` — `approval_mode` parse/validate; `lib/start.sh` —
  manifest `mode`/`mode_updated_at` rows + creation-intent binding;
  `lib/status.sh` — `Mode:` line + drift marker; `lib/resolve.sh` — `--actor`
  + approve reason preservation; `lib/arena.sh` — dispatch `autopilot` and
  `mode`.
- Test `tests/run.sh` — §50–53.

---

### Task 0: Atomic lock reclamation (lib/lock.sh)

**Files:** Modify `lib/lock.sh`; Test `tests/run.sh` (§39 stays green + new §50 preamble fixture or §53 fixture).

**Interfaces:** `arena_lock_acquire LOCK_PATH TOKEN` — dead-owner branch becomes
`mv`-to-tombstone (only one claimer wins) then rebuild; failed rebuild exits 4
(retry), never continues. Behavior-compatible for all existing tests.

- [ ] **Step 1: Write the failing test** (two concurrent reclaimers)

```bash
printf '%s\n' '50. lock reclamation: two claimers, exactly one wins'
lock_root="${tmp_root}/reap-locks"
mkdir -p "$lock_root"
mkdir -p "$lock_root/one"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"$lock_root/one/owner"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" claim-a
    # simulate the loser: its mkdir after a lost race must fail, not corrupt
    if arena_lock_acquire "$2" claim-b 2>/dev/null; then exit 9; fi
    arena_lock_is_held "$2" || exit 10
' _ "$source_root" "$lock_root/one" || fail 'reclamation race not safe'
```

- [ ] **Step 2: Run it to verify it fails** (today `rm -rf`+`mkdir` lets both claimers "win").
- [ ] **Step 3: Implement atomic reclamation**

```bash
# in arena_lock_acquire, dead-owner branch:
tombstone="${lock_path}.reap.$$"
if mv "$lock_path" "$tombstone" 2>/dev/null; then
    rm -rf "$tombstone"
    mkdir "$lock_path" 2>/dev/null || arena_die "cannot acquire lock: $lock_path"
else
    arena_die "transition in progress (lock reclamation raced): $lock_path"
fi
```

- [ ] **Step 4: Run tests** — §39 and all earlier sections green; the new fixture green.
- [ ] **Step 5: Commit** — `git add lib/lock.sh tests/run.sh` → `fix: atomic dead-owner lock reclamation for autopilot concurrency`.

---

### Task 1: approval_mode config, manifest snapshot, mode command, drift, intent binding

**Files:** Modify `lib/config.sh`, `lib/start.sh`, `lib/status.sh`, `lib/arena.sh`; Create `lib/mode.sh`; Test `tests/run.sh` (§50).

**Interfaces:** `arena_config_approval_mode CONFIG` (prints `human`|`auto`, dies on invalid);
`arena_mode_set RUN_DIR MODE` (under run lock, atomic manifest rewrite);
`arena_mode_drift RUN_DIR` (compares manifest vs config for the `⚠` marker).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '50. approval mode config, switch, drift, and intent binding'
# init writes approval_mode=human
run_arena init --repo "$project" >/dev/null
require_match 'approval_mode=human' "${project}/.agent-arena/project.conf"
# start snapshots mode into the manifest
run_arena start mode-run --repo "$project" --no-attach >/dev/null
mode_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -name manifest.tsv -path '*/mode-run/manifest.tsv' -exec dirname {} \;)"
require_match $'mode\thuman' <(cat "${mode_dir}/manifest.tsv")
# switch to auto under the lock, then status shows Mode + no drift
run_arena mode mode-run auto >/dev/null
require_match $'mode\tauto' <(cat "${mode_dir}/manifest.tsv")
run_arena status mode-run >"${tmp_root}/mode-status.out"
require_match 'Mode: auto' "${tmp_root}/mode-status.out"
# drift: config changes to auto while manifest is human -> warning marker
printf 'approval_mode=auto\n' >>"${project}/.agent-arena/project.conf"
run_arena status mode-run >"${tmp_root}/mode-drift.out"
require_match 'Mode: human (config: auto) ⚠' "${tmp_root}/mode-drift.out"
# intent binding: interrupted start retried after mode change fails closed
# (fixture: write a creation intent with mode=human, change config, retry -> exit 2)
```

- [ ] **Step 2: Run it to verify it fails** — `approval_mode` unknown to the strict parser; no manifest rows; no `mode` command.
- [ ] **Step 3: Implement** — config parser key + validation; start snapshot + intent parameter (`mode=${ARENA_CONFIG_APPROVAL_MODE}`) + retry comparison; `lib/mode.sh` (parse, run-lock, atomic manifest rewrite, `mode_updated_at`, autopilot.log `mode` row); status `Mode:` line + drift marker; arena dispatch.
- [ ] **Step 4: Run tests** — §50 green; §0–49 green (assertion-update list: config parser now accepts the new key; status gains a line — all existing assertions are grep-based and unaffected).
- [ ] **Step 5: Commit** — `feat: approval_mode config, manifest snapshot, mode switching, and drift display`.

---

### Task 2: resolve audit pass-through (--actor, approve reason)

**Files:** Modify `lib/resolve.sh`; Test `tests/run.sh` (§51 preamble).

**Interfaces:** `resolve RUN_ID --action approve [--actor human|system] [--reason "..."]` —
actor defaults to `human`; approve preserves `--reason` into `reason_detail` when given.

- [ ] **Step 1: Write the failing test** (in §51 setup: run to approval_pending, then)

```bash
run_arena resolve "$dec_run" --action approve --actor system --reason 'autopilot smoke-token' >/dev/null
require_match $'last_transition_actor\tsystem' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'reason_detail\tautopilot smoke-token' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'last_transition_action\tresolve-approve' <(cat "${dec_run_dir}/run-state.tsv")
# default stays human
run_arena resolve "$dec2_run" --action approve >/dev/null
require_match $'last_transition_actor\thuman' <(cat "${dec2_run_dir}/run-state.tsv")
```

- [ ] **Step 2: Run it to verify it fails** — `--actor` unknown; approve clears reason_detail.
- [ ] **Step 3: Implement** — parse `--actor` (validate `human|system`); approve branch: write `reason_detail="$reason"` when non-empty (else clear, v0.4 behavior); set `ARENA_STATE_LAST_TRANSITION_ACTOR` from the flag.
- [ ] **Step 4: Run tests** — new assertions green; §0–49 green.
- [ ] **Step 5: Commit** — `feat: resolve --actor and approve reason preservation for autopilot audit`.

---

### Task 3: autopilot core (scan, matrix, exit 6, whitelist, approve-delay)

**Files:** Create `lib/autopilot.sh`; Modify `lib/arena.sh`; Test `tests/run.sh` (§51 auto approve, §52 human/alert).

**Interfaces:** `arena_autopilot_run ONCE SCOPE ...`; helpers `arena_autopilot_scan_run RUN_DIR`,
`arena_autopilot_act RUN_DIR` (returns `acted|deferred|benign-race|needs-human|error`),
`arena_autopilot_aggregate` (6>5>4>0); per-run `status` is the only read path.

- [ ] **Step 1: Write the failing test** (§51: full loop)

```bash
printf '%s\n' '51. autopilot auto approval and exit-code protocol'
# run through submit/validate/decision APPROVE (existing helpers), then:
run_arena autopilot --once --state-root "$state_base" --repo "$project" >"${tmp_root}/ap-once.out"
require_match $'run_status\tcompleted' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'last_transition_actor\tsystem' <(cat "${ap_run_dir}/run-state.tsv")
# approve-delay: a fresh decision is NOT approved immediately
# (fixture with --approve-delay 3600 -> state stays approval_pending, exit 6)
# idempotence: second --once exits 0 with a benign-race log row
# human mode: no mutation, exit 6 on approval_pending
```

- [ ] **Step 2: Run it to verify it fails** — no `autopilot` command.
- [ ] **Step 3: Implement** — parse flags; autopilot lock (owner + `last_seen_at`);
  scope resolution (`--repo` default cwd, `--all-repos`); per-run `status` read
  (map exit codes 0/2/4/5 → state parse / error / defer / incomplete); action
  matrix dispatch (approve with delay check; escalate on reviewer-pane dead;
  alerts); exit-code aggregation; per-run TSV stdout summary; `--once` vs
  `--watch` loop.
- [ ] **Step 4: Run tests** — §51/§52 green; §0–50 green.
- [ ] **Step 5: Commit** — `feat: autopilot scan loop with state×pane matrix and exit 6`.

---

### Task 4: Observation files, relay throttle, lock liveness

**Files:** Modify `lib/autopilot.sh` (already created); Test `tests/run.sh` (§53).

**Interfaces:** `arena_autopilot_heartbeat_write` (per-instance row),
`arena_autopilot_log ACTION RESULT`, `arena_autopilot_relay_throttled RUN_DIR`
(`last_relay_at` observation, `--relay-after` default 30).

- [ ] **Step 1: Write the failing test** (§53)

```bash
printf '%s\n' '53. autopilot heartbeat, relay throttle, and two-claimer lock'
# heartbeat: autopilot.tsv has one row per instance with last_seen_at
# relay throttle: changes_requested run older than relay-after gets ONE reminder
#   per window (fake tmux records pane keys; second --once within the window logs skipped-throttled)
# last_seen staleness: lock with dead pid but fresh last_seen -> live; stale -> reclaimed
```

- [ ] **Step 2: Run it to verify it fails**.
- [ ] **Step 3: Implement** — heartbeat/log writers (per-instance rows, result
  classification); throttle state file under the state root
  (`autopilot-throttle.tsv`: `run_id reason last_relay_at`); lock
  `last_seen_at` refresh after every scan; staleness check in acquire for
  autopilot locks (`pid alive AND last_seen fresh`), gated to autopilot locks
  so v0.4 lock semantics are untouched.
- [ ] **Step 4: Run tests** — §53 green; §0–52 green.
- [ ] **Step 5: Commit** — `feat: autopilot heartbeat, action log, and relay throttling`.

---

### Task 5: Docs, regression sweep, and review-ready

**Files:** Modify `README.md` (autopilot section + non-promise table + deployment matrix),
`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md` (frontmatter → `review-ready` +
assertion-update list), `RELEASE-NOTES.md` (v0.5.0 draft); Test: full suites.

- [ ] **Step 1: Full regression**

```bash
bash tests/run.sh && bash tests/tmuxp-smoke.sh && bash tests/cli-contract-smoke.sh   && bash packaging/package.sh --check && bash -n lib/*.sh adapters/*.sh
```

Expected: §0–53 green; the plan records the assertion-update list (config
parser, `Mode:` line, manifest rows) per v05-AC11.

- [ ] **Step 2: Document** — README "Autopilot" section (flags, deployment
  matrix, non-promise table, trust-model note); spec frontmatter →
  `review-ready` with the drift note (zero wire-contract change; `--actor`,
  mode rows, lock fix).
- [ ] **Step 3: Commit** — `docs: autopilot usage, non-promise table, and review-ready status`.

---

## Self-review

- **Spec coverage:** v05-AC1/2/3 → Task 1; v05-AC4 → Tasks 2/3; v05-AC5 → Task 3;
  v05-AC6 → Tasks 0/4; v05-AC7/8 → Task 3; v05-AC9 → Task 4; v05-AC10 → Task 3;
  v05-AC11 → Task 5. Walkthrough rulings (exit 6, actor=system, no list column,
  resume 0, observation files never authoritative, atomic reclamation) all
  mapped to Tasks 0–5. ✅
- **Placeholder scan:** no stubs — every Task's Step 3 references the spec
  contract directly; Task 3's matrix is the spec's action matrix verbatim.
- **Type consistency:** `arena_config_approval_mode`, `arena_mode_set`,
  `arena_autopilot_*`, `arena_autopilot_log/Heartbeat` names consistent across
  tasks; exit codes 0/4/5/6 (autopilot) and 0/1/2/3/4/5/10 (v0.4) never overlap
  in meaning.
