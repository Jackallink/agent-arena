#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: bash packaging/uninstall.sh [--prefix DIR] [--alias arena] --yes

Move this version's launcher, optional alias, and installed source into a dated
backup. Nothing is permanently deleted. --yes is required because it changes an
installed command.
EOF
}

prefix="${HOME}/.local"
alias_name=''
confirmed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -ge 2 ]] || arena_die '--prefix requires a directory'
            prefix="$2"
            shift 2
            ;;
        --alias)
            [[ $# -ge 2 ]] || arena_die '--alias requires a name'
            alias_name="$2"
            shift 2
            ;;
        --yes)
            confirmed=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done

[[ "$confirmed" == 1 ]] || arena_die 'uninstall requires --yes'
[[ -z "$alias_name" || "$alias_name" == arena ]] || \
    arena_die 'only the optional alias name "arena" is supported'
arena_reject_control_characters "$prefix"
[[ -d "$prefix" ]] || arena_die "prefix does not exist: $prefix"
prefix="$(arena_abs_dir "$prefix")"
version="$(<"${source_root}/VERSION")"
share_dir="${prefix}/share/agent-arena"
backup_dir="${share_dir}/backups"
timestamp="$(date +%Y%m%d-%H%M%S)"
targets=("${prefix}/bin/agent-arena" "${share_dir}/${version}")
if [[ -n "$alias_name" ]]; then
    targets+=("${prefix}/bin/${alias_name}")
fi

arena_make_private_dir "$backup_dir"
moved=0
for target in "${targets[@]}"; do
    if [[ -e "$target" || -L "$target" ]]; then
        mv "$target" "${backup_dir}/$(basename "$target")-uninstalled-${timestamp}"
        moved=1
    fi
done
[[ "$moved" == 1 ]] || arena_die 'no matching Agent Arena installation was found'
arena_note "moved installation to $backup_dir"
