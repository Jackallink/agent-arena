#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: bash packaging/install.sh [--prefix DIR] [--alias arena] [--force]

Install a private local copy under PREFIX (default: ~/.local). The main command is
`agent-arena`; `arena` is optional because it is a generic name. Existing targets
are never overwritten unless --force is supplied; forced replacements are moved to
a timestamped backup under PREFIX/share/agent-arena/backups.
EOF
}

prefix="${HOME}/.local"
force=0
alias_name=''
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
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done

[[ -z "$alias_name" || "$alias_name" == arena ]] || \
    arena_die 'only the optional alias name "arena" is supported'
arena_reject_control_characters "$prefix"
mkdir -p "$prefix"
prefix="$(arena_abs_dir "$prefix")"
bin_dir="${prefix}/bin"
share_dir="${prefix}/share/agent-arena"
version="$(<"${source_root}/VERSION")"
release_dir="${share_dir}/${version}"
command_path="${bin_dir}/agent-arena"
alias_path="${bin_dir}/${alias_name}"
backup_dir="${share_dir}/backups"
timestamp="$(date +%Y%m%d-%H%M%S)"

for target in "$release_dir" "$command_path"; do
    if [[ -e "$target" || -L "$target" ]]; then
        [[ "$force" == 1 ]] || arena_die "target exists (rerun with --force): $target"
    fi
done
if [[ -n "$alias_name" && ( -e "$alias_path" || -L "$alias_path" ) ]]; then
    [[ "$force" == 1 ]] || arena_die "alias exists (rerun with --force): $alias_path"
fi

mkdir -p "$bin_dir" "$share_dir"
if [[ "$force" == 1 ]]; then
    arena_make_private_dir "$backup_dir"
    for target in "$release_dir" "$command_path"; do
        if [[ -e "$target" || -L "$target" ]]; then
            mv "$target" "${backup_dir}/$(basename "$target")-${timestamp}"
        fi
    done
    if [[ -n "$alias_name" && ( -e "$alias_path" || -L "$alias_path" ) ]]; then
        mv "$alias_path" "${backup_dir}/${alias_name}-${timestamp}"
    fi
fi

stage_dir="$(mktemp -d "${share_dir}/.install.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
required=(AGENTS.md LICENSE LICENSE-STATUS.md README.md VERSION .gitignore adapters bin docs examples lib packaging templates tests)
tar -C "$source_root" -cf - "${required[@]}" | tar -C "$stage_dir" -xf -
mv "$stage_dir" "$release_dir"

tmp_command="$(mktemp "${bin_dir}/.agent-arena.XXXXXX")"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${release_dir}/bin/agent-arena" >"$tmp_command"
chmod 755 "$tmp_command"
mv "$tmp_command" "$command_path"
if [[ -n "$alias_name" ]]; then
    ln -s agent-arena "$alias_path"
fi

arena_note "installed $command_path"
if [[ ":${PATH}:" != *":${bin_dir}:"* ]]; then
    arena_note "add ${bin_dir} to PATH to call agent-arena without its full path"
fi
