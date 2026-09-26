#!/usr/bin/env bash
# Agent Arena deterministic gate: syntax, unit tests, lints, full suite.
set -euo pipefail
source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail=0
for f in "$source_root"/lib/*.sh "$source_root"/adapters/*.sh "$source_root"/bin/agent-arena "$source_root"/tests/run.sh "$source_root"/packaging/*.sh; do
    bash -n "$f" || fail=1
done
if (( fail )); then
    printf '%s\n' 'bash -n failed' >&2
    exit 1
fi
( cd "$source_root/ui" && cargo test --quiet >/dev/null ) || exit 1
( cd "$source_root/ui" && cargo clippy --quiet -- -D warnings >/dev/null 2>&1 ) || exit 1
ARENA_TEST_SKIP_HEAVY="${ARENA_TEST_SKIP_HEAVY:-0}"
if [[ "$ARENA_TEST_SKIP_HEAVY" != 1 ]]; then
    bash "$source_root/tests/run.sh" >/dev/null 2>&1 || exit 1
fi
printf '%s\n' 'agent-arena gate: PASS'
