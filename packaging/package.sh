#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: bash packaging/package.sh [--output DIR] [--check]

Create a tar.gz and SHA-256 checksum. Publishing a release artifact still requires
the applicable specification's Gate 4 evidence and release notes.
EOF
}

output_dir="${source_root}/dist"
check_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || arena_die '--output requires a directory'
            output_dir="$2"
            shift 2
            ;;
        --check)
            check_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done

version="$(<"${source_root}/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || arena_die "invalid VERSION: $version"
arena_reject_control_characters "$output_dir"
mkdir -p "$output_dir"
output_dir="$(arena_abs_dir "$output_dir")"

release_name="agent-arena-${version}"
archive="${output_dir}/${release_name}.tar.gz"
checksum="${archive}.sha256"

verify_archive() {
    tar -tzf "$archive" | grep -Fqx "${release_name}/bin/agent-arena" || \
        arena_die 'archive is missing the main command'
    tar -tzf "$archive" | grep -Fqx "${release_name}/LICENSE" || \
        arena_die 'archive is missing the MIT license'
    tar -tzf "$archive" | grep -Fqx "${release_name}/templates/tmuxp/arena.yaml" || \
        arena_die 'archive is missing the tmuxp template'
    if command -v shasum >/dev/null 2>&1; then
        (cd "$output_dir" && shasum -a 256 -c "$(basename "$checksum")")
    else
        (cd "$output_dir" && sha256sum -c "$(basename "$checksum")")
    fi
}

if [[ -e "$archive" || -L "$archive" || -e "$checksum" || -L "$checksum" ]]; then
    if [[ "$check_only" == 1 && -f "$archive" && -f "$checksum" ]]; then
        verify_archive
        arena_note "verified $archive"
        exit 0
    fi
    arena_die "refusing to overwrite archive or checksum: $archive"
fi

required=(
    AGENTS.md LICENSE LICENSE-STATUS.md README.md VERSION .gitignore
    adapters bin docs examples lib packaging templates tests
)
for path in "${required[@]}"; do
    [[ -e "${source_root}/${path}" ]] || arena_die "missing package content: $path"
done

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-arena-package.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
release_dir="${stage_root}/${release_name}"
mkdir -p "$release_dir"
tar -C "$source_root" -cf - "${required[@]}" | tar -C "$release_dir" -xf -
tar -C "$stage_root" -czf "$archive" "$release_name"

if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive" >"$checksum"
else
    sha256sum "$archive" >"$checksum"
fi

if [[ "$check_only" == 1 ]]; then
    verify_archive
fi

arena_note "built $archive"
arena_note "checksum $checksum"
