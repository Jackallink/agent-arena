---
status: draft
created: '2026-08-15'
owner: 'local owner'
drift: none (spec precedes implementation; §61 tests written first per the plan)
---

# Agent Arena v0.7: Dashboard TUI (ui/ companion, thin client)

## Summary and scope

A standalone TUI companion in a new `ui/` subdirectory (Rust + Ratatui,
cargo workspace of its own) that gives an operator a multi-run monitoring
and action surface. The bash
core gains machine-readable oracle exits (`list --json`, `status RUN --json`)
that the TUI — and any future UI — consumes. The UI is a **thin client**: it
reads only the JSON oracles and acts only by spawning existing CLI subcommands.

In scope: JSON oracle contract (v1), `ui/` skeleton (build, model, selftest,
interactive v0), `agent-arena dashboard` dispatch, `ui/AGENTS.md` local rules.

Out of scope: Web UI (rejected — see decisions), remote/multi-host aggregation,
libvaxis (withdrawn 2026-09-25 — Ratatui landed and needs nothing it offers;
no follow-up spec will be written), destructive ops in the UI (cancel,
repair-state, reset are never offered).

## Decisions

- **TUI/CMD over Web** (2026-08-15): users are terminal-native; the operated
  agents already live in tmux panes (pane jump-in is native); Web adds a
  runtime dependency, a daemon lifecycle, an HTTP attack surface, and a
  rendering-vs-oracle dual-truth risk.
- **Rust + Ratatui over Zig** (2026-08-15, supersedes the earlier
  Zig-stdlib draft decision): (a) toolchain stability — the only local Zig is
  `0.17.0-dev`, the exact compiler that produced zell's live use-after-free
  panic today; Rust's stability guarantee makes the UI layer zero-drift;
  (b) framework maturity — Ratatui + crossterm is the Rust TUI de-facto
  standard and ships the exact widgets this dashboard needs (Table, List,
  layout constraints, event loop, diff rendering, resize); (c) serde
  (deny_unknown_fields) doubles as the strictest JSON-contract validator;
  (d) distribution via a static musl single binary — ratatui/crossterm are
  pure Rust, so `rustup target add x86_64-unknown-linux-musl` with the
  self-contained musl linker suffices; no zig/cargo-zigbuild involved.
- **One UI only**: no parallel bash tmux dashboard. `--json` is the contract
  layer either way.
- **JSON on stdout, humans on stderr**: for both oracle commands, `--json`
  prints a JSON document to stdout on every exit path (including error exits,
  which carry an `error` field); stderr keeps the existing human diagnostics.
  Exit codes are unchanged.

## JSON contract v1

- `agent-arena list --json` →
  `{"schema":1,"generated_at":<ts>,"runs":[{ run_id, repository, profile,
  gate, mode, run_status, phase, party, reason_code, waiting_since, authority,
  anomaly }]}`. Fields mirror the fixed columns of `list` exactly; `anomaly`
  is `""` when none. `waiting_since` is a number or null.
- `agent-arena status RUN_ID --json` → `{"schema":1,"run_id":...,"fields":{
  <every human status line as key:value>},"panes":{"reviewer":bool,
  "writer":bool},"error":null|"corrupt"|"incomplete"|...}`. Keys are the
  snake_cased counterparts of the existing status lines (mode, verdict,
  validation_result, last_transition_at, integrity, review_head, ...). On the
  error exits (2/4/5) stdout still carries the JSON with `error` set; exit
  codes stay 0/1/2/4/5.
- Escaping: every string value passes `arena_json_escape` (lib/json.sh):
  backslash, double quote, and control characters escaped per RFC 8259
  (`\u00XX` for C0). Fields are otherwise controlled values (validated text,
  enums, SHAs, integers).

## UI thin-client contract

- Reads: `bin/agent-arena list --json` (poll, interval ≥2s, or on keypress),
  `bin/agent-arena status RUN --json` for the selected run.
- Acts: a static keymap table — the only permitted actions, each a verbatim
  CLI invocation shown on the confirm line before spawn:
  | Key | Action | CLI |
  | a | approve | `resolve RUN --action approve` |
  | r | request changes | `decision RUN --verdict CHANGES_REQUESTED --summary | next ...` (prompted; the CLI verdicts are APPROVE/CHANGES_REQUESTED/BLOCKED — there is no REJECT; `resolve --action reject` is the human-only escalation path) |
  | d | decision approve | `decision RUN --verdict APPROVE --summary ...` (prompted) |
  | l | relay writer | `relay RUN --to writer --message ...` (prompted) |
  | m | toggle mode | `mode RUN auto` / `mode RUN human` |
  | v | validate | `validate RUN` |
  | Enter | jump pane | `tmux select-window -t SESSION` (writer pane focus) |
  | q | quit | — |
- Never offered: cancel, repair-state, reset, merge, push, bypass flags.
- The keymap table is the tested contract: Rust unit tests (`cargo test`)
  assert the argv each key produces; bash tests assert the CLI accepts those
  argv forms.

## ui/ skeleton

- `ui/Cargo.toml` (ratatui, crossterm, serde/serde_json with
  `deny_unknown_fields`) + `ui/src/main.rs` (event loop, alternate screen) +
  `ui/src/model.rs` (JSON→runs model, needs-human-first ordering, keymap
  table — pure, unit-tested) + `ui/src/agent.rs` (Command wrapper; only ever
  execs `bin/agent-arena`).
- Non-interactive probe: `agent-arena-ui --selftest [ARGS...]` spawns the CLI
  once, parses, renders one frame to stdout, exits 0/1 — this lets the bash
  hermetic suite cover the UI's entire data path without a pty.
- Interactive v0: run list with needs-human-first highlight, j/k selection,
  keymap actions with confirm line, status pane for the selected run.
- `agent-arena dashboard`: execs the UI binary if present, else dies with the
  build hint (`cd ui && cargo build --release`).

## ui/AGENTS.md local rules

- Stable Rust channel pinned in `rust-toolchain.toml`; `cargo fmt` clean,
  `cargo clippy -- -D warnings` and `cargo test` green before handoff.
- No async runtime; the loop is crossterm-event-driven.
- No direct reads of state roots: every byte of data enters through the CLI
  subprocess. No process spawns other than `bin/agent-arena` and `tmux`
  (jump-in).

## Acceptance criteria and test mapping

| AC | Requirement | Test |
| --- | --- | --- |
| j1 | `list --json` schema: fields, escaping, exit codes, anomaly/legacy rows | §61 |
| j2 | `status --json` on ok/corrupt/ambiguous paths: JSON on stdout with `error`, exit unchanged, stderr human text intact | §61 |
| j3 | JSON escaping: quotes/backslashes/control chars in repository paths survive round-trip (read-only manifest fixture; `start` refuses quoted tmuxp paths by design) | §61 |
| u1 | model layer: parse, needs-human-first ordering, keymap argv | cargo test (strict serde) |
| u2 | `--selftest` data path against a fake state root | §61 (bash) |
| u3 | `dashboard` dispatch: exec when present (tty refused when stdin is not a terminal), die with build hint otherwise | §61 |
| u4 | full gates stay green; bash core untouched without the UI binary | full suite |

## Validation matrix

| Gate | Evidence | Status |
| --- | --- | --- |
| JSON contract | §61 (`tests: ok`, 62 sections) | done |
| UI model/selftest | cargo test 5 passed + `--selftest` probe in §61 | done |
| Full regression | tests/run.sh, tmuxp-smoke, package.sh --check, bash -n | done |
| Interactive smoke | headless tmux session `arena-tui-smoke`: render, confirm line, prompted input, staged decision argv, cancel paths, real spawn with terminal suspend/restore, clean exit (see plan Gate 4) | done |
