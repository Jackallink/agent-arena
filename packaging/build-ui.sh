#!/usr/bin/env bash
# Build the ui/ dashboard release binary for distribution targets and stage
# the archives into dist/. The bash-core release tarball (package.sh) ships
# ui/ as source; this script adds prebuilt binaries for hosts that want to
# skip the cargo step.
#
# Usage:
#   packaging/build-ui.sh [--check] [--linux-musl] [--host-only]
#
# Defaults to building the host target plus, when the toolchain target is
# installed, x86_64-unknown-linux-musl (statically linked, pure Rust — no
# zig or cargo-zigbuild involved).

set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"

usage() {
    cat <<'EOF'
Usage: packaging/build-ui.sh [--check] [--linux-musl] [--host-only]

  --check        Verify checksums of already-built dist artifacts and exit.
  --linux-musl   Also build the x86_64-unknown-linux-musl static binary.
  --host-only    Build only the host target (skip musl even if installed).
EOF
}

check_only=0
want_musl=0
host_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) check_only=1; shift ;;
        --linux-musl) want_musl=1; shift ;;
        --host-only) host_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'agent-arena: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

version="$(<"${source_root}/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'agent-arena: invalid VERSION: %s\n' "$version" >&2
    exit 2
}
dist_dir="${source_root}/dist"
output_dir="${source_root}/packaging/out"
mkdir -p "$dist_dir" "$output_dir"

verify_dist() {
    local archive="$1"
    local checksum="${archive}.sha256"
    [[ -f "$archive" && -f "$checksum" ]] || {
        printf 'agent-arena: missing dist artifact: %s\n' "$archive" >&2
        exit 2
    }
    (
        cd "$dist_dir" &&
            if command -v shasum >/dev/null 2>&1; then
                shasum -a 256 -c "$(basename "$checksum")"
            else
                sha256sum -c "$(basename "$checksum")"
            fi
    )
}

if [[ "$check_only" == 1 ]]; then
    for existing in "$dist_dir"/agent-arena-ui-"${version}"-*.tar.gz; do
        [[ -e "$existing" ]] || {
            printf 'agent-arena: no ui/ dist artifacts for %s\n' "$version" >&2
            exit 2
        }
        verify_dist "$existing"
    done
    printf 'agent-arena: verified ui/ artifacts for %s\n' "$version"
    exit 0
fi

command -v cargo >/dev/null 2>&1 || {
    printf 'agent-arena: cargo not found; install the Rust stable toolchain\n' >&2
    exit 2
}

host_target="$(rustc -vV | sed -n 's/^host: //p')"
[[ -n "$host_target" ]] || {
    printf 'agent-arena: cannot determine the rustc host target\n' >&2
    exit 2
}

targets=("$host_target")
if [[ "$host_only" == 0 ]] || [[ "$want_musl" == 1 ]]; then
    musl_target='x86_64-unknown-linux-musl'
    if [[ "$want_musl" == 1 ]]; then
        targets+=("$musl_target")
    elif rustup target list --installed 2>/dev/null | grep -Fqx "$musl_target"; then
        targets+=("$musl_target")
    fi
fi

for target in "${targets[@]}"; do
    printf 'agent-arena: building ui/ for %s\n' "$target"
    (cd "${source_root}/ui" && cargo build --release --locked --target "$target")
    binary="${source_root}/ui/target/${target}/release/agent-arena-ui"
    [[ -x "$binary" ]] || {
        printf 'agent-arena: build did not produce %s\n' "$binary" >&2
        exit 2
    }
    # The host binary must pass the oracle probe against an empty state
    # root (exits 0 with {"runs":[]}); cross targets cannot run here and
    # are checked for linkage instead.
    if [[ "$target" == "$host_target" ]]; then
        probe_state="$(mktemp -d "${TMPDIR:-/tmp}/arena-ui-probe.XXXXXX")"
        if ! "$binary" --selftest --state-root "$probe_state" >/dev/null 2>&1; then
            rm -rf "$probe_state"
            printf 'agent-arena: host ui/ binary failed the --selftest probe\n' >&2
            exit 2
        fi
        rm -rf "$probe_state"
    elif [[ "$target" == *musl* ]]; then
        if command -v file >/dev/null 2>&1; then
            file_output="$(file "$binary")"
            case "$file_output" in
                *'statically linked'*|*'static-pie'*) ;;
                *)
                    printf 'agent-arena: musl binary is not static: %s\n' "$file_output" >&2
                    exit 2
                    ;;
            esac
        fi
    fi
    archive="${dist_dir}/agent-arena-ui-${version}-${target}.tar.gz"
    checksum="${archive}.sha256"
    rm -f "$archive" "$checksum"
    stage_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-arena-ui-pkg.XXXXXX")"
    release_dir="${stage_root}/agent-arena-ui-${version}-${target}"
    mkdir -p "$release_dir"
    cp "$binary" "$release_dir/agent-arena-ui"
    chmod 755 "$release_dir/agent-arena-ui"
    tar -C "$stage_root" -czf "$archive" "agent-arena-ui-${version}-${target}"
    rm -rf "$stage_root"
    (
        cd "$dist_dir" &&
            if command -v shasum >/dev/null 2>&1; then
                shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
            else
                sha256sum "$(basename "$archive")" > "$(basename "$checksum")"
            fi
    )
    printf 'agent-arena: staged %s\n' "$archive"
done

printf 'agent-arena: ui/ artifacts ready in dist/\n'
