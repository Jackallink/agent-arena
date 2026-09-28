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
  stage RUN_ID <intent|spec|plan> [--prompt-text T | --prompt-file F]
                                Generate the next artifact draft (headless,
                                sandboxed stage session)
  artifact RUN_ID --stage S (--accept | --reject --summary T)
                                Human gate over the generated artifact draft
  resume RUN_ID [--repo PATH]    Attach or recreate an existing run
  submit RUN_ID                  Freeze the writer's committed checkpoint for review
  validate RUN_ID                Run the project-defined validation gate
  decision RUN_ID [options]      Record the gate's formal decision
  escalate RUN_ID                Raise a stuck reviewer-bound run to human
  resolve RUN_ID                 Human disposition: approve, reject, recover, cancel
  relay RUN_ID [options]         Send a direct, literal agent-pane message
  repair-state RUN_ID [options]  Accept a status-printed repair candidate
  mode RUN_ID human|auto         Switch a live run's approval mode
  autopilot [options]            Auto-approve and alert; --once for cron
  status RUN_ID [--json]         Show manifest, validation, and decision state
  list [--json]                  List all recorded runs with their state
  dashboard                      Launch the ui/ Rust TUI (built on demand)
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
    doctor|init|start|stage|artifact|submit|validate|decision|escalate|resolve|relay|repair-state|mode|autopilot|status|list)
        exec "${source_root}/lib/${command_name}.sh" "$@"
        ;;
    dashboard)
        # The TUI lives in ui/ as a standalone Rust binary; it is a pure
        # consumer of the --json oracle layer and never bypasses the
        # subcommand surface (docs/superpowers/specs/2026-08-15-dashboard-tui.md).
        # Lookup order: the source tree's own builds first (dev loop), then
        # a PATH-installed agent-arena-ui (install.sh --with-ui or a dist
        # tarball unpacked onto PATH).
        dashboard_bin=''
        for candidate in \
            "${source_root}/ui/target/debug/agent-arena-ui" \
            "${source_root}/ui/target/release/agent-arena-ui"; do
            if [[ -x "$candidate" ]]; then
                dashboard_bin="$candidate"
                break
            fi
        done
        if [[ -z "$dashboard_bin" ]] && command -v agent-arena-ui >/dev/null 2>&1; then
            dashboard_bin="$(command -v agent-arena-ui)"
        fi
        if [[ -z "$dashboard_bin" ]]; then
            if [[ -f "${source_root}/ui/Cargo.toml" ]]; then
                arena_die "dashboard binary missing; build it first: (cd ui && cargo build)"
            fi
            arena_die "dashboard binary missing; install it with: bash packaging/install.sh --with-ui <agent-arena-ui binary> (or put agent-arena-ui on PATH)"
        fi
        # README promises a bare `agent-arena dashboard`: the UI binary
        # requires a state root explicitly, so inject the CLI's default
        # (env-aware) when the caller did not pass one.
        if [[ " $* " != *" --state-root "* ]]; then
            set -- "$@" --state-root "$(arena_state_root)"
        fi
        exec "$dashboard_bin" "$@"
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
