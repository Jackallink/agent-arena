#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena list [--state-root PATH]

List every recorded run with its profile and derived state. This command makes
no changes; it reads only run manifests and pointer files.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-root)
            [[ $# -ge 2 ]] || arena_die '--state-root requires a path'
            ARENA_STATE_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done

runs_root="$(arena_state_root)/runs"
if [[ ! -d "$runs_root" ]]; then
    arena_note 'no runs recorded'
    exit 0
fi

found=0
while IFS= read -r manifest; do
    [[ -n "$manifest" ]] || continue
    run_dir="$(dirname "$manifest")"
    run_id="$(awk -F $'\t' '$1 == "run_id" { print $2 }' "$manifest" | head -1)"
    repository="$(awk -F $'\t' '$1 == "repository" { print $2 }' "$manifest" | head -1)"
    profile="$(awk -F $'\t' '$1 == "profile" { print $2 }' "$manifest" | head -1)"
    [[ -n "$run_id" ]] || run_id='<unreadable>'
    # v0.1 manifests carry no profile field; they are Pi-only by definition.
    [[ -n "$profile" ]] || profile='pi-cursor'
    [[ -n "$repository" ]] || repository='<unreadable>'
    status='RUNNING'
    [[ -f "${run_dir}/review.tsv" ]] && status='SUBMITTED'
    [[ -f "${run_dir}/validation.md" ]] && status='VALIDATED'
    [[ -f "${run_dir}/decision.md" ]] && status='DECIDED'
    printf '%-24s %-16s %-12s %s\n' "$run_id" "$profile" "$status" "$repository"
    found=1
done < <(find "$runs_root" -mindepth 3 -maxdepth 3 -type f -name manifest.tsv 2>/dev/null | sort)
[[ "$found" == 1 ]] || arena_note 'no runs recorded'
