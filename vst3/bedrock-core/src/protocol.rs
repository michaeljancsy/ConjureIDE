//! The Track → Vision wire format.
//!
//! Each Track instance opens one TCP connection to Vision and owns it for its lifetime, so the
//! connection *is* the track's identity — there is no track id in the hot-path frame. A stream
//! looks like:
//!
//! ```text
//! preamble   MAGIC:u32  VERSION:u16  REALM:u16
//! message*   TYPE:u8  LEN:u16  PAYLOAD[LEN]
//! ```
//!
//! Everything is little-endian. Messages are length-prefixed so a reader can skip a message
//! type it doesn't know, which is what lets a newer Track talk to an older Vision as long as
//! the version byte still matches.
//!
//! Spectrum magnitudes are quantised to one byte each. The graph is ~500 px tall at most, and a
//! byte across the 120 dB display range resolves to 0.47 dB, far finer than a pixel — so the
//! quantisation is invisible while cutting frame size four-fold. A frame is 137 bytes, and a
//! 32-track session at 47 frames/sec is about 200 KB/s over loopback.

use crate::analyzer::{Spectrum, DB_FLOOR, NUM_BINS};
use crate::palette::Rgb;

/// Stream preamble magic, "BDRK".
pub const MAGIC: u32 = 0x424d_524b;

/// Bumped whenever the framing or message semantics change incompatibly.
pub const PROTOCOL_VERSION: u16 = 1;

/// Top of the quantisation range. Frames above this clip — it's a mix analyzer, and anything
/// over +20 dBFS is already off the top of the graph.
pub const DB_CEIL: f32 = 20.0;

/// Longest track name we carry. Host track names are far shorter in practice.
pub const MAX_NAME_LEN: usize = 63;

/// Stable identifier for a track within a realm.
pub type TrackId = u32;

/// Bytes in the stream preamble.
pub const PREAMBLE_LEN: usize = 8;

/// Bytes in a message header.
const HEADER_LEN: usize = 3;

mod msg_type {
    pub const HELLO: u8 = 1;
    pub const FRAME: u8 = 2;
    pub const GOODBYE: u8 = 3;
}

/// Quantises a dBFS value into one byte over `[DB_FLOOR, DB_CEIL]`.
pub fn quantize_db(db: f32) -> u8 {
    let t = (db - DB_FLOOR) / (DB_CEIL - DB_FLOOR);
    (t * 255.0).round().clamp(0.0, 255.0) as u8
}

/// Inverse of [`quantize_db`].
pub fn dequantize_db(q: u8) -> f32 {
    DB_FLOOR + (q as f32 / 255.0) * (DB_CEIL - DB_FLOOR)
}

/// Identity and appearance of a track. Sent on connect, and again whenever the host renames or
/// recolours the channel.
#[derive(Clone, Debug, PartialEq)]
pub struct Hello {
    pub track: TrackId,
    /// Display order. Lower sorts first; ties break on `track`.
    pub slot: u16,
    pub name: String,
    /// Colour reported by the host, if it told us one.
    pub daw_color: Option<Rgb>,
}

/// One analysis frame.
///
/// `Copy` on purpose: the audio thread hands these to the sender thread through a lock-free
/// queue that needs to move them by value without allocating.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub bins: [u8; NUM_BINS],
    pub peak_db: f32,
    pub rms_db: f32,
}

impl Default for Frame {
    fn default() -> Frame {
        Frame {
            bins: [0; NUM_BINS],
            peak_db: DB_FLOOR,
            rms_db: DB_FLOOR,
        }
    }
}

impl Frame {
    pub fn from_spectrum(s: &Spectrum) -> Frame {
        let mut bins = [0u8; NUM_BINS];
        for (dst, &db) in bins.iter_mut().zip(s.bins.iter()) {
            *dst = quantize_db(db);
        }
        Frame {
            bins,
            peak_db: s.peak_db,
            rms_db: s.rms_db,
        }
    }

    /// Magnitude of display bin `i`, in dBFS.
    pub fn bin_db(&self, i: usize) -> f32 {
        dequantize_db(self.bins[i])
    }
}

/// A decoded message.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Hello(Hello),
    Frame(Frame),
    Goodbye,
}

/// Why a stream was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtocolError {
    BadMagic,
    /// Carries the version the peer offered.
    VersionMismatch(u16),
    Malformed,
}

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProtocolError::BadMagic => write!(f, "not a Bedrock stream"),
            ProtocolError::VersionMismatch(v) => write!(
                f,
                "protocol version {v}, this build speaks {PROTOCOL_VERSION}"
            ),
            ProtocolError::Malformed => write!(f, "malformed message"),
        }
    }
}

impl std::error::Error for ProtocolError {}

/// Writes the bytes a Track sends before any message.
pub fn encode_preamble(realm: u16) -> [u8; PREAMBLE_LEN] {
    let mut out = [0u8; PREAMBLE_LEN];
    out[0..4].copy_from_slice(&MAGIC.to_le_bytes());
    out[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    out[6..8].copy_from_slice(&realm.to_le_bytes());
    out
}

/// Parses a preamble, returning the realm the peer wants to join.
pub fn decode_preamble(bytes: &[u8]) -> Result<u16, ProtocolError> {
    if bytes.len() < PREAMBLE_LEN {
        return Err(ProtocolError::Malformed);
    }
    let magic = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
    if magic != MAGIC {
        return Err(ProtocolError::BadMagic);
    }
    let version = u16::from_le_bytes(bytes[4..6].try_into().unwrap());
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::VersionMismatch(version));
    }
    Ok(u16::from_le_bytes(bytes[6..8].try_into().unwrap()))
}

fn push_message(out: &mut Vec<u8>, ty: u8, payload: &[u8]) {
    out.push(ty);
    out.extend_from_slice(&(payload.len() as u16).to_le_bytes());
    out.extend_from_slice(payload);
}

pub fn encode_hello(hello: &Hello, out: &mut Vec<u8>) {
    let mut p = Vec::with_capacity(16 + hello.name.len());
    p.extend_from_slice(&hello.track.to_le_bytes());
    p.extend_from_slice(&hello.slot.to_le_bytes());
    match hello.daw_color {
        Some(c) => {
            p.push(1);
            p.extend_from_slice(&[c.r, c.g, c.b]);
        }
        None => {
            p.push(0);
            p.extend_from_slice(&[0, 0, 0]);
        }
    }

    // Truncate on a char boundary so the payload stays valid UTF-8.
    let mut name = hello.name.as_str();
    while name.len() > MAX_NAME_LEN {
        name = &name[..name
            .char_indices()
            .take_while(|(i, _)| *i < MAX_NAME_LEN)
            .last()
            .map(|(i, _)| i)
            .unwrap_or(0)];
    }
    p.push(name.len() as u8);
    p.extend_from_slice(name.as_bytes());

    push_message(out, msg_type::HELLO, &p);
}

pub fn encode_frame(frame: &Frame, out: &mut Vec<u8>) {
    let mut p = Vec::with_capacity(NUM_BINS + 8);
    p.extend_from_slice(&frame.peak_db.to_le_bytes());
    p.extend_from_slice(&frame.rms_db.to_le_bytes());
    p.extend_from_slice(&frame.bins);
    push_message(out, msg_type::FRAME, &p);
}

pub fn encode_goodbye(out: &mut Vec<u8>) {
    push_message(out, msg_type::GOODBYE, &[]);
}

fn decode_hello(p: &[u8]) -> Result<Hello, ProtocolError> {
    if p.len() < 11 {
        return Err(ProtocolError::Malformed);
    }
    let track = u32::from_le_bytes(p[0..4].try_into().unwrap());
    let slot = u16::from_le_bytes(p[4..6].try_into().unwrap());
    let daw_color = if p[6] != 0 {
        Some(Rgb::new(p[7], p[8], p[9]))
    } else {
        None
    };
    let name_len = p[10] as usize;
    if p.len() < 11 + name_len {
        return Err(ProtocolError::Malformed);
    }
    let name = String::from_utf8_lossy(&p[11..11 + name_len]).into_owned();
    Ok(Hello {
        track,
        slot,
        name,
        daw_color,
    })
}

fn decode_frame(p: &[u8]) -> Result<Frame, ProtocolError> {
    if p.len() < 8 + NUM_BINS {
        return Err(ProtocolError::Malformed);
    }
    let peak_db = f32::from_le_bytes(p[0..4].try_into().unwrap());
    let rms_db = f32::from_le_bytes(p[4..8].try_into().unwrap());
    let mut bins = [0u8; NUM_BINS];
    bins.copy_from_slice(&p[8..8 + NUM_BINS]);
    Ok(Frame {
        bins,
        peak_db,
        rms_db,
    })
}

/// Incremental reader. Bytes arrive from a socket in arbitrary chunks, so feed whatever you got
/// to [`Decoder::feed`] and then drain whole messages with [`Decoder::next_message`].
#[derive(Default)]
pub struct Decoder {
    buf: Vec<u8>,
    preamble_done: bool,
    realm: u16,
}

impl Decoder {
    pub fn new() -> Decoder {
        Decoder::default()
    }

    /// The realm from the preamble. Meaningless until [`Decoder::preamble_done`] is true.
    pub fn realm(&self) -> u16 {
        self.realm
    }

    pub fn preamble_done(&self) -> bool {
        self.preamble_done
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// Pulls the next complete message, consuming the preamble first if it hasn't been read.
    ///
    /// Returns `Ok(None)` when more bytes are needed. An `Err` is terminal: the stream is not
    /// one of ours, or is corrupt, and the caller should drop the connection.
    pub fn next_message(&mut self) -> Result<Option<Message>, ProtocolError> {
        if !self.preamble_done {
            if self.buf.len() < PREAMBLE_LEN {
                return Ok(None);
            }
            self.realm = decode_preamble(&self.buf[..PREAMBLE_LEN])?;
            self.buf.drain(..PREAMBLE_LEN);
            self.preamble_done = true;
        }

        if self.buf.len() < HEADER_LEN {
            return Ok(None);
        }
        let ty = self.buf[0];
        let len = u16::from_le_bytes([self.buf[1], self.buf[2]]) as usize;
        if self.buf.len() < HEADER_LEN + len {
            return Ok(None);
        }

        let payload: Vec<u8> = self.buf[HEADER_LEN..HEADER_LEN + len].to_vec();
        self.buf.drain(..HEADER_LEN + len);

        match ty {
            msg_type::HELLO => Ok(Some(Message::Hello(decode_hello(&payload)?))),
            msg_type::FRAME => Ok(Some(Message::Frame(decode_frame(&payload)?))),
            msg_type::GOODBYE => Ok(Some(Message::Goodbye)),
            // Unknown type: the length prefix let us skip it cleanly, so a newer peer sending
            // a message we don't understand is survivable rather than fatal.
            _ => self.next_message(),
        }
    }

    /// Bytes buffered but not yet consumed. Used to bound memory on a misbehaving peer.
    pub fn pending(&self) -> usize {
        self.buf.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_hello() -> Hello {
        Hello {
            track: 0xdead_beef,
            slot: 7,
            name: "Kick Bus".to_string(),
            daw_color: Some(Rgb::new(10, 200, 30)),
        }
    }

    fn sample_frame() -> Frame {
        let mut bins = [0u8; NUM_BINS];
        for (i, b) in bins.iter_mut().enumerate() {
            *b = (i * 2 % 256) as u8;
        }
        Frame {
            bins,
            peak_db: -6.5,
            rms_db: -18.25,
        }
    }

    fn drain(dec: &mut Decoder) -> Vec<Message> {
        let mut out = Vec::new();
        while let Some(m) = dec.next_message().expect("decode failed") {
            out.push(m);
        }
        out
    }

    #[test]
    fn preamble_round_trips() {
        let bytes = encode_preamble(42);
        assert_eq!(decode_preamble(&bytes), Ok(42));
    }

    #[test]
    fn preamble_rejects_a_foreign_stream() {
        let mut bytes = encode_preamble(0);
        bytes[0] ^= 0xff;
        assert_eq!(decode_preamble(&bytes), Err(ProtocolError::BadMagic));
    }

    #[test]
    fn preamble_rejects_a_different_protocol_version() {
        let mut bytes = encode_preamble(0);
        bytes[4..6].copy_from_slice(&99u16.to_le_bytes());
        assert_eq!(
            decode_preamble(&bytes),
            Err(ProtocolError::VersionMismatch(99))
        );
    }

    #[test]
    fn messages_round_trip() {
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(3));
        encode_hello(&sample_hello(), &mut wire);
        encode_frame(&sample_frame(), &mut wire);
        encode_goodbye(&mut wire);

        let mut dec = Decoder::new();
        dec.feed(&wire);
        let msgs = drain(&mut dec);

        assert_eq!(dec.realm(), 3);
        assert_eq!(
            msgs,
            vec![
                Message::Hello(sample_hello()),
                Message::Frame(sample_frame()),
                Message::Goodbye,
            ]
        );
    }

    #[test]
    fn decoding_survives_arbitrary_chunking() {
        // A socket hands over whatever it feels like; every split must behave identically.
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(1));
        encode_hello(&sample_hello(), &mut wire);
        encode_frame(&sample_frame(), &mut wire);

        for chunk_size in [1usize, 2, 3, 7, 64, 137, 1024] {
            let mut dec = Decoder::new();
            let mut msgs = Vec::new();
            for chunk in wire.chunks(chunk_size) {
                dec.feed(chunk);
                msgs.extend(drain(&mut dec));
            }
            assert_eq!(
                msgs,
                vec![Message::Hello(sample_hello()), Message::Frame(sample_frame())],
                "failed at chunk size {chunk_size}"
            );
        }
    }

    #[test]
    fn partial_message_yields_nothing_rather_than_an_error() {
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(0));
        encode_frame(&sample_frame(), &mut wire);
        wire.truncate(wire.len() - 10);

        let mut dec = Decoder::new();
        dec.feed(&wire);
        assert_eq!(dec.next_message(), Ok(None));
    }

    #[test]
    fn unknown_message_types_are_skipped_not_fatal() {
        // Forward compatibility: a future Track may send messages this Vision predates.
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(0));
        push_message(&mut wire, 200, &[1, 2, 3, 4, 5]);
        encode_frame(&sample_frame(), &mut wire);

        let mut dec = Decoder::new();
        dec.feed(&wire);
        assert_eq!(drain(&mut dec), vec![Message::Frame(sample_frame())]);
    }

    #[test]
    fn quantisation_error_stays_under_half_a_step() {
        let step = (DB_CEIL - DB_FLOOR) / 255.0;
        let mut worst = 0.0f32;
        for i in 0..=2400 {
            let db = DB_FLOOR + i as f32 * 0.05;
            if db > DB_CEIL {
                break;
            }
            let err = (dequantize_db(quantize_db(db)) - db).abs();
            worst = worst.max(err);
        }
        assert!(
            worst <= step / 2.0 + 1e-4,
            "worst quantisation error {worst} dB exceeds half a step ({})",
            step / 2.0
        );
    }

    #[test]
    fn quantisation_clamps_outside_the_display_range() {
        assert_eq!(quantize_db(DB_FLOOR - 50.0), 0);
        assert_eq!(quantize_db(DB_CEIL + 50.0), 255);
        assert_eq!(quantize_db(f32::NEG_INFINITY), 0);
    }

    #[test]
    fn frame_carries_spectrum_magnitudes_within_quantisation_error() {
        let mut s = Spectrum::default();
        for (i, b) in s.bins.iter_mut().enumerate() {
            *b = -90.0 + i as f32 * 0.7;
        }
        let f = Frame::from_spectrum(&s);
        let step = (DB_CEIL - DB_FLOOR) / 255.0;
        for i in 0..NUM_BINS {
            assert!(
                (f.bin_db(i) - s.bins[i]).abs() <= step / 2.0 + 1e-3,
                "bin {i}: {} vs {}",
                f.bin_db(i),
                s.bins[i]
            );
        }
    }

    #[test]
    fn long_names_are_truncated_on_a_char_boundary() {
        let hello = Hello {
            name: "ドラムバスのトラック名前がとても長い場合のテスト".repeat(4),
            ..sample_hello()
        };
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(0));
        encode_hello(&hello, &mut wire);

        let mut dec = Decoder::new();
        dec.feed(&wire);
        match drain(&mut dec).remove(0) {
            Message::Hello(h) => {
                assert!(h.name.len() <= MAX_NAME_LEN);
                assert!(hello.name.starts_with(&h.name), "truncation corrupted UTF-8");
            }
            other => panic!("expected Hello, got {other:?}"),
        }
    }

    #[test]
    fn hello_without_a_daw_color_round_trips_as_none() {
        let hello = Hello {
            daw_color: None,
            ..sample_hello()
        };
        let mut wire = Vec::new();
        wire.extend_from_slice(&encode_preamble(0));
        encode_hello(&hello, &mut wire);

        let mut dec = Decoder::new();
        dec.feed(&wire);
        assert_eq!(drain(&mut dec), vec![Message::Hello(hello)]);
    }

    #[test]
    fn a_frame_fits_in_a_loopback_packet() {
        let mut wire = Vec::new();
        encode_frame(&sample_frame(), &mut wire);
        assert_eq!(wire.len(), HEADER_LEN + 8 + NUM_BINS);
        assert!(wire.len() < 1400, "frame should fit one MTU");
    }
}
