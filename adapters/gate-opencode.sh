#!/usr/bin/env bash
# Temporary Task 1 stub; the real OpenCode gate adapter replaces this in Task 5.
set -euo pipefail

case "${1:-}" in
    probe) exit 0 ;;
    capabilities)
        printf '%s\n' 'policy_path=opencode.json' 'wrapper_path=.agent-arena-gate'
        ;;
    launch)
        printf '%s\n' "gate-launch $*" >>"${FAKE_GATE_LOG:-/dev/null}"
        ;;
    policy)
        printf 'policy\topencode.json\t%s\n' \
            '2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881'
        printf 'wrapper\t.agent-arena-gate\t%s\n' \
            '2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881'
        ;;
esac
