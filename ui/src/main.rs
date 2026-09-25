//! agent-arena-ui — terminal dashboard for Agent Arena.
//!
//! v0 contract: `--selftest --state-root PATH` proves the full oracle
//! chain (spawn → JSON → strict parse → ordering) non-interactively;
//! with no arguments it runs the alternate-screen list view.

mod agent;
mod model;

use agent::Arena;
use model::{parse_list, sort_runs};

use std::path::PathBuf;
use std::process::ExitCode;

struct Options {
    selftest: bool,
    state_root: PathBuf,
}

fn parse_args() -> Result<Options, String> {
    let mut opts = Options {
        selftest: false,
        state_root: std::env::var("ARENA_STATE_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("")),
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--selftest" => opts.selftest = true,
            "--state-root" => {
                let v = args
                    .next()
                    .ok_or_else(|| "--state-root requires a path".to_string())?;
                opts.state_root = PathBuf::from(v);
            }
            "-h" | "--help" => {
                print_usage();
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    if opts.state_root.as_os_str().is_empty() {
        return Err("--state-root is required (or set ARENA_STATE_ROOT)".to_string());
    }
    Ok(opts)
}

fn print_usage() {
    println!(
        "Usage: agent-arena-ui [--selftest] --state-root PATH\n\n\
         Thin-client dashboard over `agent-arena list --json` / `status RUN --json`.\n\
         Keys: a approve · r reject · d decision · l relay · m mode · v validate ·\n\
               Enter writer pane · q quit"
    );
}

/// Non-interactive probe: prove the oracle chain end-to-end and print the
/// needs-human-first digests (tests/run.sh §61 asserts `run-one` shows up).
fn run_selftest(arena: &Arena, state_root: &PathBuf) -> ExitCode {
    let raw = match arena.list_json(state_root) {
        Ok(raw) => raw,
        Err(e) => {
            eprintln!("selftest: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match parse_list(&raw) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("selftest: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut runs = doc.runs;
    sort_runs(&mut runs);
    if doc.schema != 1 {
        eprintln!("selftest: unexpected schema {}", doc.schema);
        return ExitCode::FAILURE;
    }
    for run in &runs {
        println!("{}", run.digest());
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let opts = match parse_args() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("agent-arena-ui: {e}");
            return ExitCode::from(2);
        }
    };
    let arena = match Arena::discover() {
        Some(a) => a,
        None => {
            eprintln!("agent-arena-ui: cannot locate bin/agent-arena (set ARENA_BIN)");
            return ExitCode::FAILURE;
        }
    };
    if opts.selftest {
        return run_selftest(&arena, &opts.state_root);
    }
    run_tui(&arena, &opts.state_root)
}

/// Interactive v0: alternate-screen list, j/k selection, Enter on a run
/// shows its status digest; q quits. Actions confirm on the status line
/// before spawning. This loop keeps the terminal discipline strict:
/// raw mode only inside the guard, restore on every exit path.
/// One input mode of the interactive loop. Actions never spawn directly:
/// they stage a confirm line showing the verbatim argv (or a one-line
/// input for the prompted actions d/l), and only y confirms.
enum InputMode {
    Normal,
    Confirm { argv: Vec<String> },
    Input { kind: PromptKind, buffer: String },
}

enum PromptKind {
    RejectReason,
    DecisionSummary,
    RelayMessage,
}

impl PromptKind {
    fn hint(&self, run_id: &str) -> String {
        match self {
            PromptKind::RejectReason => {
                format!(
                    "decision {} --verdict REJECT --summary <type>, Enter submit, Esc cancel",
                    run_id
                )
            }
            PromptKind::DecisionSummary => {
                format!("decision {} --verdict APPROVE --summary <type>, Enter submit, Esc cancel", run_id)
            }
            PromptKind::RelayMessage => {
                format!("relay {} --to writer --message <type>, Enter submit, Esc cancel", run_id)
            }
        }
    }

}

/// Interactive v0: alternate-screen list, j/k selection, Enter for the
/// status digest / writer-pane jump, keymap actions through the confirm
/// line, q quits. Terminal discipline: raw mode only inside this function,
/// the alternate screen is left around every child spawn.
fn run_tui(arena: &Arena, state_root: &PathBuf) -> ExitCode {
    // Interactive guard: without a tty the event loop would block forever
    // (tests, cron, pipes). Fail fast with the dispatch hint instead.
    use crossterm::tty::IsTty;
    if !std::io::stdin().is_tty() {
        eprintln!("agent-arena-ui: interactive mode requires a tty");
        return ExitCode::FAILURE;
    }
    use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
    use crossterm::terminal::{
        disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
    };
    use ratatui::backend::CrosstermBackend;
    use ratatui::layout::{Constraint, Layout, Rect};
    use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};
    use ratatui::Terminal;

    if enable_raw_mode().is_err() {
        eprintln!("agent-arena-ui: tty required for the interactive view");
        return ExitCode::FAILURE;
    }
    let _ = crossterm::execute!(std::io::stdout(), EnterAlternateScreen);
    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = match Terminal::new(backend) {
        Ok(t) => t,
        Err(_) => {
            let _ = disable_raw_mode();
            let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
            return ExitCode::FAILURE;
        }
    };

    // Leave the alternate screen so a spawned child gets a clean terminal,
    // then restore it. Every spawn path goes through this pair.
    fn with_suspended_terminal<T>(
        terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
        f: impl FnOnce() -> T,
    ) -> T {
        let _ = disable_raw_mode();
        let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
        let out = f();
        let _ = enable_raw_mode();
        let _ = crossterm::execute!(std::io::stdout(), EnterAlternateScreen);
        let _ = terminal.clear();
        out
    }

    let mut runs: Vec<model::RunSummary> = Vec::new();
    let mut notice = String::from("q quit · Enter status/jump · j/k move · a approve · r reject · d decision · l relay · m mode · v validate");
    let mut selected: usize = 0;
    let mut list_state = ListState::default();
    let mut input_mode = InputMode::Normal;
    let mut status_cache: Option<model::StatusDoc> = None;
    let result = ExitCode::SUCCESS;

    loop {
        // Re-scan only in Normal mode: typing into the input line must not
        // pay a subprocess per keystroke, and staged confirms render the
        // already-fetched list.
        if matches!(input_mode, InputMode::Normal) {
            let doc = arena
                .list_json(state_root)
                .as_deref()
                .map_err(Clone::clone)
                .and_then(model::parse_list);
            match doc {
                Ok(mut d) => {
                    sort_runs(&mut d.runs);
                    runs = d.runs;
                }
                Err(e) => {
                    notice = format!("oracle error: {e}");
                    runs.clear();
                }
            }
        }
        if selected >= runs.len() {
            selected = runs.len().saturating_sub(1);
        }
        list_state.select(Some(selected));

        let _ = terminal.draw(|f| {
            let chunks = Layout::vertical([
                Constraint::Min(3),
                Constraint::Length(2),
                Constraint::Length(2),
            ])
            .split(f.area());
            let items: Vec<ListItem> = runs.iter().map(|r| ListItem::new(r.digest())).collect();
            let selected_id = runs
                .get(selected)
                .map(|r| r.run_id.as_str())
                .unwrap_or("");
            let title = match &input_mode {
                InputMode::Normal => "agent-arena runs".to_string(),
                InputMode::Confirm { argv } => model::confirm_text(argv),
                InputMode::Input { kind, buffer } => {
                    format!("{} > {}", kind.hint(selected_id), buffer)
                }
            };
            let list = List::new(items)
                .block(Block::default().title(title).borders(Borders::ALL))
                .highlight_symbol("> ");
            f.render_stateful_widget(list, chunks[0], &mut list_state);
            let notice_area = Rect::new(chunks[1].x, chunks[1].y, chunks[1].width, 1);
            f.render_widget(Paragraph::new(notice.as_str()), notice_area);
            if let Some(s) = &status_cache {
                let line = format!(
                    "{}  mode {}  verdict {}  reviewer-pane {}  writer-pane {}",
                    s.run_id,
                    s.field_str("mode").unwrap_or("-"),
                    s.field_str("verdict").unwrap_or("-"),
                    s.panes.reviewer,
                    s.panes.writer
                );
                let status_area = Rect::new(chunks[2].x, chunks[2].y, chunks[2].width, 1);
                f.render_widget(Paragraph::new(line), status_area);
            }
        });

        let event = match event::read() {
            Ok(ev) => ev,
            Err(_) => break,
        };
        let Event::Key(key) = event else { continue };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        // Confirm mode owns y/n first: a stray y elsewhere must not spawn.
        if let InputMode::Confirm { argv } = &input_mode {
            let argv = argv.clone();
            match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    input_mode = InputMode::Normal;
                    let outcome = with_suspended_terminal(&mut terminal, || {
                        arena.spawn_interactive(&argv, state_root)
                    });
                    notice = match outcome {
                        Ok(()) => format!("ok: agent-arena {}", argv.join(" ")),
                        Err(e) => e,
                    };
                    status_cache = None;
                }
                KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc | KeyCode::Char('q') => {
                    input_mode = InputMode::Normal;
                    notice = "cancelled".to_string();
                }
                _ => {}
            }
            continue;
        }

        // Prompted input mode: editable buffer, Enter stages the confirm.
        if let InputMode::Input { kind, buffer } = &mut input_mode {
            match key.code {
                KeyCode::Esc => {
                    input_mode = InputMode::Normal;
                    notice = "cancelled".to_string();
                }
                KeyCode::Enter => {
                    let run_id = runs
                        .get(selected)
                        .map(|r| r.run_id.clone())
                        .unwrap_or_default();
                    let text = buffer.trim().to_string();
                    if text.is_empty() {
                        notice = "empty input; Esc to cancel".to_string();
                        continue;
                    }
                    let argv = match kind {
                        PromptKind::RejectReason => {
                            model::reject_argv(&run_id, &text)
                        }
                        PromptKind::DecisionSummary => {
                            model::decision_approve_argv(&run_id, &text)
                        }
                        PromptKind::RelayMessage => {
                            model::relay_writer_argv(&run_id, &text)
                        }
                    };
                    input_mode = InputMode::Confirm { argv };
                }
                KeyCode::Backspace => {
                    buffer.pop();
                }
                KeyCode::Char(c) => {
                    if key.modifiers.contains(KeyModifiers::CONTROL) {
                        continue;
                    }
                    buffer.push(c);
                }
                _ => {}
            }
            continue;
        }

        // Normal mode: navigation, staged actions, quit.
        match key.code {
            KeyCode::Char('q') => break,
            KeyCode::Char('j') | KeyCode::Down => {
                selected = (selected + 1).min(runs.len().saturating_sub(1));
            }
            KeyCode::Char('k') | KeyCode::Up => {
                selected = selected.saturating_sub(1);
            }
            KeyCode::Enter => {
                let Some(run) = runs.get(selected) else { continue };
                let fetched = arena
                    .status_json(&run.run_id, state_root)
                    .as_deref()
                    .map_err(Clone::clone)
                    .and_then(model::parse_status);
                match fetched {
                    Ok(status) => {
                        let session = status
                            .field_str("tmux_session")
                            .unwrap_or("")
                            .to_string();
                        notice = format!(
                            "{}: mode {} verdict {} (reviewer {}, writer {})",
                            status.run_id,
                            status.field_str("mode").unwrap_or("-"),
                            status.field_str("verdict").unwrap_or("-"),
                            status.panes.reviewer,
                            status.panes.writer
                        );
                        // The jump is the only non-arena spawn; it is
                        // inert (window focus) and needs no confirm.
                        if !session.is_empty() {
                            let jumped =
                                with_suspended_terminal(&mut terminal, || {
                                    arena.jump_writer_pane(&session)
                                });
                            if let Err(e) = jumped {
                                notice = e;
                            }
                        }
                        status_cache = Some(status);
                    }
                    Err(e) => notice = e,
                }
            }
            KeyCode::Char(c) => match model::keymap_action(c) {
                Some(action) => {
                    let Some(run) = runs.get(selected) else {
                        notice = "no run selected".to_string();
                        continue;
                    };
                    match action {
                        model::Action::Quit => break,
                        model::Action::Approve | model::Action::Validate => {
                            match model::action_argv(action, &run.run_id) {
                                Some(argv) => input_mode = InputMode::Confirm { argv },
                                None => notice = "cannot build argv".to_string(),
                            }
                        }
                        model::Action::Reject => {
                            input_mode = InputMode::Input {
                                kind: PromptKind::RejectReason,
                                buffer: String::new(),
                            };
                        }
                        model::Action::ToggleMode => {
                            // Never blind-toggle: fetch the live mode when
                            // the cache misses, then flip what is really
                            // there (a stale None would no-op a human run
                            // and could downgrade an auto run).
                            let mut current: Option<String> = match &status_cache {
                                Some(s) if s.run_id == run.run_id => {
                                    s.field_str("mode").map(str::to_string)
                                }
                                _ => None,
                            };
                            if current.is_none() {
                                match arena
                                    .status_json(&run.run_id, state_root)
                                    .as_deref()
                                    .map_err(Clone::clone)
                                    .and_then(model::parse_status)
                                {
                                    Ok(s) => {
                                        current = s.field_str("mode").map(str::to_string);
                                        status_cache = Some(s);
                                    }
                                    Err(e) => {
                                        notice = e;
                                        continue;
                                    }
                                }
                            }
                            input_mode = InputMode::Confirm {
                                argv: model::toggle_mode_argv(
                                    current.as_deref(),
                                    &run.run_id,
                                ),
                            };
                        }
                        model::Action::DecisionApprove => {
                            input_mode = InputMode::Input {
                                kind: PromptKind::DecisionSummary,
                                buffer: String::new(),
                            };
                        }
                        model::Action::RelayWriter => {
                            input_mode = InputMode::Input {
                                kind: PromptKind::RelayMessage,
                                buffer: String::new(),
                            };
                        }
                        model::Action::JumpWriterPane => { /* handled by Enter */ }
                    }
                }
                None => {}
            },
            _ => {}
        }
    }

    let _ = disable_raw_mode();
    let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
    result
}
