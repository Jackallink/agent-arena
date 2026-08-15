#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena COMMAND [RUN_ID] [options]

Commands:
  doctor                         Check required tools and adapter availability
  init [--repo PATH]             Add a minimal project adapter without overwrite
  start RUN_ID [--repo PATH]     Create/resume a writer + gate tmuxp run
  resume RUN_ID [--repo PATH]    Attach or recreate an existing run
  submit RUN_ID                  Freeze the writer's committed checkpoint for review
  validate RUN_ID                Run the project-defined validation gate
  decision RUN_ID [options]      Record the gate's formal decision
  escalate RUN_ID                Raise a stuck reviewer-bound run to human
  resolve RUN_ID                 Human disposition: approve, reject, recover, cancel
  relay RUN_ID [options]         Send a direct, literal agent-pane message
  repair-state RUN_ID [options]  Accept a status-printed repair candidate
  status RUN_ID                  Show manifest, validation, and decision state
  list                           List all recorded runs with their state
  version                        Print the Agent Arena version
  help                           Show this help

Use `agent-arena COMMAND --help` for command-specific options.
EOF
}

command_name="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$command_name" in
    doctor|init|start|submit|validate|decision|escalate|resolve|relay|repair-state|mode|autopilot|status|list)
        exec "${source_root}/lib/${command_name}.sh" "$@"
        ;;
    resume)
        [[ $# -ge 1 ]] || arena_die 'resume requires RUN_ID'
        run_id="$1"
        shift
        ARENA_RESUME=1 exec "${source_root}/lib/start.sh" --run-id "$run_id" "$@"
        ;;
    version|--version|-V)
        <"${source_root}/VERSION" tr -d '\n'
        printf '\n'
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        arena_die "unknown command: $command_name"
        ;;
esac
