#!/usr/bin/env bash
set -euo pipefail

source_root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-arena-package-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

output_dir="${tmp_root}/dist"
prefix="${tmp_root}/prefix"
bash "${source_root}/packaging/package.sh" --output "$output_dir" --check
archive="${output_dir}/agent-arena-$(<"${source_root}/VERSION").tar.gz"
tar -tzf "$archive" | grep -Fqx "agent-arena-$(<"${source_root}/VERSION")/bin/agent-arena"
extract_root="${tmp_root}/extract"
mkdir -p "$extract_root"
tar -C "$extract_root" -xzf "$archive"
packaged_source="${extract_root}/agent-arena-$(<"${source_root}/VERSION")"

bash "${packaged_source}/packaging/install.sh" --prefix "$prefix"
"${prefix}/bin/agent-arena" version | grep -Fqx "$(<"${source_root}/VERSION")"
if bash "${packaged_source}/packaging/install.sh" --prefix "$prefix" >/dev/null 2>&1; then
    printf '%s\n' 'expected collision protection to reject reinstall' >&2
    exit 1
fi
bash "${source_root}/packaging/uninstall.sh" --prefix "$prefix" --yes
[[ ! -e "${prefix}/bin/agent-arena" && ! -L "${prefix}/bin/agent-arena" ]]
printf '%s\n' 'package test: ok'
