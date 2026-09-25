# ui/ local rules

Scope: the Rust TUI companion (`ui/`). The root `AGENTS.md` bash rules do not
apply to `ui/` sources; these rules do.

- Toolchain: **stable** Rust only (no nightly features); record the channel in
  `rust-toolchain.toml`. `cargo fmt` clean, `cargo clippy -- -D warnings` and
  `cargo test` green before handoff.
- Dependencies: `ratatui`, `crossterm`, `serde`/`serde_json` (with
  `deny_unknown_fields` on every contract struct). Any new dependency needs a
  spec-level justification; no async runtime — the loop is
  crossterm-event-driven with a poll timeout.
- Thin-client discipline (hard rule): every byte of Arena data enters through
  `bin/agent-arena list --json` / `status RUN --json`; every action is a
  spawn of a documented CLI subcommand from `src/model.rs`'s keymap table.
  Never read state roots, manifests, or run-state files directly. The only
  spawnable programs are `bin/agent-arena` and `tmux`.
- Destructive operations (cancel, repair-state, reset, merge, push, bypass
  flags) are never mapped.
- Style: `snake_case`, no `unwrap()` outside tests; keep `src/model.rs` free
  of I/O so it stays unit-testable; errors propagate as typed enums at the
  boundary only.
- Tests: `cargo test` covers model + keymap; the data path is smoke-tested
  via `--selftest` from the bash suite (§61), not by hand.
