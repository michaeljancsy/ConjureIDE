//! Bedrock — platform-independent engine for a multi-track spectrum analyzer.
//!
//! The product is two plugins that cooperate across a DAW session:
//!
//! * **Track** — an analysis-only insert placed on every channel you want to see. It measures
//!   the signal passing through it and publishes a spectrum frame to a hub.
//! * **Vision** — a single instance that hosts the hub, collects every Track's frames, and
//!   draws them layered into one graph.
//!
//! The two halves talk over loopback TCP ([`hub`]) rather than shared memory, so any number of
//! Track instances in any number of plugin sandboxes can reach one Vision. Sessions are kept
//! apart by a *realm* number, so two open projects don't draw on each other's graph.
//!
//! This crate holds everything that isn't VST3 or windowing: analysis ([`analyzer`]), the wire
//! format ([`protocol`]), the transport ([`hub`]), the live track table ([`registry`]), colour
//! ([`palette`]) and the software renderer ([`render`], [`font`]).

pub mod analyzer;
pub mod font;
pub mod hub;
pub mod palette;
pub mod protocol;
pub mod registry;
pub mod render;

pub use analyzer::{Analyzer, Spectrum, DB_FLOOR, FREQ_MAX, FREQ_MIN, NUM_BINS};
pub use palette::{Palette, Rgb};
pub use protocol::{Frame, TrackId};
pub use registry::Registry;

/// Product name, used in plugin names and the window title bar.
pub const PRODUCT: &str = "Bedrock";

/// Vendor string reported to the host.
pub const VENDOR: &str = "ConjureDSP";

/// Number of realms a session can address. Realm 0 is the default.
pub const NUM_REALMS: u16 = 100;
