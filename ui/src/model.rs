//! Pure contract layer: JSON document types, needs-human-first ordering,
//! and the keymap → argv table. No I/O lives here, so every rule is unit
//! testable (see the tests at the bottom and `cargo test`).
//!
//! Thin-client rule (ui/AGENTS.md): the only data sources are
//! `agent-arena list --json` and `agent-arena status RUN --json`; the only
//! actions are `agent-arena` subcommand spawns. Destructive subcommands
//! (cancel, repair-state, reset, merge, push, bypass) are never mapped.

use serde::Deserialize;

/// One row of `agent-arena list --json` (JSON contract v1).
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RunSummary {
    pub run_id: String,
    pub repository: String,
    #[serde(default)]
    pub profile: String,
    #[serde(default)]
    pub gate: String,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub run_status: String,
    #[serde(default)]
    pub phase: String,
    #[serde(default)]
    pub party: String,
    #[serde(default)]
    pub reason_code: String,
    #[serde(default)]
    pub waiting_since: String,
    #[serde(default)]
    pub authority: String,
    #[serde(default)]
    pub anomaly: String,
    /// Artifact-pipeline stages (v0.7 additive JSON field); None for
    /// v0.6-shaped runs that carry no pipeline key.
    #[serde(default)]
    pub pipeline: Option<Vec<String>>,
}

impl RunSummary {
    /// A run waits on the human when it is active, reviewer-bound, and has
    /// no transition anomaly (anomalies surface first regardless).
    pub fn needs_human(&self) -> bool {
        self.anomaly.is_empty()
            && self.run_status == "active"
            && !self.party.is_empty()
            && self.party != "none"
    }

    /// One-line digest used by both the selftest output and the TUI list.
    pub fn digest(&self) -> String {
        format!(
            "{}  {}  {}  {}  {}",
            self.run_id, self.run_status, self.phase, self.party, self.anomaly
        )
    }
}

/// `agent-arena list --json` document.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListDoc {
    pub schema: u32,
    #[allow(dead_code)]
    pub generated_at: i64,
    pub runs: Vec<RunSummary>,
}

/// The `panes` block of `agent-arena status RUN --json`. Error-path
/// documents emit `"panes":{}` (pane liveness is unknown there), so both
/// fields default to false instead of failing the strict parse — the
/// contract stays parseable on every exit path.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Panes {
    #[serde(default)]
    pub reviewer: bool,
    #[serde(default)]
    pub writer: bool,
}

/// One element of the `stages` array in a pipeline-run status document
/// (additive v1 JSON field; absent for non-pipeline and error-path docs).
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StageStatus {
    pub name: String,
    pub status: String,
    pub attempts: u64,
}

/// `agent-arena status RUN --json` document. `fields` stays open (the
/// bash oracle owns the key set); everything else is strict.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusDoc {
    #[allow(dead_code)]
    pub schema: u32,
    pub run_id: String,
    pub fields: serde_json::Map<String, serde_json::Value>,
    /// Pipeline stage chain (additive v1 field). None for non-pipeline
    /// runs and error-path documents; present docs stay strict.
    #[serde(default)]
    pub stages: Option<Vec<StageStatus>>,
    pub panes: Panes,
    #[allow(dead_code)]
    pub error: Option<String>,
}

impl StatusDoc {
    /// Convenience accessor for the fields the TUI renders directly.
    pub fn field_str(&self, key: &str) -> Option<&str> {
        self.fields.get(key).and_then(|v| v.as_str())
    }

    /// Render the pipeline stage chain in manifest order, e.g.
    /// `intent accepted -> spec awaiting_accept -> plan pending`. None
    /// when the document carries no `stages` array (non-pipeline runs,
    /// error-path documents) or the array is empty — the renderer then
    /// draws no chain line and does not error.
    pub fn stage_chain(&self) -> Option<String> {
        let stages = self.stages.as_ref()?;
        if stages.is_empty() {
            return None;
        }
        Some(
            stages
                .iter()
                .map(|s| format!("{} {}", s.name, s.status))
                .collect::<Vec<_>>()
                .join(" -> "),
        )
    }

    /// The artifact gate target: the first stage in manifest order whose
    /// status is `awaiting_accept`. None when the document carries no
    /// stages array, or no stage is awaiting the human gate.
    pub fn awaiting_stage(&self) -> Option<&str> {
        self.stages
            .as_ref()?
            .iter()
            .find(|s| s.status == "awaiting_accept")
            .map(|s| s.name.as_str())
    }

    /// The furthest accepted stage in manifest order (post-gate review
    /// target). None when nothing has been accepted yet.
    pub fn latest_accepted_stage(&self) -> Option<&str> {
        self.stages
            .as_ref()?
            .iter()
            .rev()
            .find(|s| s.status == "accepted")
            .map(|s| s.name.as_str())
    }
}

/// Parse `list --json` output strictly (unknown keys are a contract drift
/// and must fail loudly).
pub fn parse_list(json: &str) -> Result<ListDoc, String> {
    serde_json::from_str(json).map_err(|e| format!("list --json contract violation: {e}"))
}

/// Parse `status RUN --json` output strictly.
pub fn parse_status(json: &str) -> Result<StatusDoc, String> {
    serde_json::from_str(json).map_err(|e| format!("status --json contract violation: {e}"))
}

/// Sort runs for display: needs-human first, then anomalies, then the
/// composite (repository, run_id) order the oracle already guarantees.
pub fn sort_runs(runs: &mut [RunSummary]) {
    runs.sort_by(|a, b| {
        let key = |r: &RunSummary| {
            if r.needs_human() {
                0u8
            } else if !r.anomaly.is_empty() {
                1
            } else {
                2
            }
        };
        key(a)
            .cmp(&key(b))
            .then_with(|| a.repository.cmp(&b.repository))
            .then_with(|| a.run_id.cmp(&b.run_id))
    });
}

/// Actions the TUI can take. Each maps to exactly one non-destructive
/// `agent-arena` subcommand spawn (or the tmux pane jump).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // JumpWriterPane is matched in main.rs inline (Enter key)
pub enum Action {
    Approve,
    Reject,
    DecisionApprove,
    RelayWriter,
    ToggleMode,
    Validate,
    NewRun,
    ArtifactAccept,
    ArtifactReject,
    ViewArtifact,
    JumpWriterPane,
    Quit,
}

/// Keymap contract: one key, one action, no hidden aliases.
pub fn keymap_action(key: char) -> Option<Action> {
    match key {
        'a' => Some(Action::Approve),
        'r' => Some(Action::Reject),
        'd' => Some(Action::DecisionApprove),
        'l' => Some(Action::RelayWriter),
        'm' => Some(Action::ToggleMode),
        'v' => Some(Action::Validate),
        'n' => Some(Action::NewRun),
        'g' => Some(Action::ArtifactAccept),
        'G' => Some(Action::ArtifactReject),
        'o' => Some(Action::ViewArtifact),
        'q' => Some(Action::Quit),
        _ => None,
    }
}

/// New-run wizard steps (spec 2026-09-26 §11): run_id → repo → profile →
/// pipeline depth → models (advisory only, walkthrough F8: v0.7 never
/// carries model overrides in argv — roles.conf is the single source) →
/// confirm. Empty input skips optional flags; the run id is required.
pub enum WizardStep {
    RunId,
    Repo,
    Profile,
    Pipeline,
    Models,
    Done,
}

pub struct RunWizard {
    pub step: WizardStep,
    pub run_id: String,
    pub repo: String,
    pub profile: String,
    pub pipeline: String,
}

impl Default for RunWizard {
    fn default() -> Self {
        Self::new()
    }
}

impl RunWizard {
    pub fn new() -> Self {
        RunWizard {
            step: WizardStep::RunId,
            run_id: String::new(),
            repo: String::new(),
            profile: String::new(),
            pipeline: String::new(),
        }
    }

    /// The roles.conf hint line (walkthrough F8): model overrides live in
    /// roles.conf, not in wizard argv.
    fn roles_hint() -> String {
        let home = std::env::var("HOME").unwrap_or_default();
        let config_home = std::env::var("ARENA_CONFIG_HOME")
            .unwrap_or_else(|_| format!("{home}/.config"));
        format!("{config_home}/agent-arena/roles.conf (+ <repo>/.agent-arena/roles.conf)")
    }

    pub fn hint(&self) -> String {
        match self.step {
            WizardStep::RunId => {
                "new run: RUN_ID > (Enter next · Esc cancel)".to_string()
            }
            WizardStep::Repo => format!(
                "new run: repo path (empty = current dir) > roles.conf: {} · Esc cancel",
                Self::roles_hint()
            ),
            WizardStep::Profile => {
                "new run: writer-gate profile (empty = pi-cursor) > (Enter next · Esc cancel)"
                    .to_string()
            }
            WizardStep::Pipeline => {
                "new run: pipeline none|lean|full|intent,spec,plan (empty = roles.conf default) > (Enter next · Esc cancel)"
                    .to_string()
            }
            WizardStep::Models => format!(
                "new run: model overrides (advisory — configure {}) > (Enter next · Esc cancel)",
                Self::roles_hint()
            ),
            WizardStep::Done => "new run: ready".to_string(),
        }
    }

    /// Advance one step. A validation error keeps the step and explains
    /// itself on the notice line.
    pub fn submit(&mut self, text: &str) -> Result<(), String> {
        let text = text.trim();
        match self.step {
            WizardStep::RunId => {
                if text.is_empty() {
                    return Err("new run: RUN_ID is required".to_string());
                }
                self.run_id = text.to_string();
                self.step = WizardStep::Repo;
            }
            WizardStep::Repo => {
                self.repo = text.to_string();
                self.step = WizardStep::Profile;
            }
            WizardStep::Profile => {
                self.profile = text.to_string();
                self.step = WizardStep::Pipeline;
            }
            WizardStep::Pipeline => {
                if !text.is_empty() && text != "none" && text != "lean" && text != "full" {
                    let stages: Vec<&str> = text.split(',').map(str::trim).collect();
                    if stages.is_empty() || stages.iter().any(|s| {
                        !matches!(*s, "intent" | "spec" | "plan")
                    }) {
                        return Err(
                            "new run: pipeline must be none, lean, full, or a comma list of intent/spec/plan"
                                .to_string(),
                        );
                    }
                }
                self.pipeline = text.to_string();
                self.step = WizardStep::Models;
            }
            WizardStep::Models => {
                // Advisory free text (F8): never carried in argv.
                self.step = WizardStep::Done;
            }
            WizardStep::Done => {}
        }
        Ok(())
    }

    pub fn finished(&self) -> bool {
        matches!(self.step, WizardStep::Done)
    }

    /// Verbatim spawn argv (after the binary). Optional flags drop out
    /// when their step input was empty.
    pub fn argv(&self) -> Option<Vec<String>> {
        if !self.finished() {
            return None;
        }
        let mut argv = vec!["start".to_string(), self.run_id.clone()];
        if !self.repo.is_empty() {
            argv.push("--repo".to_string());
            argv.push(self.repo.clone());
        }
        if !self.profile.is_empty() {
            argv.push("--profile".to_string());
            argv.push(self.profile.clone());
        }
        if !self.pipeline.is_empty() {
            argv.push("--pipeline".to_string());
            argv.push(self.pipeline.clone());
        }
        Some(argv)
    }
}

/// Enter (the carriage return) jumps to the writer pane via tmux. Kept
/// as part of the tested keymap contract even though main.rs handles
/// Enter inline for its dual status/jump behavior.
#[allow(dead_code)]
pub fn keymap_enter() -> Option<Action> {
    Some(Action::JumpWriterPane)
}

/// argv (after the binary) for a non-prompted action. The caller spawns
/// exactly this; nothing else may be constructed from key input.
pub fn action_argv(action: Action, run_id: &str) -> Option<Vec<String>> {
    let argv = match action {
        Action::Approve => vec![
            "resolve".to_string(),
            run_id.to_string(),
            "--action".to_string(),
            "approve".to_string(),
        ],
        Action::Validate => vec!["validate".to_string(), run_id.to_string()],
        _ => return None,
    };
    Some(argv)
}

/// argv for `mode RUN auto|human` — the toggle reads the current mode from
/// the status fields and flips it. An unknown or missing mode resolves to
/// human: the UI never auto-promotes a run it cannot read.
pub fn toggle_mode_argv(current_mode: Option<&str>, run_id: &str) -> Vec<String> {
    let next = match current_mode {
        Some("human") => "auto",
        _ => "human",
    };
    vec!["mode".to_string(), run_id.to_string(), next.to_string()]
}

/// argv for the prompted reject action: the reviewer's formal gate
/// decision (CHANGES_REQUESTED) — the CLI's legal verdicts are APPROVE,
/// CHANGES_REQUESTED, and BLOCKED; there is no REJECT. `resolve --action
/// reject` is human-only (escalation path) and must not be reached from
/// the reviewer-phase dashboard. The input carries `summary | next`;
/// `next` is the instruction handed back to the writer.
pub fn reject_argv(run_id: &str, input: &str) -> Vec<String> {
    let (summary, next) = split_summary_next(input);
    vec![
        "decision".to_string(),
        run_id.to_string(),
        "--verdict".to_string(),
        "CHANGES_REQUESTED".to_string(),
        "--summary".to_string(),
        summary.to_string(),
        "--next".to_string(),
        next.to_string(),
    ]
}

/// Split the prompted decision input at the first `|`: summary | next.
/// Without a separator the whole input is the summary and `next` defaults
/// to a fix-and-resubmit directive (REJECT) or "proceed" (APPROVE).
pub fn split_summary_next(input: &str) -> (&str, &str) {
    match input.split_once('|') {
        Some((s, n)) => (s.trim(), n.trim()),
        None => (input.trim(), ""),
    }
}

/// argv for the prompted decision action: approve with a one-line summary
/// and the optional `| next` suffix.
pub fn decision_approve_argv(run_id: &str, input: &str) -> Vec<String> {
    let (summary, next) = split_summary_next(input);
    let next = if next.is_empty() { "proceed" } else { next };
    vec![
        "decision".to_string(),
        run_id.to_string(),
        "--verdict".to_string(),
        "APPROVE".to_string(),
        "--summary".to_string(),
        summary.to_string(),
        "--next".to_string(),
        next.to_string(),
    ]
}

/// argv for the artifact accept gate: no prompt needed, the confirm line
/// shows this verbatim and `y` spawns exactly it.
pub fn artifact_accept_argv(run_id: &str, stage: &str) -> Vec<String> {
    vec![
        "artifact".to_string(),
        run_id.to_string(),
        "--stage".to_string(),
        stage.to_string(),
        "--accept".to_string(),
    ]
}

/// argv for the artifact reject gate: the summary is required by the CLI.
pub fn artifact_reject_argv(run_id: &str, stage: &str, summary: &str) -> Vec<String> {
    vec![
        "artifact".to_string(),
        run_id.to_string(),
        "--stage".to_string(),
        stage.to_string(),
        "--reject".to_string(),
        "--summary".to_string(),
        summary.to_string(),
    ]
}

/// argv for reading the awaiting draft through the oracle verb (the TUI
/// never reads run files directly — thin-client rule).
pub fn artifact_show_argv(run_id: &str, stage: &str) -> Vec<String> {
    vec![
        "artifact".to_string(),
        run_id.to_string(),
        "--stage".to_string(),
        stage.to_string(),
        "--show".to_string(),
    ]
}

/// Line indices (0-based) of case-insensitive substring matches, one
/// hit per line, in order. Empty queries yield no matches.
pub fn find_matches(body: &str, query: &str) -> Vec<usize> {
    if query.is_empty() {
        return Vec::new();
    }
    let needle = query.to_lowercase();
    body.lines()
        .enumerate()
        .filter(|(_, line)| line.to_lowercase().contains(&needle))
        .map(|(idx, _)| idx)
        .collect()
}

/// Deterministic full-screen render of a status document for the TUI
/// run-detail screen: every field as `key  value` (sorted, empties
/// skipped), the pane liveness line, and the pipeline stage chain when
/// the document carries a stages array.
pub fn render_detail(doc: &StatusDoc) -> String {
    let mut lines: Vec<String> = Vec::new();
    for (key, value) in doc.fields.iter() {
        let Some(text) = value.as_str() else { continue };
        if text.is_empty() {
            continue;
        }
        lines.push(format!("{key:<18} {text}"));
    }
    lines.push(format!(
        "{:<18} reviewer={} writer={}",
        "panes", doc.panes.reviewer, doc.panes.writer
    ));
    if let Some(stages) = &doc.stages {
        for (idx, stage) in stages.iter().enumerate() {
            let label = if idx == 0 { "stages" } else { "" };
            lines.push(format!(
                "{:<18} {}: {} (attempts {})",
                label, stage.name, stage.status, stage.attempts
            ));
        }
    }
    lines.join("\n")
}

/// argv for reading the latest regen context (previous-version toggle;
/// the TUI never reads run files directly — thin-client rule).
pub fn artifact_show_previous_argv(run_id: &str, stage: &str) -> Vec<String> {
    vec![
        "artifact".to_string(),
        run_id.to_string(),
        "--stage".to_string(),
        stage.to_string(),
        "--show-previous".to_string(),
    ]
}

/// argv for the prompted relay action.
pub fn relay_writer_argv(run_id: &str, message: &str) -> Vec<String> {
    vec![
        "relay".to_string(),
        run_id.to_string(),
        "--to".to_string(),
        "writer".to_string(),
        "--from".to_string(),
        "reviewer".to_string(),
        "--message".to_string(),
        message.to_string(),
    ]
}

/// tmux argv to jump to the run's writer pane: focus the session window.
pub fn jump_tmux_argv(session_name: &str) -> Vec<String> {
    vec![
        "select-window".to_string(),
        "-t".to_string(),
        session_name.to_string(),
    ]
}

/// The confirm line shown before any spawn: verbatim CLI, no surprises.
pub fn confirm_text(argv: &[String]) -> String {
    format!("run: agent-arena {}  (y=confirm, n=cancel)", argv.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST_JSON: &str = r#"{"schema":1,"generated_at":123,"runs":[
        {"run_id":"b-run","repository":"/tmp/r","profile":"pi-cursor","gate":"cursor",
         "mode":"human","run_status":"active","phase":"submitted","party":"reviewer",
         "reason_code":"review_pending","waiting_since":"1","authority":"state","anomaly":""},
        {"run_id":"a-run","repository":"/tmp/r","profile":"pi-cursor","gate":"cursor",
         "mode":"human","run_status":"completed","phase":"decided","party":"none",
         "reason_code":"none","waiting_since":"","authority":"state","anomaly":""},
        {"run_id":"c-run","repository":"/tmp/r","profile":"pi-cursor","gate":"cursor",
         "mode":"human","run_status":"active","phase":"submit","party":"writer",
         "reason_code":"none","waiting_since":"","authority":"state","anomaly":"corrupt"}
    ]}"#;

    #[test]
    fn parses_strict_and_rejects_unknown_fields() {
        assert!(parse_list(LIST_JSON).is_ok());
        let bad = LIST_JSON.replace("\"generated_at\":123", "\"generated_at\":123,\"evil\":1");
        assert!(parse_list(&bad).is_err(), "unknown field must fail");
    }

    #[test]
    fn needs_human_first_ordering() {
        let mut doc = parse_list(LIST_JSON).unwrap();
        sort_runs(&mut doc.runs);
        let ids: Vec<&str> = doc.runs.iter().map(|r| r.run_id.as_str()).collect();
        assert_eq!(ids, vec!["b-run", "c-run", "a-run"]);
    }

    #[test]
    fn status_error_path_document_is_parseable() {
        // The EXIT-trap document for locked/corrupt/usage errors carries
        // empty fields/panes; the client must accept it (panes unknown ->
        // false), not reject its own oracle.
        let trap = r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":"locked"}"#;
        let doc = parse_status(trap).unwrap();
        assert_eq!(doc.error.as_deref(), Some("locked"));
        assert!(!doc.panes.reviewer && !doc.panes.writer);
    }

    #[test]
    fn status_doc_parses_null_and_string_errors() {
        let ok = r#"{"schema":1,"run_id":"r","fields":{"verdict":"APPROVE"},"panes":{"reviewer":true,"writer":false},"error":null}"#;
        let doc = parse_status(ok).unwrap();
        assert_eq!(doc.field_str("verdict"), Some("APPROVE"));
        assert!(!doc.panes.writer);
        let err = ok.replace("\"error\":null", "\"error\":\"corrupt\"");
        assert_eq!(parse_status(&err).unwrap().error.as_deref(), Some("corrupt"));
    }

    const STATUS_WITH_STAGES: &str = r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null,"stages":[
        {"name":"intent","status":"accepted","attempts":3},
        {"name":"spec","status":"awaiting_accept","attempts":1},
        {"name":"plan","status":"pending","attempts":0}
    ]}"#;

    #[test]
    fn stages_present_parse_strict_and_chain_in_manifest_order() {
        let doc = parse_status(STATUS_WITH_STAGES).unwrap();
        let stages = doc.stages.as_ref().unwrap();
        assert_eq!(
            stages,
            &[
                StageStatus {
                    name: "intent".into(),
                    status: "accepted".into(),
                    attempts: 3,
                },
                StageStatus {
                    name: "spec".into(),
                    status: "awaiting_accept".into(),
                    attempts: 1,
                },
                StageStatus {
                    name: "plan".into(),
                    status: "pending".into(),
                    attempts: 0,
                },
            ]
        );
        assert_eq!(
            doc.stage_chain().as_deref(),
            Some("intent accepted -> spec awaiting_accept -> plan pending")
        );
        // unknown fields inside one stage element fail the strict parse
        let evil = STATUS_WITH_STAGES.replace("\"attempts\":3", "\"attempts\":3,\"evil\":1");
        assert!(parse_status(&evil).is_err(), "stage element must be strict");
    }

    #[test]
    fn stages_absent_chain_is_none() {
        let no_stages = r#"{"schema":1,"run_id":"r","fields":{"verdict":"APPROVE"},"panes":{},"error":null}"#;
        let doc = parse_status(no_stages).unwrap();
        assert!(doc.stages.is_none());
        assert_eq!(doc.stage_chain(), None);
        // an empty stages array is legal and also renders no chain line
        let empty = r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null,"stages":[]}"#;
        let doc = parse_status(empty).unwrap();
        assert!(doc.stages.is_some());
        assert_eq!(doc.stage_chain(), None);
    }

    #[test]
    fn keymap_maps_exactly_the_contract_keys() {
        assert_eq!(keymap_action('a'), Some(Action::Approve));
        assert_eq!(keymap_action('r'), Some(Action::Reject));
        assert_eq!(keymap_action('d'), Some(Action::DecisionApprove));
        assert_eq!(keymap_action('l'), Some(Action::RelayWriter));
        assert_eq!(keymap_action('m'), Some(Action::ToggleMode));
        assert_eq!(keymap_action('v'), Some(Action::Validate));
        assert_eq!(keymap_action('n'), Some(Action::NewRun));
        assert_eq!(keymap_action('q'), Some(Action::Quit));
        assert_eq!(keymap_action('x'), None);
        assert_eq!(keymap_enter(), Some(Action::JumpWriterPane));
    }

    #[test]
    fn argv_is_non_destructive_and_exact() {
        let approve = action_argv(Action::Approve, "run-one").unwrap();
        assert_eq!(approve, vec!["resolve", "run-one", "--action", "approve"]);
        // reject is the prompted gate decision (REJECT), not the
        // human-only `resolve --action reject`.
        assert!(action_argv(Action::Reject, "run-one").is_none());
        assert_eq!(
            reject_argv("run-one", "fails validation | fix the gate"),
            vec![
                "decision",
                "run-one",
                "--verdict",
                "CHANGES_REQUESTED",
                "--summary",
                "fails validation",
                "--next",
                "fix the gate",
            ]
        );
        let validate = action_argv(Action::Validate, "run-one").unwrap();
        assert_eq!(validate, vec!["validate", "run-one"]);
        // Destructive subcommands never appear in any argv.
        for a in [Action::Approve, Action::Validate] {
            if let Some(argv) = action_argv(a, "r") {
                for banned in [
                    "cancel", "repair-state", "reset", "merge", "push", "bypass",
                ] {
                    assert!(!argv.contains(&banned.to_string()));
                }
            }
        }
        for argv in [
            reject_argv("r", "s"),
            decision_approve_argv("r", "s"),
            relay_writer_argv("r", "m"),
            toggle_mode_argv(Some("human"), "r"),
        ] {
            for banned in [
                "cancel", "repair-state", "reset", "merge", "push", "bypass",
            ] {
                assert!(!argv.contains(&banned.to_string()));
            }
        }
    }

    #[test]
    fn mode_toggle_flips_and_defaults_safe() {
        assert_eq!(
            toggle_mode_argv(Some("auto"), "r"),
            vec!["mode", "r", "human"]
        );
        assert_eq!(
            toggle_mode_argv(Some("human"), "r"),
            vec!["mode", "r", "auto"]
        );
        // Unknown/missing modes resolve to human: never auto-promote.
        assert_eq!(toggle_mode_argv(None, "r"), vec!["mode", "r", "human"]);
        assert_eq!(
            toggle_mode_argv(Some("bogus"), "r"),
            vec!["mode", "r", "human"]
        );
    }

    #[test]
    fn prompted_argvs_carry_the_payload_verbatim() {
        assert_eq!(
            decision_approve_argv("r", "ok"),
            vec![
                "decision", "r", "--verdict", "APPROVE", "--summary", "ok", "--next", "proceed",
            ]
        );
        assert_eq!(
            decision_approve_argv("r", "ok | merge after release"),
            vec![
                "decision",
                "r",
                "--verdict",
                "APPROVE",
                "--summary",
                "ok",
                "--next",
                "merge after release",
            ]
        );
        assert_eq!(
            reject_argv("r", "stub script | fix validate.sh"),
            vec![
                "decision",
                "r",
                "--verdict",
                "CHANGES_REQUESTED",
                "--summary",
                "stub script",
                "--next",
                "fix validate.sh",
            ]
        );
        assert_eq!(split_summary_next("no pipe"), ("no pipe", ""));
        assert_eq!(
            relay_writer_argv("r", "hello"),
            vec!["relay", "r", "--to", "writer", "--from", "reviewer", "--message", "hello"]
        );
        assert_eq!(jump_tmux_argv("sess"), vec!["select-window", "-t", "sess"]);
    }

    #[test]
    fn confirm_line_shows_verbatim_cli() {
        let argv = action_argv(Action::Approve, "run-one").unwrap();
        assert_eq!(
            confirm_text(&argv),
            "run: agent-arena resolve run-one --action approve  (y=confirm, n=cancel)"
        );
    }

    #[test]
    fn wizard_requires_run_id() {
        let mut w = RunWizard::new();
        assert!(matches!(w.step, WizardStep::RunId));
        assert!(w.submit("").is_err());
        assert!(w.submit("  ").is_err());
        // still on RunId after failed submits
        assert!(matches!(w.step, WizardStep::RunId));
        w.submit("s66w").unwrap();
        assert!(matches!(w.step, WizardStep::Repo));
    }

    #[test]
    fn wizard_full_path_builds_verbatim_argv() {
        let mut w = RunWizard::new();
        w.submit("s66w").unwrap();
        w.submit("/tmp/repo").unwrap();
        w.submit("zell-cursor").unwrap();
        w.submit("lean").unwrap();
        w.submit("").unwrap();
        assert!(w.finished());
        assert_eq!(
            w.argv(),
            Some(vec![
                "start".to_string(),
                "s66w".to_string(),
                "--repo".to_string(),
                "/tmp/repo".to_string(),
                "--profile".to_string(),
                "zell-cursor".to_string(),
                "--pipeline".to_string(),
                "lean".to_string(),
            ])
        );
    }

    #[test]
    fn wizard_empty_optionals_drop_flags() {
        let mut w = RunWizard::new();
        w.submit("r1").unwrap();
        w.submit("").unwrap(); // repo -> cwd default
        w.submit("").unwrap(); // profile -> start default
        w.submit("").unwrap(); // pipeline -> roles.conf default
        w.submit("").unwrap();
        assert_eq!(
            w.argv(),
            Some(vec!["start".to_string(), "r1".to_string()])
        );
    }

    #[test]
    fn wizard_pipeline_validation() {
        let mut w = RunWizard::new();
        w.submit("r2").unwrap();
        w.submit("").unwrap();
        w.submit("").unwrap();
        // legal depths
        for depth in ["none", "lean", "full", "intent,spec,plan", "plan"] {
            assert!(w.submit(depth).is_ok(), "depth {depth} must be legal");
            // step moved on; step back is impossible, so rebuild each time
            let mut w2 = RunWizard::new();
            w2.submit("r2").unwrap();
            w2.submit("").unwrap();
            w2.submit("").unwrap();
            assert!(w2.submit(depth).is_ok());
        }
        // illegal lists refuse and hold the step
        let mut w3 = RunWizard::new();
        w3.submit("r3").unwrap();
        w3.submit("").unwrap();
        w3.submit("").unwrap();
        assert!(w3.submit("intent,bogus").is_err());
        assert!(matches!(w3.step, WizardStep::Pipeline));
        assert!(w3.submit("intent,,plan").is_err());
        assert!(w3.argv().is_none());
    }

    #[test]
    fn wizard_argv_unavailable_until_done() {
        let mut w = RunWizard::new();
        w.submit("r4").unwrap();
        assert!(w.argv().is_none());
        assert!(!w.finished());
    }
    #[test]
    fn awaiting_stage_picks_the_first_gate_target_in_manifest_order() {
        let doc = parse_status(STATUS_WITH_STAGES).unwrap();
        assert_eq!(doc.awaiting_stage(), Some("spec"));
    }

    #[test]
    fn awaiting_stage_is_none_without_a_gate_target() {
        let doc = parse_status(
            r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null,"stages":[
                {"name":"intent","status":"accepted","attempts":1}
            ]}"#,
        )
        .unwrap();
        assert_eq!(doc.awaiting_stage(), None);
        let doc = parse_status(
            r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null}"#,
        )
        .unwrap();
        assert_eq!(doc.awaiting_stage(), None);
    }

    #[test]
    fn artifact_gate_argvs_are_verbatim() {
        assert_eq!(
            artifact_accept_argv("s74", "intent"),
            vec![
                "artifact".to_string(),
                "s74".to_string(),
                "--stage".to_string(),
                "intent".to_string(),
                "--accept".to_string(),
            ]
        );
        assert_eq!(
            artifact_reject_argv("s74", "spec", "needs risk section"),
            vec![
                "artifact".to_string(),
                "s74".to_string(),
                "--stage".to_string(),
                "spec".to_string(),
                "--reject".to_string(),
                "--summary".to_string(),
                "needs risk section".to_string(),
            ]
        );
    }

    #[test]
    fn render_detail_is_deterministic_and_skips_empties() {
        let doc = parse_status(
            r#"{"schema":1,"run_id":"s78","fields":{
                "run_id":"s78","repository":"/repo","verdict":"","mode":"human",
                "run_status":"active","phase":"intent"
            },"panes":{"reviewer":false,"writer":true},"error":null,
            "stages":[{"name":"intent","status":"awaiting_accept","attempts":2}]}"#,
        )
        .unwrap();
        let text = render_detail(&doc);
        // sorted fields, empty verdict skipped
        let expected = concat!(
            "mode               human\n",
            "phase              intent\n",
            "repository         /repo\n",
            "run_id             s78\n",
            "run_status         active\n",
            "panes              reviewer=false writer=true\n",
            "stages             intent: awaiting_accept (attempts 2)"
        );
        assert_eq!(text, expected);
    }

    #[test]
    fn render_detail_minimal_on_error_path_documents() {
        let doc = parse_status(
            r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":"locked"}"#,
        )
        .unwrap();
        assert_eq!(
            render_detail(&doc),
            "panes              reviewer=false writer=false"
        );
    }

    #[test]
    fn find_matches_is_case_insensitive_one_hit_per_line() {
        let body = "alpha Beta\nnothing here\nGAMMA beta\nbeta";
        assert_eq!(find_matches(body, "beta"), vec![0, 2, 3]);
        assert_eq!(find_matches(body, "BETA"), vec![0, 2, 3]);
        assert_eq!(find_matches(body, "zzz"), Vec::<usize>::new());
        assert_eq!(find_matches(body, ""), Vec::<usize>::new());
        assert_eq!(find_matches("", "x"), Vec::<usize>::new());
    }

    #[test]
    fn artifact_show_previous_argv_is_verbatim() {
        assert_eq!(
            artifact_show_previous_argv("s77", "intent"),
            vec![
                "artifact".to_string(),
                "s77".to_string(),
                "--stage".to_string(),
                "intent".to_string(),
                "--show-previous".to_string(),
            ]
        );
    }

    #[test]
    fn latest_accepted_stage_picks_the_furthest_progress() {
        let doc = parse_status(STATUS_WITH_STAGES).unwrap();
        // intent accepted, spec awaiting, plan pending -> intent
        assert_eq!(doc.latest_accepted_stage(), Some("intent"));
        let doc = parse_status(
            r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null,"stages":[
                {"name":"intent","status":"accepted","attempts":1},
                {"name":"spec","status":"accepted","attempts":2}
            ]}"#,
        )
        .unwrap();
        assert_eq!(doc.latest_accepted_stage(), Some("spec"));
        let doc = parse_status(
            r#"{"schema":1,"run_id":"r","fields":{},"panes":{},"error":null,"stages":[
                {"name":"intent","status":"awaiting_accept","attempts":1}
            ]}"#,
        )
        .unwrap();
        assert_eq!(doc.latest_accepted_stage(), None);
    }

    #[test]
    fn artifact_show_argv_is_verbatim_and_keyed_on_o() {
        assert_eq!(
            artifact_show_argv("s75", "intent"),
            vec![
                "artifact".to_string(),
                "s75".to_string(),
                "--stage".to_string(),
                "intent".to_string(),
                "--show".to_string(),
            ]
        );
        assert_eq!(keymap_action('o'), Some(Action::ViewArtifact));
        assert_eq!(action_argv(Action::ViewArtifact, "s75"), None);
    }

    #[test]
    fn keymap_maps_g_and_shift_g_to_the_artifact_gate() {
        assert_eq!(keymap_action('g'), Some(Action::ArtifactAccept));
        assert_eq!(keymap_action('G'), Some(Action::ArtifactReject));
        // status-dependent actions are never built from the run id alone
        assert_eq!(action_argv(Action::ArtifactAccept, "s74"), None);
        assert_eq!(action_argv(Action::ArtifactReject, "s74"), None);
    }

}
