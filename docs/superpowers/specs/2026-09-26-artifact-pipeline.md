# Spec: Multi-Stage Artifact Pipeline (intent → spec → plan → implementation)

- Date: 2026-09-26
- Status: draft (awaiting approval) → planned for v0.7
- Reference: https://claude.com/blog/the-ai-native-sdlc-playbook (AI-Native SDLC playbook, Anthropic Applied AI)
- Upstream: https://jihulab.com/yh/zell-ai/zell-agent-core/-/work_items/325 (`--no-builtin-tools` pi-parity bug; not blocking)
- Walkthrough (3 rounds, validator passed 2026-09-26): `walkthrough/01-round1-user-stories.md` (18 paths, 21 ACs), `walkthrough/02-round2-technical-trace.md` (closed traces, F1-F8 resolutions), `walkthrough/03-round3-integration-check.md` (E2E + error matrix). Findings F1-F11 resolved; see §15 drift log.

## 1. Summary

Extend Agent Arena's run lifecycle with three upstream artifact stages —
**intent**, **spec**, **plan** — before the existing implementation phase
(writer/gate, unchanged). Each stage is a headless agent session bound to its
own `{adapter, model, role prompt}`, producing a versioned, SHA-locked
markdown artifact. Human gates accept (or reject) each artifact; the approved
artifacts travel into the repo with the writer's first commit so the reviewer
snapshot always contains the plan it must review the diff against.

The configuration surface requested by the product direction — role → agent →
provider → model — lands as per-stage defaults in `roles.conf`, editable per
project, and is surfaced in the dashboard TUI as a new-run wizard.

## 2. Background and alignment with the playbook

The AI-native SDLC playbook defines each stage as "ends by committing an
artifact; the next stage begins by reading it", with the commit chain as the
audit trail and human attention concentrated at the gates. Agent Arena already
implements this pattern downstream of Build (SHA-bound validation reports,
decision records, worktree isolation, mode-based autonomy). This spec imports
the same pattern upstream of Build:

| Playbook artifact | Arena artifact | Human gate |
|---|---|---|
| `intent.md` (originator's own words) | `intent.md` in the run dir | accept |
| `spec.md` (agent-generated requirements+design) | `spec.md` in the run dir | accept |
| `plan.md` (implementation plan) | `plan.md` in the run dir | accept |
| diff + tests + PR review | existing writer/gate loop | existing |

Traditional roles (PM, analyst, architect) are **not** new stateful role
instances; they are artifact-generation sessions plus human gates, per the
playbook's "roles are absorbed by artifacts" shift.

## 3. Decisions locked during discussion (2026-09-25/26)

1. **Artifact storage = hybrid (Option C).** Live generation/iteration in the
   run dir (state tree, Arena digest chain); human accept locks the SHA; the
   writer's **first commit** carries the accepted artifacts into the repo at
   `docs/arena/<run-id>/`. Rationale: the reviewer snapshot must contain
   `plan.md` for "review the diff against the plan" to work; cancelled runs
   leave zero residue in the repo; the single-writer principle is untouched
   (the writer remains the only committer).
2. **Repo `intent/` directory is an entry point, not the home.** Anyone may
   drop an `intent.md` there; `start --from-intent intent/foo.md` lifts it
   into a run. Untracked until the writer's first commit.
3. **No persistent role instances.** Stage config is `{adapter, model,
   prompt}` per artifact stage; verdict semantics (APPROVE /
   CHANGES_REQUESTED / BLOCKED) already cover stage review outcomes.
4. **Sandbox ownership = orchestration layer.** pi/zell intentionally ship
   tool-name gating only (`--tools` allowlist, core-enforced, verified
   identical to pi 0.84.3 semantics: filtered tools never reach the system
   prompt or agent loop, extension tools included in the same pool). Parameter
   level sandboxing (write-path allowlists) is deliberately out of scope for
   pi/zell; Arena provides OS-level sandboxing at spawn time (macOS seatbelt
   `sandbox-exec`, verified working; Linux bwrap deferred, see §11).
5. **No Claude-specific mechanisms are imported.** CLAUDE.md →
   `.agent-arena/context.md` injected into every stage session; skills →
   per-stage prompt template files referenced by `roles.conf`; hooks → the
   existing validation gate (plus artifact accept-time lint checks); merge
   triggers → Arena's own state machine.
6. **Rejected alternatives.** Option A (run-dir only) loses "reviewer
   snapshot contains the plan" and git-native audit; Option B (repo-only)
   conflicts with the single-writer principle and creates an intent graveyard
   for abandoned runs; Option D (multi-level gate) mismatches semantics —
   architecture review happens before a checkpoint exists.

## 4. Goals

- G1: Three new upstream stages with per-stage `{adapter, model, prompt}`
  configuration, digest-locked artifacts, and human accept/reject gates.
- G2: Zero behavior change when no `roles.conf` exists (default pipeline =
  implementation-only, identical to v0.6).
- G3: OS-sandboxed headless stage sessions on macOS; soft degradation with a
  loud warning where the sandbox tool is unavailable.
- G4: Dashboard TUI new-run wizard (`n`) covering repo, profile, pipeline
  depth, and per-stage model overrides.
- G5: JSON contracts grow without breaking v1 consumers (additive fields,
  `#[serde(default)]` on the Rust side).

## 5. Non-goals

- N1: Changing writer/gate adapters, mode semantics, or the existing keymap
  (except adding `n`).
- N2: Runtime switching of a run's writer/agent/model (evidence-chain
  immutability). Changing the model means a new run.
- N3: The maintenance loop (breached control band → new intent) — v0.8.
- N4: Cross-stage automatic back-jumps (spec reject lands on spec, not intent;
  humans may edit the intent draft manually and rerun spec).
- N5: Interactive stage sessions in tmux panes. Stage sessions are headless
  (`-p`); interactive polishing = human edits the draft file in the run dir,
  then accept re-hashes it.

## 6. Lifecycle and state machine

```
intake ──(start)──► intent ──accept──► spec ──accept──► plan ──accept──► implementation ──► submitted ──► validated ──► decided ──► completed
             ▲  ▲reject       ▲  ▲reject      ▲  ▲reject
             └──┘             └──┘           └──┘   (regenerate same stage, reject summary
                                                        injected into the next attempt's prompt)
```

- `pipeline` is a per-run value: the enabled stage sequence, e.g.
  `intent,spec,plan` (full), `intent` (lean), or empty (v0.6 behavior).
  Stages absent from `roles.conf`/`--pipeline` are skipped.
- New phase values: `intent`, `spec`, `plan`. During generation `party=none`
  and `reason_code=stage_generating`; while waiting for the human gate
  `party=human` and `reason_code=awaiting_stage_accept` with
  `waiting_since` set — the needs-human-first sort in the TUI applies
  unchanged.
- `cancel`, `escalate`, `resolve`, and recovery paths must cover the new
  phases (cancel from any stage removes the run dir; nothing reaches the
  repo, satisfying the graveyard concern).
- While a stage session is generating, a lock on the run dir rejects
  concurrent `stage`/`cancel` invocations (reuse `lib/lock.sh`).

## 7. Artifact lifecycle (Option C flow)

1. **Draft creation.** `arena stage RUN intent` (and `spec`/`plan`) spawns
   the stage session headlessly. The session reads the previous accepted
   artifact(s) and the repo (read-only), writes the draft into the run dir
   (`intent-draft.md` etc.), and its stdout JSON is retained under
   `sessions/` for audit. The prompt template plus `.agent-arena/context.md`
   (if present) form the appended system prompt. Intent input (walkthrough
   F1, Severe): `stage RUN intent` requires `--prompt-text T` or
   `--prompt-file F` — the originator's request in their own words; later
   stages take the previous artifact as input and need neither. The TUI
   wizard collects free text and passes it via `--prompt-file` (temp file).
2. **Human gate.** `arena artifact RUN --stage intent --accept` hashes
   `intent-draft.md` (sha256), renames it to `intent.md`, records
   `stage_intent_digest` + `stage_intent_accepted_at` + agent/model in the
   manifest, and advances the phase. `--reject --summary "..."` records the
   summary, keeps/creates the draft, and re-arms the same stage.
   Humans may edit the draft file between generation and accept; accept
   hashes what is actually on disk. Guards (walkthrough F6): accept refuses
   with exit 1 when the draft is missing or `--stage` does not match the
   current phase (`phase=X, cannot accept Y`). Next-step hint (walkthrough
   F2): accept never auto-spawns the next stage — every agent-spending
   action stays human-triggered, same principle as writer-invoked submit —
   but it prints the exact next command (`arena stage RUN spec`, or the
   bootstrap notice after the final stage) on stdout.
3. **Carry into the repo.** At `start` implementation time the writer
   worktree is seeded with accepted artifacts at
   `docs/arena/<run-id>/{intent,spec,plan}.md` (unstaged; idempotent copy).
   The writer's first
   checkpoint naturally commits them; the reviewer snapshot then contains the
   plan against which the diff is reviewed. Two-phase start (walkthrough
   F3): in pipeline mode `start` creates only the run dir + state (phase =
   first stage); worktree creation, the single-writer assertion, the dirty
   check, artifact seeding, and writer spawn are deferred to the
   implementation bootstrap triggered when the last stage is accepted
   (`arena_implementation_bootstrap` — the existing start.sh logic factored
   out; the dirty check running later is more correct, since hours may pass
   between start and plan accept). Non-pipeline (v0.6) behavior is
   byte-identical.
4. **Entry point.** `start RUN --repo P --from-intent intent/foo.md` copies
   the file into the run dir as the intent draft and enters the `intent`
   phase with `party=human` (the originator reviews their own intent before
   accept, matching the playbook). Validation (walkthrough F7): the file
   must be non-empty, at most 64 KB, and valid UTF-8; violations exit 1
   with the reason and path.

## 8. Configuration contract

Flat `KEY=VALUE` lines, consistent with the existing project conf. Two
scopes, later wins per key:

- Global defaults: `${ARENA_CONFIG_HOME:-~/.config}/agent-arena/roles.conf`
- Project override: `<repo>/.agent-arena/roles.conf`

Keys per stage (`<s>` ∈ `intent`, `spec`, `plan`):

| Key | Meaning | Default when absent |
|---|---|---|
| `<s>_adapter` | writer-capable adapter name (validated against adapters/) | stage disabled (skipped) |
| `<s>_model` | `--model` passthrough (also persisted in the manifest) | adapter default |
| `<s>_prompt` | prompt template file, resolved relative to the conf file's directory | built-in minimal template |

Parsing errors (unknown key, unknown adapter, missing prompt file) fail fast
with the conf path and line number. Adapter availability for stages is
gated by a new capability declaration:

```
headless_stage=true        # adapter supports -p/--print style one-shot runs
tool_gate=core-enforced    # adapter's tool allowlist is enforced in its core
```

zell declares both today (verified). cursor/opencode/pi/agy are verified in
the implementation gate; an adapter without the declaration is skipped for
stage sessions with a `doctor` warning.

## 9. Spawn protocol (stage sessions)

macOS, zell example (the reference implementation of this spec):

```
sandbox-exec -f <run>/sandbox.sb \
  zell -p --json \
       --tools read,write --no-extensions \
       --no-skills --no-prompt-templates --no-themes \
       --session-dir <run>/sessions --session-id arena-<run-id>-<stage>-a<attempt> \
       --provider <p> --model <m> \
       --append-system-prompt "<short role text>" \
       "@prompt-template" "@context.md (if present)" "@intent.md (prev artifact)" \
       "<stage instruction + run-dir write target>"
```

Gate 0 spike verified 2026-09-26 (live zell 0.4.0-rc.1, scratch repo):

- **Composition works**: `-p` x `--json` x `--tools read,write` x
  `--no-extensions` x fresh `--session-id` x `--session-dir` x
  `--append-system-prompt` x `@file` attachments — session ran, draft
  written from the attached requirement, session persisted under the run
  dir, exit 0.
- **Never resume an existing session id in `-p` mode** (upstream crash,
  jihulab 327: `free(@constCast)` bus error before any model call). Every
  attempt uses a fresh attempt-suffixed id
  `arena-<run-id>-<stage>-a<N>`; retries never continue a prior
  conversation (context re-enters via `@file` attachments: previous draft
  + reject summary). This also matches the evidence model — each attempt
  is a self-contained blob.
- **`--append-system-prompt` is text-only in zell** (pi also accepts file
  contents; zell does not). It carries the short role text only; the
  prompt template, `.agent-arena/context.md`, the previous artifact, and
  the requirement text travel as `@file` message attachments. The stage
  adapter contract (`headless_stage=true`) therefore includes "supports
  file attachment in the prompt message" — adapters without it fall back
  to composing a single text argument (argv-length bounded).
- **stdout is a JSONL event stream and is currently malformed upstream**
  (jihulab 326: every `tool_execution_end` line carries an extra trailing
  brace). Harvest contract stays: exit code + draft existence; stdout is
  saved verbatim under `sessions/` as an opaque blob and is never parsed.
- seatbelt profile: `(allow default)` + `(deny file-write*)` + allow-list
  `subpath` for the run dir and `${TMPDIR}` (realpath'd — macOS /tmp is
  /private/tmp). Verified live: sandboxed session completed (network,
  repo read, run-dir write all fine) while an instructed write into the
  repo returned `Error: PermissionDenied` from the OS layer.
- Environment hygiene: stage sessions inherit the same ARENA_* scrubbing
  rules as writer panes; `isolate_env` in the TUI already covers spawned
  children.

## 10. CLI and JSON contract changes

- New: `stage RUN <intent|spec|plan> [--prompt-text T | --prompt-file F]` —
  generate the next draft (runs the configured adapter headlessly; requires
  the run to be in that phase). Intent requires prompt input (F1); a
  running stage holds the run lock, and re-entry against a dead owner
  recovers the lock (`stage_<s>_recovered_at`, walkthrough F4) while a live
  owner is refused with the holder PID.
- New: `artifact RUN --stage <s> --accept | --reject --summary "..."`.
- New: `start ... [--from-intent FILE] [--pipeline LIST]` — `--pipeline`
  overrides config (`intent,spec,plan`, subsets, or `none`).
- `manifest`: `pipeline`, per-stage `status/digest/accepted_at/agent/model`
  keys (flat, consistent with existing style).
- `list --json` (schema stays 1): each run row gains an additive
  `"pipeline": [..]` and the phase column may now read `intent`/`spec`/
  `plan`. Rust model: `#[serde(default)]` additions only; existing tests
  keep passing byte-identically for v0.6-shaped runs.
- `status RUN --json`: additive `pipeline` block in `fields`.
- `cancel` gains one privilege (walkthrough F11): it may kill a hung stage
  session's PID and reclaim the run lock — cancel is already the
  destructive human-controlled operation. No hard stage timeout in v0.7
  (external `timeout` wrappers work); sessions record stdout under
  `sessions/` for diagnosis.
- Exit codes: new commands follow the existing pattern (0 ok, 1 usage,
  2 state/die).

## 11. Dashboard TUI changes

- New key `n`: new-run wizard (InputMode::Input sequence: run_id → repo →
  profile → pipeline depth (none/lean/full + explicit list) → per-stage
  model overrides as free text — no prefill in v0.7, hint line shows the
  roles.conf path, walkthrough F8) → confirm
  line with verbatim argv → spawn `bin/agent-arena start ...`. Destructive
  operations remain unmapped; the wizard only ever spawns documented
  subcommands (thin-client rule preserved).
- Run list rows: phase cell shows the artifact stages; a run waiting on a
  stage accept sorts as needs-human (existing `sort_runs` logic applies via
  party=human).
- Keymap contract, `ui/src/model.rs` unit tests, and the spec keymap table
  gain the `n` row; all other keys unchanged.

## 12. Acceptance criteria → test mapping (tests/run.sh sections)

| AC | Requirement | Test |
|---|---|---|
| AC1 | No roles.conf ⇒ v0.6-identical behavior end to end | new §62 regression run (full v0.6 flow assertions) |
| AC2 | roles.conf parse: global defaults, project override, unknown key/adapter fails fast with path+line | §63 (hermetic) |
| AC3 | `stage` spawns the sandboxed headless session with argv contract (`--tools read,write --no-extensions -p --json`, session id/dir, model passthrough) via a fake adapter binary | §64 (argv assertion) |
| AC4 | accept locks sha256 + timestamps + phase advance; reject re-arms the same stage with summary recorded; concurrency lock holds | §65 |
| AC5 | `start --from-intent` lifts the file, phase=intake→intent, party=human | §66 |
| AC6 | writer worktree seeded with `docs/arena/<run-id>/` accepted artifacts | §67 |
| AC7 | seatbelt profile denies writes outside the run dir (probe write fails); environments without sandbox-exec degrade with a visible warning and the test guards-skip | §68 (macOS local; skip-guarded) |
| AC8 | TUI `n` wizard argv assembly + keymap table updated; `q`/`Esc` cancels cleanly at every prompt step | cargo unit tests + §69 dispatch |
| AC9 | JSON v1 backward compatibility for v0.6-shaped manifests; additive fields present for pipeline runs | §61 extension + Rust `#[serde(default)]` tests |
| AC10 | cancel/escalate/resolve cover intent/spec/plan phases (including stage-generating lock) | §70 |
| AC11 | adapter without `headless_stage` capability: stage skipped (pipeline shrinks) + doctor advisory names adapter and missing declaration | §63 |
| AC12 | stage failure harvest: non-zero exit or missing draft ⇒ `stage_failed` + reason in manifest, lock released, retry works | §64 |
| AC13 | accept guards (draft missing, stage≠phase) and `--from-intent` validation (empty/oversized/non-UTF-8) all exit 1 with actionable messages | §65/§66 |
| AC14 | stale/hung stage lock: dead-owner recovery re-arms; cancel kills the holder and reclaims | §70 |
| Live | Real zell `-p` sessions complete intent→spec→plan on a scratch repo; human gates accepted via CLI; writer (live zell) first commit carries `docs/arena/<run-id>/`; TUI wizard creates a lean-pipeline run | Gate 4 live section in the plan doc |

## 13. Risks and mitigations

| Risk | Mitigation |
|---|---|
| ~~`zell -p` × `--session-id` composition unverified~~ | **Verified in Gate 0** (§9): fresh ids compose; resume crashes upstream (jihulab 327) — design avoids resume via attempt-suffixed ids |
| seatbelt `sandbox-exec` is deprecated by Apple | Works today (Gate 0 re-verified against a real zell session, not just `touch`); profile is data, not code — swappable for the container API later; absence degrades to warning + soft constraints, never silent |
| Stage generation quality depends on prompt templates | Templates live in the repo (reviewable); reject summary feeds the retry; live gate validates one full pass |
| State machine growth escalates recovery complexity | cancel/escalate/resolve coverage is AC10; run-dir-only artifacts keep cleanup atomic |
| JSON consumers break on new phases | Additive-only schema change + AC9 compatibility tests |
| zell `-nbt` bug (jihulab work item 325) slightly widens tool surface if extensions existed | Arena always passes `--no-extensions`, so no extension tools exist in stage sessions regardless |
| Stage stuck (agent hang, no exit) blocks on a live-held lock | cancel's kill privilege (F11) + dead-owner recovery (F4); escalate stays unchanged — reason-code set documented as not covering stage hangs (F9) |
| Upstream jihulab 326: `tool_execution_end` JSONL lines malformed | Non-blocking by design: Arena never parses stage stdout (exit code + draft existence + opaque blob) |
| Upstream jihulab 327: `-p` resume crashes on existing `--session-id` | Non-blocking by design: attempt-suffixed fresh ids per invocation; retry context re-enters via `@file` attachments |

## 14. Versioning and delivery

- Target release: v0.7.0. Docs: README section "Artifact pipeline" +
  RELEASE-NOTES; spec/plan under docs/superpowers/ dated 2026-09-26.
- Delivery order: ~~Gate 0 spike (zell -p × session flags; sandbox
  probe)~~ **done 2026-09-26** (§9, upstream bugs 326/327 filed, both
  designed around) → spec freeze → failing tests (§62–70 + cargo) → bash
  core (state machine, conf, stage/artifact commands, seeding) → TUI
  wizard → hermetic gates → tmuxp smoke → live gate → release.

## 15. Walkthrough drift log (2026-09-26)

Three-round walkthrough against the draft (validator passed). Resolutions
folded into the sections above; recorded here for audit:

| ID | Severity | Resolution | Where |
|---|---|---|---|
| F1 | Severe | intent input via `--prompt-text/--prompt-file`; TUI via temp file | §7.1, §10 |
| F2 | Major | accept prints next-command hint; no auto-spawn (human-triggered agent spend) | §7.2 |
| F3 | Major | two-phase start; `arena_implementation_bootstrap` at final accept; dirty check moves later | §7.3 |
| F4 | Major | dead-owner lock recovery reuses `arena_lock_owner_alive`; audit key `stage_<s>_recovered_at` | §10 |
| F5 | Minor | AC11 added (headless_stage skip + doctor advisory) | §12 |
| F6 | Minor | accept guards (draft missing, stage≠phase) | §7.2, AC13 |
| F7 | Minor | `--from-intent` validation (non-empty, ≤64KB, UTF-8) | §7.4, AC13 |
| F8 | Minor | wizard free-text model overrides, no prefill; `config --json` oracle deferred | §11 |
| F9 | Minor | escalate unchanged; stage-stuck → cancel/kill documented | §13 |
| F10 | Minor | authorship deferred — digest chain suffices for replay | backlog |
| F11 | Minor | cancel kills hung stage PID + reclaims lock | §10, AC14 |

No rollback plan change: the pipeline is additive behind config absence
(AC1 byte-identical v0.6 regression), so full rollback = remove roles.conf
/ stop passing `--pipeline`.

## 16. Gate 0 spike record (2026-09-26, live)

Scratch repo + real zell 0.4.0-rc.1 (`/Users/jakeliu/bin/zell`), three probes:

| Probe | Result | Design consequence |
|---|---|---|
| S1 full-argv composition | ✅ exit 0, draft from `@need.md` written, session persisted, clean stderr | Spawn protocol in §9 confirmed as-is |
| S2 resume with existing `--session-id` | ❌ Bus error (SIGABRT) before any model call; `free(@constCast(model.*))` in `restoreSessionSettings` (main.zig:2103) — jihulab 327 | Attempt-suffixed fresh session ids; retries re-enter context via `@file`; never resume |
| S3 seatbelt-wrapped real session | ✅ completed inside sandbox; run-dir write allowed; instructed repo write returned `Error: PermissionDenied` at OS layer | Profile shape `(allow default)+(deny file-write*)+subpath allowlist(run,TMPDIR)` locked (realpath'd) |

Side finding: `--json` stdout is JSONL and every `tool_execution_end` line
is malformed (extra `}`) — jihulab 326. Harvest already never parses
stdout, so non-blocking.

Also confirmed: `--append-system-prompt` is text-only in zell (pi accepts
files) — long content rides `@file` attachments (§9).
