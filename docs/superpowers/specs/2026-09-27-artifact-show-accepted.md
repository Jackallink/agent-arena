# Spec: artifact --show covers accepted artifacts

- Date: 2026-09-27
- Status: draft → implemented (same day)
- Scope: `lib/artifact.sh`, `ui/src/model.rs`, `ui/src/main.rs`, `tests/run.sh` §76, README
- Context: `--show`/`o` only read the pre-gate draft (`<stage>-draft.md`).
  After accept the draft is renamed to `<stage>.md` and the phase moves
  on — the seeded artifact was unreadable from the dashboard exactly when
  reviewing it matters.

## 1. CLI resolution rule

`artifact RUN --stage S --show` (read-only, unchanged exclusivity):

1. `<stage>-draft.md` exists → print it (pre-gate / re-armed draft);
2. else `<stage>.md` exists → print it (accepted artifact);
3. else refuse naming the draft path.

Guard change: the `phase == stage` check (and the gate reason_code check)
apply to accept/reject only; `--show` requires an active run, the stage
being in the pipeline, and one of the two files. The phase-mismatch
message and ordering for accept/reject are byte-identical (§65 depends
on `phase=intent` firing before the pipeline-membership message).

## 2. TUI `o` resolution rule

- `awaiting_stage()` present → view that draft (title
  `<stage>-draft.md`) — unchanged;
- else the LAST accepted stage in manifest order (furthest progress) →
  view `<stage>.md` (title `<stage>.md`);
- else notice `no artifact to view`.

Viewer gains a filename field; argv builder unchanged (`--show` is
stage-keyed, the CLI owns file resolution).

## 3. Acceptance criteria → test mapping

| AC | Requirement | Test |
|---|---|---|
| AC-A1 | after accept, `--show` prints the accepted artifact | §76 CLI |
| AC-A2 | draft wins while present (re-armed stage shows its working draft) | §76 CLI |
| AC-A3 | `o` opens the accepted artifact with the `<stage>.md` title; nothing to view stays inert | §76 tmux + cargo |
| AC-A4 | accept/reject guard messages and order unchanged | §65 regression |
| AC-A5 | latest_accepted_stage picks the furthest accepted stage; None when absent | cargo unit tests |

## 4. Non-goals

- Rejected-draft history (superseded generations); the manifest records
  digests, the files are overwritten by regeneration.
- Viewing artifacts of completed (terminal) runs.
