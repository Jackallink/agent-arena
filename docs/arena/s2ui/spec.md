# Spec — s2ui: expose and render pipeline stage chains

## Scope

Extend the `status RUN --json` oracle output to include per-stage chain data
for pipeline runs, and render that chain in the TUI run detail view.

In scope:

- Add a top-level `stages` array to `status RUN --json` for pipeline runs.
- Order stage elements in manifest pipeline order: `intent`, `spec`, `plan`.
- Render the stage chain in the UI run detail view.
- Keep `stages` absent for non-pipeline runs and error-path documents.
- Keep `list --json` unchanged.

## Functional Requirements

### FR1 — Stage data in status JSON

`status RUN --json` for a pipeline run emits a top-level `stages` array.

Each element has shape:

```json
{"name": "<stage>", "status": "<manifest status>", "attempts": <int>}
```

AC1: For a pipeline run, `stages` contains one element per pipeline stage in
manifest order `intent -> spec -> plan`.

AC2: Each element's `name` matches the stage name; `status` is read verbatim
from the manifest key `stage_<name>_status`; `attempts` is read from
`stage_<name>_attempts` and is a JSON integer.

AC3: `status` values are limited to the stored manifest values `pending`,
`generating`, `awaiting_accept`, `accepted`, `failed`. No translation to
run-state reason codes (e.g. `awaiting_stage_accept` is not emitted as a stage
status).

AC4: For a non-pipeline run, the `stages` key is omitted.

AC5: For error-path documents, the `stages` key is omitted.

AC6: Output remains valid JSON with existing escaping rules intact.

AC7: `list --json` output is unchanged (no `stages` key).

### FR2 — TUI stage-chain rendering

The UI run detail view renders the chain for pipeline runs, for example:

```text
intent accepted -> spec awaiting_accept -> plan pending
```

AC8: The renderer joins stage name and status pairs with ` -> ` in manifest
pipeline order.

AC9: For documents without a `stages` key, the renderer produces no chain line
(or a compatible empty/absent representation) and does not error.

### FR3 — JSON contract and model compatibility

The v1 JSON contract stays strict-serde parseable. The UI model treats
`stages` as optional so older and error-path documents still parse.

AC10: Strict parsing accepts a document with a present `stages` array.

AC11: Strict parsing accepts a document where `stages` is absent.

### FR4 — Thin-client behavior preserved

AC12: The TUI reads only the oracle JSON and spawns only the existing
non-destructive CLI actions.

### FR5 — Compatibility and test hygiene

AC13: Shell code is Bash 3.2 / macOS-compatible, uses `set -euo pipefail`,
and contains no `eval`.

AC14: Tests are hermetic: no live model or network calls.

## Out of Scope

- Adding `stages` to `list --json`.
- Changing the v1 JSON contract or introducing v2.
- Translating stage statuses to run-state reason codes.
- New CLI actions or TUI actions beyond rendering existing JSON.
- Mutating or writing stage data from the TUI.

## Risks

- Contract drift: emitting `stages` on error paths could break strict parsers;
  mitigated by omitting the key on error-path documents and making it optional
  in the UI model.
- Field-name mismatch with manifest keys could silently return empty/zero
  values; mitigated by AC2/AC3 verification against stored keys and values.
- Rendering regressions in the TUI if a non-pipeline document is treated as a
  pipeline run; mitigated by AC9 strict-parse handling of absence.
- Test gate regressions if `cargo test` in `ui/` is not updated for both
  present and absent `stages`; covered by AC10/AC11.

## Validation Gates

- `bash tests/run.sh`
- `bash tests/tmuxp-smoke.sh`
- `bash packaging/package.sh --check`
- `cargo test` in `ui/`
