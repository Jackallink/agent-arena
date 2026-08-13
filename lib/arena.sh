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
  start RUN_ID [--repo PATH]     Create/resume a Pi + Cursor tmuxp run
  resume RUN_ID [--repo PATH]    Attach or recreate an existing run
  submit RUN_ID                  Freeze Pi's committed checkpoint for review
  validate RUN_ID                Run the project-defined validation gate
  decision RUN_ID [options]      Record Cursor's formal decision
  relay RUN_ID [options]         Send a direct, literal agent-pane message
  status RUN_ID                  Show manifest, validation, and decision state
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
    doctor|init|start|submit|validate|decision|relay|status)
        exec "${source_root}/lib/${command_name}.sh" "$@"
        ;;
    resume)
        [[ $# -ge 1 ]] || arena_die 'resume requires RUN_ID'
        run_id="$1"
        shift
        exec "${source_root}/lib/start.sh" --run-id "$run_id" "$@"
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
