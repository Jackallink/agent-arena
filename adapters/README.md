# Adapter contract

Every adapter is an executable Bash script with:

```text
adapter.sh probe
adapter.sh capabilities
adapter.sh launch
```

`probe` must only inspect local availability. `capabilities` prints stable,
line-oriented capability flags. `launch` receives all paths through `ARENA_*`
environment variables and normally `exec`s the provider CLI. An adapter may wait
for a provider's successful initial exit only when it must atomically publish
verified session state; Gemini's first-session marker is the v0.2 exception. It
never creates a Git worktree, runs project validation, manages credentials,
merges, pushes, or enables dangerous bypass flags.

The orchestration layer owns worktree isolation and decisions. A provider is a
writer only unless its independent formal-gate policy is verified. In v0.2, Pi,
Codex, OpenCode, and Gemini are writer adapters; Cursor remains the only formal
review, validation, and decision gate. Every enabled provider needs fake-CLI,
explicit safety/session, and relay coverage before it is advertised as supported;
authenticated provider-permission behavior remains a separate release smoke.
