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
fn run_tui(arena: &Arena, state_root: &PathBuf) -> ExitCode {
    // Interactive guard: without a tty the event loop would block forever
    // (tests, cron, pipes). Fail fast with the dispatch hint instead.
    use crossterm::tty::IsTty;
    if !std::io::stdin().is_tty() {
        eprintln!("agent-arena-ui: interactive mode requires a tty");
        return ExitCode::FAILURE;
    }
    use crossterm::event::{self, Event, KeyCode, KeyEventKind};
    use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
    use ratatui::backend::CrosstermBackend;
    use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};
    use ratatui::Terminal;

    if enable_raw_mode().is_err() {
        eprintln!("agent-arena-ui: tty required for the interactive view");
        return ExitCode::FAILURE;
    }
    let _ = crossterm::execute!(std::io::stdout(), EnterAlternateScreen);
    let backend = CrosstermBackend::new(std::io::stdout());
    let terminal = Terminal::new(backend);
    let mut terminal = match terminal {
        Ok(t) => t,
        Err(_) => {
            let _ = disable_raw_mode();
            let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
            return ExitCode::FAILURE;
        }
    };

    let mut runs = Vec::new();
    let mut notice = String::from("q quit · Enter status · j/k move · r refresh");
    let mut selected: usize = 0;
    let mut list_state = ListState::default();
    let mut result = ExitCode::SUCCESS;

    loop {
        let raw = arena.list_json(state_root);
        let doc = raw.as_deref().map_err(Clone::clone).and_then(parse_list);
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

        let _ = terminal.draw(|f| {
            let items: Vec<ListItem> = runs
                .iter()
                .map(|r| ListItem::new(r.digest()))
                .collect();
            let list = List::new(items)
                .block(Block::default().title("agent-arena runs").borders(Borders::ALL))
                .highlight_symbol("> ");
            f.render_stateful_widget(list, f.size(), &mut list_state);
            let area = f.size();
            let hint = Paragraph::new(notice.as_str()).block(Block::default().borders(Borders::TOP));
            use ratatui::layout::Rect;
            let hint_area = Rect::new(area.x, area.bottom().saturating_sub(2), area.width, 2);
            f.render_widget(hint, hint_area);
        });
        if selected >= runs.len() {
            selected = runs.len().saturating_sub(1);
        }
        list_state.select(Some(selected));

        if let Ok(Event::Key(key)) = event::read() {
            if key.kind == KeyEventKind::Press {
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char('j') | KeyCode::Down => {
                        selected = (selected + 1).min(runs.len().saturating_sub(1));
                    }
                    KeyCode::Char('k') | KeyCode::Up => {
                        selected = selected.saturating_sub(1);
                    }
                    KeyCode::Char('r') => { /* refresh: the loop re-reads */ }
                    KeyCode::Enter => {
                        if let Some(run) = runs.get(selected) {
                            match arena
                                .status_json(&run.run_id, state_root)
                                .as_deref()
                                .map_err(Clone::clone)
                                .and_then(model::parse_status)
                            {
                                Ok(status) => {
                                    let verdict = status
                                        .field_str("verdict")
                                        .unwrap_or("-")
                                        .to_string();
                                    notice = format!(
                                        "{}: {} (reviewer pane: {}, writer pane: {})",
                                        status.run_id, verdict, status.panes.reviewer, status.panes.writer
                                    );
                                }
                                Err(e) => notice = e,
                            }
                        }
                    }
                    other => {
                        if let Some(action) = model::keymap_action(
                            match other {
                                KeyCode::Char(c) => c,
                                _ => ' ',
                            },
                        ) {
                            notice = format!("action {action:?} needs the selected run flow (v0: read-only)");
                        }
                    }
                }
            }
        }
    }

    let _ = disable_raw_mode();
    let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
    result
}
