//! Finding and talking to the Moonlander's Oryx raw HID interface.

use std::collections::BTreeSet;
use std::ffi::CString;
use std::time::{Duration, Instant};

use hidapi::{DeviceInfo, HidApi, HidDevice};

use crate::output::Snapshot;
use crate::protocol::{self, Event, KeyState};

/// How long a single Oryx reply may take before the request is retried.
const RESPONSE_TIMEOUT: Duration = Duration::from_millis(400);
/// How many times the protocol version request is sent before giving up.
const VERSION_ATTEMPTS: usize = 2;
/// How long pairing may take before the attempt is abandoned.
const PAIRING_TIMEOUT: Duration = Duration::from_millis(700);
/// Upper bound on one blocking read, so signals and unplug checks stay timely.
const READ_SLICE: Duration = Duration::from_millis(100);
/// How often the device list is re-checked while streaming.
const PRESENCE_CHECK: Duration = Duration::from_secs(1);
/// First reconnect delay; it doubles up to [`RETRY_MAX`].
pub const RETRY_MIN: Duration = Duration::from_millis(500);
/// Cap on the reconnect delay.
pub const RETRY_MAX: Duration = Duration::from_millis(4_000);
/// `kIOReturnExclusiveAccess` in the hex form IOKit reports it.
const KIORETURN_EXCLUSIVE_ACCESS: &str = "E00002C5";

/// Why a session could not be established.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// No Moonlander is on the bus.
    Disconnected,
    /// The keyboard is present but its raw HID interface is exclusively held.
    Busy {
        /// The underlying hidapi error, for diagnostics only.
        detail: String,
    },
    /// The keyboard answered but cannot be used; the string explains it.
    Unavailable(String),
}

impl Failure {
    /// The snapshot this failure reports, so the stream never drifts from reality.
    pub fn snapshot(&self) -> Snapshot {
        match self {
            Failure::Disconnected => Snapshot::disconnected(),
            Failure::Busy { .. } => Snapshot::busy(),
            Failure::Unavailable(message) => Snapshot::unavailable(message.clone()),
        }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::Disconnected => write!(formatter, "no Moonlander keyboard detected"),
            Failure::Busy { detail } => write!(
                formatter,
                "the raw HID interface is held by another process ({detail}); quit or disconnect Keymapp to use direct HID"
            ),
            Failure::Unavailable(message) => write!(formatter, "{message}"),
        }
    }
}

/// What one read produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadOutcome {
    /// A decodable Oryx event arrived.
    Event(Event),
    /// Nothing arrived within the slice; a timeout is healthy on an idle keyboard.
    Idle,
    /// The read failed; the device is gone or faulty.
    Lost,
}

/// The interface we opened, identified by its device path so unplugs are seen.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Identity {
    path: CString,
}

impl Identity {
    /// True when `info` describes the interface this session opened.
    fn matches(&self, info: &DeviceInfo) -> bool {
        info.path() == self.path.as_c_str()
    }
}

/// One Moonlander raw interface, with everything needed once the device-list
/// borrow ends.
struct Candidate {
    path: CString,
    keyboard: Option<String>,
}

/// A paired session with one Moonlander.
pub struct Session {
    device: HidDevice,
    identity: Identity,
    state: KeyState,
    /// Rebuilt in place on every change, so streaming allocates nothing.
    snapshot: Snapshot,
    next_presence: Instant,
}

impl Session {
    /// Finds the Moonlander, claims its raw HID interface, and pairs with it.
    ///
    /// Only ZSA's Oryx raw HID interface is looked at; keyboard and mouse
    /// interfaces are ignored, and several Moonlanders are refused rather than
    /// silently picking one.
    pub fn open(api: &mut HidApi) -> Result<Self, Failure> {
        refresh(api)?;
        let candidate = scan(api)?;
        let identity = Identity {
            path: candidate.path,
        };
        let device = match api.open_path(identity.path.as_c_str()) {
            Ok(device) => device,
            Err(error) => return Err(open_failure(api, &identity, error)),
        };

        let version = request_version(&device, api, &identity)?;
        if version != protocol::PROTOCOL_VERSION {
            return Err(Failure::Unavailable(format!(
                "unsupported Oryx protocol version {version} (this helper needs {})",
                protocol::PROTOCOL_VERSION
            )));
        }

        drain(&device);
        if let Err(error) = device.write(&protocol::pairing_request()) {
            return Err(write_failure(api, &identity, error));
        }
        let layer = match wait_for(&device, PAIRING_TIMEOUT, |event| match event {
            Event::Layer { layer } => Some(layer),
            _ => None,
        }) {
            Wait::Found(layer) => layer,
            Wait::Timeout => {
                return Err(Failure::Unavailable(
                    "the keyboard never reported its layer after pairing".to_string(),
                ))
            }
            Wait::Error => return Err(Failure::Disconnected),
        };

        let mut state = KeyState::new();
        state.apply(Event::Layer { layer });
        let mut pressed = Vec::new();
        state.pressed_into(&mut pressed);
        Ok(Self {
            device,
            identity,
            state,
            snapshot: Snapshot::connected(layer, pressed, candidate.keyboard),
            next_presence: Instant::now(),
        })
    }

    /// Reads until `deadline`, in bounded slices so signals and unplug checks
    /// stay timely.
    pub fn poll_until(&mut self, deadline: Instant) -> ReadOutcome {
        let wait = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1))
            .min(READ_SLICE);
        self.poll(wait)
    }

    /// Applies an event; true when the snapshot content changed.
    pub fn apply(&mut self, event: Event) -> bool {
        let changed = self.state.apply(event);
        if changed {
            self.refresh_snapshot();
        }
        changed
    }

    /// The current full snapshot for this session.
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    /// Forgets keys and layer; called before dropping a broken session.
    pub fn clear(&mut self) {
        self.state.clear();
        self.snapshot = Snapshot::disconnected();
    }

    /// Re-checks the device list at most once a second, so a physical unplug is
    /// noticed even when reads keep timing out with zero bytes.
    pub fn still_present(&mut self, api: &mut HidApi) -> bool {
        let now = Instant::now();
        if now < self.next_presence {
            return true;
        }
        self.next_presence = now + PRESENCE_CHECK;
        match api.refresh_devices() {
            // Cannot tell; assume the keyboard is still there and let reads decide.
            Err(_) => true,
            Ok(()) => api.device_list().any(|info| self.identity.matches(info)),
        }
    }

    /// Refreshes the cached snapshot in place; the pressed buffer and the
    /// keyboard name keep their allocations.
    fn refresh_snapshot(&mut self) {
        self.snapshot.layer = self.state.layer();
        self.state.pressed_into(&mut self.snapshot.pressed);
    }

    /// Reads one report, waiting at most `wait`.
    fn poll(&mut self, wait: Duration) -> ReadOutcome {
        let mut buffer = [0u8; 64];
        let slice = wait.min(READ_SLICE);
        match self.device.read_timeout(&mut buffer, slice.as_millis() as i32) {
            Ok(0) => ReadOutcome::Idle,
            Ok(read) => match protocol::decode(protocol::payload_of(&buffer[..read])) {
                Some(event) => ReadOutcome::Event(event),
                // Malformed reports are ignored, never trusted.
                None => ReadOutcome::Idle,
            },
            Err(_) => ReadOutcome::Lost,
        }
    }
}

/// Re-reads the OS device list; hidapi caches it per context.
fn refresh(api: &mut HidApi) -> Result<(), Failure> {
    api.refresh_devices()
        .map_err(|error| Failure::Unavailable(format!("cannot list HID devices: {error}")))
}

/// Picks the Oryx raw HID interface, refusing ambiguous setups.
fn scan(api: &HidApi) -> Result<Candidate, Failure> {
    let mut paths = BTreeSet::new();
    let mut candidate: Option<Candidate> = None;
    for info in api.device_list() {
        if info.vendor_id() != protocol::VENDOR_ID || info.product_id() != protocol::PRODUCT_ID {
            continue;
        }
        if info.usage_page() != protocol::RAW_USAGE_PAGE || info.usage() != protocol::RAW_USAGE {
            continue;
        }
        let path = info.path().to_owned();
        if paths.insert(path.clone()) {
            candidate = Some(Candidate {
                path,
                keyboard: info.product_string().map(str::to_owned),
            });
        }
    }

    if paths.len() > 1 {
        return Err(Failure::Unavailable(
            "multiple Moonlander keyboards detected — connect only one".to_string(),
        ));
    }
    candidate.ok_or(Failure::Disconnected)
}

/// Asks for the protocol version, retrying the request once with a bounded wait.
fn request_version(
    device: &HidDevice,
    api: &mut HidApi,
    identity: &Identity,
) -> Result<u8, Failure> {
    for _ in 0..VERSION_ATTEMPTS {
        if let Err(error) = device.write(&protocol::version_request()) {
            return Err(write_failure(api, identity, error));
        }
        match wait_for(device, RESPONSE_TIMEOUT, |event| match event {
            Event::Version { version } => Some(version),
            _ => None,
        }) {
            Wait::Found(version) => return Ok(version),
            Wait::Timeout => continue,
            Wait::Error => return Err(Failure::Disconnected),
        }
    }
    Err(Failure::Unavailable(
        "the keyboard never answered the protocol version request".to_string(),
    ))
}

/// Maps a failed open onto the truthful state.
///
/// hidapi opens the raw interface exclusively; while Keymapp holds it, IOKit
/// answers `kIOReturnExclusiveAccess` (`0xE00002C5`) and hidapi carries that
/// code in its error text — a busy keyboard that quitting Keymapp frees. A
/// device that vanished mid-open is disconnected; anything else (I/O errors,
/// permissions) is unavailable and reports hidapi's own message.
fn open_failure(api: &mut HidApi, identity: &Identity, error: hidapi::HidError) -> Failure {
    if let Ok(()) = api.refresh_devices() {
        if !api.device_list().any(|info| identity.matches(info)) {
            return Failure::Disconnected;
        }
    }
    if let hidapi::HidError::HidApiError { message } = &error {
        let upper = message.to_ascii_uppercase();
        if upper.contains(KIORETURN_EXCLUSIVE_ACCESS) || upper.contains("EXCLUSIVE") {
            return Failure::Busy {
                detail: message.clone(),
            };
        }
    }
    Failure::Unavailable(format!("cannot open the raw HID interface: {error}"))
}

/// Classifies a write failure after the interface was opened: an unplug looks
/// like a write error too, so check whether the device is still enumerated.
fn write_failure(api: &mut HidApi, identity: &Identity, error: hidapi::HidError) -> Failure {
    let present = match api.refresh_devices() {
        Ok(()) => api.device_list().any(|info| identity.matches(info)),
        // Cannot tell; assume the keyboard is still there.
        Err(_) => true,
    };
    if present {
        Failure::Unavailable(format!("cannot talk to the keyboard: {error}"))
    } else {
        Failure::Disconnected
    }
}

/// Outcome of waiting for a specific event.
enum Wait<T> {
    Found(T),
    Timeout,
    Error,
}

/// Reads until `pick` accepts an event, the deadline passes, or a read fails.
fn wait_for<T>(
    device: &HidDevice,
    timeout: Duration,
    mut pick: impl FnMut(Event) -> Option<T>,
) -> Wait<T> {
    let deadline = Instant::now() + timeout;
    let mut buffer = [0u8; 64];
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Wait::Timeout;
        }
        let slice = (deadline - now).min(READ_SLICE);
        match device.read_timeout(&mut buffer, slice.as_millis() as i32) {
            Ok(0) => continue,
            Ok(read) => {
                if let Some(event) = protocol::decode(protocol::payload_of(&buffer[..read])) {
                    if let Some(found) = pick(event) {
                        return Wait::Found(found);
                    }
                }
            }
            Err(_) => return Wait::Error,
        }
    }
}

/// Drops reports queued before this session; they describe an older pairing.
fn drain(device: &HidDevice) {
    let mut buffer = [0u8; 64];
    for _ in 0..protocol::PAYLOAD_LENGTH {
        match device.read_timeout(&mut buffer, 0) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}
