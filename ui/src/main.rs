//! agent-arena-ui — terminal dashboard for Agent Arena.
//!
//! v0 contract: `--selftest --state-root PATH` proves the full oracle
//! chain (spawn → JSON → strict parse → ordering) non-interactively;
//! with no arguments it runs the alternate-screen list view.

mod agent;
mod model;

use agent::Arena;
use model::{parse_list, sort_runs};

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

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
fn run_selftest(arena: &Arena, state_root: &Path) -> ExitCode {
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
    NewRun,
    /// Artifact reject gate: the stage name is resolved from the fresh
    /// status fetch at keypress time and carried here until submit.
    ArtifactRejectSummary { stage: String },
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
            PromptKind::ArtifactRejectSummary { stage } => {
                format!(
                    "artifact {} --stage {} --reject --summary <type>, Enter submit, Esc cancel",
                    run_id, stage
                )
            }
            PromptKind::NewRun => String::new(),
        }
    }

    /// The new-run wizard drives its own step hints from the RunWizard
    /// state, not from the selected run.
    fn is_wizard(&self) -> bool {
        matches!(self, PromptKind::NewRun)
    }
}

/// Full-screen draft reader (spec 2026-09-27-tui-artifact-viewer). The
/// content is oracle output (`artifact --show`), never a direct file read.
struct ArtifactViewer {
    run_id: String,
    stage: String,
    filename: String,
    content: String,
    previous: Option<String>,
    lines: usize,
    offset: usize,
    showing_previous: bool,
    notice: Option<String>,
}

impl ArtifactViewer {
    fn new(run_id: String, stage: String, filename: String, content: String) -> Self {
        let lines = content.lines().count();
        Self {
            run_id,
            stage,
            filename,
            content,
            previous: None,
            lines,
            offset: 0,
            showing_previous: false,
            notice: None,
        }
    }

    fn scroll(&mut self, delta: isize, viewport: usize) {
        let max = self.lines.saturating_sub(viewport);
        let next = self.offset as isize + delta;
        self.offset = next.clamp(0, max as isize) as usize;
    }
}

/// Interactive v0: alternate-screen list, j/k selection, Enter for the
/// status digest / writer-pane jump, keymap actions through the confirm
/// line, q quits. Terminal discipline: raw mode only inside this function,
/// the alternate screen is left around every child spawn.
fn run_tui(arena: &Arena, state_root: &Path) -> ExitCode {
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
    use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
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
    let mut notice = String::from("q quit · Enter status/jump · j/k move · a approve · r reject · d decision · l relay · m mode · v validate · g accept artifact · G reject artifact · o view artifact");
    let mut selected: usize = 0;
    let mut list_state = ListState::default();
    let mut input_mode = InputMode::Normal;
    let mut wizard: Option<model::RunWizard> = None;
    let mut status_cache: Option<model::StatusDoc> = None;
    let mut viewer: Option<ArtifactViewer> = None;
    let result = ExitCode::SUCCESS;

    // Live status (spec 2026-09-27): poll with a timeout instead of a
    // blocking read. A tick falls through to the loop top, whose Normal-mode
    // re-scan (list + status_cache refetch) is the refresh; input modes
    // never pay a subprocess on tick (guard below).
    const TICK: Duration = Duration::from_millis(1500);

    loop {
        // Re-scan only in Normal mode with no viewer open: typing into the
        // input line must not pay a subprocess per keystroke, staged
        // confirms render the already-fetched list, and the artifact
        // viewer shows static oracle output.
        if matches!(input_mode, InputMode::Normal) && viewer.is_none() {
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

        // Live status: keep the Enter-fetched status document fresh on
        // every Normal-mode iteration (including ticks). An oracle failure
        // or error document keeps the last good cache; a run that vanished
        // from the list drops it with an explanatory notice.
        if matches!(input_mode, InputMode::Normal) && viewer.is_none() {
            if let Some(s) = &status_cache {
                if !runs.iter().any(|r| r.run_id == s.run_id) {
                    notice = format!("{}: run gone from the state root", s.run_id);
                    status_cache = None;
                } else if let Ok(fetched) = arena
                    .status_json(&s.run_id, state_root)
                    .as_deref()
                    .map_err(Clone::clone)
                    .and_then(model::parse_status)
                {
                    if fetched.error.is_none() {
                        status_cache = Some(fetched);
                    } else {
                        notice = format!("{}: oracle error document; keeping the last good status", s.run_id);
                    }
                }
            }
        }

        let _ = terminal.draw(|f| {
            if let Some(v) = &viewer {
                let file_label = if v.showing_previous {
                    format!("regen-{}.md", v.stage)
                } else {
                    v.filename.clone()
                };
                let title = format!(
                    "{} / {}  (j/k line, PgUp/PgDn page, p previous, Esc back)",
                    v.run_id, file_label
                );
                let body = if v.showing_previous {
                    v.previous.as_deref().unwrap_or("")
                } else {
                    v.content.as_str()
                };
                let viewport = f.area().height.saturating_sub(2) as usize;
                let offset = v.offset.min(v.lines.saturating_sub(viewport));
                let mut block = Block::default().title(title).borders(Borders::ALL);
                if let Some(msg) = &v.notice {
                    block = block.title_bottom(ratatui::text::Line::from(msg.clone()));
                }
                let para = Paragraph::new(body)
                    .block(block)
                    .wrap(Wrap { trim: false })
                    .scroll((offset as u16, 0));
                f.render_widget(para, f.area());
                return;
            }
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
                    if kind.is_wizard() {
                        match &wizard {
                            Some(w) => format!("{} {}", w.hint(), buffer),
                            None => format!("{} > {}", kind.hint(selected_id), buffer),
                        }
                    } else {
                        format!("{} > {}", kind.hint(selected_id), buffer)
                    }
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
                // Pipeline runs also render the stage chain on the second
                // row of the two-row status area; non-pipeline and
                // error-path documents skip it entirely (stage_chain is
                // None there).
                if let Some(chain) = s.stage_chain() {
                    let chain_area = Rect::new(chunks[2].x, chunks[2].y + 1, chunks[2].width, 1);
                    f.render_widget(Paragraph::new(chain), chain_area);
                }
            }
        });

        let has_input = match event::poll(TICK) {
            Ok(b) => b,
            Err(_) => break,
        };
        if !has_input {
            continue;
        }
        let event = match event::read() {
            Ok(ev) => ev,
            Err(_) => break,
        };
        let Event::Key(key) = event else { continue };

        // Artifact viewer owns the keyboard while open (spec §2).
        if let Some(v) = &mut viewer {
            v.notice = None;
            match key.code {
                KeyCode::Esc | KeyCode::Char('q') => viewer = None,
                KeyCode::Char('j') | KeyCode::Down => v.scroll(1, 1),
                KeyCode::Char('k') | KeyCode::Up => v.scroll(-1, 1),
                KeyCode::PageDown => v.scroll(15, 1),
                KeyCode::PageUp => v.scroll(-15, 1),
                KeyCode::Char('p') => {
                    // Previous-version toggle (spec 2026-09-27-tui-artifact-
                    // viewer §2): one oracle fetch per toggle-in, cached.
                    if v.showing_previous {
                        v.showing_previous = false;
                        v.lines = v.content.lines().count();
                        v.offset = 0;
                    } else {
                        if v.previous.is_none() {
                            match arena.oracle_output(
                                &model::artifact_show_previous_argv(&v.run_id, &v.stage),
                                state_root,
                            ) {
                                Ok(text) => v.previous = Some(text),
                                Err(e) => v.notice = Some(e),
                            }
                        }
                        if v.previous.is_some() {
                            v.showing_previous = true;
                            if let Some(prev) = &v.previous {
                                v.lines = prev.lines().count();
                            }
                            v.offset = 0;
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
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
        // The new-run wizard owns its prompt sequence (spec §11): Enter
        // advances the step, Esc cancels at every step, and q cancels on
        // an empty buffer (AC8). Non-wizard prompts keep the original
        // behavior below.
        if let InputMode::Input { kind, buffer } = &mut input_mode {
            if kind.is_wizard() {
                match key.code {
                    KeyCode::Esc => {
                        wizard = None;
                        input_mode = InputMode::Normal;
                        notice = "cancelled".to_string();
                    }
                    KeyCode::Char('q') if buffer.is_empty() => {
                        wizard = None;
                        input_mode = InputMode::Normal;
                        notice = "cancelled".to_string();
                    }
                    KeyCode::Enter => {
                        if let Some(w) = wizard.as_mut() {
                            let text = buffer.trim().to_string();
                            match w.submit(&text) {
                                Ok(()) => {
                                    buffer.clear();
                                    if w.finished() {
                                        // Take the finished wizard out and
                                        // stage the verbatim confirm line.
                                        if let Some(w) = wizard.take() {
                                            match w.argv() {
                                                Some(argv) => {
                                                    input_mode = InputMode::Confirm { argv };
                                                    notice =
                                                        "note: per-stage models come from roles.conf; start does not carry model overrides in v0.7"
                                                            .to_string();
                                                }
                                                None => {
                                                    notice = "cannot build argv".to_string();
                                                }
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    notice = e;
                                }
                            }
                        }
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
                        // Unreachable: the wizard branch above consumed
                        // NewRun input; kept total for exhaustiveness.
                        PromptKind::NewRun => unreachable!(),
                        PromptKind::RejectReason => {
                            model::reject_argv(&run_id, &text)
                        }
                        PromptKind::DecisionSummary => {
                            model::decision_approve_argv(&run_id, &text)
                        }
                        PromptKind::RelayMessage => {
                            model::relay_writer_argv(&run_id, &text)
                        }
                        PromptKind::ArtifactRejectSummary { stage } => {
                            model::artifact_reject_argv(&run_id, stage, &text)
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
            KeyCode::Char(c) => {
                if let Some(action) = model::keymap_action(c) {
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
                        model::Action::ArtifactAccept | model::Action::ArtifactReject => {
                            // Gate target resolution happens at keypress
                            // time from a FRESH fetch — never from the
                            // auto-refresh cache (spec 2026-09-27 §2).
                            let fetched = arena
                                .status_json(&run.run_id, state_root)
                                .as_deref()
                                .map_err(Clone::clone)
                                .and_then(model::parse_status);
                            let stage = match fetched {
                                Ok(s) => s.awaiting_stage().map(str::to_string),
                                Err(e) => {
                                    notice = e;
                                    continue;
                                }
                            };
                            let Some(stage) = stage else {
                                notice = "no artifact awaiting accept".to_string();
                                continue;
                            };
                            match action {
                                model::Action::ArtifactAccept => {
                                    input_mode = InputMode::Confirm {
                                        argv: model::artifact_accept_argv(&run.run_id, &stage),
                                    };
                                }
                                _ => {
                                    input_mode = InputMode::Input {
                                        kind: PromptKind::ArtifactRejectSummary { stage },
                                        buffer: String::new(),
                                    };
                                }
                            }
                        }
                        model::Action::ViewArtifact => {
                            // Same fresh-fetch resolution as the gate keys:
                            // awaiting draft first, else the furthest
                            // accepted artifact (spec 2026-09-27 §2).
                            let fetched = arena
                                .status_json(&run.run_id, state_root)
                                .as_deref()
                                .map_err(Clone::clone)
                                .and_then(model::parse_status);
                            let target = match fetched {
                                Ok(s) => match s.awaiting_stage() {
                                    Some(stage) => {
                                        Some((stage.to_string(), format!("{stage}-draft.md")))
                                    }
                                    None => s.latest_accepted_stage().map(|stage| {
                                        (stage.to_string(), format!("{stage}.md"))
                                    }),
                                },
                                Err(e) => {
                                    notice = e;
                                    continue;
                                }
                            };
                            let Some((stage, filename)) = target else {
                                notice = "no artifact to view".to_string();
                                continue;
                            };
                            match arena
                                .oracle_output(
                                    &model::artifact_show_argv(&run.run_id, &stage),
                                    state_root,
                                )
                            {
                                Ok(text) => {
                                    viewer = Some(ArtifactViewer::new(
                                        run.run_id.clone(),
                                        stage,
                                        filename,
                                        text,
                                    ));
                                }
                                Err(e) => notice = e,
                            }
                        }
                        model::Action::NewRun => {
                            wizard = Some(model::RunWizard::new());
                            input_mode = InputMode::Input {
                                kind: PromptKind::NewRun,
                                buffer: String::new(),
                            };
                        }
                        model::Action::JumpWriterPane => { /* handled by Enter */ }
                    }
                }
            }
            _ => {}
        }
    }

    let _ = disable_raw_mode();
    let _ = crossterm::execute!(std::io::stdout(), LeaveAlternateScreen);
    result
}
