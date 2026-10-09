//! Snapshot modelling and the NDJSON writer.

use std::io::{self, Write};

use serde::Serialize;

use crate::protocol::MatrixPosition;

/// The connection states the helper reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Handshake completed: the keyboard is paired and its layer is known.
    Connected,
    /// A Moonlander is present but another process holds its raw HID interface.
    Busy,
    /// No Moonlander is on the bus.
    Disconnected,
    /// The keyboard is there but unusable (wrong protocol, several keyboards).
    Unavailable,
}

/// One full status snapshot: the unit of the stdout stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Snapshot {
    /// Connection state.
    pub state: State,
    /// Active layer, only once the handshake established a real one.
    pub layer: Option<u8>,
    /// Held keys, by physical position.
    pub pressed: Vec<MatrixPosition>,
    /// Human-readable detail for non-connected states.
    pub message: String,
    /// Keyboard product name, only while connected.
    pub keyboard: Option<String>,
}

impl Snapshot {
    /// A paired keyboard with an established layer.
    pub fn connected(layer: u8, pressed: Vec<MatrixPosition>, keyboard: Option<String>) -> Self {
        Self {
            state: State::Connected,
            layer: Some(layer),
            pressed,
            message: String::new(),
            keyboard,
        }
    }

    /// The keyboard is held by another process; nothing is known about it.
    pub fn busy() -> Self {
        Self {
            state: State::Busy,
            layer: None,
            pressed: Vec::new(),
            message: "Quit/disconnect Keymapp to use direct HID".to_string(),
            keyboard: None,
        }
    }

    /// No keyboard is present; nothing is pressed or known.
    pub fn disconnected() -> Self {
        Self {
            state: State::Disconnected,
            layer: None,
            pressed: Vec::new(),
            message: "no Moonlander keyboard detected".to_string(),
            keyboard: None,
        }
    }

    /// The keyboard cannot be used; `message` says why. Never carries a layer.
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self {
            state: State::Unavailable,
            layer: None,
            pressed: Vec::new(),
            message: message.into(),
            keyboard: None,
        }
    }
}

/// Writes one JSON object per line and flushes, so readers see snapshots at once.
pub struct Emitter<W: Write> {
    out: W,
}

impl<W: Write> Emitter<W> {
    /// Wraps a writer, usually a locked stdout.
    pub fn new(out: W) -> Self {
        Self { out }
    }

    /// Writes one snapshot as a single NDJSON line.
    pub fn emit(&mut self, snapshot: &Snapshot) -> io::Result<()> {
        let mut line = serde_json::to_vec(snapshot)
            .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
        line.push(b'\n');
        self.out.write_all(&line)?;
        self.out.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn connected_snapshot_serializes_the_full_contract_shape() {
        let snapshot = Snapshot::connected(
            2,
            vec![MatrixPosition { row: 2, column: 1 }],
            Some("Moonlander MK1".to_string()),
        );

        assert_eq!(
            serde_json::to_value(&snapshot).expect("snapshot serializes"),
            json!({
                "state": "connected",
                "layer": 2,
                "pressed": [{"row": 2, "column": 1}],
                "message": "",
                "keyboard": "Moonlander MK1",
            })
        );
    }

    #[test]
    fn unavailable_snapshots_never_invent_a_layer() {
        let value = serde_json::to_value(Snapshot::unavailable("unsupported protocol"))
            .expect("snapshot serializes");

        assert_eq!(value["state"], json!("unavailable"));
        assert_eq!(value["layer"], json!(null));
        assert_eq!(value["pressed"], json!([]));
        assert_eq!(value["keyboard"], json!(null));
        assert_eq!(value["message"], json!("unsupported protocol"));
    }

    #[test]
    fn busy_snapshot_carries_the_actionable_message() {
        let snapshot = Snapshot::busy();
        assert_eq!(snapshot.message, "Quit/disconnect Keymapp to use direct HID");
        assert_eq!(snapshot.layer, None);
        assert!(snapshot.pressed.is_empty());
    }

    #[test]
    fn emitter_writes_one_ndjson_line_per_snapshot() {
        let mut buffer = Vec::new();
        {
            let mut emitter = Emitter::new(&mut buffer);
            emitter.emit(&Snapshot::disconnected()).expect("first line");
            emitter.emit(&Snapshot::busy()).expect("second line");
        }

        let text = String::from_utf8(buffer).expect("utf8");
        assert_eq!(text.matches('\n').count(), 2, "one terminated line per snapshot");
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);

        let first: serde_json::Value = serde_json::from_str(lines[0]).expect("parse first");
        let second: serde_json::Value = serde_json::from_str(lines[1]).expect("parse second");
        assert_eq!(first["state"], json!("disconnected"));
        assert_eq!(second["state"], json!("busy"));
    }
}
