# Dashboard TUI implementation plan

## Gate record

- Gate 1 — spec audit: **complete**. `../specs/2026-08-15-dashboard-tui.md`
  records the TUI-over-Web decision, the Rust+Ratatui-over-Zig decision, the
  JSON contract v1, and the thin-client keymap.
- Gate 2 — TDD kickoff: **complete**. §61 written first and confirmed
  failing (`list --json exited 1` with `--json` unimplemented; dashboard
  dispatch and cargo steps failed for their own reasons as they were
  reached).
- Gate 3 — drift check: **complete** (see Drift and lessons below; all
  62 sections §0–61 green, `tests: ok`).
- Gate 4 — release gate: **pending** (interactive smoke open; v0.6.x).

## Tasks

1. **§61 failing tests (bash)**: `list --json` schema/escaping/exits; `status
   --json` ok + error paths (JSON on stdout, `error` field, exit unchanged);
   `dashboard` dispatch (missing binary → die with build hint; present →
   selftest probe runs).
2. **Implement bash contract layer**: `lib/json.sh` (`arena_json_escape`),
   `list --json`, `status --json` (all existing exit paths emit JSON to
   stdout), `bin/agent-arena dashboard` dispatch.
3. **ui/ skeleton (Rust + Ratatui)**: `Cargo.toml` + `rust-toolchain.toml` (stable),
   `src/model.rs` (serde strict parse + ordering + keymap argv table, unit
   tests), `src/agent.rs` (Command wrapper), `src/main.rs` (`--selftest`
   probe + interactive v0 alternate-screen loop), `ui/AGENTS.md`.
4. **Wire §61**: `--selftest` probe against a fake state root; keymap argv
   asserted by cargo tests and cross-checked by bash (CLI accepts the mapped
   forms — already covered by §37/§47/§51 suites).
5. **Full gates + commit** (`feat: dashboard tui (ui/ companion + json oracles)`).

## Gate 2/3 evidence

- §61 first run: `test failure: list --json exited 1` (flag unimplemented) —
  failing-first confirmed. Subsequent failures each exposed exactly one
  contract gap until green.
- Final run: `tests: ok` (62 sections), `tmuxp smoke: ok`,
  `package.sh --check OK`, `bash -n` clean over bin/lib/adapters.
- UI selftest probe (§61): `cargo test --quiet` 5 passed; `cargo build`;
  `agent-arena-ui --selftest --state-root <state_base>` exit 0 printing the
  needs-human-first digests including `run-one`.

## Drift and lessons (Gate 3)

1. **`set -e` + command substitution + explicit exit inside `if`**: the first
   `arena_list_row_json` wrapper called `arena_list_fields` bare; its
   non-zero return (2/4/5) killed the row subshell via `set -e`, so corrupt
   rows silently vanished from `list --json`. Fixed with
   `local row_exit=0; arena_list_fields ... || row_exit=$?`. Worse: the
   corrupt-row probe itself (`if arena_state_read ...`) never worked for
   list — `arena_state_die` is an explicit `exit 2`, which an `if` condition
   does not catch. Fixed with a subshell probe
   (`( arena_state_read "$run_dir" )`) before the real read that must keep
   `ARENA_STATE_*` in this shell. Lesson: `if` guards return codes, never
   explicit exits; probe in a subshell when you need both outcomes.
2. **`require_match` is `grep -F` (literal)** — third occurrence of this
   lesson family: `'\"runs\":\[\\]'` never matches a literal JSON array.
   Regex-shaped assertions must use `grep -Eq` directly; §61 now uses
   literal strings only.
3. **Bash `${VAR:-{}}` swallows a brace**: the `}` inside the default value
   terminates the expansion, so `"panes":${PANES:-{}}` emitted a stray `}`.
   Use a temporary variable with an explicit empty check.
4. **`config_line_re` regex must live in a variable**: bash re-tokenizes
   inline `=~` patterns; `[^"\\\\]`-style classes are unreadable inline and
   broke once during writing. Variable-held POSIX ERE + init-side escaping
   (`\"`, `\\`) + parse-side unescaping fixed quoted repository names end to
   end. Note: `start` still refuses tmuxp-bound paths containing quotes by
   design, so the JSON-escape test (j3) exercises a hand-built manifest via
   the read-only list path instead of a full start.
5. **A test can create ambiguous run ids**: the dual-project fixture left
   two `run-one` manifests under one state root, so `status run-one --json`
   exited 1 with the usage die. §61 now disambiguates via the inherited
   `ARENA_RUN_DIR` (a supported calling form) *and* locks the
   ambiguous-lookup behavior (`exit 1` + `"error":"unknown"` on stdout).
6. **A dashboard binary in the test PATH can hijack a terminal**: once
   `ui/target/debug/agent-arena-ui` existed, `run_arena dashboard` inside
   tests exec'd the real TUI and blocked on `event::read()` against the
   test's tty. Fixed twice over: the TUI fails fast on a non-tty stdin
   (`crossterm::tty::IsTty` guard), and §61 runs `dashboard` with
   `</dev/null` plus a positive assertion that the non-tty path is refused.
7. **Toolchain reality**: local stable is 1.85.1 (nightly is 1.95.0-nightly);
   per `ui/AGENTS.md` (stable only) the new-MSRV transitive deps were
   downgraded (`instability 0.3.14 → 0.3.7`) instead of touching the global
   toolchain.

## Assertion-update list

- `list`/`status` gain `--json`; human output byte-identical without the flag.
- `bin/agent-arena` gains the `dashboard` command; `help` updated.
- `init`/`config` escape project_name values (`\"`, `\\`) for conf round-trip.
- No state-file, manifest-schema, or exit-code changes.
