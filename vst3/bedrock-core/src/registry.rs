//! The live track table Vision draws from.
//!
//! One entry per connected Track. The registry is written by the hub's reader threads and read
//! by the UI, so it lives behind a mutex owned by the hub — [`Registry`] itself is plain data.
//!
//! Time is passed in rather than read from the clock so eviction is testable without sleeping.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::palette::Rgb;
use crate::protocol::{Frame, TrackId};

/// How long a track may go unheard before it drops off the graph. Comfortably longer than a
/// stalled audio callback or a host briefly suspending processing, short enough that deleting
/// a track makes it disappear promptly.
pub const DEFAULT_STALE_AFTER: Duration = Duration::from_millis(2000);

/// Everything Vision knows about one track.
#[derive(Clone, Debug)]
pub struct TrackState {
    pub id: TrackId,
    /// Display order requested by the Track instance.
    pub slot: u16,
    pub name: String,
    /// Colour the host reported for the channel, if it reported one.
    pub daw_color: Option<Rgb>,
    pub frame: Frame,
    /// When we last received anything from this track.
    pub last_seen: Instant,
    /// False until the first frame arrives, so a track that has said hello but is sitting in
    /// silence doesn't draw a floor-level line before it has really been measured.
    pub has_frame: bool,
}

impl TrackState {
    /// Whether the track has gone quiet for longer than `stale_after`.
    pub fn is_stale(&self, now: Instant, stale_after: Duration) -> bool {
        now.saturating_duration_since(self.last_seen) > stale_after
    }
}

#[derive(Default)]
pub struct Registry {
    tracks: HashMap<TrackId, TrackState>,
}

impl Registry {
    pub fn new() -> Registry {
        Registry::default()
    }

    /// Records a track's identity, creating the entry if this is the first we've heard of it.
    ///
    /// A repeat hello updates name, slot and colour in place and keeps the current frame, which
    /// is what happens when the user renames or recolours a channel mid-session.
    pub fn hello(
        &mut self,
        id: TrackId,
        slot: u16,
        name: String,
        daw_color: Option<Rgb>,
        now: Instant,
    ) {
        let entry = self.tracks.entry(id).or_insert_with(|| TrackState {
            id,
            slot,
            name: String::new(),
            daw_color: None,
            frame: Frame::default(),
            last_seen: now,
            has_frame: false,
        });
        entry.slot = slot;
        entry.name = name;
        entry.daw_color = daw_color;
        entry.last_seen = now;
    }

    /// Records an analysis frame. Ignored for a track that never said hello, so a malformed or
    /// out-of-order stream can't create a nameless entry.
    pub fn frame(&mut self, id: TrackId, frame: Frame, now: Instant) {
        if let Some(t) = self.tracks.get_mut(&id) {
            t.frame = frame;
            t.last_seen = now;
            t.has_frame = true;
        }
    }

    pub fn remove(&mut self, id: TrackId) -> bool {
        self.tracks.remove(&id).is_some()
    }

    pub fn clear(&mut self) {
        self.tracks.clear();
    }

    /// Drops tracks that have gone quiet. Returns how many were removed.
    pub fn evict_stale(&mut self, now: Instant, stale_after: Duration) -> usize {
        let before = self.tracks.len();
        self.tracks.retain(|_, t| !t.is_stale(now, stale_after));
        before - self.tracks.len()
    }

    pub fn len(&self) -> usize {
        self.tracks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    pub fn get(&self, id: TrackId) -> Option<&TrackState> {
        self.tracks.get(&id)
    }

    /// Tracks in display order: by slot, then by id so the order is stable across frames even
    /// when several tracks share a slot (the default until the user assigns them).
    pub fn ordered(&self) -> Vec<&TrackState> {
        let mut v: Vec<&TrackState> = self.tracks.values().collect();
        v.sort_by(|a, b| a.slot.cmp(&b.slot).then(a.id.cmp(&b.id)));
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analyzer::NUM_BINS;

    fn frame_with(level: u8) -> Frame {
        Frame {
            bins: [level; NUM_BINS],
            peak_db: -6.0,
            rms_db: -12.0,
        }
    }

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn hello_creates_a_track() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(1, 0, "Kick".into(), None, now);
        assert_eq!(r.len(), 1);
        let t = r.get(1).unwrap();
        assert_eq!(t.name, "Kick");
        assert!(!t.has_frame, "a track with no frame yet should say so");
    }

    #[test]
    fn frames_land_on_the_right_track() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(1, 0, "Kick".into(), None, now);
        r.hello(2, 0, "Snare".into(), None, now);
        r.frame(1, frame_with(200), now);

        assert!(r.get(1).unwrap().has_frame);
        assert_eq!(r.get(1).unwrap().frame.bins[0], 200);
        assert!(!r.get(2).unwrap().has_frame);
    }

    #[test]
    fn frames_for_an_unknown_track_are_ignored() {
        // Guards against a corrupt or reordered stream inventing a nameless entry.
        let mut r = Registry::new();
        r.frame(99, frame_with(10), t0());
        assert!(r.is_empty());
    }

    #[test]
    fn a_repeat_hello_updates_identity_but_keeps_the_frame() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(1, 0, "Audio 1".into(), None, now);
        r.frame(1, frame_with(123), now);
        r.hello(1, 4, "Lead Vox".into(), Some(Rgb::new(1, 2, 3)), now);

        let t = r.get(1).unwrap();
        assert_eq!(t.name, "Lead Vox");
        assert_eq!(t.slot, 4);
        assert_eq!(t.daw_color, Some(Rgb::new(1, 2, 3)));
        assert_eq!(t.frame.bins[0], 123, "renaming should not clear the spectrum");
        assert!(t.has_frame);
    }

    #[test]
    fn stale_tracks_are_evicted() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(1, 0, "Old".into(), None, now);
        r.hello(2, 0, "Fresh".into(), None, now);

        let later = now + Duration::from_millis(1500);
        r.frame(2, frame_with(1), later);

        let much_later = now + Duration::from_millis(2500);
        assert_eq!(r.evict_stale(much_later, DEFAULT_STALE_AFTER), 1);
        assert!(r.get(1).is_none(), "silent track should be gone");
        assert!(r.get(2).is_some(), "recently updated track should survive");
    }

    #[test]
    fn eviction_is_a_no_op_when_everything_is_fresh() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(1, 0, "A".into(), None, now);
        assert_eq!(r.evict_stale(now, DEFAULT_STALE_AFTER), 0);
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn ordering_is_by_slot_then_id() {
        let mut r = Registry::new();
        let now = t0();
        r.hello(30, 2, "third".into(), None, now);
        r.hello(10, 1, "first".into(), None, now);
        r.hello(20, 1, "second".into(), None, now);

        let names: Vec<_> = r.ordered().iter().map(|t| t.name.clone()).collect();
        assert_eq!(names, vec!["first", "second", "third"]);
    }

    #[test]
    fn ordering_is_stable_across_repeated_reads() {
        // HashMap iteration order is arbitrary; the graph must not reshuffle every frame.
        let mut r = Registry::new();
        let now = t0();
        for id in 0..16u32 {
            r.hello(id, 0, format!("t{id}"), None, now);
        }
        let first: Vec<_> = r.ordered().iter().map(|t| t.id).collect();
        for _ in 0..8 {
            let again: Vec<_> = r.ordered().iter().map(|t| t.id).collect();
            assert_eq!(first, again);
        }
    }

    #[test]
    fn remove_reports_whether_it_did_anything() {
        let mut r = Registry::new();
        r.hello(1, 0, "A".into(), None, t0());
        assert!(r.remove(1));
        assert!(!r.remove(1));
        assert!(r.is_empty());
    }
}
