#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: agent-arena init [--repo PATH]

Create <repo>/.agent-arena/project.conf and validate.sh. This command refuses to
overwrite either file; edit the validation stub after initialization.
EOF
}

repository='.'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            [[ $# -ge 2 ]] || arena_die '--repo requires a path'
            repository="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) arena_die "unknown option: $1" ;;
    esac
done

[[ -d "$repository" ]] || arena_die "repository path does not exist: $repository"
repository="$(arena_abs_dir "$repository")"
git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    arena_die "not a Git repository: $repository"
[[ "$(git -C "$repository" rev-parse --show-toplevel)" == "$repository" ]] || \
    arena_die '--repo must be the Git worktree root'

adapter_dir="${repository}/.agent-arena"
config="${adapter_dir}/project.conf"
validation="${adapter_dir}/validate.sh"
[[ ! -e "$config" && ! -L "$config" ]] || arena_die "refusing to overwrite: $config"
[[ ! -e "$validation" && ! -L "$validation" ]] || arena_die "refusing to overwrite: $validation"

mkdir -p "$adapter_dir"
repository_name="$(basename "$repository")"
{
    printf '%s\n' '# Project adapter for Agent Arena.'
    printf 'project_name="%s"\n' "$repository_name"
    printf 'validation_script=".agent-arena/validate.sh"\n'
} >"$config"
cat >"$validation" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Replace this stub with deterministic checks for this repository, for example:
# npm test
# cargo test
# zig build test
printf '%s\n' 'Configure .agent-arena/validate.sh for this project.' >&2
exit 2
EOF
chmod 755 "$validation"
arena_note "created $config"
arena_note "created $validation; edit it, run it locally, then commit both files"
