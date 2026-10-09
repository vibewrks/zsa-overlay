//! Reports the Moonlander's active layer by polling the Keymapp API over its
//! Unix domain socket.
//!
//! One JSON object per status is written to stdout (`--help` documents the
//! shape); diagnostics go to stderr.

use std::env;
use std::error::Error as StdError;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use serde::Serialize;
use tokio::time::MissedTickBehavior;
use tonic::transport::{Channel, Endpoint};

use api::keyboard_service_client::KeyboardServiceClient;
use api::{GetStatusReply, GetStatusRequest};

/// gRPC bindings generated from the official Keymapp API (`proto/keymapp.proto`).
pub mod api {
    #![allow(dead_code)]
    tonic::include_proto!("api");
}

const STATE_CONNECTED: &str = "connected";
const STATE_DISCONNECTED: &str = "disconnected";
const STATE_UNAVAILABLE: &str = "unavailable";

const DEFAULT_INTERVAL_MS: u64 = 100;
const MIN_INTERVAL_MS: u64 = 10;
const MAX_INTERVAL_MS: u64 = 60_000;

/// Upper bound on reaching Keymapp.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(1_000);
/// Upper bound on a single `GetStatus` call.
const REQUEST_TIMEOUT: Duration = Duration::from_millis(1_000);

/// Socket of a Keymapp installed from the direct download.
const SOCKET_PATH: &str = "Library/Application Support/.keymapp/keymapp.sock";
/// Socket of the sandboxed Mac App Store build.
const APP_STORE_SOCKET_PATH: &str =
    "Library/Containers/io.zsa.keymapp/Data/Library/Application Support/.keymapp/keymapp.sock";

/// Exit status when no trustworthy status could be produced.
const EXIT_UNAVAILABLE: u8 = 1;
/// Exit status for a malformed command line.
const EXIT_USAGE: u8 = 2;

const USAGE: &str = r#"Prints the Moonlander's active layer from Keymapp as JSON lines.

Usage:
  moonlander-layer-status --once  [--socket PATH]
  moonlander-layer-status --watch [--socket PATH] [--interval-ms MS]

Options:
  --once             Print one status line, then exit. Exit status is 1 when the
                     status is "unavailable" or could not be written.
  --watch            Print one status line per interval until interrupted
                     (Ctrl-C, or stdout being closed by the reader).
  --socket PATH      Keymapp Unix socket; defaults to the macOS Keymapp locations.
  --interval-ms MS   Poll interval in milliseconds (default 100, range 10..=60000).
  -h, --help         Print this help.
  -V, --version      Print the version.

stdout carries one JSON object per line:
  {"state":"connected|disconnected|unavailable","layer":<int|null>,"message":"<text>","keyboard":"<name|null>"}
stderr carries diagnostics."#;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = match parse_args(env::args_os().skip(1)) {
        Ok(cli) => cli,
        Err(message) => {
            eprintln!("moonlander-layer-status: {message}");
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
            println!("moonlander-layer-status {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Cli::Run(args) => run(args).await,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Once,
    Watch,
}

struct Args {
    mode: Mode,
    socket: Option<PathBuf>,
    interval_ms: u64,
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
    let mut socket = None;
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
            "--socket" => {
                let value = take_value(&mut args, inline, flag)?;
                if value.is_empty() {
                    return Err("--socket requires a path".to_string());
                }
                if socket.replace(PathBuf::from(value)).is_some() {
                    return Err("--socket was given more than once".to_string());
                }
            }
            "--interval-ms" => {
                let value = take_value(&mut args, inline, flag)?;
                let parsed: u64 = value.parse().map_err(|_| {
                    format!("--interval-ms expects a whole number of milliseconds, got {value:?}")
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

    let mode = mode.ok_or_else(|| "exactly one of --once or --watch is required".to_string())?;
    Ok(Cli::Run(Args {
        mode,
        socket,
        interval_ms: interval_ms.unwrap_or(DEFAULT_INTERVAL_MS),
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

async fn run(args: Args) -> ExitCode {
    let Args {
        mode,
        socket,
        interval_ms,
    } = args;
    // `--once` reports a single line, so its diagnostics travel in that line
    // instead of on stderr.
    let mut poller = Poller::new(socket, mode == Mode::Watch);
    let mut line = Vec::new();

    match mode {
        Mode::Once => {
            let report = poller.poll().await;
            let usable = report.state != STATE_UNAVAILABLE;
            match emit(&report, &mut line) {
                Ok(()) => {}
                Err(err) if err.kind() == io::ErrorKind::BrokenPipe => return ExitCode::SUCCESS,
                Err(err) => {
                    eprintln!("moonlander-layer-status: cannot write status to stdout: {err}");
                    return ExitCode::from(EXIT_UNAVAILABLE);
                }
            }
            if usable {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(EXIT_UNAVAILABLE)
            }
        }
        Mode::Watch => watch(&mut poller, Duration::from_millis(interval_ms), &mut line).await,
    }
}

async fn watch(poller: &mut Poller, interval: Duration, line: &mut Vec<u8>) -> ExitCode {
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);

    loop {
        tokio::select! {
            _ = &mut ctrl_c => {
                eprintln!("moonlander-layer-status: interrupted");
                return ExitCode::SUCCESS;
            }
            _ = ticker.tick() => {
                let report = poller.poll().await;
                match emit(&report, line) {
                    Ok(()) => {}
                    Err(err) if err.kind() == io::ErrorKind::BrokenPipe => return ExitCode::SUCCESS,
                    Err(err) => {
                        eprintln!("moonlander-layer-status: cannot write status to stdout: {err}");
                        return ExitCode::from(EXIT_UNAVAILABLE);
                    }
                }
            }
        }
    }
}

/// One line of the status stream.
#[derive(Serialize)]
struct StatusReport {
    state: &'static str,
    layer: Option<i32>,
    message: String,
    keyboard: Option<String>,
}

impl StatusReport {
    fn unavailable(message: String) -> Self {
        Self {
            state: STATE_UNAVAILABLE,
            layer: None,
            message,
            keyboard: None,
        }
    }
}

/// Socket locations to probe, or why they could not be determined.
type SocketCandidates = Result<Vec<PathBuf>, &'static str>;

/// Holds the Keymapp connection between polls so a healthy keyboard layer does
/// not cost a dial per status line.
struct Poller {
    socket: Option<PathBuf>,
    client: Option<KeyboardServiceClient<Channel>>,
    connected_to: Option<PathBuf>,
    notes: bool,
    last_note: Option<String>,
}

impl Poller {
    fn new(socket: Option<PathBuf>, notes: bool) -> Self {
        Self {
            socket,
            client: None,
            connected_to: None,
            notes,
            last_note: None,
        }
    }

    /// Produces one status line, dialing Keymapp when there is no live channel.
    ///
    /// A failed call, or the socket moving, drops the channel; the next poll
    /// dials again, so retries are bounded by the poll interval.
    async fn poll(&mut self) -> StatusReport {
        let candidates = socket_candidates(self.socket.as_deref());
        let existing: Vec<PathBuf> = match &candidates {
            Ok(candidates) => candidates
                .iter()
                .filter(|candidate| fs::symlink_metadata(candidate.as_path()).is_ok())
                .cloned()
                .collect(),
            Err(_) => Vec::new(),
        };

        if existing.is_empty() {
            self.disconnect();
            let message = match &candidates {
                Err(reason) => (*reason).to_string(),
                Ok(candidates) => format!("keymapp socket not found at {}", join_paths(candidates)),
            };
            return self.note(StatusReport::unavailable(message));
        }

        let bound_socket_is_gone = self
            .connected_to
            .as_ref()
            .is_some_and(|bound| !existing.contains(bound));
        if bound_socket_is_gone {
            self.disconnect();
        }
        if self.client.is_none() {
            match connect_first(&existing).await {
                Ok((client, path)) => {
                    self.client = Some(client);
                    self.connected_to = Some(path);
                }
                Err(message) => {
                    self.disconnect();
                    return self.note(StatusReport::unavailable(format!(
                        "keymapp is not reachable: {message}"
                    )));
                }
            }
        }

        let outcome = {
            let client = self
                .client
                .as_mut()
                .expect("a channel was established above");
            tokio::time::timeout(REQUEST_TIMEOUT, client.get_status(GetStatusRequest {})).await
        };

        match outcome {
            Ok(Ok(reply)) => self.note(report_from_reply(reply.into_inner())),
            Ok(Err(status)) => {
                self.disconnect();
                self.note(StatusReport::unavailable(format!(
                    "GetStatus failed: {}",
                    error_chain(&status)
                )))
            }
            Err(_) => {
                self.disconnect();
                self.note(StatusReport::unavailable(format!(
                    "GetStatus timed out after {} ms",
                    REQUEST_TIMEOUT.as_millis()
                )))
            }
        }
    }

    fn disconnect(&mut self) {
        self.client = None;
        self.connected_to = None;
    }

    /// Keeps stdout a pure status stream: changes are reported on stderr.
    fn note(&mut self, report: StatusReport) -> StatusReport {
        if self.notes {
            let note = if report.message.is_empty() {
                report.state.to_string()
            } else {
                format!("{}: {}", report.state, report.message)
            };
            if self.last_note.as_deref() != Some(note.as_str()) {
                eprintln!("moonlander-layer-status: {note}");
                self.last_note = Some(note);
            }
        }
        report
    }
}

/// Dials the first candidate socket that accepts a connection.
async fn connect_first(
    candidates: &[PathBuf],
) -> Result<(KeyboardServiceClient<Channel>, PathBuf), String> {
    let mut last_error = None;
    for path in candidates {
        match connect(path).await {
            Ok(client) => return Ok((client, path.clone())),
            Err(message) => last_error = Some(format!("{}: {message}", path.display())),
        }
    }
    Err(last_error.unwrap_or_else(|| "no socket to connect to".to_string()))
}

async fn connect(path: &Path) -> Result<KeyboardServiceClient<Channel>, String> {
    let socket = path
        .to_str()
        .ok_or_else(|| format!("socket path {} is not valid UTF-8", path.display()))?;
    // tonic dials Unix sockets natively for `unix://` endpoints.
    let endpoint =
        Endpoint::from_shared(format!("unix://{socket}")).map_err(|err| error_chain(&err))?;
    let channel = match tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect()).await {
        Ok(Ok(channel)) => channel,
        Ok(Err(err)) => return Err(error_chain(&err)),
        Err(_) => {
            return Err(format!(
                "connect timed out after {} ms",
                CONNECT_TIMEOUT.as_millis()
            ))
        }
    };
    Ok(KeyboardServiceClient::new(channel))
}

fn report_from_reply(reply: GetStatusReply) -> StatusReport {
    match reply.connected_keyboard {
        Some(keyboard) => StatusReport {
            state: STATE_CONNECTED,
            layer: Some(keyboard.current_layer),
            message: String::new(),
            keyboard: Some(keyboard.friendly_name),
        },
        None => StatusReport {
            state: STATE_DISCONNECTED,
            layer: None,
            message: "keymapp is running but no keyboard is connected".to_string(),
            keyboard: None,
        },
    }
}

/// Flattens an error's causes: transport failures otherwise read as a bare
/// "transport error" and lose the reason the socket was unusable.
fn error_chain(error: &(dyn StdError + 'static)) -> String {
    let mut message = String::new();
    let mut current = Some(error);
    let mut depth = 0;
    while let Some(err) = current {
        let text = err.to_string();
        if !text.is_empty() && !message.contains(&text) {
            if !message.is_empty() {
                message.push_str(": ");
            }
            message.push_str(&text);
        }
        depth += 1;
        if depth >= 8 {
            break;
        }
        current = err.source();
    }
    if message.is_empty() {
        "unknown error".to_string()
    } else {
        message
    }
}

/// Writes one JSON line, reusing `line` so a steady poll does not allocate.
fn emit(report: &StatusReport, line: &mut Vec<u8>) -> io::Result<()> {
    line.clear();
    serde_json::to_writer(&mut *line, report).map_err(io::Error::other)?;
    line.push(b'\n');

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    stdout.write_all(line)?;
    stdout.flush()
}

fn socket_candidates(explicit: Option<&Path>) -> SocketCandidates {
    if let Some(path) = explicit {
        return Ok(vec![path.to_path_buf()]);
    }
    let home = match env::var_os("HOME") {
        Some(home) if !home.is_empty() => PathBuf::from(home),
        _ => return Err("HOME is not set; pass --socket to name the Keymapp socket"),
    };
    Ok(vec![home.join(SOCKET_PATH), home.join(APP_STORE_SOCKET_PATH)])
}

fn join_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}
