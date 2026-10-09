//! The Oryx raw HID protocol used by ZSA keyboards.
//!
//! Framing, report decoding, and the key/layer bookkeeping the helper exposes.
//! The byte layout follows `oryx/oryx.h` and `oryx/oryx.c` in
//! <https://github.com/zsa/qmk_modules>; the matrix table mirrors the verified
//! Oryx ordering in the app's `MoonlanderMatrix.swift`.

use serde::Serialize;

/// ZSA Technologies vendor id.
pub const VENDOR_ID: u16 = 0x3297;
/// Moonlander product id.
pub const PRODUCT_ID: u16 = 0x1969;
/// Usage page of the Oryx raw HID interface.
pub const RAW_USAGE_PAGE: u16 = 0xff60;
/// Usage of the Oryx raw HID interface.
pub const RAW_USAGE: u16 = 0x61;

/// Report id `hidapi` expects as the first byte of every write.
pub const REPORT_ID: u8 = 0x00;
/// Length of the Oryx report payload, without the report id.
pub const PAYLOAD_LENGTH: usize = 32;
/// The firmware's terminator for a parameter list.
pub const STOP_BIT: u8 = 0xfe;

/// Host -> keyboard: request the Oryx protocol version.
pub const CMD_GET_PROTOCOL_VERSION: u8 = 0xfe;
/// Host -> keyboard: pair this host so keyboard events start flowing.
pub const CMD_PAIRING_INIT: u8 = 0x01;

/// Keyboard -> host: pairing succeeded; a layer event follows.
pub const EVT_PAIRING_SUCCESS: u8 = 0x04;
/// Keyboard -> host: active layer changed, `[0x05, layer, stop]`.
pub const EVT_LAYER: u8 = 0x05;
/// Keyboard -> host: key down, `[0x06, column, row, stop]`.
pub const EVT_KEY_DOWN: u8 = 0x06;
/// Keyboard -> host: key up, `[0x07, column, row, stop]`.
pub const EVT_KEY_UP: u8 = 0x07;
/// Keyboard -> host: version reply, `[0xfe, version, stop]`.
pub const EVT_GET_PROTOCOL_VERSION: u8 = 0xfe;

/// The Oryx protocol version this helper understands.
pub const PROTOCOL_VERSION: u8 = 0x05;

/// Rows of the Moonlander matrix.
const MATRIX_ROWS: usize = 12;
/// Columns of the Moonlander matrix.
const MATRIX_COLUMNS: usize = 7;
/// Cells in the row-major matrix bitmap; not every cell is a key.
const CELLS: usize = MATRIX_ROWS * MATRIX_COLUMNS;
/// Words the held-key bitmap needs; 84 cells fit in two 64-bit words.
const WORDS: usize = (CELLS + 63) / 64;
/// One mask bit per column of each matrix row: `KEY_MASKS[row] & (1 << column)`
/// is set for the board's 72 physical keys, so matrix holes are never keys.
const KEY_MASKS: [u8; MATRIX_ROWS] = [
    0x7f, // row 0: columns 0..=6
    0x7f, // row 1: columns 0..=6
    0x7f, // row 2: columns 0..=6
    0x3f, // row 3: columns 0..=5
    0x1f, // row 4: columns 0..=4
    0x0f, // row 5: columns 0..=3
    0x7f, // row 6: columns 0..=6
    0x7f, // row 7: columns 0..=6
    0x7f, // row 8: columns 0..=6
    0x7e, // row 9: columns 1..=6
    0x7c, // row 10: columns 2..=6
    0x78, // row 11: columns 3..=6
];

/// Builds the report `hidapi` writes: report id, command, parameter, zeros.
fn command_report(command: u8, parameter: u8) -> [u8; PAYLOAD_LENGTH + 1] {
    let mut report = [0u8; PAYLOAD_LENGTH + 1];
    report[0] = REPORT_ID;
    report[1] = command;
    report[2] = parameter;
    report
}

/// The report asking the firmware for its Oryx protocol version.
pub fn version_request() -> [u8; PAYLOAD_LENGTH + 1] {
    command_report(CMD_GET_PROTOCOL_VERSION, STOP_BIT)
}

/// The report pairing this host; the keyboard answers with a layer event.
pub fn pairing_request() -> [u8; PAYLOAD_LENGTH + 1] {
    command_report(CMD_PAIRING_INIT, STOP_BIT)
}

/// Normalizes a `hid_read` result to the report payload.
///
/// The tested macOS build hands back the bare 32-byte payload; a leading report
/// id is accepted too, since hidapi documents that byte as the report id. Bytes
/// after an event's stop bit are undefined and ignored.
pub fn payload_of(report: &[u8]) -> &[u8] {
    if report.len() == PAYLOAD_LENGTH + 1 && report[0] == REPORT_ID {
        &report[1..]
    } else {
        report
    }
}

/// True when `row`/`column` is one of the board's 72 physical keys.
fn is_key(row: u8, column: u8) -> bool {
    if usize::from(column) >= MATRIX_COLUMNS {
        return false;
    }
    match KEY_MASKS.get(usize::from(row)) {
        Some(mask) => mask & (1u8 << column) != 0,
        None => false,
    }
}

/// True when `payload` is at least `length` bytes long and its last parameter
/// byte is the firmware's stop bit.
fn is_stopped(payload: &[u8], length: usize) -> bool {
    payload.len() >= length && payload[length - 1] == STOP_BIT
}

/// A physical key position on the Moonlander matrix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct MatrixPosition {
    /// Row of the switch in the keyboard matrix.
    pub row: u8,
    /// Column of the switch in the keyboard matrix.
    pub column: u8,
}

/// One decoded Oryx event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// The active layer changed.
    Layer { layer: u8 },
    /// A key went down.
    KeyDown { position: MatrixPosition },
    /// A key came up.
    KeyUp { position: MatrixPosition },
    /// The firmware answered a protocol version request.
    Version { version: u8 },
    /// This host is paired now.
    Paired,
}

/// Decodes one report payload.
///
/// Anything missing the trailing stop bit, too short, naming a matrix hole, or
/// otherwise unrecognized yields `None`, so malformed reports can never be
/// mistaken for keyboard state.
pub fn decode(payload: &[u8]) -> Option<Event> {
    let code = *payload.first()?;
    match code {
        EVT_LAYER if is_stopped(payload, 3) => Some(Event::Layer { layer: payload[1] }),
        EVT_KEY_DOWN if is_stopped(payload, 4) => {
            let position = MatrixPosition {
                row: payload[2],
                column: payload[1],
            };
            is_key(position.row, position.column).then_some(Event::KeyDown { position })
        }
        EVT_KEY_UP if is_stopped(payload, 4) => {
            let position = MatrixPosition {
                row: payload[2],
                column: payload[1],
            };
            is_key(position.row, position.column).then_some(Event::KeyUp { position })
        }
        EVT_GET_PROTOCOL_VERSION if is_stopped(payload, 3) => {
            Some(Event::Version { version: payload[1] })
        }
        EVT_PAIRING_SUCCESS if is_stopped(payload, 2) => Some(Event::Paired),
        _ => None,
    }
}

/// The observable state of one connected keyboard.
#[derive(Debug)]
pub struct KeyState {
    layer: Option<u8>,
    /// One bit per matrix cell, set while that key is held.
    pressed: [u64; WORDS],
}

impl KeyState {
    /// Creates empty state; nothing is held until the board says so.
    pub fn new() -> Self {
        Self {
            layer: None,
            pressed: [0; WORDS],
        }
    }

    /// The active layer, once the firmware has reported one.
    pub fn layer(&self) -> Option<u8> {
        self.layer
    }

    /// Writes the held keys into `out`, ordered by row then column.
    pub fn pressed_into(&self, out: &mut Vec<MatrixPosition>) {
        out.clear();
        for row in 0..MATRIX_ROWS {
            for column in 0..MATRIX_COLUMNS {
                if self.is_pressed(row, column) {
                    out.push(MatrixPosition {
                        row: row as u8,
                        column: column as u8,
                    });
                }
            }
        }
    }

    /// Applies an event; returns whether the observable state changed.
    ///
    /// Repeated downs and ups of keys that are not held are no-ops, and held
    /// keys keep their identity across layer changes until their key-up arrives.
    pub fn apply(&mut self, event: Event) -> bool {
        match event {
            Event::Layer { layer } => {
                if self.layer == Some(layer) {
                    return false;
                }
                self.layer = Some(layer);
                true
            }
            Event::KeyDown { position } => self.set_pressed(position, true),
            Event::KeyUp { position } => self.set_pressed(position, false),
            Event::Version { .. } | Event::Paired => false,
        }
    }

    /// Forgets held keys and the layer, so a teardown cannot leave keys stuck.
    pub fn clear(&mut self) {
        self.pressed = [0; WORDS];
        self.layer = None;
    }

    fn is_pressed(&self, row: usize, column: usize) -> bool {
        let index = row * MATRIX_COLUMNS + column;
        self.pressed[index / 64] & (1u64 << (index % 64)) != 0
    }

    /// Sets or clears one key; returns whether that bit changed. Positions that
    /// are not physical keys can never enter the bitmap.
    fn set_pressed(&mut self, position: MatrixPosition, held: bool) -> bool {
        if !is_key(position.row, position.column) {
            return false;
        }
        let index = usize::from(position.row) * MATRIX_COLUMNS + usize::from(position.column);
        let bit = 1u64 << (index % 64);
        let word = &mut self.pressed[index / 64];
        let was = *word & bit != 0;
        if held {
            *word |= bit;
        } else {
            *word &= !bit;
        }
        was != held
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A well-formed 32-byte payload: event bytes plus the undefined tail the
    /// firmware pads reports with.
    fn payload(bytes: &[u8]) -> Vec<u8> {
        let mut payload = vec![0xff; PAYLOAD_LENGTH];
        payload[..bytes.len()].copy_from_slice(bytes);
        payload
    }

    fn held(state: &KeyState) -> Vec<MatrixPosition> {
        let mut held = Vec::new();
        state.pressed_into(&mut held);
        held
    }

    #[test]
    fn prefixed_frame_decodes_after_normalization() {
        let mut report = vec![REPORT_ID];
        report.extend_from_slice(&payload(&[EVT_LAYER, 4, STOP_BIT]));
        assert_eq!(decode(payload_of(&report)), Some(Event::Layer { layer: 4 }));
    }

    #[test]
    fn malformed_reports_are_never_decoded() {
        assert_eq!(decode(&[]), None);
        assert_eq!(decode(&[EVT_LAYER]), None);
        assert_eq!(decode(&[EVT_KEY_DOWN, 1]), None);
        assert_eq!(decode(&[EVT_KEY_UP, 1]), None);
        assert_eq!(decode(&[EVT_GET_PROTOCOL_VERSION]), None);
        assert_eq!(decode(&[0x42, 1, 2, 3]), None);
        assert_eq!(decode(&[0xff, 0x01]), None);
    }

    #[test]
    fn reports_without_the_stop_bit_are_ignored() {
        assert_eq!(decode(&payload(&[EVT_LAYER, 2, 0x00])), None);
        assert_eq!(decode(&payload(&[EVT_LAYER, 2])), None);
        assert_eq!(decode(&payload(&[EVT_KEY_DOWN, 1, 2, 0x00])), None);
        assert_eq!(decode(&payload(&[EVT_KEY_UP, 1, 2, 0x00])), None);
        assert_eq!(
            decode(&payload(&[EVT_GET_PROTOCOL_VERSION, PROTOCOL_VERSION, 0x00])),
            None
        );
        assert_eq!(decode(&payload(&[EVT_PAIRING_SUCCESS, 0x00])), None);
    }

    #[test]
    fn key_events_require_real_matrix_positions() {
        // Matrix holes and out-of-range cells are malformed, not held keys.
        assert_eq!(decode(&payload(&[EVT_KEY_DOWN, 6, 3, STOP_BIT])), None); // row 3 stops at column 5
        assert_eq!(decode(&payload(&[EVT_KEY_DOWN, 0, 9, STOP_BIT])), None); // row 9 starts at column 1
        assert_eq!(decode(&payload(&[EVT_KEY_DOWN, 7, 0, STOP_BIT])), None); // column 7 does not exist
        assert_eq!(decode(&payload(&[EVT_KEY_DOWN, 12, 0, STOP_BIT])), None); // row 12 does not exist
        assert_eq!(
            decode(&payload(&[EVT_KEY_DOWN, 255, 255, STOP_BIT])),
            None
        );
        assert_eq!(decode(&payload(&[EVT_KEY_UP, 255, 255, STOP_BIT])), None);

        // The corner keys and the thumb positions stay valid.
        for (row, column) in [(0u8, 0u8), (0, 6), (5, 3), (9, 1), (11, 6)] {
            assert_eq!(
                decode(&payload(&[EVT_KEY_DOWN, column, row, STOP_BIT])),
                Some(Event::KeyDown {
                    position: MatrixPosition { row, column }
                }),
                "row {row} column {column} is a physical key"
            );
        }
    }

    #[test]
    fn matrix_holds_exactly_the_seventy_two_verified_keys() {
        let mut keys = 0;
        let mut state = KeyState::new();
        for row in 0..MATRIX_ROWS {
            for column in 0..MATRIX_COLUMNS {
                if !is_key(row as u8, column as u8) {
                    continue;
                }
                keys += 1;
                let position = MatrixPosition {
                    row: row as u8,
                    column: column as u8,
                };
                assert!(state.apply(Event::KeyDown { position }));
            }
        }
        assert_eq!(keys, 72, "the Moonlander Mark I has 72 physical keys");

        let positions = held(&state);
        assert_eq!(positions.len(), 72);
        assert_eq!(positions.first(), Some(&MatrixPosition { row: 0, column: 0 }));
        assert_eq!(positions.last(), Some(&MatrixPosition { row: 11, column: 6 }));
        let mut sorted = positions.clone();
        sorted.sort_by_key(|position| (position.row, position.column));
        assert_eq!(positions, sorted, "held keys stay ordered by row then column");
    }

    #[test]
    fn layer_events_set_the_layer_and_ignore_trailing_bytes() {
        let event = decode(&payload(&[EVT_LAYER, 2, STOP_BIT, 0x13, 0x37])).expect("layer event");
        assert_eq!(event, Event::Layer { layer: 2 });

        let mut state = KeyState::new();
        assert!(state.apply(event));
        assert_eq!(state.layer(), Some(2));
        assert!(!state.apply(event), "an unchanged layer is not a change");
    }

    #[test]
    fn key_events_carry_column_then_row() {
        assert_eq!(
            decode(&payload(&[EVT_KEY_DOWN, 3, 2, STOP_BIT])),
            Some(Event::KeyDown {
                position: MatrixPosition { row: 2, column: 3 }
            })
        );
        assert_eq!(
            decode(&payload(&[EVT_KEY_UP, 4, 1, STOP_BIT])),
            Some(Event::KeyUp {
                position: MatrixPosition { row: 1, column: 4 }
            })
        );
    }

    #[test]
    fn duplicate_downs_and_stray_ups_are_idempotent() {
        let down = Event::KeyDown {
            position: MatrixPosition { row: 2, column: 3 },
        };
        let stray_up = Event::KeyUp {
            position: MatrixPosition { row: 0, column: 0 },
        };
        let mut state = KeyState::new();

        assert!(state.apply(down));
        assert!(!state.apply(down), "a duplicate key-down must not register twice");
        assert_eq!(held(&state).len(), 1);
        assert!(!state.apply(stray_up), "a key-up for a key that is not held is a no-op");
        assert_eq!(held(&state).len(), 1);
    }

    #[test]
    fn held_keys_survive_layer_changes_until_their_key_up() {
        let position = MatrixPosition { row: 2, column: 1 };
        let mut state = KeyState::new();

        assert!(state.apply(Event::KeyDown { position }));
        assert!(state.apply(Event::Layer { layer: 1 }));
        assert_eq!(
            held(&state),
            vec![position],
            "a layer change must not release a held key"
        );

        assert!(state.apply(Event::KeyUp { position }));
        assert!(held(&state).is_empty());
    }

    #[test]
    fn clear_forgets_held_keys_and_the_layer() {
        let mut state = KeyState::new();
        state.apply(Event::Layer { layer: 2 });
        state.apply(Event::KeyDown {
            position: MatrixPosition { row: 0, column: 0 },
        });

        state.clear();

        assert_eq!(state.layer(), None, "a teardown must not keep reporting a layer");
        assert!(held(&state).is_empty());
    }

    #[test]
    fn pressed_positions_are_ordered_by_row_then_column() {
        let mut state = KeyState::new();
        state.apply(Event::KeyDown {
            position: MatrixPosition { row: 4, column: 0 },
        });
        state.apply(Event::KeyDown {
            position: MatrixPosition { row: 4, column: 2 },
        });
        state.apply(Event::KeyDown {
            position: MatrixPosition { row: 1, column: 6 },
        });

        assert_eq!(
            held(&state),
            vec![
                MatrixPosition { row: 1, column: 6 },
                MatrixPosition { row: 4, column: 0 },
                MatrixPosition { row: 4, column: 2 },
            ]
        );
    }

    #[test]
    fn version_and_pairing_events_update_nothing_on_their_own() {
        assert_eq!(
            decode(&payload(&[EVT_GET_PROTOCOL_VERSION, PROTOCOL_VERSION, STOP_BIT])),
            Some(Event::Version {
                version: PROTOCOL_VERSION
            })
        );
        assert_eq!(
            decode(&payload(&[EVT_PAIRING_SUCCESS, STOP_BIT])),
            Some(Event::Paired)
        );

        let mut state = KeyState::new();
        assert!(!state.apply(Event::Version {
            version: PROTOCOL_VERSION
        }));
        assert!(!state.apply(Event::Paired));
        assert_eq!(state.layer(), None, "no event may invent a layer");
    }
}
