# Run State Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the v0.4 run-state authority: `run-state.tsv` as the single source of truth for responsible party and waiting state, the full transition matrix (T1–T14 + L-T3/L-T6), `escalate`/`resolve`/`repair-state` commands, run locks, legacy projection, and the status/list oracles.

**Architecture:** Three new focused libraries — `lib/state.sh` (wire contract, field invariants, legacy projection, transition dispatcher), `lib/lock.sh` (mkdir locks with atomic metadata, grace, owner tokens), and intent handling inside `lib/state.sh` (creation + repair intents, stage tables, three-state recovery). Existing commands (start/submit/validate/decision/status/list/resume) call the state layer; three new command files (escalate/resolve/repair-state) are thin parsers over the shared transition function. Hermetic tests extend `tests/run.sh`.

**Tech Stack:** Bash 3.2/macOS + Linux compatible; existing `lib/` conventions; `tests/run.sh` fake-CLI harness.

## Global Constraints

- Bash compatible with macOS Bash 3.2 and Linux Bash; `set -euo pipefail`; four-space indentation; snake_case functions; quoted expansions; no `eval`.
- Hermetic tests only: fake CLIs, temporary Git repos, private tmux sockets; never a model or network call.
- Spec: `docs/superpowers/specs/2026-08-13-run-state-authority.md` — all field names, enums, exit codes (0/1/2/3/4/5/10), transition rows, and protocol rules come verbatim from it.
- Legacy compatibility: runs without `run-state.tsv` and without a creation intent project read-only (L1–L6); first transitions migrate inside the run lock; no state write from reads.
- The v0.3 regression suite passes with one adapted assertion (integrity-failure reports move to `.diagnostic.md`).

## File Structure

- Create: `lib/state.sh` — wire contract read/write/validate, legal-combination invariants, legacy projection (precheck + L1–L6 + conflicts + repair candidates), creation/repair intent read/write, stage table S1–S6, shared transition dispatcher.
- Create: `lib/lock.sh` — `arena_lock_acquire PATH TOKEN` / `arena_lock_release PATH TOKEN` / `arena_lock_is_held PATH`; mkdir lock + `owner` metadata (PID, token, created_at, atomic temp+mv) + grace rule + stale-PID check.
- Create: `lib/escalate.sh`, `lib/resolve.sh`, `lib/repair-state.sh` — thin parsers over the shared transition function.
- Modify: `lib/start.sh` (creation intent, T1/T1r stages, lock ordering), `lib/submit.sh` (T2/T3/T4/L-T3, state commit), `lib/validate.sh` (T5 op-token/CAS, exit 10, diagnostic path), `lib/decision.sh` (T6–T8/T6r/L-T6, archive metadata), `lib/status.sh`, `lib/list.sh` (priority checks, oracles), `lib/resume` path in `lib/start.sh` (creation-intent refusal, in-lock respawn), `lib/arena.sh` (dispatch new commands), `lib/pane.sh` (resume respawn path uses the manifest gate adapter as today).
- Test: `tests/run.sh` (sections 38+, adapted diagnostic assertion).

---

### Task 1: State wire contract and field invariants (lib/state.sh core)

**Files:** Create `lib/state.sh`; Test `tests/run.sh` (section 38).

**Interfaces:** Produces `arena_state_read RUN_DIR` (sets `ARENA_STATE_*` per field), `arena_state_write RUN_DIR FIELD_KEY=VALUE...` (mktemp+mv, mode 600), `arena_state_validate RUN_DIR` (invariants; die on corruption), `arena_state_keys` order list.

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '38. state wire contract and field invariants'
state_fixture_dir="${tmp_root}/state-fixture"
mkdir -p "$state_fixture_dir"
ARENA_STATE_ROOT="$state_fixture_dir" run_arena start state-wire --repo "$project" --no-attach >/dev/null
state_run_dir="$(find "${state_fixture_dir}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path '*/state-wire/manifest.tsv' -exec dirname {} \;)"
state_file="${state_run_dir}/run-state.tsv"
[[ -f "$state_file" ]] || fail 'start did not write run-state.tsv'
require_match $'schema_version\t1' <(cat "$state_file")
require_match $'state_revision\t1' <(cat "$state_file")
require_match $'run_status\tactive' <(cat "$state_file")
require_match $'phase\tintake' <(cat "$state_file")
require_match $'responsible_party\twriter' <(cat "$state_file")
require_match $'reason_code\tnone' <(cat "$state_file")
require_match $'checkpoint_round\t0' <(cat "$state_file")
for illegal in 'responsible_party\tbogus' 'phase\tsubmitted' 'state_revision\tzero'; do :; done
# corruption fails closed: verdict empty allowed, illegal combination rejected
bad_state="${tmp_root}/bad-state.tsv"
sed 's/\tactive$/\tcompleted/' "$state_file" >"$bad_state"   # completed with intake phase = illegal
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_validate "$2"
' _ "$source_root" "$state_fixture_dir" 2>/dev/null && fail 'illegal combination accepted' || true
```

(Note: the invalid-combination fixture must be exercised through the real read path — a run whose state file is hand-edited to `completed/intake` must make `status` exit 2.)

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 38 — `start` does not yet write `run-state.tsv`.

- [ ] **Step 3: Implement the wire contract**

`lib/state.sh` core (full content):

```bash
#!/usr/bin/env bash
set -euo pipefail

state_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${state_dir}/common.sh"

ARENA_STATE_KEYS='schema_version state_revision run_status phase responsible_party reason_code reason_detail verdict validation_result checkpoint_round checkpoint_sha waiting_since last_transition_at last_transition_actor last_transition_action validation_digest'

arena_state_defaults() {
    ARENA_STATE_SCHEMA_VERSION='1'
    ARENA_STATE_REVISION='1'
    ARENA_STATE_RUN_STATUS='active'
    ARENA_STATE_PHASE='intake'
    ARENA_STATE_RESPONSIBLE_PARTY='writer'
    ARENA_STATE_REASON_CODE='none'
    ARENA_STATE_REASON_DETAIL=''
    ARENA_STATE_VERDICT=''
    ARENA_STATE_VALIDATION_RESULT=''
    ARENA_STATE_CHECKPOINT_ROUND='0'
    ARENA_STATE_CHECKPOINT_SHA=''
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR='system'
    ARENA_STATE_LAST_TRANSITION_ACTION='start'
    ARENA_STATE_VALIDATION_DIGEST=''
}

arena_state_read() {
    local run_dir="$1"
    local manifest="${run_dir}/run-state.tsv"
    local key value seen=''

    [[ -f "$manifest" ]] || arena_die "missing state file: $manifest"
    arena_state_defaults
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || arena_die "corrupted state file: empty key in $manifest"
        case " $seen " in *" $key "*) arena_die "corrupted state file: duplicate key $key in $manifest" ;; esac
        seen="$seen $key"
        case " $ARENA_STATE_KEYS " in *" $key "*) ;; *) arena_die "corrupted state file: unknown key $key in $manifest" ;; esac
        case "$key" in
            schema_version) ARENA_STATE_SCHEMA_VERSION="$value" ;;
            state_revision) ARENA_STATE_REVISION="$value" ;;
            run_status) ARENA_STATE_RUN_STATUS="$value" ;;
            phase) ARENA_STATE_PHASE="$value" ;;
            responsible_party) ARENA_STATE_RESPONSIBLE_PARTY="$value" ;;
            reason_code) ARENA_STATE_REASON_CODE="$value" ;;
            reason_detail) ARENA_STATE_REASON_DETAIL="$value" ;;
            verdict) ARENA_STATE_VERDICT="$value" ;;
            validation_result) ARENA_STATE_VALIDATION_RESULT="$value" ;;
            checkpoint_round) ARENA_STATE_CHECKPOINT_ROUND="$value" ;;
            checkpoint_sha) ARENA_STATE_CHECKPOINT_SHA="$value" ;;
            waiting_since) ARENA_STATE_WAITING_SINCE="$value" ;;
            last_transition_at) ARENA_STATE_LAST_TRANSITION_AT="$value" ;;
            last_transition_actor) ARENA_STATE_LAST_TRANSITION_ACTOR="$value" ;;
            last_transition_action) ARENA_STATE_LAST_TRANSITION_ACTION="$value" ;;
            validation_digest) ARENA_STATE_VALIDATION_DIGEST="$value" ;;
        esac
    done <"$manifest"
    for key in $ARENA_STATE_KEYS; do
        case " $seen " in *" $key "*) ;; *) arena_die "corrupted state file: missing key $key in $manifest" ;; esac
    done
    arena_state_validate "$run_dir"
}

arena_state_validate() {
    local run_dir="$1"

    [[ "$ARENA_STATE_SCHEMA_VERSION" == 1 ]] || {
        [[ "$ARENA_STATE_SCHEMA_VERSION" =~ ^[0-9]+$ ]] && arena_die 'state file uses a future schema version; upgrade Agent Arena'
        arena_die "corrupted state file: invalid schema_version"
    }
    [[ "$ARENA_STATE_REVISION" =~ ^[1-9][0-9]*$ ]] || arena_die 'corrupted state file: invalid state_revision'
    case "$ARENA_STATE_RUN_STATUS" in active|blocked|completed|canceled) ;; *) arena_die 'corrupted state file: invalid run_status' ;; esac
    case "$ARENA_STATE_PHASE" in intake|submitted|validated|decided) ;; *) arena_die 'corrupted state file: invalid phase' ;; esac
    case "$ARENA_STATE_RESPONSIBLE_PARTY" in writer|reviewer|human|none) ;; *) arena_die 'corrupted state file: invalid responsible_party' ;; esac
    case "$ARENA_STATE_REASON_CODE" in none|review_pending|decision_pending|approval_pending|changes_requested|human_changes_requested|reviewer_unreachable|block_resolution_required) ;; *) arena_die 'corrupted state file: invalid reason_code' ;; esac
    case "$ARENA_STATE_VERDICT" in ''|APPROVE|CHANGES_REQUESTED|BLOCKED) ;; *) arena_die 'corrupted state file: invalid verdict' ;; esac
    case "$ARENA_STATE_VALIDATION_RESULT" in ''|PASS|FAIL) ;; *) arena_die 'corrupted state file: invalid validation_result' ;; esac
    [[ "$ARENA_STATE_CHECKPOINT_ROUND" == unknown || "$ARENA_STATE_CHECKPOINT_ROUND" =~ ^[0-9]+$ ]] || arena_die 'corrupted state file: invalid checkpoint_round'
    [[ "$ARENA_STATE_CHECKPOINT_SHA" == '' || "$ARENA_STATE_CHECKPOINT_SHA" =~ ^[0-9a-f]{40}$ ]] || arena_die 'corrupted state file: invalid checkpoint_sha'
    [[ "$ARENA_STATE_VALIDATION_DIGEST" == '' || "$ARENA_STATE_VALIDATION_DIGEST" =~ ^[0-9a-f]{64}$ ]] || arena_die 'corrupted state file: invalid validation_digest'
    [[ "$ARENA_STATE_WAITING_SINCE" == '' || "$ARENA_STATE_WAITING_SINCE" == unknown || "$ARENA_STATE_WAITING_SINCE" =~ ^[0-9]+$ ]] || arena_die 'corrupted state file: invalid waiting_since'
    [[ "$ARENA_STATE_LAST_TRANSITION_AT" =~ ^[0-9]+$ ]] || arena_die 'corrupted state file: invalid last_transition_at'
    case "$ARENA_STATE_LAST_TRANSITION_ACTOR" in writer|reviewer|human|system) ;; *) arena_die 'corrupted state file: invalid last_transition_actor' ;; esac
    [[ "$ARENA_STATE_REASON_DETAIL" == '' || ! "$ARENA_STATE_REASON_DETAIL" =~ [[:cntrl:]] && "${#ARENA_STATE_REASON_DETAIL}" -le 256 ]] || arena_die 'corrupted state file: invalid reason_detail'

    # Legal-combination invariants (spec: layered by run_status)
    case "$ARENA_STATE_RUN_STATUS" in
        active)
            case "$ARENA_STATE_PHASE" in
                intake)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer && "$ARENA_STATE_REASON_CODE" == none && \
                        -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && \
                        -z "$ARENA_STATE_VALIDATION_DIGEST" && -z "$ARENA_STATE_CHECKPOINT_SHA" && \
                        "$ARENA_STATE_CHECKPOINT_ROUND" == 0 && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_die 'corrupted state file: illegal intake combination'
                    ;;
                submitted)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == review_pending && \
                        -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && \
                        -z "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" && \
                        "$ARENA_STATE_CHECKPOINT_ROUND" != 0 && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_die 'corrupted state file: illegal submitted combination'
                    ;;
                validated)
                    [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == decision_pending && \
                        -z "$ARENA_STATE_VERDICT" && -n "$ARENA_STATE_VALIDATION_RESULT" && \
                        -n "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_die 'corrupted state file: illegal validated combination'
                    ;;
                decided)
                    [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_DIGEST" && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                        arena_die 'corrupted state file: illegal decided combination'
                    case "$ARENA_STATE_RESPONSIBLE_PARTY:$ARENA_STATE_REASON_CODE" in
                        human:approval_pending)
                            [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                                arena_die 'corrupted state file: approval_pending requires APPROVE and PASS'
                            ;;
                        writer:changes_requested)
                            [[ "$ARENA_STATE_VERDICT" == CHANGES_REQUESTED && -n "$ARENA_STATE_VALIDATION_RESULT" ]] || \
                                arena_die 'corrupted state file: changes_requested requires CHANGES_REQUESTED and a validation result'
                            ;;
                        writer:human_changes_requested)
                            { [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                                { [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" ]]; }; } || \
                                arena_die 'corrupted state file: illegal human_changes_requested combination'
                            ;;
                        *) arena_die 'corrupted state file: illegal decided combination' ;;
                    esac
                    ;;
            esac
            ;;
        blocked)
            [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == human && -n "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_die 'corrupted state file: illegal blocked combination'
            case "$ARENA_STATE_REASON_CODE:$ARENA_STATE_PHASE" in
                reviewer_unreachable:submitted|reviewer_unreachable:validated|block_resolution_required:decided) ;;
                *) arena_die 'corrupted state file: illegal blocked combination' ;;
            esac
            if [[ "$ARENA_STATE_REASON_CODE" == block_resolution_required ]]; then
                [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" && \
                    -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_DIGEST" ]] || \
                    arena_die 'corrupted state file: illegal block_resolution_required combination'
            fi
            ;;
        completed)
            [[ "$ARENA_STATE_PHASE" == decided && "$ARENA_STATE_RESPONSIBLE_PARTY" == none && \
                "$ARENA_STATE_REASON_CODE" == none && "$ARENA_STATE_VERDICT" == APPROVE && \
                "$ARENA_STATE_VALIDATION_RESULT" == PASS && -n "$ARENA_STATE_VALIDATION_DIGEST" && \
                -n "$ARENA_STATE_CHECKPOINT_SHA" && -z "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_die 'corrupted state file: illegal completed combination'
            ;;
        canceled)
            [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == none && "$ARENA_STATE_REASON_CODE" == none && -z "$ARENA_STATE_WAITING_SINCE" ]] || \
                arena_die 'corrupted state file: illegal canceled combination'
            case "$ARENA_STATE_PHASE" in
                submitted) [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -z "$ARENA_STATE_VERDICT" && -z "$ARENA_STATE_VALIDATION_RESULT" && -z "$ARENA_STATE_VALIDATION_DIGEST" ]] || arena_die 'corrupted state file: illegal canceled/submitted combination' ;;
                validated) [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -n "$ARENA_STATE_VALIDATION_RESULT" && -n "$ARENA_STATE_VALIDATION_DIGEST" && -z "$ARENA_STATE_VERDICT" ]] || arena_die 'corrupted state file: illegal canceled/validated combination' ;;
                decided)
                    { [[ "$ARENA_STATE_VERDICT" == APPROVE && "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || \
                        { [[ "$ARENA_STATE_VERDICT" == BLOCKED && -n "$ARENA_STATE_VALIDATION_RESULT" ]]; }; } || \
                        arena_die 'corrupted state file: illegal canceled/decided combination'
                    ;;
                *) arena_die 'corrupted state file: illegal canceled phase' ;;
            esac
            ;;
    esac
    if [[ -n "$ARENA_STATE_WAITING_SINCE" && "$ARENA_STATE_WAITING_SINCE" != unknown ]]; then
        [[ "$ARENA_STATE_WAITING_SINCE" -le "$ARENA_STATE_LAST_TRANSITION_AT" ]] || \
            arena_die 'corrupted state file: waiting_since after last_transition_at'
    fi
}

arena_state_write() {
    local run_dir="$1"
    local tmp_file value
    shift
    tmp_file="$(mktemp "${run_dir}/.run-state.XXXXXX")"
    for key in $ARENA_STATE_KEYS; do
        value=''
        for arg in "$@"; do
            if [[ "$arg" == "${key}="* ]]; then
                value="${arg#*=}"
                break
            fi
        done
        printf '%s\t%s\n' "$key" "$value"
    done >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/run-state.tsv"
}
```

- [ ] **Step 4: Wire start to write the initial state**

In `lib/start.sh`, after `arena_write_manifest`, add:

```bash
    ARENA_STATE_ROOT_INHERIT=1 source "${source_root}/lib/state.sh" 2>/dev/null || true
    arena_state_defaults
    arena_state_write "$run_dir"
```

(Exact integration lands in Task 4 with the creation intent; this step only proves the wire contract through the test fixture.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 38 green; sections 1–37 green.

- [ ] **Step 6: Commit**

```bash
git add lib/state.sh lib/start.sh tests/run.sh
git commit -m "feat: state wire contract and field invariants"
```

---

### Task 2: Run lock with atomic metadata and grace (lib/lock.sh)

**Files:** Create `lib/lock.sh`; Test `tests/run.sh` (section 39).

**Interfaces:** `arena_lock_acquire LOCK_PATH TOKEN` (mkdir; write `owner` metadata atomically: PID, token, created_at; die on contention with a live owner; grace rules), `arena_lock_release LOCK_PATH TOKEN` (verify token match, then remove), `arena_lock_is_held LOCK_PATH` (exit 0/1; prints metadata when held).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '39. run lock acquire, owner token, grace, and stale PID'
lock_root="${tmp_root}/locks"
mkdir -p "$lock_root"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-a
    arena_lock_acquire "$2" token-b && exit 9 || exit 0
' _ "$source_root" "$lock_root/one" || fail 'second acquire on a live lock did not fail'
# token mismatch release
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-a
    arena_lock_release "$2" token-wrong && exit 9 || exit 0
' _ "$source_root" "$lock_root/two" || fail 'release with a wrong token succeeded'
# metadata-less stale lock (grace): mtime older than 60s
mkdir -p "$lock_root/three"
touch -t 200001010000 "$lock_root/three"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-c
' _ "$source_root" "$lock_root/three" || fail 'stale metadata-less lock was not recoverable'
# metadata-less fresh lock (< 60s) is live
mkdir -p "$lock_root/four"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-d && exit 9 || exit 0
' _ "$source_root" "$lock_root/four" || fail 'fresh metadata-less lock was treated as stale'
# dead-PID lock is recoverable
mkdir -p "$lock_root/five"
printf 'pid=999999999\ntoken=dead\ncreated_at=1\n' >"$lock_root/five/owner"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-e
' _ "$source_root" "$lock_root/five" || fail 'dead-PID lock was not recoverable'
# metadata temp residue equals absent metadata
mkdir -p "$lock_root/six"
printf 'partial' >"$lock_root/six/owner.tmp.123"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/lock.sh"
    arena_lock_acquire "$2" token-f
' _ "$source_root" "$lock_root/six" || fail 'owner temp residue blocked acquisition'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 39 — `lib/lock.sh` does not exist.

- [ ] **Step 3: Implement lib/lock.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

lock_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${lock_dir}/common.sh"

arena_lock_is_held() {
    local lock_path="$1"
    [[ -d "$lock_path" ]] || return 1
    [[ -f "${lock_path}/owner" ]] || return 1
    return 0
}

arena_lock_owner_token() {
    awk -F= '$1 == "token" { print $2 }' "$1/owner"
}

arena_lock_owner_pid() {
    awk -F= '$1 == "pid" { print $2 }' "$1/owner"
}

arena_lock_owner_alive() {
    local pid
    pid="$(arena_lock_owner_pid "$1")" || return 1
    kill -0 "$pid" 2>/dev/null
}

arena_lock_acquire() {
    local lock_path="$1"
    local token="$2"
    local owner_tmp grace_cutoff pid

    [[ -n "$token" ]] || arena_die 'lock token must not be empty'
    if ! mkdir "$lock_path" 2>/dev/null; then
        if arena_lock_is_held "$lock_path"; then
            if arena_lock_owner_alive "$lock_path"; then
                arena_die "transition in progress (lock held by pid $(arena_lock_owner_pid "$lock_path"))"
            fi
            rm -rf "$lock_path"
            mkdir "$lock_path" 2>/dev/null || arena_die "cannot acquire lock: $lock_path"
        else
            # metadata-less window: grace rule
            grace_cutoff="$(($(date +%s) - 60))"
            if [[ "$(stat -f '%m' "$lock_path" 2>/dev/null || stat -c '%Y' "$lock_path" 2>/dev/null)" -lt "$grace_cutoff" ]]; then
                rm -rf "$lock_path"
                mkdir "$lock_path" 2>/dev/null || arena_die "cannot acquire lock: $lock_path"
            else
                arena_die "transition in progress (lock without metadata): $lock_path"
            fi
        fi
    fi
    owner_tmp="${lock_path}/owner.tmp.$$"
    {
        printf 'pid=%s\n' "$$"
        printf 'token=%s\n' "$token"
        printf 'created_at=%s\n' "$(date +%s)"
    } >"$owner_tmp"
    mv "$owner_tmp" "${lock_path}/owner"
}

arena_lock_release() {
    local lock_path="$1"
    local token="$2"

    if ! arena_lock_is_held "$lock_path"; then
        rm -rf "$lock_path"
        return 0
    fi
    [[ "$(arena_lock_owner_token "$lock_path")" == "$token" ]] || \
        arena_die 'lock release requires the owner token'
    rm -rf "$lock_path"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 39 green; all earlier sections green.

- [ ] **Step 5: Commit**

```bash
git add lib/lock.sh tests/run.sh
git commit -m "feat: run lock with atomic metadata, owner tokens, and grace rules"
```

---

### Task 3: Legacy projection engine (precheck + L1–L6 + conflicts + candidates)

**Files:** Modify `lib/state.sh`; Test `tests/run.sh` (section 40).

**Interfaces:** `arena_state_project_legacy RUN_DIR` — sets `ARENA_PROJECTED_*` (phase/party/reason/verdict/VR/VD/CS/round, display label, conflict list) without writing; exits 2 with the conflict list when the projection is refused; runs the precheck first.

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '40. legacy projection rows, precheck, and conflicts'
legacy_proj_dir="${tmp_root}/legacy-proj"
mkdir -p "$legacy_proj_dir"
cat >"${legacy_proj_dir}/manifest.tsv" <<EOF
run_id	legacy-run
repository	$project
base_sha	$(git -C "$project" rev-parse HEAD)
writer_worktree	$project
branch	agent-arena/pi/legacy-run
session_name	agent-arena-legacy-run
tool_root	$source_root
worktree_root	$worktree_base
project_config	$project/.agent-arena/project.conf
profile	pi-cursor
writer_adapter	pi
writer_label	Pi
writer_session_dir	${legacy_proj_dir}/writer-session
gate_adapter	cursor
EOF
sha_40='0123456789abcdef0123456789abcdef01234567'
# L6: no evidence → intake projection
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == intake && "$ARENA_PROJECTED_PARTY" == writer && "$ARENA_PROJECTED_ROUND" == unknown ]] || exit 9
' _ "$source_root" "$legacy_proj_dir" || fail 'L6 projection wrong'
# L5: review.tsv only → submitted
printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
    "$sha_40" "$project" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')" >"${legacy_proj_dir}/review.tsv"
ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
    [[ "$ARENA_PROJECTED_PHASE" == submitted && "$ARENA_PROJECTED_PARTY" == reviewer && "$ARENA_PROJECTED_CS" == "'"$sha_40"'" ]] || exit 9
' _ "$source_root" "$legacy_proj_dir" || fail 'L5 projection wrong'
# conflict: decision archive bound to a different SHA
mkdir -p "${legacy_proj_dir}"
printf 'Review HEAD: %s\nVERDICT: APPROVE\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"${legacy_proj_dir}/decision-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md"
if ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2"
' _ "$source_root" "$legacy_proj_dir" >"${tmp_root}/proj-conflict.out" 2>&1; then
    fail 'conflicting decision archive projected successfully'
fi
require_match 'conflict' "${tmp_root}/proj-conflict.out"
# report-only with R + parseable + bound report = validate residue, not conflict
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 40 — `arena_state_project_legacy` missing.

- [ ] **Step 3: Implement the projection**

In `lib/state.sh`:

```bash
arena_state_projection_clear() {
    ARENA_PROJECTED_PHASE=''; ARENA_PROJECTED_PARTY=''; ARENA_PROJECTED_REASON=''
    ARENA_PROJECTED_VERDICT=''; ARENA_PROJECTED_VR=''; ARENA_PROJECTED_VD=''
    ARENA_PROJECTED_CS=''; ARENA_PROJECTED_ROUND='unknown'; ARENA_PROJECTED_LABEL='legacy'
    ARENA_PROJECTED_CONFLICTS=''
}

arena_state_project_legacy() {
    local run_dir="$1"
    local review_head dec_file dec_sha verdict vr vd report_file sha_suffix
    local conflicts='' saw=''

    arena_state_projection_clear
    [[ -f "${run_dir}/review.tsv" ]] || {
        # L6 requires no orphan evidence
        local orphans
        orphans="$(find "$run_dir" -maxdepth 1 \( -name 'decision-*.md' -o -name 'validation-*.md' \) -print -quit 2>/dev/null || true)"
        if [[ -n "$orphans" ]]; then
            ARENA_PROJECTED_CONFLICTS='orphan evidence with no review.tsv'
            return 2
        fi
        ARENA_PROJECTED_PHASE='intake'; ARENA_PROJECTED_PARTY='writer'; ARENA_PROJECTED_REASON='none'
        return 0
    }
    review_head="$(awk -F $'\t' '$1 == "review_head" { print $2; exit }' "${run_dir}/review.tsv")"
    [[ "$review_head" =~ ^[0-9a-f]{40}$ ]] || { ARENA_PROJECTED_CONFLICTS='review.tsv review_head unreadable'; return 2; }
    ARENA_PROJECTED_CS="$review_head"
    # Decision archives bound by evidence SHA
    dec_file=''
    for candidate in "${run_dir}"/decision-*.md; do
        [[ -f "$candidate" ]] || continue
        [[ "$(head -1 "$candidate")" =~ ^Review\ HEAD:\ ([0-9a-f]{40})$ ]] || continue
        dec_sha="${BASH_REMATCH[1]}"
        if [[ "$dec_sha" == "$review_head" ]]; then
            [[ -z "$dec_file" ]] || { ARENA_PROJECTED_CONFLICTS='multiple decision archives bound to review_head'; return 2; }
            dec_file="$candidate"
        else
            conflicts="${conflicts}decision archive bound to differing SHA ($dec_sha);"
        fi
    done
    if [[ -n "$dec_file" ]]; then
        verdict="$(grep -F 'VERDICT: ' "$dec_file" | head -1 | sed 's/^VERDICT: //')"
        case "$verdict" in
            APPROVE|CHANGES_REQUESTED|BLOCKED) ;;
            *) ARENA_PROJECTED_CONFLICTS='decision verdict unparseable'; return 2 ;;
        esac
        report_file="${run_dir}/validation-${review_head}.md"
        [[ -f "$report_file" ]] || { ARENA_PROJECTED_CONFLICTS='decision without a canonical validation report'; return 2; }
        vr="$(grep -F 'RESULT: ' "$report_file" | tail -1 | sed 's/^RESULT: //')"
        case "$vr" in PASS|FAIL) ;; *) ARENA_PROJECTED_CONFLICTS='validation RESULT unparseable'; return 2 ;; esac
        [[ "$verdict" == APPROVE && "$vr" != PASS ]] && { ARENA_PROJECTED_CONFLICTS='legacy APPROVE without PASS'; return 2; }
        vd="$(arena_file_hash "$report_file")" || { ARENA_PROJECTED_CONFLICTS='cannot hash validation report'; return 2; }
        ARENA_PROJECTED_VERDICT="$verdict"; ARENA_PROJECTED_VR="$vr"; ARENA_PROJECTED_VD="$vd"
        case "$verdict" in
            APPROVE) ARENA_PROJECTED_PHASE='decided'; ARENA_PROJECTED_PARTY='human'; ARENA_PROJECTED_REASON='approval_pending'; ARENA_PROJECTED_LABEL='legacy_human_disposition_unknown' ;;
            CHANGES_REQUESTED) ARENA_PROJECTED_PHASE='decided'; ARENA_PROJECTED_PARTY='writer'; ARENA_PROJECTED_REASON='changes_requested' ;;
            BLOCKED) ARENA_PROJECTED_PHASE='decided'; ARENA_PROJECTED_PARTY='human'; ARENA_PROJECTED_REASON='block_resolution_required' ;;
        esac
        return 0
    fi
    # Val pointer + canonical report bound to review_head
    if [[ -f "${run_dir}/validation.md" ]]; then
        report_file="${run_dir}/validation-${review_head}.md"
        if [[ ! -f "$report_file" ]]; then
            ARENA_PROJECTED_CONFLICTS='validation pointer without a canonical report'
            return 2
        fi
        vr="$(grep -F 'RESULT: ' "$report_file" | tail -1 | sed 's/^RESULT: //')"
        case "$vr" in PASS|FAIL) ;; *) ARENA_PROJECTED_CONFLICTS='validation RESULT unparseable'; return 2 ;; esac
        ARENA_PROJECTED_PHASE='validated'; ARENA_PROJECTED_PARTY='reviewer'; ARENA_PROJECTED_REASON='decision_pending'
        ARENA_PROJECTED_VR="$vr"
        ARENA_PROJECTED_VD="$(arena_file_hash "$report_file")"
        return 0
    fi
    # report without pointer: precheck classification
    report_file="${run_dir}/validation-${review_head}.md"
    if [[ -f "$report_file" ]]; then
        ARENA_PROJECTED_RESIDUE='validate'
        ARENA_PROJECTED_CONFLICTS=''  # validate-owned residue: exit 5 at call sites
        ARENA_PROJECTED_PHASE='submitted'; ARENA_PROJECTED_PARTY='reviewer'; ARENA_PROJECTED_REASON='review_pending'
        return 5
    fi
    ARENA_PROJECTED_PHASE='submitted'; ARENA_PROJECTED_PARTY='reviewer'; ARENA_PROJECTED_REASON='review_pending'
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 40 green.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh tests/run.sh
git commit -m "feat: legacy projection engine with precheck and conflict diagnosis"
```

---

### Task 4: Creation intent, T1/T1r stages, and start lock ordering

**Files:** Modify `lib/start.sh`, `lib/state.sh`; Test `tests/run.sh` (section 41).

**Interfaces:** `arena_creation_intent_write ROOT REPO_ID RUN_ID PARAMS...`, `arena_creation_intent_stage RUN_DIR` → prints S1–S6; start gains the T1/T1r flow; every non-start command refuses on a live creation intent (exit 5) via a shared `arena_state_precheck_intents RUN_DIR`.

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '41. creation intent stages and start interruption recovery'
intent_root="${tmp_root}/intent-root"
mkdir -p "${intent_root}/runs/proj-id"
# S1: intent only
printf 'run_id=s1-run\n' >"${intent_root}/runs/proj-id/.creating-s1-run"
ARENA_STATE_ROOT="$intent_root" ARENA_SOURCE_ROOT="$source_root" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    stage="$(arena_creation_intent_stage "$2/runs/proj-id" s1-run)"
    [[ "$stage" == S1 ]] || exit 9
' _ "$source_root" "$intent_root" || fail 'S1 not detected'
# S6: state present + intent remains → delete intent
mkdir -p "${intent_root}/runs/proj-id/s6-run"
printf 'run_id=s6-run\n' >"${intent_root}/runs/proj-id/.creating-s6-run"
printf 'schema_version\t1\nstate_revision\t1\nrun_status\tactive\nphase\tintake\nresponsible_party\twriter\nreason_code\tnone\nreason_detail\t\nverdict\t\nvalidation_result\t\ncheckpoint_round\t0\ncheckpoint_sha\t\nwaiting_since\t1\nlast_transition_at\t1\nlast_transition_actor\tsystem\nlast_transition_action\tstart\nvalidation_digest\t\n' >"${intent_root}/runs/proj-id/s6-run/run-state.tsv"
ARENA_STATE_ROOT="$intent_root" run_arena start s6-run --repo "$project" --no-attach >/dev/null 2>&1 || fail 'S6 recovery start failed'
[[ ! -e "${intent_root}/runs/proj-id/.creating-s6-run" ]] || fail 'S6 intent was not removed'
# non-start command refuses on live creation intent (exit 5)
mkdir -p "${intent_root}/runs/proj-id/s1-run"
if ARENA_STATE_ROOT="$intent_root" run_arena status s1-run >"${tmp_root}/s1-status.out" 2>&1; then
    fail 'status accepted a run with a creation intent'
fi
require_match 'retry: start' "${tmp_root}/s1-status.out"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 41.

- [ ] **Step 3: Implement intents and the start flow**

In `lib/state.sh`:

```bash
arena_creation_intent_write() {
    local runs_root="$1" repo_id="$2" run_id="$3"
    shift 3
    local tmp_file
    tmp_file="$(mktemp "${runs_root}/${repo_id}/.creating-${run_id}.XXXXXX")"
    {
        printf 'run_id\t%s\n' "$run_id"
        for arg in "$@"; do printf '%s\n' "$arg"; done
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${runs_root}/${repo_id}/.creating-${run_id}"
}

arena_creation_intent_path() {
    printf '%s/runs/%s/.creating-%s' "$(arena_state_root)" "$1" "$2"
}

arena_creation_intent_stage() {
    local repo_runs_dir="$1" run_id="$2"
    local run_dir="${repo_runs_dir}/${run_id}" intent="${repo_runs_dir}/.creating-${run_id}"

    if [[ ! -e "$intent" ]]; then
        printf 'NONE\n'
        return 0
    fi
    if [[ ! -e "$run_dir" ]]; then printf 'S1\n'; return 0; fi
    if [[ ! -e "${run_dir}/manifest.tsv" ]]; then
        if find "$run_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then printf 'S3\n'; else printf 'S2\n'; fi
        return 0
    fi
    if [[ ! -e "$(awk -F $'\t' '$1 == "writer_worktree" { print $2 }' "${run_dir}/manifest.tsv")" ]]; then
        printf 'S4\n'; return 0
    fi
    if [[ ! -e "${run_dir}/run-state.tsv" ]]; then printf 'S5\n'; else printf 'S6\n'; fi
    return 0
}

arena_state_precheck_intents() {
    local run_dir="$1" repo_id="$2" run_id="$3"
    local stage repo_runs_dir intent

    repo_runs_dir="$(dirname "$run_dir")"
    intent="${repo_runs_dir}/.creating-${run_id}"
    [[ -e "$intent" ]] || return 0
    stage="$(arena_creation_intent_stage "$repo_runs_dir" "$run_id")"
    case "$stage" in
        NONE) return 0 ;;
        S3|S4)
            if [[ "${ARENA_CALLER:-}" == status || "${ARENA_CALLER:-}" == list || "${ARENA_CALLER:-}" == start ]]; then
                printf 'interrupted start stage %s: inspect %s; if it contains only Arena-created artifacts, remove the directory, the creation intent, the Git worktree registration (git worktree remove; git worktree prune), and the writer branch, then re-run start\n' "$stage" "$run_dir" >&2
                exit 2
            fi
            printf 'interrupted start; retry: agent-arena start %s\n' "$run_id" >&2
            exit 5
            ;;
        *)
            if [[ "${ARENA_CALLER:-}" == start ]]; then return 0; fi
            printf 'interrupted start; retry: agent-arena start %s\n' "$run_id" >&2
            exit 5
            ;;
    esac
}
```

In `lib/start.sh`, replace the new-run creation block with:

```bash
    arena_creation_intent_write "$(arena_state_root)/runs" "$repo_id" "$run_id" \
        "repository=${repository}" "state_root=${state_root}" "worktree_root=${worktree_root}" \
        "profile=${profile}" "gate_adapter=${ARENA_PROFILE_GATE_ADAPTER}" \
        "session_name=${session_name}" "base_sha=${base_sha}" "branch=${branch}" \
        "writer_worktree=${writer_worktree}" "writer_adapter=${writer_adapter}" \
        "gate_adapter_path=${source_root}/adapters/gate-${ARENA_PROFILE_GATE_ADAPTER}.sh" \
        "writer_adapter_path=${source_root}/adapters/${writer_adapter}.sh"
    arena_make_private_dir "$run_dir"
    arena_make_private_dir "$writer_session_dir"
    arena_make_private_dir "$writer_root"
    git -C "$repository" worktree add -b "$branch" "$writer_worktree" "$base_sha"
    arena_lock_acquire "${run_dir}/.run-lock" "start-$$"
    arena_state_defaults
    arena_state_write "$run_dir"
    arena_write_manifest "$run_dir" "$run_id" "$repository" "$base_sha" \
        "$writer_worktree" "$branch" "$session_name" "$source_root" "$worktree_root" \
        "$ARENA_PROJECT_CONFIG" "$profile" "$writer_adapter" "$writer_label" \
        "$writer_session_dir" "$ARENA_PROFILE_GATE_ADAPTER"
    rm -f "$(arena_creation_intent_path "$(dirname "$(dirname "$run_dir")")" "$repo_id" "$run_id")"
    arena_lock_release "${run_dir}/.run-lock" "start-$$"
```

(Manifest write ordering becomes: state before manifest removal of the intent; both inside the run lock. The parent creation lock wraps the whole block as before.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 41 green; section 38 still green.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh lib/start.sh tests/run.sh
git commit -m "feat: creation intent, T1/T1r stages, and start lock ordering"
```

---

### Task 5: Shared transition dispatcher + submit transitions (T2/T3/T4/L-T3)

**Files:** Modify `lib/state.sh`, `lib/submit.sh`; Test `tests/run.sh` (section 42).

**Interfaces:** `arena_state_transition RUN_DIR FROM_RE MATCHING_FN DELTA_FN ACTION_NAME` — validates the source tuple against `ARENA_STATE_*`, runs the guard, applies the delta, increments revision, updates transition fields, writes atomically. `arena_state_delta_*` helpers.

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '42. submit transitions T2/T3/T4 and legacy L-T3'
trans_run='trans-submit'
run_arena start "$trans_run" --repo "$project" --no-attach >/dev/null
trans_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${trans_run}/manifest.tsv" -exec dirname {} \;)"
trans_writer="$(manifest_value "${trans_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' t2 >"${trans_writer}/t2.txt"
git -C "$trans_writer" add t2.txt
git -C "$trans_writer" commit -m 'feat: t2' >/dev/null
run_arena submit "$trans_run" >/dev/null
require_match $'phase\tsubmitted' <(cat "${trans_run_dir}/run-state.tsv")
require_match $'responsible_party\treviewer' <(cat "${trans_run_dir}/run-state.tsv")
require_match $'reason_code\treview_pending' <(cat "${trans_run_dir}/run-state.tsv")
require_match $'checkpoint_round\t1' <(cat "${trans_run_dir}/run-state.tsv")
first_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${trans_run_dir}/run-state.tsv")"
first_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${trans_run_dir}/run-state.tsv")"
# T3 same-SHA submit: zero-write
run_arena submit "$trans_run" >/dev/null
second_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${trans_run_dir}/run-state.tsv")"
second_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${trans_run_dir}/run-state.tsv")"
[[ "$first_revision" == "$second_revision" ]] || fail 'T3 same-SHA submit wrote state'
[[ "$first_waiting" == "$second_waiting" ]] || fail 'T3 same-SHA submit reset waiting_since'
# T4: same SHA after CHANGES_REQUESTED is rejected
run_arena validate "$trans_run" >/dev/null 2>&1
run_arena decision "$trans_run" --verdict CHANGES_REQUESTED --summary s --next n --no-relay >/dev/null
if run_arena submit "$trans_run" >"${tmp_root}/t4.out" 2>&1; then
    fail 'T4 same-SHA submit after changes_requested succeeded'
fi
require_match 'must submit a new SHA' "${tmp_root}/t4.out"
# L-T3: legacy L5 same-SHA submit materializes v1
legacy_lt3="${tmp_root}/legacy-lt3"
mkdir -p "$legacy_lt3"
sha_lt3='1111111111111111111111111111111111111111'
printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
    "$sha_lt3" "$trans_writer" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')" >"${legacy_lt3}/review.tsv"
cp "${trans_run_dir}/manifest.tsv" "${legacy_lt3}/manifest.tsv"
if ARENA_STATE_ROOT="$state_base" run_arena submit "$trans_run" >/dev/null 2>&1; then :; fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 42 — submit does not write state transitions yet.

- [ ] **Step 3: Implement the dispatcher and submit transitions**

In `lib/state.sh`:

```bash
arena_state_transition() {
    local run_dir="$1" source_check="$2" guard_fn="$3" delta_fn="$4" action_name="$5"
    local new_revision

    arena_state_read "$run_dir"
    "$source_check" || arena_die "illegal transition from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    "$guard_fn" || return 2
    new_revision=$((ARENA_STATE_REVISION + 1))
    "$delta_fn"
    ARENA_STATE_REVISION="$new_revision"
    ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_ACTION="$action_name"
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
        "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
        "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
        "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
        "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
        "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
        "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
        "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
}

arena_source_intake_or_decided_writer() {
    [[ "$ARENA_STATE_RUN_STATUS" == active ]] || return 1
    if [[ "$ARENA_STATE_PHASE" == intake ]]; then
        [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer && "$ARENA_STATE_REASON_CODE" == none ]] || return 1
        return 0
    fi
    if [[ "$ARENA_STATE_PHASE" == decided ]]; then
        [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer ]] || return 1
        case "$ARENA_STATE_REASON_CODE" in changes_requested|human_changes_requested) return 0 ;; *) return 1 ;; esac
    fi
    return 1
}

arena_source_submitted_reviewer() {
    [[ "$ARENA_STATE_RUN_STATUS" == active && "$ARENA_STATE_PHASE" == submitted && \
        "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == review_pending ]]
}
```

In `lib/submit.sh`, after the existing evidence checks and before the final notes:

```bash
state_run_dir="$run_dir"
ARENA_CALLER=submit source "${source_root}/lib/state.sh"
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if arena_source_submitted_reviewer && [[ "$ARENA_STATE_CHECKPOINT_SHA" == "$writer_head" ]]; then
        : # T3: same-SHA idempotent retry — zero-write, evidence recreated/verified above
    elif arena_source_intake_or_decided_writer && [[ -z "$ARENA_STATE_CHECKPOINT_SHA" || "$ARENA_STATE_CHECKPOINT_SHA" != "$writer_head" ]]; then
        arena_state_transition "$run_dir" arena_source_intake_or_decided_writer \
            true \
            arena_state_delta_submit_new_sha \
            submit
    elif [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == writer ]] && \
        { [[ "$ARENA_STATE_REASON_CODE" == changes_requested || "$ARENA_STATE_REASON_CODE" == human_changes_requested ]]; } && \
        [[ "$ARENA_STATE_CHECKPOINT_SHA" == "$writer_head" ]]; then
        arena_die 'writer must submit a new SHA'
    fi
else
    # legacy: project inside the lock; L-T3 for L5 same-SHA, otherwise T2-like migration
    arena_state_project_legacy "$run_dir"
    if [[ "$ARENA_PROJECTED_PHASE" == submitted && "$ARENA_PROJECTED_CS" == "$writer_head" ]]; then
        arena_state_defaults
        ARENA_STATE_PHASE='submitted'; ARENA_STATE_RESPONSIBLE_PARTY='reviewer'; ARENA_STATE_REASON_CODE='review_pending'
        ARENA_STATE_CHECKPOINT_SHA="$writer_head"; ARENA_STATE_CHECKPOINT_ROUND='unknown'
        ARENA_STATE_WAITING_SINCE="$(date +%s)"; ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
        ARENA_STATE_LAST_TRANSITION_ACTOR='writer'; ARENA_STATE_LAST_TRANSITION_ACTION='submit'
        arena_state_write "$run_dir"
    elif [[ "$ARENA_PROJECTED_PHASE" == intake ]]; then
        arena_state_defaults
        ARENA_STATE_PHASE='submitted'; ARENA_STATE_RESPONSIBLE_PARTY='reviewer'; ARENA_STATE_REASON_CODE='review_pending'
        ARENA_STATE_CHECKPOINT_SHA="$writer_head"; ARENA_STATE_CHECKPOINT_ROUND='1'
        ARENA_STATE_WAITING_SINCE="$(date +%s)"; ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
        ARENA_STATE_LAST_TRANSITION_ACTOR='writer'; ARENA_STATE_LAST_TRANSITION_ACTION='submit'
        arena_state_write "$run_dir"
    else
        arena_die 'legacy projection does not admit this submit'
    fi
fi
```

And the delta helper in `lib/state.sh`:

```bash
arena_state_delta_submit_new_sha() {
    ARENA_STATE_RUN_STATUS='active'
    ARENA_STATE_PHASE='submitted'
    ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
    ARENA_STATE_REASON_CODE='review_pending'
    ARENA_STATE_REASON_DETAIL=''
    ARENA_STATE_VERDICT=''
    ARENA_STATE_VALIDATION_RESULT=''
    ARENA_STATE_VALIDATION_DIGEST=''
    ARENA_STATE_CHECKPOINT_SHA="$writer_head"
    if [[ "$ARENA_STATE_CHECKPOINT_ROUND" == unknown ]]; then
        : # sticky unknown
    elif [[ "$ARENA_STATE_CHECKPOINT_ROUND" =~ ^[0-9]+$ ]]; then
        ARENA_STATE_CHECKPOINT_ROUND=$((ARENA_STATE_CHECKPOINT_ROUND + 1))
    fi
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_ACTOR='writer'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 42 green; all earlier sections green.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh lib/submit.sh tests/run.sh
git commit -m "feat: shared transition dispatcher and submit transitions T2/T3/T4/L-T3"
```

---

### Task 6: Validate op-token protocol and CAS publish (T5)

**Files:** Modify `lib/validate.sh`; Test `tests/run.sh` (section 43).

**Interfaces:** op-token flow per spec: first-lock pending-archive check, triple baseline, gate outside the lock, CAS publish with archive-COPY + atomic canonical replace, exit 0/10/2/3/4/5; diagnostic-only `.diagnostic.md` path on integrity failure.

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '43. validate op-token CAS and exit 10 on recorded FAIL'
val_run='val-cas'
run_arena start "$val_run" --repo "$project" --no-attach >/dev/null
val_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${val_run}/manifest.tsv" -exec dirname {} \;)"
val_writer="$(manifest_value "${val_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' v >"${val_writer}/v.txt"
git -C "$val_writer" add v.txt
git -C "$val_writer" commit -m 'feat: v' >/dev/null
run_arena submit "$val_run" >/dev/null
run_arena validate "$val_run" >"${tmp_root}/val-pass.out"
require_match 'RESULT: PASS' "${tmp_root}/val-pass.out"
require_match $'phase\tvalidated' <(cat "${val_run_dir}/run-state.tsv")
require_match $'reason_code\tdecision_pending' <(cat "${val_run_dir}/run-state.tsv")
val_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${val_run_dir}/run-state.tsv")"
require_match "validation_digest\t$(arena_file_hash "${val_run_dir}/validation-${val_sha}.md")" <(cat "${val_run_dir}/run-state.tsv")
# revalidate: WS preserved, revision bumps, new digest
val_waiting="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${val_run_dir}/run-state.tsv")"
val_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
run_arena validate "$val_run" >/dev/null
require_match "waiting_since\t${val_waiting}" <(cat "${val_run_dir}/run-state.tsv")
new_revision="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${val_run_dir}/run-state.tsv")"
[[ "$new_revision" -gt "$val_revision" ]] || fail 'revalidate did not bump revision'
# pending decision archive blocks validate (first-lock refusal, exit 5)
run_arena decision "$val_run" --verdict CHANGES_REQUESTED --summary s --next n --no-relay >/dev/null
# (decision completed; now a fresh checkpoint for the exit-10 FAIL case)
printf '%s\n' f >"${val_writer}/f.txt"
git -C "$val_writer" add f.txt
git -C "$val_writer" commit -m 'feat: f' >/dev/null
run_arena submit "$val_run" >/dev/null
# swap the project validation script to FAIL
cat >"${project}/.agent-arena/validate.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "${project}/.agent-arena/validate.sh"
git -C "$project" add .agent-arena/validate.sh
git -C "$project" commit -m 'test: failing validation' >/dev/null
run_arena validate "$val_run" >"${tmp_root}/val-fail.out" 2>&1
val_exit=$?
[[ "$val_exit" == 10 ]] || fail "validate FAIL exited $val_exit, expected 10"
require_match 'RESULT: FAIL' "${tmp_root}/val-fail.out"
require_match $'validation_result\tFAIL' <(cat "${val_run_dir}/run-state.tsv")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 43.

- [ ] **Step 3: Implement the op-token flow in validate.sh**

Replace the body of `lib/validate.sh` after the run-dir resolution with:

```bash
source "${source_root}/lib/lock.sh"
source "${source_root}/lib/state.sh"

lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "validate-$$"
# first-lock pending-archive refusal
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if [[ -n "$ARENA_STATE_CHECKPOINT_SHA" && -f "${run_dir}/decision-${ARENA_STATE_CHECKPOINT_SHA}.md" && \
        -z "$ARENA_STATE_VERDICT" ]]; then
        arena_lock_release "$lock_path" "validate-$$"
        arena_die 'pending decision residue; complete the decision retry first'
    fi
    base_revision="$ARENA_STATE_REVISION"
    base_sha="$ARENA_STATE_CHECKPOINT_SHA"
else
    arena_state_project_legacy "$run_dir"
    base_sha="$ARENA_PROJECTED_CS"
    base_revision='absent'
fi
base_archive='absent'
op_token="validate.$$.$RANDOM"
arena_lock_release "$lock_path" "validate-$$"

# gate outside the lock (writes only the token temporary)
tmp_report="${run_dir}/.validation.${op_token}.tmp"
run_gate >"$tmp_report" 2>&1 || { gate_status=$?; arena_note 'gate infrastructure failure; diagnostic only'; }
# (run_gate retains the existing integrity logic; integrity failure writes .diagnostic.md and exits 2 WITHOUT touching state)

arena_lock_acquire "$lock_path" "validate-$$"
arena_state_read "$run_dir"
current_archive='absent'
[[ -f "${run_dir}/decision-${base_sha}.md" ]] && current_archive="$(arena_file_hash "${run_dir}/decision-${base_sha}.md")"
if [[ "$current_archive" != absent && "$ARENA_STATE_REVISION" == "$base_revision" ]]; then
    arena_lock_release "$lock_path" "validate-$$"
    rm -f "$tmp_report"
    exit 5
fi
if [[ "$ARENA_STATE_REVISION" != "$base_revision" && "$base_revision" != absent ]]; then
    arena_lock_release "$lock_path" "validate-$$"
    rm -f "$tmp_report"
    exit 3
fi
if [[ "$ARENA_STATE_CHECKPOINT_SHA" != "$base_sha" ]]; then
    arena_lock_release "$lock_path" "validate-$$"
    rm -f "$tmp_report"
    exit 3
fi
# CAS success: publish
short_sha="$(arena_short_sha "$ARENA_STATE_CHECKPOINT_SHA")"
report="${run_dir}/validation-${short_sha}.md"
if [[ -f "$report" ]]; then
    rotated="${report%.md}.r1.md"
    rotation_index=1
    while [[ -e "$rotated" ]]; do
        rotation_index=$((rotation_index + 1))
        rotated="${report%.md}.r${rotation_index}.md"
    done
    archive_tmp="$(mktemp "${run_dir}/.archive.XXXXXX")"
    cp "$report" "$archive_tmp"
    mv "$archive_tmp" "$rotated"
    chmod 600 "$rotated"
fi
if [[ "${gate_status:-0}" == 0 ]]; then
    printf '\nRESULT: PASS\n' >>"$tmp_report"
else
    printf '\nRESULT: FAIL\n' >>"$tmp_report"
fi
chmod 600 "$tmp_report"
mv "$tmp_report" "$report"
printf 'Latest validation report: %s\n' "$(basename "$report")" >"${run_dir}/validation.md"
chmod 600 "${run_dir}/validation.md"
new_digest="$(arena_file_hash "$report")"
new_revision=$((ARENA_STATE_REVISION + 1))
ARENA_STATE_PHASE='validated'
ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
ARENA_STATE_REASON_CODE='decision_pending'
ARENA_STATE_VALIDATION_RESULT="$([[ "${gate_status:-0}" == 0 ]] && printf PASS || printf FAIL)"
ARENA_STATE_VALIDATION_DIGEST="$new_digest"
if [[ "$ARENA_STATE_REASON_CODE" == decision_pending && "$ARENA_STATE_PHASE" == validated ]]; then
    : # revalidate: WS preserved (no change)
else
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
fi
ARENA_STATE_REVISION="$new_revision"
ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
ARENA_STATE_LAST_TRANSITION_ACTOR='reviewer'
ARENA_STATE_LAST_TRANSITION_ACTION='validate'
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
    "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
    "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
    "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
    "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
    "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
    "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
    "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
arena_lock_release "$lock_path" "validate-$$"
cat "$report"
[[ "${gate_status:-0}" == 0 ]] && exit 0 || exit 10
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 43 green; adapt the v0.3 integrity-failure assertion (section 13) to the `.diagnostic.md` path.

- [ ] **Step 5: Commit**

```bash
git add lib/validate.sh tests/run.sh
git commit -m "feat: validate op-token protocol, CAS publish, and exit 10"
```

---

### Task 7: Decision transitions and archive metadata (T6–T8/T6r/L-T6)

**Files:** Modify `lib/decision.sh`, `lib/state.sh`; Test `tests/run.sh` (section 44).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '44. decision transitions, archive metadata, and T6r'
dec_run='dec-meta'
run_arena start "$dec_run" --repo "$project" --no-attach >/dev/null
dec_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${dec_run}/manifest.tsv" -exec dirname {} \;)"
dec_writer="$(manifest_value "${dec_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' d >"${dec_writer}/d.txt"
git -C "$dec_writer" add d.txt
git -C "$dec_writer" commit -m 'feat: d' >/dev/null
run_arena submit "$dec_run" >/dev/null
run_arena validate "$dec_run" >/dev/null
run_arena decision "$dec_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'run_status\tactive' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'phase\tdecided' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'reason_code\tapproval_pending' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'verdict\tAPPROVE' <(cat "${dec_run_dir}/run-state.tsv")
dec_sha="$(awk -F $'\t' '$1 == "checkpoint_sha" { print $2 }' "${dec_run_dir}/run-state.tsv")"
archive="${dec_run_dir}/decision-${dec_sha:0:12}.md"
require_match "State revision: " <(cat "$archive")
require_match "Validation digest: " <(cat "$archive")
# T6r: archive-only residue completes the state commit
cp "${dec_run_dir}/run-state.tsv" "${tmp_root}/pre-t6r-state.tsv"
# simulate: verdict empty, archive present, metadata matches
awk -F $'\t' 'BEGIN { OFS = FS } $1 == "verdict" { $2 = "" } $1 == "responsible_party" { $2 = "reviewer" } $1 == "reason_code" { $2 = "decision_pending" } { print }' \
    "${dec_run_dir}/run-state.tsv" >"${dec_run_dir}/run-state.tsv.next"
mv "${dec_run_dir}/run-state.tsv.next" "${dec_run_dir}/run-state.tsv"
run_arena decision "$dec_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
require_match $'verdict\tAPPROVE' <(cat "${dec_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${dec_run_dir}/run-state.tsv")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 44.

- [ ] **Step 3: Implement**

In `lib/decision.sh`, after the existing evidence checks:

```bash
source "${source_root}/lib/lock.sh"
source "${source_root}/lib/state.sh"
lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "decision-$$"
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    source_ok=0
    [[ "$ARENA_STATE_RUN_STATUS" == active && "$ARENA_STATE_PHASE" == validated && \
        "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && "$ARENA_STATE_REASON_CODE" == decision_pending ]] && source_ok=1
    [[ "$source_ok" == 1 ]] || { arena_lock_release "$lock_path" "decision-$$"; arena_die "illegal transition from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"; }
    if [[ "$verdict" == APPROVE ]]; then
        [[ "$ARENA_STATE_VALIDATION_RESULT" == PASS ]] || { arena_lock_release "$lock_path" "decision-$$"; arena_die 'APPROVE requires a passing validation report'; }
    fi
    if [[ -f "$decision_archive" ]]; then
        archive_meta_revision="$(grep -F 'State revision: ' "$decision_archive" | head -1 | sed 's/^State revision: //')"
        archive_meta_vd="$(grep -F 'Validation digest: ' "$decision_archive" | head -1 | sed 's/^Validation digest: //')"
        if [[ -n "$ARENA_STATE_VERDICT" && "$ARENA_STATE_VERDICT" == "$verdict" ]]; then
            arena_lock_release "$lock_path" "decision-$$"
            arena_die 'a decision already exists for this checkpoint'
        fi
        [[ "$archive_meta_revision" == "$ARENA_STATE_REVISION" && "$archive_meta_vd" == "$ARENA_STATE_VALIDATION_DIGEST" ]] || {
            arena_lock_release "$lock_path" "decision-$$"
            arena_die 'decision archive metadata does not match the current state'
        }
        # T6r: archive-only residue — complete decision.md and commit
    fi
    # write archive (evidence) with metadata
    {
        printf '# Agent Arena Gate Decision\n\n'
        printf 'Run: %s\n\n' "$run_id"
        printf 'Review HEAD: %s\n\n' "$ARENA_REVIEW_HEAD"
        printf 'VERDICT: %s\n\n' "$verdict"
        printf 'State revision: %s\n' "$ARENA_STATE_REVISION"
        printf 'Validation digest: %s\n' "$ARENA_STATE_VALIDATION_DIGEST"
        printf '## Summary\n\n%s\n\n' "$summary"
        printf '## Findings\n\n'
        if [[ -n "${findings[*]:-}" ]]; then
            for finding in "${findings[@]}"; do printf '%s\n' "- $finding"; done
        else
            printf '%s\n' '- No additional findings.'
        fi
        printf '\n## Next Step for Writer\n\n%s\n' "$next_step"
    } >"$tmp_decision"
    chmod 600 "$tmp_decision"
    mv "$tmp_decision" "$decision_archive"
    tmp_pointer="$(mktemp "${run_dir}/.decision-md.XXXXXX")"
    cp "$decision_archive" "$tmp_pointer"
    mv "$tmp_pointer" "${run_dir}/decision.md"
    chmod 600 "${run_dir}/decision.md"
    # state commit per verdict
    ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
    ARENA_STATE_PHASE='decided'
    ARENA_STATE_VERDICT="$verdict"
    ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_ACTOR='reviewer'
    ARENA_STATE_LAST_TRANSITION_ACTION='decision'
    case "$verdict" in
        APPROVE) ARENA_STATE_RUN_STATUS='active'; ARENA_STATE_RESPONSIBLE_PARTY='human'; ARENA_STATE_REASON_CODE='approval_pending'; ARENA_STATE_WAITING_SINCE="${ARENA_STATE_LAST_TRANSITION_AT}" ;;
        CHANGES_REQUESTED) ARENA_STATE_RUN_STATUS='active'; ARENA_STATE_RESPONSIBLE_PARTY='writer'; ARENA_STATE_REASON_CODE='changes_requested'; ARENA_STATE_WAITING_SINCE="${ARENA_STATE_LAST_TRANSITION_AT}" ;;
        BLOCKED) ARENA_STATE_RUN_STATUS='blocked'; ARENA_STATE_RESPONSIBLE_PARTY='human'; ARENA_STATE_REASON_CODE='block_resolution_required'; ARENA_STATE_WAITING_SINCE="${ARENA_STATE_LAST_TRANSITION_AT}" ;;
    esac
    ARENA_STATE_REASON_DETAIL=''
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
        "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
        "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
        "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
        "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
        "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
        "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
        "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
else
    # legacy: L-T6 when the archive carries v0.4 metadata with State revision: 0
    arena_state_project_legacy "$run_dir"
    [[ -f "$decision_archive" ]] && \
        grep -Fqx 'State revision: 0' "$decision_archive" && {
            arena_state_defaults
            ARENA_STATE_PHASE='decided'
            ARENA_STATE_VERDICT="$verdict"
            ARENA_STATE_VALIDATION_RESULT="${ARENA_PROJECTED_VR}"
            ARENA_STATE_VALIDATION_DIGEST="${ARENA_PROJECTED_VD}"
            ARENA_STATE_CHECKPOINT_SHA="$ARENA_PROJECTED_CS"
            ARENA_STATE_CHECKPOINT_ROUND='unknown'
            ARENA_STATE_WAITING_SINCE="$(date +%s)"
            ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
            ARENA_STATE_LAST_TRANSITION_ACTOR='reviewer'
            ARENA_STATE_LAST_TRANSITION_ACTION='decision'
            case "$verdict" in
                APPROVE) ARENA_STATE_RESPONSIBLE_PARTY='human'; ARENA_STATE_REASON_CODE='approval_pending' ;;
                CHANGES_REQUESTED) ARENA_STATE_RESPONSIBLE_PARTY='writer'; ARENA_STATE_REASON_CODE='changes_requested' ;;
                BLOCKED) ARENA_STATE_RUN_STATUS='blocked'; ARENA_STATE_RESPONSIBLE_PARTY='human'; ARENA_STATE_REASON_CODE='block_resolution_required' ;;
            esac
            arena_state_write "$run_dir"
        }
}
arena_lock_release "$lock_path" "decision-$$"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 44 green; sections 1–43 green.

- [ ] **Step 5: Commit**

```bash
git add lib/decision.sh tests/run.sh
git commit -m "feat: decision transitions T6-T8/T6r with archive metadata and L-T6"
```

---

### Task 8: escalate and resolve commands (T9–T13)

**Files:** Create `lib/escalate.sh`, `lib/resolve.sh`; Modify `lib/arena.sh`, `lib/start.sh` (resume respawn + creation-intent refusal); Test `tests/run.sh` (section 45).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '45. escalate and resolve transitions'
er_run='er-run'
run_arena start "$er_run" --repo "$project" --no-attach >/dev/null
er_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${er_run}/manifest.tsv" -exec dirname {} \;)"
er_writer="$(manifest_value "${er_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' e >"${er_writer}/e.txt"
git -C "$er_writer" add e.txt
git -C "$er_writer" commit -m 'feat: e' >/dev/null
run_arena submit "$er_run" >/dev/null
# escalate from submitted/reviewer (legal)
run_arena escalate "$er_run" --reason-code reviewer_unreachable --reason 'pane dead' >/dev/null
require_match $'run_status\tblocked' <(cat "${er_run_dir}/run-state.tsv")
require_match $'responsible_party\thuman' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_code\treviewer_unreachable' <(cat "${er_run_dir}/run-state.tsv")
require_match $'reason_detail\tpane dead' <(cat "${er_run_dir}/run-state.tsv")
# duplicate escalate: idempotent zero-write
er_rev="$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${er_run_dir}/run-state.tsv")"
er_ws="$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${er_run_dir}/run-state.tsv")"
run_arena escalate "$er_run" --reason-code reviewer_unreachable --reason 'again' >/dev/null
[[ "$er_rev" == "$(awk -F $'\t' '$1 == "state_revision" { print $2 }' "${er_run_dir}/run-state.tsv")" ]] || fail 'duplicate escalate wrote state'
[[ "$er_ws" == "$(awk -F $'\t' '$1 == "waiting_since" { print $2 }' "${er_run_dir}/run-state.tsv")" ]] || fail 'duplicate escalate reset waiting_since'
# resolve recover with dead reviewer pane must refuse
if run_arena resolve "$er_run" --action recover --reason 'try' >"${tmp_root}/recover.out" 2>&1; then
    fail 'recover with unreachable pane succeeded'
fi
require_match 'resume' "${tmp_root}/recover.out"
# resolve cancel
run_arena resolve "$er_run" --action cancel --reason 'abandoned' >/dev/null
require_match $'run_status\tcanceled' <(cat "${er_run_dir}/run-state.tsv")
require_match $'responsible_party\tnone' <(cat "${er_run_dir}/run-state.tsv")
require_match $'waiting_since\t' <(cat "${er_run_dir}/run-state.tsv")
# resolve approve after reviewer APPROVE
ap_run='ap-run'
run_arena start "$ap_run" --repo "$project" --no-attach >/dev/null
ap_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${ap_run}/manifest.tsv" -exec dirname {} \;)"
ap_writer="$(manifest_value "${ap_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' a >"${ap_writer}/a.txt"
git -C "$ap_writer" add a.txt
git -C "$ap_writer" commit -m 'feat: a' >/dev/null
run_arena submit "$ap_run" >/dev/null
run_arena validate "$ap_run" >/dev/null
run_arena decision "$ap_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
run_arena resolve "$ap_run" --action approve >/dev/null
require_match $'run_status\tcompleted' <(cat "${ap_run_dir}/run-state.tsv")
require_match $'responsible_party\tnone' <(cat "${ap_run_dir}/run-state.tsv")
# resolve reject
rj_run='rj-run'
run_arena start "$rj_run" --repo "$project" --no-attach >/dev/null
rj_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${rj_run}/manifest.tsv" -exec dirname {} \;)"
rj_writer="$(manifest_value "${rj_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' r >"${rj_writer}/r.txt"
git -C "$rj_writer" add r.txt
git -C "$rj_writer" commit -m 'feat: r' >/dev/null
run_arena submit "$rj_run" >/dev/null
run_arena validate "$rj_run" >/dev/null
run_arena decision "$rj_run" --verdict APPROVE --summary ok --next go --no-relay >/dev/null
if run_arena resolve "$rj_run" --action reject >"${tmp_root}/rj.out" 2>&1; then
    fail 'reject without --reason succeeded'
fi
run_arena resolve "$rj_run" --action reject --reason 'needs rework' >/dev/null
require_match $'responsible_party\twriter' <(cat "${rj_run_dir}/run-state.tsv")
require_match $'reason_code\thuman_changes_requested' <(cat "${rj_run_dir}/run-state.tsv")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 45 — commands missing from the dispatcher.

- [ ] **Step 3: Implement escalate**

`lib/escalate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena escalate RUN_ID --reason-code reviewer_unreachable --reason "..."

Raise a stuck run to human responsibility. Allowed only from
responsible_party=reviewer with phase submitted or validated. Idempotent in
the blocked/human/reviewer_unreachable state.
EOF
}

run_id=''
reason_code=''
reason=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason-code) [[ $# -ge 2 ]] || arena_die '--reason-code requires a value'; reason_code="$2"; shift 2 ;;
        --reason) [[ $# -ge 2 ]] || arena_die '--reason requires a value'; reason="$2"; shift 2 ;;
        --state-root) [[ $# -ge 2 ]] || arena_die '--state-root requires a value'; ARENA_STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *) [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'; run_id="$1"; shift ;;
    esac
done
[[ -n "$run_id" && -n "$reason_code" && -n "$reason" ]] || arena_die 'escalate requires RUN_ID, --reason-code, and --reason'
[[ "$reason_code" == reviewer_unreachable ]] || arena_die 'v1 escalate supports only --reason-code reviewer_unreachable'
arena_validate_run_id "$run_id"
arena_validate_text "$reason" 'reason' 256
run_dir="$(arena_find_run_dir "$run_id")"
lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "escalate-$$"
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    if [[ "$ARENA_STATE_RUN_STATUS" == blocked && "$ARENA_STATE_RESPONSIBLE_PARTY" == human && \
        "$ARENA_STATE_REASON_CODE" == reviewer_unreachable ]]; then
        arena_lock_release "$lock_path" "escalate-$$"
        arena_note 'already escalated'
        exit 0
    fi
    { [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == reviewer && \
        ( "$ARENA_STATE_PHASE" == submitted || "$ARENA_STATE_PHASE" == validated ) ]]; } || {
        arena_lock_release "$lock_path" "escalate-$$"
        arena_die "escalate is not allowed from ${ARENA_STATE_RUN_STATUS}/${ARENA_STATE_PHASE}/${ARENA_STATE_RESPONSIBLE_PARTY}/${ARENA_STATE_REASON_CODE}"
    }
    ARENA_STATE_RUN_STATUS='blocked'
    ARENA_STATE_RESPONSIBLE_PARTY='human'
    ARENA_STATE_REASON_CODE='reviewer_unreachable'
    ARENA_STATE_REASON_DETAIL="$reason"
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR='human'
    ARENA_STATE_LAST_TRANSITION_ACTION='escalate'
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
        "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
        "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
        "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
        "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
        "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
        "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
        "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
else
    arena_state_project_legacy "$run_dir"
    { [[ "$ARENA_PROJECTED_PARTY" == reviewer && \
        ( "$ARENA_PROJECTED_PHASE" == submitted || "$ARENA_PROJECTED_PHASE" == validated ) ]]; } || {
        arena_lock_release "$lock_path" "escalate-$$"
        arena_die 'legacy projection does not admit escalate'
    }
    arena_state_defaults
    ARENA_STATE_RUN_STATUS='blocked'
    ARENA_STATE_PHASE="$ARENA_PROJECTED_PHASE"
    ARENA_STATE_RESPONSIBLE_PARTY='human'
    ARENA_STATE_REASON_CODE='reviewer_unreachable'
    ARENA_STATE_REASON_DETAIL="$reason"
    ARENA_STATE_CHECKPOINT_SHA="$ARENA_PROJECTED_CS"
    ARENA_STATE_CHECKPOINT_ROUND='unknown'
    ARENA_STATE_VERDICT="$ARENA_PROJECTED_VERDICT"
    ARENA_STATE_VALIDATION_RESULT="$ARENA_PROJECTED_VR"
    ARENA_STATE_VALIDATION_DIGEST="$ARENA_PROJECTED_VD"
    ARENA_STATE_WAITING_SINCE="$(date +%s)"
    ARENA_STATE_LAST_TRANSITION_AT="${ARENA_STATE_WAITING_SINCE}"
    ARENA_STATE_LAST_TRANSITION_ACTOR='human'
    ARENA_STATE_LAST_TRANSITION_ACTION='escalate'
    arena_state_write "$run_dir"
fi
arena_lock_release "$lock_path" "escalate-$$"
arena_note 'escalated to human; release with: agent-arena resolve '"$run_id"' --action recover --reason "..."'
```

- [ ] **Step 4: Implement resolve**

`lib/resolve.sh` (analogous parser with `--action`; guards per T10–T13):

```bash
#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena resolve RUN_ID --action approve|reject|recover|cancel --reason "..."

Human disposition. Allowed only when responsible_party=human. reject/recover/
cancel require --reason. approve only after a reviewer APPROVE; recover only
after an operational escalation with a reachable reviewer pane; BLOCKED admits
only reject or cancel in v1.
EOF
}

run_id=''
action=''
reason=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --action) [[ $# -ge 2 ]] || arena_die '--action requires a value'; action="$2"; shift 2 ;;
        --reason) [[ $# -ge 2 ]] || arena_die '--reason requires a value'; reason="$2"; shift 2 ;;
        --state-root) [[ $# -ge 2 ]] || arena_die '--state-root requires a value'; ARENA_STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *) [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'; run_id="$1"; shift ;;
    esac
done
[[ -n "$run_id" && -n "$action" ]] || arena_die 'resolve requires RUN_ID and --action'
case "$action" in approve|reject|recover|cancel) ;; *) arena_die 'action must be approve, reject, recover, or cancel' ;; esac
if [[ "$action" != approve && -z "$reason" ]]; then
    arena_die "$action requires --reason"
fi
[[ -z "$reason" ]] || arena_validate_text "$reason" 'reason' 256
arena_validate_run_id "$run_id"
run_dir="$(arena_find_run_dir "$run_id")"
lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "resolve-$$"
arena_state_read "$run_dir"
[[ "$ARENA_STATE_RESPONSIBLE_PARTY" == human ]] || {
    arena_lock_release "$lock_path" "resolve-$$"
    arena_die "resolve requires human responsibility (current: ${ARENA_STATE_RESPONSIBLE_PARTY})"
}
case "$action" in
    approve)
        { [[ "$ARENA_STATE_PHASE" == decided && "$ARENA_STATE_REASON_CODE" == approval_pending && \
            "$ARENA_STATE_VERDICT" == APPROVE ]]; } || {
            arena_lock_release "$lock_path" "resolve-$$"
            arena_die 'approve is allowed only after a reviewer APPROVE'
        }
        ARENA_STATE_RUN_STATUS='completed'
        ARENA_STATE_RESPONSIBLE_PARTY='none'
        ARENA_STATE_REASON_CODE='none'
        ARENA_STATE_REASON_DETAIL=''
        ARENA_STATE_WAITING_SINCE=''
        ;;
    reject)
        { [[ "$ARENA_STATE_PHASE" == decided && \
            ( "$ARENA_STATE_REASON_CODE" == approval_pending || "$ARENA_STATE_REASON_CODE" == block_resolution_required ) ]]; } || {
            arena_lock_release "$lock_path" "resolve-$$"
            arena_die 'reject is not allowed from this state'
        }
        ARENA_STATE_RUN_STATUS='active'
        ARENA_STATE_RESPONSIBLE_PARTY='writer'
        ARENA_STATE_REASON_CODE='human_changes_requested'
        ARENA_STATE_REASON_DETAIL="$reason"
        ARENA_STATE_WAITING_SINCE="$(date +%s)"
        ;;
    recover)
        { [[ "$ARENA_STATE_RUN_STATUS" == blocked && "$ARENA_STATE_REASON_CODE" == reviewer_unreachable ]]; } || {
            arena_lock_release "$lock_path" "resolve-$$"
            arena_die 'recover handles operational escalation only, never a formal BLOCKED verdict'
        }
        session_name="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "${run_dir}/manifest.tsv")"
        if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "=${session_name}" 2>/dev/null || \
            ! arena_find_live_pane "$session_name" reviewer reviewer-agent >/dev/null 2>&1; then
            arena_lock_release "$lock_path" "resolve-$$"
            arena_die "reviewer pane unreachable; first run: agent-arena resume ${run_id} (respawns the reviewer pane), confirm the trust prompt in the pane, then re-run recover"
        fi
        ARENA_STATE_RUN_STATUS='active'
        ARENA_STATE_RESPONSIBLE_PARTY='reviewer'
        [[ "$ARENA_STATE_PHASE" == submitted ]] && ARENA_STATE_REASON_CODE='review_pending'
        [[ "$ARENA_STATE_PHASE" == validated ]] && ARENA_STATE_REASON_CODE='decision_pending'
        ARENA_STATE_REASON_DETAIL="$reason"
        ARENA_STATE_WAITING_SINCE="$(date +%s)"
        ;;
    cancel)
        case "$ARENA_STATE_REASON_CODE" in
            approval_pending|block_resolution_required|reviewer_unreachable) ;;
            *) arena_lock_release "$lock_path" "resolve-$$"; arena_die 'cancel is not allowed from this state' ;;
        esac
        ARENA_STATE_RUN_STATUS='canceled'
        ARENA_STATE_RESPONSIBLE_PARTY='none'
        ARENA_STATE_REASON_CODE='none'
        ARENA_STATE_REASON_DETAIL="$reason"
        ARENA_STATE_WAITING_SINCE=''
        ;;
esac
ARENA_STATE_REVISION=$((ARENA_STATE_REVISION + 1))
ARENA_STATE_LAST_TRANSITION_AT="$(date +%s)"
ARENA_STATE_LAST_TRANSITION_ACTOR='human'
ARENA_STATE_LAST_TRANSITION_ACTION="resolve-${action}"
arena_state_write "$run_dir" \
    "schema_version=${ARENA_STATE_SCHEMA_VERSION}" "state_revision=${ARENA_STATE_REVISION}" \
    "run_status=${ARENA_STATE_RUN_STATUS}" "phase=${ARENA_STATE_PHASE}" \
    "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" "reason_code=${ARENA_STATE_REASON_CODE}" \
    "reason_detail=${ARENA_STATE_REASON_DETAIL}" "verdict=${ARENA_STATE_VERDICT}" \
    "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
    "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
    "waiting_since=${ARENA_STATE_WAITING_SINCE}" "last_transition_at=${ARENA_STATE_LAST_TRANSITION_AT}" \
    "last_transition_actor=${ARENA_STATE_LAST_TRANSITION_ACTOR}" "last_transition_action=${ARENA_STATE_LAST_TRANSITION_ACTION}" \
    "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
arena_lock_release "$lock_path" "resolve-$$"
arena_note "resolved ${action} for ${run_id}"
```

(arena.sh: add `escalate|resolve|repair-state` to the dispatcher case and the usage text. resume: creation-intent refusal + in-lock respawn per the spec traces.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 45 green.

- [ ] **Step 6: Commit**

```bash
git add lib/escalate.sh lib/resolve.sh lib/arena.sh lib/start.sh tests/run.sh
git commit -m "feat: escalate and resolve commands with T9-T13 transitions"
```

---

### Task 9: repair-state with intent protocol (T14)

**Files:** Create `lib/repair-state.sh`; Modify `lib/state.sh` (repair intent helpers, candidates); Test `tests/run.sh` (section 46).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '46. repair-state candidates and intent three-state recovery'
# conflict fixture: decision bound to a different SHA
rp_dir="${tmp_root}/repair-run"
mkdir -p "$rp_dir"
printf 'review_head\t%s\nreview_worktree\t%s\ncursor_policy_hash\t%s\ngate_wrapper_hash\t%s\ngate_adapter\tcursor\ngate_policy_path\t.cursor/cli.json\n' \
    '2222222222222222222222222222222222222222' "$project" "$(printf x | shasum -a 256 | awk '{print $1}')" "$(printf y | shasum -a 256 | awk '{print $1}')" >"${rp_dir}/review.tsv"
cp "$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -name manifest.tsv | head -1)" "${rp_dir}/manifest.tsv"
printf 'Review HEAD: 3333333333333333333333333333333333333333\nVERDICT: APPROVE\n' >"${rp_dir}/decision-3333333333333333333333333333333333333333.md"
# status prints a repair candidate
ARENA_SOURCE_ROOT="$source_root" ARENA_STATE_ROOT="$state_base" bash -c '
    set -euo pipefail
    source "$1/lib/state.sh"
    arena_state_project_legacy "$2" || true
' _ "$source_root" "$rp_dir" >"${tmp_root}/rp-proj.out" 2>&1
require_match 'repair-candidate' "${tmp_root}/rp-proj.out"
# stale token rejected
if run_arena repair-state repair-run --candidate deadbeefdeadbeef --reason 'x' >"${tmp_root}/rp.out" 2>&1; then
    fail 'repair-state accepted a stale token'
fi
require_match 'stale' "${tmp_root}/rp.out"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 46.

- [ ] **Step 3: Implement repair intent helpers and the command**

In `lib/state.sh`:

```bash
arena_repair_intent_write() {
    local run_dir="$1" baseline="$2" token="$3" reason="$4" target_digest="$5"
    local tmp_file
    tmp_file="$(mktemp "${run_dir}/.repair.intent.XXXXXX")"
    {
        printf 'baseline\t%s\n' "$baseline"
        printf 'token\t%s\n' "$token"
        printf 'reason\t%s\n' "$reason"
        printf 'target_digest\t%s\n' "$target_digest"
        printf 'move_map\t%s\n' "${ARENA_REPAIR_MOVE_MAP:-}"
    } >"$tmp_file"
    chmod 600 "$tmp_file"
    mv "$tmp_file" "${run_dir}/.repair.intent"
}

arena_repair_intent_read() {
    local run_dir="$1"
    local key value
    ARENA_REPAIR_BASELINE=''; ARENA_REPAIR_TOKEN=''; ARENA_REPAIR_REASON=''
    ARENA_REPAIR_TARGET_DIGEST=''; ARENA_REPAIR_MOVE_MAP=''
    while IFS=$'\t' read -r key value; do
        case "$key" in
            baseline) ARENA_REPAIR_BASELINE="$value" ;;
            token) ARENA_REPAIR_TOKEN="$value" ;;
            reason) ARENA_REPAIR_REASON="$value" ;;
            target_digest) ARENA_REPAIR_TARGET_DIGEST="$value" ;;
            move_map) ARENA_REPAIR_MOVE_MAP="$value" ;;
            *) arena_die "corrupted repair intent: unknown key $key" ;;
        esac
    done <"${run_dir}/.repair.intent"
}
```

`lib/repair-state.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena repair-state RUN_ID --candidate TOKEN --reason "..."

Accept a status-printed repair candidate. The token binds the evidence digest
and the current state baseline; stale or foreign tokens are rejected.
EOF
}

run_id=''
candidate=''
reason=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidate) [[ $# -ge 2 ]] || arena_die '--candidate requires a value'; candidate="$2"; shift 2 ;;
        --reason) [[ $# -ge 2 ]] || arena_die '--reason requires a value'; reason="$2"; shift 2 ;;
        --state-root) [[ $# -ge 2 ]] || arena_die '--state-root requires a value'; ARENA_STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) arena_die "unknown option: $1" ;;
        *) [[ -z "$run_id" ]] || arena_die 'provide RUN_ID once'; run_id="$1"; shift ;;
    esac
done
[[ -n "$run_id" && -n "$candidate" && -n "$reason" ]] || arena_die 'repair-state requires RUN_ID, --candidate, and --reason'
arena_validate_run_id "$run_id"
arena_validate_text "$reason" 'reason' 256
run_dir="$(arena_find_run_dir "$run_id")"
lock_path="${run_dir}/.run-lock"
arena_lock_acquire "$lock_path" "repair-$$"
if [[ -f "${run_dir}/.repair.intent" ]]; then
    arena_repair_intent_read "$run_dir"
    current_digest='absent'
    [[ -f "${run_dir}/run-state.tsv" ]] && current_digest="$(arena_file_hash "${run_dir}/run-state.tsv")"
    if [[ "$current_digest" == "$ARENA_REPAIR_BASELINE" || ( "$ARENA_REPAIR_BASELINE" == absent && ! -f "${run_dir}/run-state.tsv" ) ]]; then
        : # (a) original baseline: continue the sequence
    elif [[ "$current_digest" == "$ARENA_REPAIR_TARGET_DIGEST" ]]; then
        rm -f "${run_dir}/.repair.intent"
        arena_lock_release "$lock_path" "repair-$$"
        arena_note 'repair already committed; intent cleaned'
        exit 0
    else
        arena_lock_release "$lock_path" "repair-$$"
        arena_die 'repair intent does not match the current state; failing closed'
    fi
fi
# candidate validation (token recomputation per the spec payload rules), then:
# tombstone orphan evidence per the move map, write v1 state, remove intent.
arena_die 'candidate validation for this fixture is covered by the acceptance tests in section 46'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 46 green.

- [ ] **Step 5: Commit**

```bash
git add lib/repair-state.sh lib/state.sh tests/run.sh
git commit -m "feat: repair-state with intent three-state recovery"
```

---

### Task 10: status/list oracles and exit-code protocol

**Files:** Modify `lib/status.sh`, `lib/list.sh`; Test `tests/run.sh` (section 47).

- [ ] **Step 1: Write the failing test**

```bash
printf '%s\n' '47. status and list oracles'
# one-sentence diagnosis
or_run='or-run'
run_arena start "$or_run" --repo "$project" --no-attach >/dev/null
or_run_dir="$(find "${state_root}/runs" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv -path "*/${or_run}/manifest.tsv" -exec dirname {} \;)"
or_writer="$(manifest_value "${or_run_dir}/manifest.tsv" writer_worktree)"
printf '%s\n' o >"${or_writer}/o.txt"
git -C "$or_writer" add o.txt
git -C "$or_writer" commit -m 'feat: o' >/dev/null
run_arena submit "$or_run" >/dev/null
run_arena status "$or_run" >"${tmp_root}/or-status.out"
require_match 'waiting on reviewer for review_pending' "${tmp_root}/or-status.out"
# list fixed columns
run_arena list >"${tmp_root}/or-list.out"
require_match 'RUN_ID' "${tmp_root}/or-list.out"
require_match 'AUTHORITY' "${tmp_root}/or-list.out"
require_match 'ANOMALY' "${tmp_root}/or-list.out"
require_match 'or-run' "${tmp_root}/or-list.out"
# status/list never return 3 or 10
run_arena status "$or_run" >/dev/null 2>&1 || { ec=$?; [[ "$ec" == 3 || "$ec" == 10 ]] && fail "status returned $ec"; }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL at section 47.

- [ ] **Step 3: Implement**

In `lib/status.sh`, after the run-dir resolution:

```bash
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"
run_dir_parent="$(dirname "$run_dir")"
run_id_only="$(basename "$run_dir")"
# priority: live lock → creation intent → repair intent → ordinary parse
if arena_lock_is_held "${run_dir}/.run-lock" && arena_lock_owner_alive "${run_dir}/.run-lock"; then
    printf 'transition in progress\n'
    exit 4
fi
ARENA_CALLER=status
arena_state_precheck_intents "$run_dir" "$(basename "$run_dir_parent")" "$run_id_only" || exit $?
if [[ -f "${run_dir}/.repair.intent" ]]; then
    printf 'incomplete transition; retry: agent-arena repair-state %s --candidate <token> --reason "...\n' "$run_id_only"
    exit 5
fi
if [[ -f "${run_dir}/run-state.tsv" ]]; then
    arena_state_read "$run_dir"
    printf 'Run: %s\n' "$ARENA_STATE_RUN_STATUS"
    printf 'Phase: %s\n' "$ARENA_STATE_PHASE"
    printf 'Gate: %s\n' "$ARENA_STATE_VERDICT"
    # one-sentence diagnosis
    if [[ "$ARENA_STATE_RESPONSIBLE_PARTY" == none ]]; then
        printf 'state: %s; verdict: %s\n' "$ARENA_STATE_RUN_STATUS" "${ARENA_STATE_VERDICT:-none}"
    else
        session_name="$(awk -F $'\t' '$1 == "session_name" { print $2 }' "${run_dir}/manifest.tsv")"
        pane_line=''
        if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "=${session_name}" 2>/dev/null; then
            pane_line='tmux session: not running; '
        elif ! arena_find_live_pane "$session_name" reviewer reviewer-agent >/dev/null 2>&1; then
            pane_line='reviewer pane: unreachable; '
        fi
        release=''
        case "$ARENA_STATE_RESPONSIBLE_PARTY:$ARENA_STATE_REASON_CODE" in
            reviewer:review_pending) release="agent-arena validate ${run_id_only}" ;;
            reviewer:decision_pending) release="agent-arena decision ${run_id_only} --verdict ..." ;;
            human:approval_pending) release="agent-arena resolve ${run_id_only} --action approve|reject" ;;
            human:block_resolution_required) release="agent-arena resolve ${run_id_only} --action reject|cancel" ;;
            human:reviewer_unreachable) release="agent-arena resolve ${run_id_only} --action recover|cancel" ;;
            writer:*) release="writer continues; then agent-arena submit ${run_id_only}" ;;
        esac
        printf 'waiting on %s for %s since %s; %srelease: %s\n' \
            "$ARENA_STATE_RESPONSIBLE_PARTY" "$ARENA_STATE_REASON_CODE" \
            "${ARENA_STATE_WAITING_SINCE:-unknown}" "$pane_line" "$release"
    fi
else
    arena_state_project_legacy "$run_dir" || exit 2
    printf 'legacy / inferred, not persisted: %s / %s / %s\n' "$ARENA_PROJECTED_PHASE" "$ARENA_PROJECTED_PARTY" "$ARENA_PROJECTED_REASON"
fi
```

In `lib/list.sh`: add the fixed-column header `REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY`, iterate manifests sorted by `(repository, run_id)`, read state or project legacy (marking AUTHORITY), compute ANOMALY (corrupt/conflict/in-progress/incomplete), and aggregate the exit code per priority 5 > 4 > 2 > 0.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: section 47 green.

- [ ] **Step 5: Commit**

```bash
git add lib/status.sh lib/list.sh tests/run.sh
git commit -m "feat: status and list oracles with the exit-code protocol"
```

---

### Task 11: Regression sweep, docs, and release prep

**Files:** Modify `README.md`, `adapters/README.md` (state authority section), `docs/superpowers/specs/2026-08-13-run-state-authority.md` (status: review-ready); Test: full suites.

- [ ] **Step 1: Full regression**

Run: `bash tests/run.sh && bash tests/tmuxp-smoke.sh && bash tests/cli-contract-smoke.sh && bash packaging/package.sh --check && bash -n lib/*.sh adapters/*.sh`
Expected: all green (v0.3 sections 1–37 plus the adapted diagnostic-path assertion, sections 38–47).

- [ ] **Step 2: Document**

README: new "Run state" section (run-state.tsv, escalate/resolve/repair-state usage, status one-sentence diagnosis, exit codes). Spec frontmatter → `review-ready` with the drift note that implementation matches the spec's T-matrix.

- [ ] **Step 3: Commit**

```bash
git add README.md docs tests
git commit -m "docs: run state authority usage, oracles, and review-ready status"
```

---

## Self-review

- **Spec coverage:** AC1 → Task 4; AC2 → Task 5; AC3 → Task 6; AC4 → Task 7; AC5 → Task 8; AC6 → Task 8; AC7 → Tasks 5/6/8; AC8 → Tasks 3/5/7/8; AC9 → Task 9; AC10 → Tasks 2/4/6; AC11 → Tasks 5/6/7/9; AC12 → Task 10; AC13 → Task 11. Round-3 rules (priority checks, exit codes, tombstones, intent recovery) → Tasks 4/6/9/10. ✅
- **Placeholder scan:** Task 9 Step 3's `arena_die 'candidate validation ...'` line is a stub — it must be replaced during implementation by the full candidate-recomputation code from the spec's T14 payload rules (sixteen key=value placeholders, @reason/@revision/@now materialization); the acceptance test in section 46 pins the observable behavior. Flagged here so the implementer does not mistake the stub for the contract.
- **Type consistency:** `ARENA_STATE_*` field names, `arena_state_read/write/validate`, `arena_lock_acquire/release/is_held`, `arena_state_project_legacy`, `arena_state_precheck_intents`, `arena_repair_intent_write/read` are used consistently across tasks. Exit codes 0/1/2/3/4/5/10 match the spec protocol table.
