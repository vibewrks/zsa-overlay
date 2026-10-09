//! Streams the Moonlander's active layer and pressed keys as JSON lines,
//! straight from the Oryx raw HID interface (no Keymapp API involved).
//!
//! `--watch` (the default) writes a full snapshot whenever a key or the layer
//! changes and at least every `--interval-ms`; `--once` writes a single
//! snapshot. Diagnostics go to stderr.

mod hid;
mod output;
mod protocol;

use std::env;
use std::ffi::OsString;
use std::io;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use hidapi::HidApi;

use crate::hid::{ReadOutcome, Session, RETRY_MAX, RETRY_MIN};
use crate::output::{Emitter, Snapshot, State};

/// Exit status when no trustworthy snapshot could be produced.
const EXIT_UNAVAILABLE: u8 = 1;
/// Exit status for a malformed command line.
const EXIT_USAGE: u8 = 2;

const DEFAULT_INTERVAL_MS: u64 = 200;
const MIN_INTERVAL_MS: u64 = 10;
const MAX_INTERVAL_MS: u64 = 60_000;

/// Longest sleep while waiting to reconnect, so signals stay responsive.
const WAIT_SLICE: Duration = Duration::from_millis(50);

const USAGE: &str = r#"Prints the Moonlander's layer and pressed keys over direct HID as JSON lines.

Usage:
  moonlander-keyboard-state [--once | --watch] [--interval-ms MS]

Options:
  --once             Print one snapshot, then exit. Exit status is 0 only when
                     the state is "connected".
  --watch            Keep printing snapshots: immediately when a key or the
                     layer changes, and at least every interval. This is the
                     default.
  --interval-ms MS   Snapshot interval in milliseconds (default 200, range 10..=60000).
  -h, --help         Print this help.
  -V, --version      Print the version.

The helper talks to the keyboard's Oryx raw HID interface directly. Keymapp
holds that interface exclusively, so quit or disconnect Keymapp to use it.

stdout carries one JSON object per line:
  {"state":"connected|busy|disconnected|unavailable","layer":<int|null>,"pressed":[{"row":<int>,"column":<int>}],"message":"<text>","keyboard":"<name|null>"}
stderr carries diagnostics. Exit status is 1 when a --once snapshot is not
"connected", 2 for usage errors."#;

fn main() -> ExitCode {
    let cli = match parse_args(env::args_os().skip(1)) {
        Ok(cli) => cli,
        Err(message) => {
            eprintln!("moonlander-keyboard-state: {message}");
            eprintln!("{USAGE}");
            return ExitCode::from(EXIT_USAGE);
        }
    };

    match cli {
        Cli::Help => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Cli::Version => {
            println!("moonlander-keyboard-state {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Cli::Run(args) => match args.mode {
            Mode::Once => once(),
            Mode::Watch => match install_signal_handler() {
                Ok(quit) => watch(&quit, args.interval),
                Err(err) => {
                    eprintln!("moonlander-keyboard-state: cannot install signal handler: {err}");
                    ExitCode::from(EXIT_UNAVAILABLE)
                }
            },
        },
    }
}

/// Marks SIGINT/SIGTERM so the run loop can release the keyboard and exit.
fn install_signal_handler() -> Result<Arc<AtomicBool>, ctrlc::Error> {
    let quit = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&quit);
    ctrlc::set_handler(move || flag.store(true, Ordering::SeqCst))?;
    Ok(quit)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Once,
    Watch,
}

struct Args {
    mode: Mode,
    interval: Duration,
}

enum Cli {
    Help,
    Version,
    Run(Args),
}

fn parse_args(argv: impl IntoIterator<Item = OsString>) -> Result<Cli, String> {
    let argv = argv
        .into_iter()
        .map(|arg| {
            arg.into_string()
                .map_err(|_| "arguments must be valid UTF-8".to_string())
        })
        .collect::<Result<Vec<String>, String>>()?;

    let mut mode = None;
    let mut interval_ms = None;
    let mut args = argv.into_iter();

    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (arg.as_str(), None),
        };
        match flag {
            "-h" | "--help" => return Ok(Cli::Help),
            "-V" | "--version" => return Ok(Cli::Version),
            "--once" => set_mode(&mut mode, Mode::Once, flag, inline)?,
            "--watch" => set_mode(&mut mode, Mode::Watch, flag, inline)?,
            "--interval-ms" => {
                let value = take_value(&mut args, inline, flag)?;
                let parsed: u64 = value.parse().map_err(|_| {
                    format!("--interval-ms expects whole milliseconds, got {value:?}")
                })?;
                if !(MIN_INTERVAL_MS..=MAX_INTERVAL_MS).contains(&parsed) {
                    return Err(format!(
                        "--interval-ms must be between {MIN_INTERVAL_MS} and {MAX_INTERVAL_MS}"
                    ));
                }
                if interval_ms.replace(parsed).is_some() {
                    return Err("--interval-ms was given more than once".to_string());
                }
            }
            other => return Err(format!("unrecognized argument {other:?}")),
        }
    }

    let interval_ms = interval_ms.unwrap_or(DEFAULT_INTERVAL_MS);
    Ok(Cli::Run(Args {
        mode: mode.unwrap_or(Mode::Watch),
        interval: Duration::from_millis(interval_ms),
    }))
}

fn set_mode(
    mode: &mut Option<Mode>,
    value: Mode,
    flag: &str,
    inline: Option<&str>,
) -> Result<(), String> {
    if inline.is_some() {
        return Err(format!("{flag} does not take a value"));
    }
    if mode.is_some() {
        return Err("--once and --watch are mutually exclusive".to_string());
    }
    *mode = Some(value);
    Ok(())
}

fn take_value(
    args: &mut impl Iterator<Item = String>,
    inline: Option<&str>,
    flag: &str,
) -> Result<String, String> {
    let value = match inline {
        Some(value) => value.to_string(),
        None => args
            .next()
            .ok_or_else(|| format!("{flag} requires a value"))?,
    };
    if value.starts_with("--") {
        return Err(format!("{flag} requires a value, got the option {value:?}"));
    }
    Ok(value)
}

/// One shot: a single snapshot; exit status 1 unless it is `connected`.
fn once() -> ExitCode {
    let mut emitter = Emitter::new(io::stdout().lock());

    let mut api = match HidApi::new() {
        Ok(api) => api,
        Err(err) => {
            let message = format!("cannot initialize hidapi: {err}");
            eprintln!("moonlander-keyboard-state: {message}");
            let snapshot = Snapshot::unavailable(message);
            return match write_snapshot(&mut emitter, &snapshot) {
                Ok(()) => ExitCode::from(EXIT_UNAVAILABLE),
                Err(code) => code,
            };
        }
    };

    match Session::open(&mut api) {
        Ok(session) => {
            let connected = session.snapshot().state == State::Connected;
            match write_snapshot(&mut emitter, session.snapshot()) {
                Ok(()) if connected => ExitCode::SUCCESS,
                Ok(()) => ExitCode::from(EXIT_UNAVAILABLE),
                Err(code) => code,
            }
        }
        Err(failure) => {
            eprintln!("moonlander-keyboard-state: {failure}");
            let snapshot = failure.snapshot();
            match write_snapshot(&mut emitter, &snapshot) {
                Ok(()) => ExitCode::from(EXIT_UNAVAILABLE),
                Err(code) => code,
            }
        }
    }
}

/// Streams snapshots until interrupted or stdout closes.
fn watch(quit: &AtomicBool, interval: Duration) -> ExitCode {
    let mut emitter = Emitter::new(io::stdout().lock());
    let mut api = match HidApi::new() {
        Ok(api) => api,
        Err(err) => {
            let message = format!("cannot initialize hidapi: {err}");
            eprintln!("moonlander-keyboard-state: {message}");
            let snapshot = Snapshot::unavailable(message);
            return match write_snapshot(&mut emitter, &snapshot) {
                Ok(()) => ExitCode::from(EXIT_UNAVAILABLE),
                Err(code) => code,
            };
        }
    };

    let mut standing = Snapshot::disconnected();
    let mut session: Option<Session> = None;
    let mut backoff = RETRY_MIN;
    let mut next_probe = Instant::now();
    let mut next_emit = Instant::now();
    let mut notes = Notes::default();

    loop {
        if quit.load(Ordering::SeqCst) {
            return ExitCode::SUCCESS;
        }
        let now = Instant::now();

        if session.is_none() && now >= next_probe {
            match Session::open(&mut api) {
                Ok(opened) => {
                    notes.clear();
                    session = Some(opened);
                    backoff = RETRY_MIN;
                }
                Err(failure) => {
                    notes.say(&failure.to_string());
                    standing = failure.snapshot();
                    next_probe = now + backoff;
                    backoff = (backoff * 2).min(RETRY_MAX);
                }
            }
            next_emit = Instant::now();
            continue;
        }

        if now >= next_emit {
            let current = match session.as_ref() {
                Some(active) => active.snapshot(),
                None => &standing,
            };
            if let Err(code) = write_snapshot(&mut emitter, current) {
                return code;
            }
            next_emit = Instant::now() + interval;
        }

        let mut lost: Option<&'static str> = None;
        match session.as_mut() {
            Some(active) => {
                match active.poll_until(next_emit) {
                    ReadOutcome::Event(event) => {
                        if active.apply(event) {
                            next_emit = Instant::now() + interval;
                            if let Err(code) = write_snapshot(&mut emitter, active.snapshot()) {
                                return code;
                            }
                        }
                    }
                    ReadOutcome::Idle => {}
                    ReadOutcome::Lost => {
                        lost = Some("lost the keyboard connection; reconnecting");
                    }
                }
                if lost.is_none() && !active.still_present(&mut api) {
                    lost = Some("the Moonlander is no longer on the bus; waiting for it");
                }
            }
            None => {
                let wake = next_emit.min(next_probe);
                let wait = wake
                    .saturating_duration_since(Instant::now())
                    .max(Duration::from_millis(1))
                    .min(WAIT_SLICE);
                thread::sleep(wait);
            }
        }

        if let Some(reason) = lost {
            notes.say(reason);
            if let Some(mut broken) = session.take() {
                // No key may stay stuck down after a teardown.
                broken.clear();
            }
            backoff = RETRY_MIN;
            standing = Snapshot::disconnected();
            next_probe = Instant::now() + RETRY_MIN;
            next_emit = Instant::now();
        }
    }
}

/// Writes one snapshot; `Err` carries the exit code to use.
fn write_snapshot(
    emitter: &mut Emitter<io::StdoutLock<'static>>,
    snapshot: &Snapshot,
) -> Result<(), ExitCode> {
    match emitter.emit(snapshot) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::BrokenPipe => Err(ExitCode::SUCCESS),
        Err(err) => {
            eprintln!("moonlander-keyboard-state: cannot write snapshot: {err}");
            Err(ExitCode::from(EXIT_UNAVAILABLE))
        }
    }
}

/// Prints diagnostics to stderr, only when the message changes.
#[derive(Default)]
struct Notes {
    last: String,
}

impl Notes {
    fn say(&mut self, message: &str) {
        if self.last != message {
            eprintln!("moonlander-keyboard-state: {message}");
            self.last.clear();
            self.last.push_str(message);
        }
    }

    fn clear(&mut self) {
        self.last.clear();
    }
}
