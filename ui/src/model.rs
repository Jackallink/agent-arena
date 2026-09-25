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

/// The `panes` block of `agent-arena status RUN --json`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Panes {
    pub reviewer: bool,
    pub writer: bool,
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
    pub panes: Panes,
    #[allow(dead_code)]
    pub error: Option<String>,
}

impl StatusDoc {
    /// Convenience accessor for the fields the TUI renders directly.
    pub fn field_str(&self, key: &str) -> Option<&str> {
        self.fields.get(key).and_then(|v| v.as_str())
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
        'q' => Some(Action::Quit),
        _ => None,
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
        Action::Reject => vec![
            "resolve".to_string(),
            run_id.to_string(),
            "--action".to_string(),
            "reject".to_string(),
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

/// argv for the prompted decision action: approve with a one-line summary.
pub fn decision_approve_argv(run_id: &str, summary: &str) -> Vec<String> {
    vec![
        "decision".to_string(),
        run_id.to_string(),
        "--verdict".to_string(),
        "APPROVE".to_string(),
        "--summary".to_string(),
        summary.to_string(),
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
    fn status_doc_parses_null_and_string_errors() {
        let ok = r#"{"schema":1,"run_id":"r","fields":{"verdict":"APPROVE"},"panes":{"reviewer":true,"writer":false},"error":null}"#;
        let doc = parse_status(ok).unwrap();
        assert_eq!(doc.field_str("verdict"), Some("APPROVE"));
        assert!(!doc.panes.writer);
        let err = ok.replace("\"error\":null", "\"error\":\"corrupt\"");
        assert_eq!(parse_status(&err).unwrap().error.as_deref(), Some("corrupt"));
    }

    #[test]
    fn keymap_maps_exactly_the_contract_keys() {
        assert_eq!(keymap_action('a'), Some(Action::Approve));
        assert_eq!(keymap_action('r'), Some(Action::Reject));
        assert_eq!(keymap_action('d'), Some(Action::DecisionApprove));
        assert_eq!(keymap_action('l'), Some(Action::RelayWriter));
        assert_eq!(keymap_action('m'), Some(Action::ToggleMode));
        assert_eq!(keymap_action('v'), Some(Action::Validate));
        assert_eq!(keymap_action('q'), Some(Action::Quit));
        assert_eq!(keymap_action('x'), None);
        assert_eq!(keymap_enter(), Some(Action::JumpWriterPane));
    }

    #[test]
    fn argv_is_non_destructive_and_exact() {
        let approve = action_argv(Action::Approve, "run-one").unwrap();
        assert_eq!(approve, vec!["resolve", "run-one", "--action", "approve"]);
        let reject = action_argv(Action::Reject, "run-one").unwrap();
        assert_eq!(reject, vec!["resolve", "run-one", "--action", "reject"]);
        let validate = action_argv(Action::Validate, "run-one").unwrap();
        assert_eq!(validate, vec!["validate", "run-one"]);
        // Destructive subcommands never appear in any argv.
        for a in [Action::Approve, Action::Reject, Action::Validate] {
            if let Some(argv) = action_argv(a, "r") {
                for banned in [
                    "cancel", "repair-state", "reset", "merge", "push", "bypass",
                ] {
                    assert!(!argv.contains(&banned.to_string()));
                }
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
            vec!["decision", "r", "--verdict", "APPROVE", "--summary", "ok"]
        );
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
}
