//! Transport between Track instances and Vision.
//!
//! # Why TCP and not shared memory
//!
//! Track and Vision are separate plugin instances that a host is free to put in separate
//! sandboxed processes, and there may be dozens of Tracks to one Vision. A loopback socket
//! crosses every one of those boundaries without asking the host's permission, needs no
//! agreed-on file path, and cleans itself up when a plugin is deleted — a closed socket *is*
//! the "this track is gone" signal. The cost is a few hundred KB/s of loopback traffic, which
//! is nothing next to the audio the host is already moving.
//!
//! # Realms
//!
//! A realm is just a port offset. Vision for realm *r* listens on `BASE_PORT + r`; Tracks set
//! to realm *r* dial it. Two projects open at once pick different realms and cannot see each
//! other's tracks — and because the realm decides the port, a second Vision on the same realm
//! fails to bind, which is exactly the error the user needs to see.
//!
//! # Threads
//!
//! Track: the audio thread pushes frames into a lock-free [`FrameQueue`]; a sender thread
//! drains it and writes to the socket, reconnecting on its own if Vision isn't up yet.
//!
//! Vision: an accept thread plus one reader thread per connection, all writing into a shared
//! [`Registry`]. Nothing on Vision's side touches an audio thread.

use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::protocol::{
    encode_frame, encode_goodbye, encode_hello, encode_preamble, Decoder, Frame, Hello, Message,
    ProtocolError, TrackId,
};
use crate::registry::{Registry, DEFAULT_STALE_AFTER};
use crate::NUM_REALMS;

/// Realm 0 lives here; realm *r* on `BASE_PORT + r`. Sits in the IANA dynamic range.
pub const BASE_PORT: u16 = 49_900;

/// Port for a realm. Realms past [`NUM_REALMS`] wrap rather than escape the reserved block.
pub fn realm_port(realm: u16) -> u16 {
    BASE_PORT + (realm % NUM_REALMS)
}

/// Frames buffered between the audio thread and the sender thread. A handful is plenty — if
/// the sender falls this far behind, the stale frames are worthless anyway.
const QUEUE_CAPACITY: usize = 8;

/// How long a reader blocks before re-checking the stop flag.
const READ_TIMEOUT: Duration = Duration::from_millis(200);

/// Refuse to buffer more than this from one peer; a peer that sends a huge length prefix and
/// then stalls shouldn't be able to grow Vision's memory without bound.
const MAX_PENDING_BYTES: usize = 1 << 16;

// ---------------------------------------------------------------------------------------------
// Lock-free handoff from the audio thread
// ---------------------------------------------------------------------------------------------

/// Single-producer single-consumer queue of [`Frame`], sized at construction.
///
/// [`FrameQueue::push`] is called from the audio thread: it never allocates, never blocks, and
/// drops the incoming frame when full rather than waiting. Dropping is the right failure mode
/// here — a spectrum frame that arrives late is of no use to anyone.
pub struct FrameQueue {
    slots: Box<[std::cell::UnsafeCell<Frame>]>,
    head: AtomicUsize,
    tail: AtomicUsize,
    dropped: AtomicU64,
}

// Safety: access is disciplined by `head`/`tail` with acquire/release ordering, and there is
// exactly one producer and one consumer.
unsafe impl Send for FrameQueue {}
unsafe impl Sync for FrameQueue {}

impl FrameQueue {
    pub fn new(capacity: usize) -> FrameQueue {
        let capacity = capacity.max(2);
        let slots = (0..capacity)
            .map(|_| std::cell::UnsafeCell::new(Frame::default()))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        FrameQueue {
            slots,
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            dropped: AtomicU64::new(0),
        }
    }

    /// Audio-thread side. Returns false if the queue was full and the frame was dropped.
    pub fn push(&self, frame: Frame) -> bool {
        let head = self.head.load(Ordering::Relaxed);
        let next = (head + 1) % self.slots.len();
        if next == self.tail.load(Ordering::Acquire) {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        // Safety: only the producer writes, and only to the slot at `head`, which the consumer
        // will not read until `head` is published below.
        unsafe { *self.slots[head].get() = frame };
        self.head.store(next, Ordering::Release);
        true
    }

    /// Consumer side.
    pub fn pop(&self) -> Option<Frame> {
        let tail = self.tail.load(Ordering::Relaxed);
        if tail == self.head.load(Ordering::Acquire) {
            return None;
        }
        // Safety: the producer published this slot before advancing `head`.
        let frame = unsafe { *self.slots[tail].get() };
        self.tail
            .store((tail + 1) % self.slots.len(), Ordering::Release);
        Some(frame)
    }

    /// Frames dropped because the sender couldn't keep up. Diagnostics only.
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

// ---------------------------------------------------------------------------------------------
// Track side
// ---------------------------------------------------------------------------------------------

/// What the Track UI shows about its connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkStatus {
    /// No Vision listening on this realm yet. Not an error — Vision is often inserted second.
    Searching,
    Connected,
}

/// Identity fields the sender thread re-publishes whenever the host changes them.
#[derive(Default)]
struct Identity {
    name: String,
    slot: u16,
    color: Option<crate::palette::Rgb>,
    dirty: bool,
}

/// A Track's connection to Vision. Owns the sender thread; dropping it shuts down cleanly.
pub struct TrackLink {
    id: TrackId,
    queue: Arc<FrameQueue>,
    identity: Arc<Mutex<Identity>>,
    realm: Arc<AtomicU32>,
    connected: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl TrackLink {
    /// Starts the sender thread. It reconnects on its own, so this never fails.
    pub fn new(id: TrackId, realm: u16) -> TrackLink {
        let queue = Arc::new(FrameQueue::new(QUEUE_CAPACITY));
        let identity = Arc::new(Mutex::new(Identity {
            name: String::new(),
            slot: 0,
            color: None,
            dirty: true,
        }));
        let realm_cell = Arc::new(AtomicU32::new(realm as u32));
        let connected = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));

        let thread = {
            let queue = Arc::clone(&queue);
            let identity = Arc::clone(&identity);
            let realm_cell = Arc::clone(&realm_cell);
            let connected = Arc::clone(&connected);
            let stop = Arc::clone(&stop);
            thread::Builder::new()
                .name("bedrock-track".into())
                .spawn(move || sender_loop(id, queue, identity, realm_cell, connected, stop))
                .ok()
        };

        TrackLink {
            id,
            queue,
            identity,
            realm: realm_cell,
            connected,
            stop,
            thread,
        }
    }

    pub fn id(&self) -> TrackId {
        self.id
    }

    /// Audio-thread safe. Drops the frame if the sender is backed up.
    pub fn publish(&self, frame: Frame) -> bool {
        self.queue.push(frame)
    }

    /// Sets what the host calls this channel. Re-sent to Vision on the next sender tick.
    pub fn set_identity(&self, name: &str, slot: u16, color: Option<crate::palette::Rgb>) {
        if let Ok(mut id) = self.identity.lock() {
            if id.name != name || id.slot != slot || id.color != color {
                id.name = name.to_string();
                id.slot = slot;
                id.color = color;
                id.dirty = true;
            }
        }
    }

    pub fn realm(&self) -> u16 {
        self.realm.load(Ordering::Relaxed) as u16
    }

    /// Moves this Track to another realm. The sender drops the current connection and dials
    /// the new port on its next tick.
    pub fn set_realm(&self, realm: u16) {
        self.realm.store(realm as u32, Ordering::Relaxed);
    }

    pub fn status(&self) -> LinkStatus {
        if self.connected.load(Ordering::Relaxed) {
            LinkStatus::Connected
        } else {
            LinkStatus::Searching
        }
    }

    pub fn dropped_frames(&self) -> u64 {
        self.queue.dropped()
    }
}

impl Drop for TrackLink {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn sender_loop(
    id: TrackId,
    queue: Arc<FrameQueue>,
    identity: Arc<Mutex<Identity>>,
    realm: Arc<AtomicU32>,
    connected: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    let mut stream: Option<TcpStream> = None;
    let mut current_realm = realm.load(Ordering::Relaxed) as u16;
    let mut backoff = Duration::from_millis(50);
    let mut out: Vec<u8> = Vec::with_capacity(1024);

    while !stop.load(Ordering::Relaxed) {
        let wanted_realm = realm.load(Ordering::Relaxed) as u16;
        if wanted_realm != current_realm {
            if let Some(s) = stream.take() {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
            connected.store(false, Ordering::Relaxed);
            current_realm = wanted_realm;
            // Re-announce ourselves to whatever is listening on the new realm.
            if let Ok(mut i) = identity.lock() {
                i.dirty = true;
            }
        }

        if stream.is_none() {
            let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, realm_port(current_realm));
            match TcpStream::connect_timeout(&addr.into(), Duration::from_millis(250)) {
                Ok(s) => {
                    let _ = s.set_nodelay(true);
                    let _ = s.set_write_timeout(Some(Duration::from_millis(500)));
                    out.clear();
                    out.extend_from_slice(&encode_preamble(current_realm));
                    stream = Some(s);
                    connected.store(true, Ordering::Relaxed);
                    backoff = Duration::from_millis(50);
                    if let Ok(mut i) = identity.lock() {
                        i.dirty = true;
                    }
                }
                Err(_) => {
                    // Vision simply isn't there yet. Back off up to a second and keep trying.
                    connected.store(false, Ordering::Relaxed);
                    thread::sleep(backoff);
                    backoff = (backoff * 2).min(Duration::from_millis(1000));
                    continue;
                }
            }
        }

        if let Ok(mut i) = identity.lock() {
            if i.dirty {
                encode_hello(
                    &Hello {
                        track: id,
                        slot: i.slot,
                        name: i.name.clone(),
                        daw_color: i.color,
                    },
                    &mut out,
                );
                i.dirty = false;
            }
        }

        let mut got_any = false;
        while let Some(frame) = queue.pop() {
            encode_frame(&frame, &mut out);
            got_any = true;
        }

        if !out.is_empty() {
            let s = stream.as_mut().expect("stream present");
            match s.write_all(&out) {
                Ok(()) => out.clear(),
                Err(_) => {
                    // Vision went away. Drop everything and start dialling again.
                    stream = None;
                    connected.store(false, Ordering::Relaxed);
                    out.clear();
                    continue;
                }
            }
        }

        if !got_any {
            // Idle: the analyzer produces a frame roughly every 21 ms, so this adds no latency
            // worth measuring while keeping the thread off the CPU.
            thread::sleep(Duration::from_millis(4));
        }
    }

    if let Some(mut s) = stream {
        out.clear();
        encode_goodbye(&mut out);
        let _ = s.write_all(&out);
        let _ = s.flush();
        let _ = s.shutdown(std::net::Shutdown::Both);
    }
}

// ---------------------------------------------------------------------------------------------
// Vision side
// ---------------------------------------------------------------------------------------------

/// Why a hub isn't running.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HubError {
    /// Another Vision already owns this realm. The user should move one of them.
    RealmInUse(u16),
    Io(String),
}

impl std::fmt::Display for HubError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HubError::RealmInUse(r) => {
                write!(f, "realm {r} is already in use by another Vision instance")
            }
            HubError::Io(e) => write!(f, "{e}"),
        }
    }
}

/// Vision's listener and track table.
pub struct Hub {
    realm: u16,
    registry: Arc<Mutex<Registry>>,
    stop: Arc<AtomicBool>,
    accept_thread: Option<JoinHandle<()>>,
    connections: Arc<AtomicUsize>,
}

impl Hub {
    /// Binds the realm's port and starts accepting Tracks.
    pub fn start(realm: u16) -> Result<Hub, HubError> {
        let addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, realm_port(realm));
        let listener = TcpListener::bind(addr).map_err(|e| match e.kind() {
            ErrorKind::AddrInUse => HubError::RealmInUse(realm),
            _ => HubError::Io(e.to_string()),
        })?;
        listener
            .set_nonblocking(true)
            .map_err(|e| HubError::Io(e.to_string()))?;

        let registry = Arc::new(Mutex::new(Registry::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let connections = Arc::new(AtomicUsize::new(0));

        let accept_thread = {
            let registry = Arc::clone(&registry);
            let stop = Arc::clone(&stop);
            let connections = Arc::clone(&connections);
            thread::Builder::new()
                .name("bedrock-hub".into())
                .spawn(move || accept_loop(listener, realm, registry, stop, connections))
                .ok()
        };

        Ok(Hub {
            realm,
            registry,
            stop,
            accept_thread,
            connections,
        })
    }

    pub fn realm(&self) -> u16 {
        self.realm
    }

    pub fn registry(&self) -> &Arc<Mutex<Registry>> {
        &self.registry
    }

    /// Live connections. Usually equals the track count, but counts a peer that has connected
    /// and not yet said hello.
    pub fn connection_count(&self) -> usize {
        self.connections.load(Ordering::Relaxed)
    }

    /// Drops tracks that have gone quiet without closing their socket — a host that suspends
    /// processing leaves the connection open but stops the audio.
    pub fn evict_stale(&self) -> usize {
        if let Ok(mut r) = self.registry.lock() {
            r.evict_stale(Instant::now(), DEFAULT_STALE_AFTER)
        } else {
            0
        }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.accept_thread.take() {
            let _ = t.join();
        }
    }
}

fn accept_loop(
    listener: TcpListener,
    realm: u16,
    registry: Arc<Mutex<Registry>>,
    stop: Arc<AtomicBool>,
    connections: Arc<AtomicUsize>,
) {
    let mut readers: Vec<JoinHandle<()>> = Vec::new();

    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                let registry = Arc::clone(&registry);
                let stop = Arc::clone(&stop);
                let owned = Arc::clone(&connections);
                connections.fetch_add(1, Ordering::Relaxed);
                if let Ok(h) = thread::Builder::new()
                    .name("bedrock-reader".into())
                    .spawn(move || {
                        reader_loop(stream, realm, &registry, &stop);
                        owned.fetch_sub(1, Ordering::Relaxed);
                    })
                {
                    readers.push(h);
                } else {
                    connections.fetch_sub(1, Ordering::Relaxed);
                }
                readers.retain(|h| !h.is_finished());
            }
            Err(ref e) if e.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(_) => thread::sleep(Duration::from_millis(100)),
        }
    }

    for h in readers {
        let _ = h.join();
    }
}

fn reader_loop(
    mut stream: TcpStream,
    realm: u16,
    registry: &Arc<Mutex<Registry>>,
    stop: &Arc<AtomicBool>,
) {
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let mut decoder = Decoder::new();
    let mut buf = [0u8; 4096];
    let mut track: Option<TrackId> = None;

    'outer: while !stop.load(Ordering::Relaxed) {
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(ref e)
                if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                continue
            }
            Err(_) => break,
        };
        decoder.feed(&buf[..n]);

        if decoder.pending() > MAX_PENDING_BYTES {
            break;
        }

        loop {
            match decoder.next_message() {
                Ok(None) => break,
                Ok(Some(Message::Hello(hello))) => {
                    // A Track that dials the wrong realm is dropped rather than shown; the
                    // port already separates realms, so this only catches a genuine mismatch.
                    if decoder.realm() != realm {
                        break 'outer;
                    }
                    track = Some(hello.track);
                    if let Ok(mut r) = registry.lock() {
                        r.hello(
                            hello.track,
                            hello.slot,
                            hello.name,
                            hello.daw_color,
                            Instant::now(),
                        );
                    }
                }
                Ok(Some(Message::Frame(frame))) => {
                    if let Some(id) = track {
                        if let Ok(mut r) = registry.lock() {
                            r.frame(id, frame, Instant::now());
                        }
                    }
                }
                Ok(Some(Message::Goodbye)) => break 'outer,
                Err(ProtocolError::BadMagic) | Err(ProtocolError::VersionMismatch(_)) => {
                    break 'outer
                }
                Err(ProtocolError::Malformed) => break 'outer,
            }
        }
    }

    // The socket closing is the authoritative "track is gone" signal.
    if let Some(id) = track {
        if let Ok(mut r) = registry.lock() {
            r.remove(id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analyzer::NUM_BINS;
    use crate::palette::Rgb;

    /// Realms are ports, and ports are a machine-wide resource, so each test claims its own.
    /// These sit above the realms a user would pick by hand.
    mod realm {
        pub const ONE_TRACK: u16 = 70;
        pub const MANY_TRACKS: u16 = 71;
        pub const DISCONNECT: u16 = 72;
        pub const IN_USE: u16 = 73;
        pub const ISOLATION_A: u16 = 74;
        pub const ISOLATION_B: u16 = 75;
        pub const LATE_VISION: u16 = 76;
        pub const RENAME: u16 = 77;
        pub const REALM_SWITCH: u16 = 78;
    }

    fn frame_with(level: u8) -> Frame {
        Frame {
            bins: [level; NUM_BINS],
            peak_db: -6.0,
            rms_db: -12.0,
        }
    }

    /// Polls until `pred` holds or the deadline passes. Networking is asynchronous; a fixed
    /// sleep would either be flaky or slow.
    fn wait_for(timeout: Duration, mut pred: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if pred() {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        pred()
    }

    fn track_count(hub: &Hub) -> usize {
        hub.registry().lock().unwrap().len()
    }

    #[test]
    fn realm_maps_to_a_port_in_the_reserved_block() {
        assert_eq!(realm_port(0), BASE_PORT);
        assert_eq!(realm_port(5), BASE_PORT + 5);
        // Out-of-range realms wrap instead of escaping the block.
        assert_eq!(realm_port(NUM_REALMS), BASE_PORT);
        assert!(realm_port(u16::MAX) < BASE_PORT + NUM_REALMS);
    }

    #[test]
    fn a_track_reaches_vision_end_to_end() {
        let hub = Hub::start(realm::ONE_TRACK).expect("hub should bind");
        let link = TrackLink::new(0xAB, realm::ONE_TRACK);
        link.set_identity("Lead Vox", 3, Some(Rgb::new(9, 8, 7)));

        assert!(
            wait_for(Duration::from_secs(5), || link.status() == LinkStatus::Connected),
            "track never connected"
        );

        link.publish(frame_with(180));

        assert!(
            wait_for(Duration::from_secs(5), || {
                hub.registry()
                    .lock()
                    .unwrap()
                    .get(0xAB)
                    .is_some_and(|t| t.has_frame)
            }),
            "frame never arrived"
        );

        let r = hub.registry().lock().unwrap();
        let t = r.get(0xAB).unwrap();
        assert_eq!(t.name, "Lead Vox");
        assert_eq!(t.slot, 3);
        assert_eq!(t.daw_color, Some(Rgb::new(9, 8, 7)));
        assert_eq!(t.frame.bins[0], 180);
    }

    #[test]
    fn many_tracks_share_one_vision() {
        let hub = Hub::start(realm::MANY_TRACKS).expect("hub should bind");
        let links: Vec<_> = (0..12u32)
            .map(|i| {
                let l = TrackLink::new(1000 + i, realm::MANY_TRACKS);
                l.set_identity(&format!("Track {i}"), i as u16, None);
                l
            })
            .collect();

        assert!(
            wait_for(Duration::from_secs(10), || track_count(&hub) == links.len()),
            "expected {} tracks, saw {}",
            links.len(),
            track_count(&hub)
        );

        for (i, l) in links.iter().enumerate() {
            l.publish(frame_with(i as u8 + 1));
        }

        assert!(
            wait_for(Duration::from_secs(5), || {
                hub.registry().lock().unwrap().ordered().iter().all(|t| t.has_frame)
            }),
            "not every track delivered a frame"
        );

        let r = hub.registry().lock().unwrap();
        let ordered = r.ordered();
        for (i, t) in ordered.iter().enumerate() {
            assert_eq!(t.name, format!("Track {i}"), "display order is wrong");
            assert_eq!(t.frame.bins[0], i as u8 + 1);
        }
    }

    #[test]
    fn deleting_a_track_removes_it_from_the_graph() {
        let hub = Hub::start(realm::DISCONNECT).expect("hub should bind");
        let keep = TrackLink::new(1, realm::DISCONNECT);
        keep.set_identity("Keep", 0, None);
        {
            let doomed = TrackLink::new(2, realm::DISCONNECT);
            doomed.set_identity("Doomed", 1, None);
            assert!(
                wait_for(Duration::from_secs(5), || track_count(&hub) == 2),
                "both tracks should register"
            );
        } // doomed drops here, closing its socket

        assert!(
            wait_for(Duration::from_secs(5), || track_count(&hub) == 1),
            "removing a Track should drop it from the registry"
        );
        assert!(hub.registry().lock().unwrap().get(1).is_some());
    }

    #[test]
    fn a_second_vision_on_the_same_realm_is_refused() {
        let _first = Hub::start(realm::IN_USE).expect("first hub should bind");
        match Hub::start(realm::IN_USE) {
            Err(HubError::RealmInUse(r)) => assert_eq!(r, realm::IN_USE),
            Err(other) => panic!("expected RealmInUse, got {other:?}"),
            Ok(_) => panic!("two Vision instances must not share a realm"),
        }
    }

    #[test]
    fn realms_are_isolated_from_each_other() {
        let hub_a = Hub::start(realm::ISOLATION_A).expect("hub a");
        let hub_b = Hub::start(realm::ISOLATION_B).expect("hub b");

        let a = TrackLink::new(1, realm::ISOLATION_A);
        a.set_identity("On A", 0, None);
        let b = TrackLink::new(2, realm::ISOLATION_B);
        b.set_identity("On B", 0, None);

        assert!(
            wait_for(Duration::from_secs(5), || track_count(&hub_a) == 1
                && track_count(&hub_b) == 1),
            "each hub should see exactly its own track"
        );
        assert!(hub_a.registry().lock().unwrap().get(1).is_some());
        assert!(hub_a.registry().lock().unwrap().get(2).is_none());
        assert!(hub_b.registry().lock().unwrap().get(2).is_some());
        assert!(hub_b.registry().lock().unwrap().get(1).is_none());
    }

    #[test]
    fn a_track_inserted_before_vision_connects_once_vision_appears() {
        // The common real-world order: Tracks go on channels first, Vision is added after.
        let link = TrackLink::new(42, realm::LATE_VISION);
        link.set_identity("Early Bird", 0, None);
        thread::sleep(Duration::from_millis(300));
        assert_eq!(link.status(), LinkStatus::Searching);

        let hub = Hub::start(realm::LATE_VISION).expect("hub should bind");
        assert!(
            wait_for(Duration::from_secs(10), || track_count(&hub) == 1),
            "track should have found Vision after it appeared"
        );
        assert_eq!(link.status(), LinkStatus::Connected);
        assert_eq!(hub.registry().lock().unwrap().get(42).unwrap().name, "Early Bird");
    }

    #[test]
    fn renaming_a_channel_updates_the_graph() {
        let hub = Hub::start(realm::RENAME).expect("hub should bind");
        let link = TrackLink::new(7, realm::RENAME);
        link.set_identity("Audio 1", 0, None);
        assert!(
            wait_for(Duration::from_secs(5), || track_count(&hub) == 1),
            "track should register"
        );

        link.set_identity("Rhodes", 2, Some(Rgb::new(1, 2, 3)));
        assert!(
            wait_for(Duration::from_secs(5), || {
                hub.registry()
                    .lock()
                    .unwrap()
                    .get(7)
                    .is_some_and(|t| t.name == "Rhodes" && t.slot == 2)
            }),
            "rename should reach Vision without reconnecting"
        );
    }

    #[test]
    fn moving_a_track_to_another_realm_migrates_it() {
        let hub_a = Hub::start(realm::REALM_SWITCH).expect("hub a");
        let hub_b = Hub::start(realm::REALM_SWITCH + 1).expect("hub b");

        let link = TrackLink::new(5, realm::REALM_SWITCH);
        link.set_identity("Mover", 0, None);
        assert!(
            wait_for(Duration::from_secs(5), || track_count(&hub_a) == 1),
            "track should start on realm a"
        );

        link.set_realm(realm::REALM_SWITCH + 1);
        assert!(
            wait_for(Duration::from_secs(10), || track_count(&hub_b) == 1
                && track_count(&hub_a) == 0),
            "track should move to realm b and leave realm a"
        );
    }

    // -- FrameQueue ----------------------------------------------------------------------

    #[test]
    fn frame_queue_round_trips_in_order() {
        let q = FrameQueue::new(8);
        assert!(q.pop().is_none());
        for i in 0..5u8 {
            assert!(q.push(frame_with(i)));
        }
        for i in 0..5u8 {
            assert_eq!(q.pop().unwrap().bins[0], i);
        }
        assert!(q.pop().is_none());
    }

    #[test]
    fn frame_queue_drops_rather_than_blocking_when_full() {
        // The audio thread must never wait on the sender thread.
        let q = FrameQueue::new(4);
        let mut accepted = 0;
        for i in 0..100u8 {
            if q.push(frame_with(i)) {
                accepted += 1;
            }
        }
        assert_eq!(accepted, 3, "capacity 4 holds 3 with one slot reserved");
        assert_eq!(q.dropped(), 97);
        assert!(q.pop().is_some());
    }

    #[test]
    fn frame_queue_survives_concurrent_producer_and_consumer() {
        let q = Arc::new(FrameQueue::new(8));
        let producer = {
            let q = Arc::clone(&q);
            thread::spawn(move || {
                for i in 0..20_000u32 {
                    while !q.push(frame_with((i % 251) as u8)) {
                        std::hint::spin_loop();
                    }
                }
            })
        };

        let mut seen = 0u32;
        let mut expect = 0u32;
        while seen < 20_000 {
            if let Some(f) = q.pop() {
                assert_eq!(
                    f.bins[0],
                    (expect % 251) as u8,
                    "frames arrived out of order at {seen}"
                );
                expect += 1;
                seen += 1;
            }
        }
        producer.join().unwrap();
    }
}
