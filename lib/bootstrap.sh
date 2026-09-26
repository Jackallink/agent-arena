#!/usr/bin/env bash
set -euo pipefail

source_root="${ARENA_SOURCE_ROOT:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${source_root}/lib/common.sh"
source "${source_root}/lib/state.sh"
source "${source_root}/lib/lock.sh"

# Implementation bootstrap (spec 2026-09-26 §7.3): the deferred half of the
# two-phase start. The final stage accept calls this; it creates the writer
# worktree, records base_sha/writer_worktree/branch in the run manifest,
# seeds docs/arena/<run-id>/<stage>.md from the accepted artifacts into the
# worktree (Option C hybrid storage: the writer's first commit carries them,
# so the reviewer snapshot always contains the plan), and lands the run in
# the v0.6 intake phase.
#
# Lock ordering mirrors start.sh: parent lock → run lock. The caller must
# NOT hold the run lock (artifact.sh releases before calling). Idempotent:
# an already-bootstrapped run is a no-op success (crash recovery).
arena_implementation_bootstrap() {
    local run_dir="$1"
    local run_id repository repo_id worktree_root profile
    local writer_adapter writer_label gate_adapter session_name
    local branch base_sha writer_root writer_worktree repo_runs_dir
    local parent_lock run_lock seeded stage seed_target state_was
    local -a seeded_files=()

    arena_read_manifest "$run_dir"
    arena_state_read "$run_dir"
    run_id="$ARENA_MANIFEST_RUN_ID"
    repository="$ARENA_MANIFEST_REPOSITORY"
    worktree_root="$ARENA_MANIFEST_WORKTREE_ROOT"
    profile="$ARENA_MANIFEST_PROFILE"
    writer_adapter="$ARENA_MANIFEST_WRITER_ADAPTER"
    writer_label="$ARENA_MANIFEST_WRITER_LABEL"
    gate_adapter="$ARENA_MANIFEST_GATE_ADAPTER"
    session_name="$ARENA_MANIFEST_SESSION_NAME"

    if [[ -n "$ARENA_MANIFEST_WRITER_WORKTREE" ]]; then
        printf 'implementation already bootstrapped: %s\n' "$ARENA_MANIFEST_WRITER_WORKTREE"
        return 0
    fi

    "${source_root}/adapters/${writer_adapter}.sh" probe || \
        arena_die "${writer_label} executable not found for profile $profile"
    "${source_root}/adapters/gate-${gate_adapter}.sh" probe || \
        arena_die "gate adapter is not available: ${gate_adapter}"

    # The deferred dirty check (walkthrough F3): hours may pass between
    # start and the final accept, so integration cleanliness is asserted
    # here, immediately before the worktree forks from HEAD.
    arena_assert_clean_worktree "$repository"
    git -C "$repository" rev-parse --verify HEAD >/dev/null 2>&1 || \
        arena_die 'integration worktree needs an initial commit before bootstrapping implementation'
    base_sha="$(git -C "$repository" rev-parse HEAD)"
    arena_profile_resolve "$profile"
    branch="$(arena_profile_branch "$writer_adapter" "$run_id")"
    git show-ref --verify --quiet "refs/heads/${branch}" && \
        arena_die "branch already exists without a matching bootstrap: $branch"
    repo_id="$(arena_repo_id "$repository")"
    writer_root="${worktree_root}/${repo_id}/${run_id}"
    writer_worktree="${writer_root}/writer"
    [[ ! -e "$writer_worktree" && ! -L "$writer_worktree" ]] || \
        arena_die "writer worktree path already exists: $writer_worktree"

    repo_runs_dir="$(dirname "$run_dir")"
    parent_lock="${repo_runs_dir}/.parent-lock"
    arena_lock_acquire "$parent_lock" "bootstrap-$$"
    arena_make_private_dir "$writer_root"
    git -C "$repository" worktree add -b "$branch" "$writer_worktree" "$base_sha"
    arena_lock_release "$parent_lock" "bootstrap-$$"

    arena_lock_acquire "${run_dir}/.run-lock" "bootstrap-$$"
    arena_manifest_upsert "$run_dir" \
        'base_sha' "$base_sha" \
        'writer_worktree' "$writer_worktree" \
        'branch' "$branch"
    # Seed the accepted artifacts (Option C): every stage in the pipeline
    # with an accepted artifact on disk rides into the worktree under
    # docs/arena/<run-id>/ as UNTRACKED files — the writer's first commit
    # adopts them, so the reviewer diff later always contains the plan.
    for stage in intent spec plan; do
        [[ ",$ARENA_MANIFEST_PIPELINE," == *",$stage,"* ]] || continue
        [[ -f "${run_dir}/${stage}.md" ]] || continue
        seed_target="${writer_worktree}/docs/arena/${run_id}/${stage}.md"
        mkdir -p "$(dirname "$seed_target")"
        cp "${run_dir}/${stage}.md" "$seed_target"
        seeded_files+=("docs/arena/${run_id}/${stage}.md")
    done
    arena_state_defaults
    ARENA_STATE_REVISION=$(( ARENA_STATE_REVISION + 1 ))
    arena_state_write "$run_dir" \
        "schema_version=${ARENA_STATE_SCHEMA_VERSION}" \
        "state_revision=${ARENA_STATE_REVISION}" \
        "run_status=${ARENA_STATE_RUN_STATUS}" \
        "phase=${ARENA_STATE_PHASE}" \
        "responsible_party=${ARENA_STATE_RESPONSIBLE_PARTY}" \
        "reason_code=${ARENA_STATE_REASON_CODE}" \
        "reason_detail=${ARENA_STATE_REASON_DETAIL}" \
        "verdict=${ARENA_STATE_VERDICT}" \
        "validation_result=${ARENA_STATE_VALIDATION_RESULT}" \
        "checkpoint_round=${ARENA_STATE_CHECKPOINT_ROUND}" \
        "checkpoint_sha=${ARENA_STATE_CHECKPOINT_SHA}" \
        "waiting_since=${ARENA_STATE_WAITING_SINCE}" \
        "last_transition_at=$(date +%s)" \
        "last_transition_actor=human" \
        "last_transition_action=bootstrap" \
        "validation_digest=${ARENA_STATE_VALIDATION_DIGEST}"
    arena_lock_release "${run_dir}/.run-lock" "bootstrap-$$"

    printf 'implementation bootstrapped for %s\n' "$run_id"
    printf '  worktree: %s\n' "$writer_worktree"
    printf '  branch: %s (base %s)\n' "$branch" "$(arena_short_sha "$base_sha")"
    for seeded in "${seeded_files[@]}"; do
        printf '  seeded: %s\n' "$seeded"
    done
    printf 'next: agent-arena start %s --repo %s\n' "$run_id" "$repository"
}
