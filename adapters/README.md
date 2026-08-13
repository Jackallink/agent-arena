# Adapter contract

Every adapter is an executable Bash script with:

```text
adapter.sh probe
adapter.sh capabilities
adapter.sh launch
```

`probe` must only inspect local availability. `capabilities` prints stable,
line-oriented capability flags. `launch` receives all paths through `ARENA_*`
environment variables and must `exec` the provider CLI. It never creates a Git
worktree, runs project validation, manages credentials, merges, pushes, or enables
dangerous bypass flags.

The orchestration layer owns worktree isolation and decisions. New providers are
marked planned until a fake-CLI test, safe permission smoke test, session/resume
test, and relay test have been added.
