// Test scaffolding pokes at macro-emitted static muts to verify the wire format;
// suppress the edition-2024 lint since the test owns the unsafety here.
#![allow(static_mut_refs)]

//! Integration tests for the typed STATE accessors emitted by the
//! `state!()` macro. The macro builds an extension trait on `Context`
//! whose readers parse the kernel's JSON STATE buffer in place — these
//! tests forge a buffer with the same `[gen_u64_le, used_len_u32_le,
//! content...]` layout the host writes and confirm each typed accessor
//! returns what an audio-thread script would expect.

use conjuredsp::*;
use std::sync::Mutex;

setup!();
state!();

// All tests write to the same macro-emitted `STATE_BUF` static, so
// run them under a shared mutex to avoid the race that surfaces when
// `cargo test` schedules them across threads.
static STATE_LOCK: Mutex<()> = Mutex::new(());

// The macro-emitted `Context::state_bytes` reads `STATE_BUF` directly,
// so we manipulate it in place. Wrapping that in a helper keeps the
// per-test plumbing minimal.
fn write_state(json: &[u8], generation: u64) {
    unsafe {
        let buf_ptr = STATE_BUF.as_mut_ptr();
        let gen_le = generation.to_le_bytes();
        let len_le = (json.len() as u32).to_le_bytes();
        core::ptr::copy_nonoverlapping(gen_le.as_ptr(), buf_ptr, 8);
        core::ptr::copy_nonoverlapping(len_le.as_ptr(), buf_ptr.add(8), 4);
        if !json.is_empty() {
            core::ptr::copy_nonoverlapping(
                json.as_ptr(),
                buf_ptr.add(conjuredsp::STATE_HEADER_BYTES),
                json.len(),
            );
        }
    }
}

static mut UNUSED_PARAMS: [f32; 16] = [0.0; 16];
static mut UNUSED_TELE: [f32; conjuredsp::TELEMETRY_LEN] = [0.0; conjuredsp::TELEMETRY_LEN];

fn make_ctx() -> conjuredsp::Context {
    unsafe {
        conjuredsp::Context::new(
            core::ptr::null(),
            core::ptr::null_mut(),
            0,
            0,
            48000.0,
            UNUSED_PARAMS.as_ptr(),
            UNUSED_TELE.as_mut_ptr(),
        )
    }
}

#[test]
fn reads_generation_and_bytes() {
    let _g = STATE_LOCK.lock().unwrap();
    let json = br#"{"slots":[1,0,1,0],"selected":2}"#;
    write_state(json, 7);
    let cx = make_ctx();
    assert_eq!(cx.state_generation(), 7);
    assert_eq!(cx.state_bytes(), json);
}

#[test]
fn state_int_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"selected":3,"count":-9}"#, 1);
    let cx = make_ctx();
    assert_eq!(cx.state_int("selected"), Some(3));
    assert_eq!(cx.state_int("count"), Some(-9));
    assert_eq!(cx.state_int("missing"), None);
}

#[test]
fn state_int_or_falls_back() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"a":1}"#, 1);
    let cx = make_ctx();
    assert_eq!(cx.state_int_or("a", 99), 1);
    assert_eq!(cx.state_int_or("missing", 99), 99);
}

#[test]
fn state_bool_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"frozen":true,"open":false}"#, 1);
    let cx = make_ctx();
    assert_eq!(cx.state_bool("frozen"), Some(true));
    assert_eq!(cx.state_bool("open"), Some(false));
    assert_eq!(cx.state_bool("missing"), None);
    assert!(cx.state_bool_or("frozen", false));
    assert!(!cx.state_bool_or("missing", false));
}

#[test]
fn state_f32_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"freq":440.5,"neg":-1.25,"int":7}"#, 1);
    let cx = make_ctx();
    assert_eq!(cx.state_f32("freq"), Some(440.5));
    assert_eq!(cx.state_f32("neg"), Some(-1.25));
    assert_eq!(cx.state_f32("int"), Some(7.0));
    assert!(cx.state_f32("missing").is_none());
}

#[test]
fn state_array_u8_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"pat":[1,2,3,255,0]}"#, 1);
    let cx = make_ctx();
    let arr = cx.state_array_u8::<5>("pat").unwrap();
    assert_eq!(arr, [1, 2, 3, 255, 0]);
}

#[test]
fn state_array_u8_too_short_is_none() {
    // Author asks for 16 elements but state only has 4 — return None so
    // the caller can fall back to defaults rather than getting partially
    // initialised data.
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"pat":[1,2,3,4]}"#, 1);
    let cx = make_ctx();
    assert!(cx.state_array_u8::<16>("pat").is_none());
    let fallback = cx.state_array_u8_or::<16>("pat", [9; 16]);
    assert_eq!(fallback, [9; 16]);
}

#[test]
fn state_array_u8_too_long_truncates_silently() {
    // State has more than the script asks for. Take the prefix; that's
    // the gracious thing to do for a UI that grew its array between
    // versions.
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"pat":[10,20,30,40,50,60]}"#, 1);
    let cx = make_ctx();
    let arr = cx.state_array_u8::<3>("pat").unwrap();
    assert_eq!(arr, [10, 20, 30]);
}

#[test]
fn state_array_u8_rejects_out_of_range_value() {
    // 256 doesn't fit in u8. The whole array fails (returning None
    // rather than partial garbage).
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"pat":[1,2,256,4]}"#, 1);
    let cx = make_ctx();
    assert!(cx.state_array_u8::<4>("pat").is_none());
}

#[test]
fn state_array_i32_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"pat":[1,-2,1000,-1000]}"#, 1);
    let cx = make_ctx();
    let arr = cx.state_array_i32::<4>("pat").unwrap();
    assert_eq!(arr, [1, -2, 1000, -1000]);
}

#[test]
fn state_array_f32_roundtrips() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{"freqs":[110.0,220,440.5,1e3]}"#, 1);
    let cx = make_ctx();
    let arr = cx.state_array_f32::<4>("freqs").unwrap();
    assert_eq!(arr, [110.0, 220.0, 440.5, 1000.0]);
}

#[test]
fn state_array_or_falls_back_when_missing() {
    let _g = STATE_LOCK.lock().unwrap();
    write_state(br#"{}"#, 1);
    let cx = make_ctx();
    let default = [42u8; 16];
    assert_eq!(cx.state_array_u8_or::<16>("pattern", default), default);
}

#[test]
fn ignores_unknown_keys() {
    // Common case: UI writes extra metadata the DSP doesn't care about.
    // Skipping the other keys mustn't trip parsing.
    let _g = STATE_LOCK.lock().unwrap();
    write_state(
        br#"{"meta":{"author":"x"},"_v":2,"selected":4,"slots":[0,1,2,3]}"#,
        1,
    );
    let cx = make_ctx();
    assert_eq!(cx.state_int("selected"), Some(4));
    let arr = cx.state_array_i32::<4>("slots").unwrap();
    assert_eq!(arr, [0, 1, 2, 3]);
}

#[test]
fn malformed_json_returns_none() {
    // The kernel validates JSON before installing, so this state shape
    // is "shouldn't happen in production" — but the helpers must still
    // return None instead of panicking if it ever does.
    let _g = STATE_LOCK.lock().unwrap();
    write_state(b"{not json}", 1);
    let cx = make_ctx();
    assert!(cx.state_int("a").is_none());
    assert!(cx.state_array_u8::<4>("a").is_none());
    assert_eq!(cx.state_int_or("a", 7), 7);
}
