---
status: review-ready
created: '2026-08-13'
owner: 'local owner'
---

# Agent Arena v0.2: Pluggable writer adapters

## Summary and scope

Add supported writer profiles `codex-cursor`, `opencode-cursor`, and
`gemini-cursor` beside `pi-cursor`. Each profile keeps Cursor as the sole
review/validation/decision gate. The selected writer alone receives the isolated
Git worktree; no profile introduces a second writer, automatic merge/push, or
dangerous permission bypass. Codex, OpenCode, and Gemini as reviewers are out of
scope until each has a separately verified immutable review-policy contract.

This specification is **review-ready**. It records the implemented v0.2
contracts and no-model validation evidence; it does not certify a provider's
authenticated live behavior or production safety. `complete` remains blocked
on the explicit manual smoke evidence described below.

## Profiles and operator usage

All profiles have the form `WRITER-cursor`: the selected CLI writes only in its
Arena-created writer worktree, while Cursor is the only agent permitted to make
the formal review, validation, and decision record. Direct tmux relays are
bidirectional advisory messages: the writer can report progress to Cursor, and
Cursor can send feedback or the next step to the writer. The persisted
SHA-bound validation report and decision are authoritative.

```bash
agent-arena doctor
agent-arena init --repo /path/to/project
agent-arena start RUN_ID --repo /path/to/project --profile pi-cursor
# Or choose: --profile codex-cursor | opencode-cursor | gemini-cursor
```

`doctor` reports a locally usable profile only when its executable and Cursor
are present. That is not proof of provider-side permission, sandbox, session, or
live-provider behavior. `start` fails closed before creating worktrees when the
selected profile or its required executable is unavailable.

| Profile | Intended writer launch discipline | Session and safety non-claims |
| --- | --- | --- |
| `pi-cursor` | Pi receives the Arena writer worktree, a private session directory, and a stable Arena session ID. | The prompt forbids integration-tree edits, merge, push, reset, and bypass flags; worktree isolation is not a general OS/network sandbox. |
| `codex-cursor` | Codex targets the writer worktree with `--sandbox workspace-write`, `--ask-for-approval on-request`, and `--no-alt-screen`. | Do not pass `--search`, `--add-dir`, or dangerous bypass flags. Codex has no creation-time Arena-owned session name/directory, so automatic resume must not be promised. |
| `opencode-cursor` | OpenCode targets the writer worktree in pure mode with a dedicated writer policy; project config and external skills are disabled where supported. | Never pass `--auto`. Its permissions are not an OS or network sandbox. Its session commands do not establish an Arena-owned creation/directory contract, so automatic resume remains unverified. |
| `gemini-cursor` | Gemini first `cd`s to the writer worktree, restricts extensions/MCP access, and uses `--approval-mode=auto_edit` only for writer edits. | Arena derives a private UUID for the initial session and publishes it only after clean exit; only then can a later launch use `--resume`. Interruption has no automatic-resume promise. Never pass `--worktree`, `--yolo`, or automatic `--skip-trust`; its built-in sandbox is not a no-network guarantee. |

Credentials remain in each provider's normal login, keychain, or environment
configuration. They must not be added to project configuration, a session
manifest, a relay message, or a tracked file.

## Walkthrough round 1: user stories and acceptance criteria

1. An operator can discover locally available writer profiles without starting a
   model.
2. An operator can start a named run with one selected writer and Cursor as the
   gate, for example `agent-arena start tui-sink --profile codex-cursor`.
3. A writer receives only its isolated worktree, run context, checkpoint command,
   and direct relay command; it must not receive an approval-bypass flag.
4. A Cursor gate receives exactly the writer's committed checkpoint and retains
   the existing validation and SHA-bound decision controls.
5. An auditor can identify the selected writer from the immutable run manifest
   and from relay labels.

| ID | Acceptance criterion | Test intent |
| --- | --- | --- |
| AC1 | `doctor` reports Cursor plus every detected writer and lists only profiles whose required CLIs exist. | fake-CLI doctor matrix |
| AC2 | Each supported profile selects its writer adapter, records `profile`, adapter, and label, and uses a writer-specific branch namespace. | lifecycle fixture for Pi/Codex/OpenCode/Gemini |
| AC3 | Unknown profiles or a missing selected writer fail before a worktree or tmux session is created. | negative profile/probe fixtures |
| AC4 | Every writer adapter launches in the isolated workspace with a fixed safety prompt and no force/yolo/dangerous-bypass flag. | fake-CLI argument assertions |
| AC5 | The writer pane dispatches the adapter recorded in the manifest; tmux role/mode and direct relay safety remain unchanged. | pane dispatch + tmuxp smoke |
| AC6 | Existing Pi manifests without v0.2 profile fields resolve as `pi-cursor` for read/resume compatibility. | legacy-manifest fixture |
| AC7 | A review submission, validation, and decision stay bound to the selected writer's clean committed HEAD. | existing gate regression under a non-Pi profile |
| AC8 | Cursor remains the only formal reviewer, validator, and decider for every writer profile; other provider CLIs cannot replace the immutable snapshot gate. | profile-to-Cursor gate regression |
| AC9 | Session metadata and resume behavior are explicit per provider; an unsupported automatic resume fails safely rather than selecting an unrelated local conversation. | fake-CLI initial/resume lifecycle fixtures |
| AC10 | The README and adapter metadata distinguish local CLI inspection from authenticated live-model testing and do not claim network isolation where a CLI does not provide it. | documentation and capability-output review |

## Walkthrough round 2: technical trace

`start --profile NAME` → profile resolver validates the `writer-cursor` mapping
→ selected adapter `probe` → clean integration root → writer-specific branch and
manifest → tmuxp exports the chosen adapter/session context → writer pane reads
the manifest and `exec`s that adapter in the isolated worktree. `submit` and the
remaining gate flow stay provider-neutral: clean writer HEAD → detached snapshot
→ Cursor policy → validation → decision → literal relay. `relay` reads the
manifest label so a message is visibly from Pi, Codex, OpenCode, or Gemini.

The manifest is the state boundary. New fields are profile, writer adapter, writer
label, and generic writer session directory. A legacy manifest missing those fields
defaults only to the established `pi-cursor` mapping. A resume request must match
the manifest profile rather than silently changing the writer of an existing run.
Provider state must stay private to the run and must never be reused across the
writer worktree and a detached Cursor review snapshot. If a provider cannot prove
that it is resuming the recorded conversation, the adapter fails closed rather
than attempting a "latest" resume. An operator can create an explicit new
run/session; the adapter must not silently select a provider conversation.

The formal path is intentionally provider-invariant:

```text
writer clean committed HEAD
  -> submit
  -> immutable detached review snapshot
  -> Cursor validation gate
  -> Cursor SHA-bound decision
  -> direct relay of the result/next step to the selected writer
```

No Codex, OpenCode, or Gemini profile may short-circuit this path by writing a
decision record, merging a branch, pushing, or treating an advisory relay as
approval.

## Walkthrough round 3: integration and errors

Missing `tmux`, `tmuxp`, Cursor, or the selected writer fails closed before
worktree creation. Unknown or mismatched profiles fail closed. A provider that
lacks deterministic session restoration must fail closed after its tmux session
is lost rather than selecting a `latest` conversation; its capability must be
explicit in the adapter metadata and tests. Prompt text and fake binaries are
untrusted test inputs; all arguments remain positional and quoted. The current
Cursor policy, review snapshot integrity checks, and relay uniqueness checks
remain mandatory.

## Testing, drift, risk, and rollback

Tests use temporary Git fixtures and fake executables only; local CLI checks are
`--help`/version/config parsing only and never make model or network requests.
The hermetic suite, tmuxp smoke, packaging test, and local CLI-contract smoke
passed on 2026-08-13. No authenticated live-model, provider-network, credential,
session-resume, or permission smoke test has been performed. Hermetic tests are
necessary but insufficient: they prove Arena's argument and lifecycle handling,
not the provider's behavior after authentication.

Drift: v0.2 expands writers, not gates, to preserve the Cursor control boundary.
Risk: provider CLI flags, policy semantics, trust behavior, or session storage can
change without an Arena source change. Additional risks are overclaiming a CLI
permission layer as OS/network isolation and resuming an unrelated conversation.
Rollback: select `pi-cursor` when it remains available, or remove/disable the
affected profile from the closed resolver. Existing worktrees, snapshots, reports,
and decisions remain untouched.

## Local CLI contract evidence and open validation

The following evidence is read-only: local binary version/help, bundled local
documentation, and configuration-source inspection. It is deliberately not a
live-model certification.

| Writer | Local evidence | Required open validation before release |
| --- | --- | --- |
| Pi | Existing adapter contract: worktree plus private session directory and stable session ID. | Hermetic session/relay/writer-dispatch regression passed; live provider smoke remains open. |
| Codex 0.146.0 | Interactive `-C`, `--sandbox workspace-write`, `--ask-for-approval on-request`, and `--no-alt-screen` are available. Creation-time session naming/directory is not. | Fake-CLI argument/cwd and no-automatic-resume coverage passed; manual permission smoke remains open. Codex is not a formal gate: read-only mode cannot write Arena records and workspace-write violates the immutable snapshot boundary. |
| OpenCode 1.18.15 | `--pure`, writer agent selection, project/external-skill disablement, and session-related commands are available; `--auto` is dangerous. No CLI OS sandbox was found. | Generated writer policy parse and fake-CLI launch contract passed; manual session behavior remains open. Do not equate policy permissions with network isolation. |
| Gemini 0.46.0 | `--approval-mode`, `--session-id`, `--resume`, `--extensions`, `--allowed-mcp-server-names`, and `--prompt-interactive` are available; there is no `--cwd`/`--workspace`. `--worktree` is experimental. | Fake initial/resume lifecycle and failed-initial-marker handling passed; trust-mode and harmless local sandbox smoke remain open. Bare `--sandbox` on macOS is not a no-network control. |

For formal review, validation, and decision, Cursor's generated local gate policy
and detached snapshot integrity checks remain mandatory. A provider writer's own
plan/read-only mode is advisory only; it does not authorize gate-record writes.
