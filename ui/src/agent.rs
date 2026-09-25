//! The only code allowed to spawn processes. Every call goes through this
//! module so the thin-client rule is auditable in one file: data comes
//! from `agent-arena list --json` / `status RUN --json` (stdout captured),
//! actions spawn `agent-arena` subcommands (terminal inherited), and the
//! writer-pane jump goes through tmux. Nothing else is exec'd.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::model;

pub struct Arena {
    bin: PathBuf,
}

impl Arena {
    /// Locate the arena entry point: explicit override, then the repo
    /// layout relative to this binary (ui/target/debug → ../../bin).
    pub fn discover() -> Option<Arena> {
        if let Ok(from_env) = std::env::var("ARENA_BIN") {
            let p = PathBuf::from(from_env);
            if p.is_file() {
                return Some(Arena { bin: p });
            }
        }
        if let Ok(exe) = std::env::current_exe() {
            // ui/target/{debug,release}/agent-arena-ui → walk up until a
            // sibling bin/agent-arena appears (works for any install depth).
            for ancestor in exe.ancestors().skip(1) {
                let p = ancestor.join("bin/agent-arena");
                if p.is_file() {
                    return Some(Arena { bin: p });
                }
            }
        }
        None
    }

    /// `list --json` — the oracle prints JSON on stdout on every exit
    /// path, so a non-zero exit still yields a parseable document.
    pub fn list_json(&self, state_root: &Path) -> Result<String, String> {
        self.capture_json(&["list".into(), "--json".into()], state_root)
    }

    /// `status RUN --json` — same every-exit-path contract.
    pub fn status_json(&self, run_id: &str, state_root: &Path) -> Result<String, String> {
        self.capture_json(
            &[
                "status".into(),
                run_id.to_string(),
                "--json".into(),
            ],
            state_root,
        )
    }

    fn capture_json(&self, args: &[String], state_root: &Path) -> Result<String, String> {
        let out = Command::new(&self.bin)
            .args(args)
            .arg("--state-root")
            .arg(state_root)
            .output()
            .map_err(|e| format!("failed to spawn {}: {e}", self.bin.display()))?;
        String::from_utf8(out.stdout).map_err(|e| format!("non-utf8 oracle output: {e}"))
    }

    /// Spawn an interactive action (resolve/validate/...): the child owns
    /// the terminal, this process waits, then the TUI redraws.
    pub fn spawn_interactive(&self, argv: &[String], state_root: &Path) -> Result<(), String> {
        let mut cmd = Command::new(&self.bin);
        cmd.args(argv).arg("--state-root").arg(state_root);
        let status = cmd
            .status()
            .map_err(|e| format!("failed to spawn {}: {e}", self.bin.display()))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!(
                "agent-arena {} exited with {status}",
                argv.first().map(String::as_str).unwrap_or("?")
            ))
        }
    }

    /// Jump to the writer pane: `tmux select-window -t SESSION`. The only
    /// non-agent-arena spawn the thin-client rule permits.
    pub fn jump_writer_pane(&self, session_name: &str) -> Result<(), String> {
        let status = Command::new("tmux")
            .args(model::jump_tmux_argv(session_name))
            .status()
            .map_err(|e| format!("failed to spawn tmux: {e}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("tmux select-window exited with {status}"))
        }
    }
}
