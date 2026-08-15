//! Shared VST3 plumbing: string marshalling, parameter definitions, and state streams.

use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicU32, Ordering};

use vst3::{ComRef, Steinberg::Vst::*, Steinberg::*};

// ---------------------------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------------------------

pub fn copy_cstring(src: &str, dst: &mut [c_char]) {
    let c_string = CString::new(src).unwrap_or_default();
    let bytes = c_string.as_bytes_with_nul();
    for (s, d) in bytes.iter().zip(dst.iter_mut()) {
        *d = *s as c_char;
    }
    if bytes.len() > dst.len() {
        if let Some(last) = dst.last_mut() {
            *last = 0;
        }
    }
}

/// VST3 strings are UTF-16. Truncation is on a code-unit boundary, which is fine for the
/// display-only fields this is used for.
pub fn copy_wstring(src: &str, dst: &mut [TChar]) {
    let mut len = 0;
    for (s, d) in src.encode_utf16().zip(dst.iter_mut()) {
        *d = s as TChar;
        len += 1;
    }
    if len < dst.len() {
        dst[len] = 0;
    } else if let Some(last) = dst.last_mut() {
        *last = 0;
    }
}

/// Reads a host-provided UTF-16 string.
///
/// # Safety
/// `ptr` must be a valid NUL-terminated UTF-16 buffer, or null.
pub unsafe fn read_wstring(ptr: *const TChar, max: usize) -> String {
    if ptr.is_null() {
        return String::new();
    }
    let mut units = Vec::new();
    for i in 0..max {
        let c = *ptr.add(i);
        if c == 0 {
            break;
        }
        units.push(c as u16);
    }
    String::from_utf16_lossy(&units)
}

// ---------------------------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------------------------

/// How a parameter presents itself to the host and how its normalised 0..1 value maps to
/// something meaningful.
#[derive(Clone, Copy)]
pub struct Param {
    pub id: u32,
    pub title: &'static str,
    pub units: &'static str,
    /// Inclusive plain-value range.
    pub min: f64,
    pub max: f64,
    pub default_plain: f64,
    /// 0 for a continuous parameter; otherwise the number of steps between min and max.
    pub step_count: i32,
    /// Names for a stepped parameter's values, shown instead of numbers when present.
    pub value_strings: Option<&'static [&'static str]>,
    pub is_toggle: bool,
}

impl Param {
    pub fn to_plain(&self, normalized: f64) -> f64 {
        let n = normalized.clamp(0.0, 1.0);
        if self.step_count > 0 {
            // VST3's discrete mapping: the host expects round-tripping through these to be exact.
            self.min + (n * self.step_count as f64).round()
        } else {
            self.min + n * (self.max - self.min)
        }
    }

    pub fn to_normalized(&self, plain: f64) -> f64 {
        let p = plain.clamp(self.min, self.max);
        if self.step_count > 0 {
            (p - self.min) / self.step_count as f64
        } else if self.max > self.min {
            (p - self.min) / (self.max - self.min)
        } else {
            0.0
        }
    }

    pub fn default_normalized(&self) -> f64 {
        self.to_normalized(self.default_plain)
    }

    pub fn format(&self, normalized: f64) -> String {
        let plain = self.to_plain(normalized);
        if let Some(strings) = self.value_strings {
            let i = (plain - self.min).round().max(0.0) as usize;
            return strings.get(i).copied().unwrap_or("?").to_string();
        }
        if self.is_toggle {
            return if plain >= 0.5 { "On" } else { "Off" }.to_string();
        }
        if self.step_count > 0 {
            format!("{}", plain as i64)
        } else {
            format!("{plain:.2}")
        }
    }

    /// Fills in a `ParameterInfo` for `getParameterInfo`.
    ///
    /// # Safety
    /// `info` must point to a writable `ParameterInfo`.
    pub unsafe fn write_info(&self, info: *mut ParameterInfo) {
        let info = &mut *info;
        info.id = self.id;
        copy_wstring(self.title, &mut info.title);
        copy_wstring(self.title, &mut info.shortTitle);
        copy_wstring(self.units, &mut info.units);
        info.stepCount = self.step_count;
        info.defaultNormalizedValue = self.default_normalized();
        info.unitId = 0;
        let mut flags = ParameterInfo_::ParameterFlags_::kCanAutomate as i32;
        if self.value_strings.is_some() {
            flags |= ParameterInfo_::ParameterFlags_::kIsList as i32;
        }
        info.flags = flags;
    }
}

/// Normalised parameter values, shared between the UI thread and the audio thread.
///
/// Stored as `f32` bits in atomics: the audio thread must never take a lock to read a knob.
pub struct ParamValues {
    values: Vec<AtomicU32>,
    defs: &'static [Param],
}

impl ParamValues {
    pub fn new(defs: &'static [Param]) -> ParamValues {
        ParamValues {
            values: defs
                .iter()
                .map(|p| AtomicU32::new((p.default_normalized() as f32).to_bits()))
                .collect(),
            defs,
        }
    }

    pub fn defs(&self) -> &'static [Param] {
        self.defs
    }

    pub fn index_of(&self, id: u32) -> Option<usize> {
        self.defs.iter().position(|p| p.id == id)
    }

    pub fn get_normalized(&self, index: usize) -> f64 {
        f32::from_bits(self.values[index].load(Ordering::Relaxed)) as f64
    }

    pub fn set_normalized(&self, index: usize, value: f64) {
        self.values[index].store((value.clamp(0.0, 1.0) as f32).to_bits(), Ordering::Relaxed);
    }

    pub fn get_plain(&self, index: usize) -> f64 {
        self.defs[index].to_plain(self.get_normalized(index))
    }

    /// Plain value as an integer, for stepped parameters.
    pub fn get_int(&self, index: usize) -> i64 {
        self.get_plain(index).round() as i64
    }

    pub fn get_bool(&self, index: usize) -> bool {
        self.get_plain(index) >= 0.5
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }

    /// Applies the automation points the host delivered with this audio block.
    ///
    /// Only the last point in each queue is used: these parameters are all display or routing
    /// settings, so sample-accurate ramping would buy nothing.
    ///
    /// # Safety
    /// `changes` must be a valid `IParameterChanges` pointer or null.
    pub unsafe fn apply_changes(&self, changes: *mut IParameterChanges) {
        let Some(changes) = ComRef::from_raw(changes) else {
            return;
        };
        for i in 0..changes.getParameterCount() {
            let Some(queue) = ComRef::from_raw(changes.getParameterData(i)) else {
                continue;
            };
            let count = queue.getPointCount();
            if count <= 0 {
                continue;
            }
            let Some(index) = self.index_of(queue.getParameterId()) else {
                continue;
            };
            let mut offset = 0i32;
            let mut value = 0f64;
            if queue.getPoint(count - 1, &mut offset, &mut value) == kResultTrue {
                self.set_normalized(index, value);
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// State streams
// ---------------------------------------------------------------------------------------------

const STATE_MAGIC: u32 = 0x4244_524b; // "BDRK"
const STATE_VERSION: u16 = 1;

/// Writes every parameter to the host's stream.
///
/// # Safety
/// `stream` must be a valid `IBStream` pointer or null.
pub unsafe fn save_params(params: &ParamValues, stream: *mut IBStream) -> tresult {
    let Some(stream) = ComRef::from_raw(stream) else {
        return kInvalidArgument;
    };

    let mut buf = Vec::with_capacity(8 + params.len() * 8);
    buf.extend_from_slice(&STATE_MAGIC.to_le_bytes());
    buf.extend_from_slice(&STATE_VERSION.to_le_bytes());
    buf.extend_from_slice(&(params.len() as u16).to_le_bytes());
    for i in 0..params.len() {
        buf.extend_from_slice(&params.get_normalized(i).to_le_bytes());
    }

    let mut written = 0i32;
    let res = stream.write(
        buf.as_ptr() as *mut c_void,
        buf.len() as i32,
        &mut written as *mut i32,
    );
    if res != kResultOk || written as usize != buf.len() {
        return kResultFalse;
    }
    kResultOk
}

/// Restores parameters previously written by [`save_params`].
///
/// A state with a different parameter count is read as far as it goes and the rest left at
/// their defaults, so a session saved by an older build still opens.
///
/// # Safety
/// `stream` must be a valid `IBStream` pointer or null.
pub unsafe fn load_params(params: &ParamValues, stream: *mut IBStream) -> tresult {
    let Some(stream) = ComRef::from_raw(stream) else {
        return kInvalidArgument;
    };

    let mut header = [0u8; 8];
    let mut read = 0i32;
    if stream.read(
        header.as_mut_ptr() as *mut c_void,
        header.len() as i32,
        &mut read as *mut i32,
    ) != kResultOk
        || read != header.len() as i32
    {
        return kResultFalse;
    }

    if u32::from_le_bytes(header[0..4].try_into().unwrap()) != STATE_MAGIC {
        return kResultFalse;
    }
    if u16::from_le_bytes(header[4..6].try_into().unwrap()) != STATE_VERSION {
        return kResultFalse;
    }
    let count = u16::from_le_bytes(header[6..8].try_into().unwrap()) as usize;

    for i in 0..count {
        let mut bytes = [0u8; 8];
        let mut read = 0i32;
        if stream.read(
            bytes.as_mut_ptr() as *mut c_void,
            8,
            &mut read as *mut i32,
        ) != kResultOk
            || read != 8
        {
            break;
        }
        if i < params.len() {
            params.set_normalized(i, f64::from_le_bytes(bytes));
        }
    }
    kResultOk
}

// ---------------------------------------------------------------------------------------------
// Audio helpers
// ---------------------------------------------------------------------------------------------

/// A block's input and output channel slices, if the layout is one we can work with.
pub struct Block<'a> {
    pub inputs: &'a [*mut f32],
    pub outputs: &'a [*mut f32],
    pub frames: usize,
}

/// Extracts the main input/output buses from `ProcessData`.
///
/// # Safety
/// `data` must be the pointer the host passed to `process`.
pub unsafe fn block(data: &ProcessData) -> Option<Block<'_>> {
    let frames = data.numSamples as usize;
    if frames == 0 || data.numInputs < 1 || data.numOutputs < 1 {
        return None;
    }
    if data.symbolicSampleSize != SymbolicSampleSizes_::kSample32 as i32 {
        return None;
    }
    if data.inputs.is_null() || data.outputs.is_null() {
        return None;
    }

    let in_bus = &*data.inputs;
    let out_bus = &*data.outputs;
    if in_bus.numChannels < 1 || out_bus.numChannels < 1 {
        return None;
    }
    if in_bus.__field0.channelBuffers32.is_null() || out_bus.__field0.channelBuffers32.is_null() {
        return None;
    }

    Some(Block {
        inputs: std::slice::from_raw_parts(
            in_bus.__field0.channelBuffers32,
            in_bus.numChannels as usize,
        ),
        outputs: std::slice::from_raw_parts(
            out_bus.__field0.channelBuffers32,
            out_bus.numChannels as usize,
        ),
        frames,
    })
}

/// Copies input to output. Both plugins are analysis-only inserts and must pass audio through
/// bit-for-bit; any output channel without a matching input is silenced.
///
/// # Safety
/// The pointers in `block` must be valid for `block.frames` samples.
pub unsafe fn passthrough(block: &Block) {
    for (ch, &out) in block.outputs.iter().enumerate() {
        if out.is_null() {
            continue;
        }
        let dst = std::slice::from_raw_parts_mut(out, block.frames);
        match block.inputs.get(ch) {
            Some(&src) if !src.is_null() => {
                if src != out {
                    dst.copy_from_slice(std::slice::from_raw_parts(src, block.frames));
                }
            }
            _ => dst.fill(0.0),
        }
    }
}

/// Sums the input channels to mono into `scratch`, which is resized as needed.
///
/// Analysis is mono: a spectrum per channel would double the wire traffic and halve the
/// legibility of the graph for no real gain in a mix-balance tool.
///
/// # Safety
/// The pointers in `block` must be valid for `block.frames` samples.
pub unsafe fn sum_to_mono(block: &Block, scratch: &mut Vec<f32>) {
    scratch.clear();
    scratch.resize(block.frames, 0.0);

    let live: Vec<&[f32]> = block
        .inputs
        .iter()
        .filter(|p| !p.is_null())
        .map(|&p| std::slice::from_raw_parts(p, block.frames))
        .collect();
    if live.is_empty() {
        return;
    }

    let scale = 1.0 / live.len() as f32;
    for (i, out) in scratch.iter_mut().enumerate() {
        let mut acc = 0.0;
        for ch in &live {
            acc += ch[i];
        }
        *out = acc * scale;
    }
}

// ---------------------------------------------------------------------------------------------
// Track identity
// ---------------------------------------------------------------------------------------------

/// Mints an id that is unique across every plugin instance on the machine.
///
/// Vision keys its track table by this, so a collision between two different plugin host
/// processes would merge two channels into one line on the graph. The per-process base is
/// seeded from the clock and the process id; the counter separates instances within a process.
pub fn next_track_id() -> u32 {
    use std::sync::atomic::AtomicU32;
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU32 = AtomicU32::new(0);
    static BASE: std::sync::OnceLock<u32> = std::sync::OnceLock::new();

    let base = *BASE.get_or_init(|| {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos() ^ d.as_secs() as u32)
            .unwrap_or(0);
        let pid = std::process::id();
        // Mix so that two processes starting in the same nanosecond still diverge.
        nanos
            .wrapping_mul(2_654_435_761)
            .rotate_left(13)
            ^ pid.wrapping_mul(2_246_822_519)
    });

    base.wrapping_add(COUNTER.fetch_add(1, Ordering::Relaxed).wrapping_mul(0x9E37_79B9))
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_PARAMS: &[Param] = &[
        Param {
            id: 0,
            title: "Continuous",
            units: "",
            min: 0.0,
            max: 1.0,
            default_plain: 0.25,
            step_count: 0,
            value_strings: None,
            is_toggle: false,
        },
        Param {
            id: 1,
            title: "Stepped",
            units: "",
            min: 0.0,
            max: 99.0,
            default_plain: 0.0,
            step_count: 99,
            value_strings: None,
            is_toggle: false,
        },
        Param {
            id: 2,
            title: "Toggle",
            units: "",
            min: 0.0,
            max: 1.0,
            default_plain: 1.0,
            step_count: 1,
            value_strings: None,
            is_toggle: true,
        },
    ];

    #[test]
    fn stepped_parameters_round_trip_every_step() {
        let p = TEST_PARAMS[1];
        for step in 0..=99i64 {
            let n = p.to_normalized(step as f64);
            assert_eq!(
                p.to_plain(n).round() as i64,
                step,
                "step {step} did not survive the round trip"
            );
        }
    }

    #[test]
    fn continuous_parameters_round_trip() {
        let p = TEST_PARAMS[0];
        for i in 0..=100 {
            let plain = i as f64 / 100.0;
            assert!((p.to_plain(p.to_normalized(plain)) - plain).abs() < 1e-9);
        }
    }

    #[test]
    fn normalized_input_is_clamped() {
        let p = TEST_PARAMS[1];
        assert_eq!(p.to_plain(-5.0), 0.0);
        assert_eq!(p.to_plain(5.0), 99.0);
    }

    #[test]
    fn defaults_come_back_as_set() {
        let v = ParamValues::new(TEST_PARAMS);
        assert!((v.get_plain(0) - 0.25).abs() < 1e-6);
        assert_eq!(v.get_int(1), 0);
        assert!(v.get_bool(2));
    }

    #[test]
    fn toggles_and_lists_format_readably() {
        assert_eq!(TEST_PARAMS[2].format(1.0), "On");
        assert_eq!(TEST_PARAMS[2].format(0.0), "Off");
        assert_eq!(TEST_PARAMS[1].format(TEST_PARAMS[1].to_normalized(42.0)), "42");
    }

    #[test]
    fn parameter_ids_resolve_to_indices() {
        let v = ParamValues::new(TEST_PARAMS);
        assert_eq!(v.index_of(1), Some(1));
        assert_eq!(v.index_of(999), None);
    }

    #[test]
    fn track_ids_do_not_repeat() {
        let ids: std::collections::HashSet<u32> = (0..10_000).map(|_| next_track_id()).collect();
        assert_eq!(ids.len(), 10_000, "track ids collided within one process");
    }

    #[test]
    fn wstring_round_trips() {
        let mut buf = [0 as TChar; 128];
        copy_wstring("Lead Vox", &mut buf);
        assert_eq!(unsafe { read_wstring(buf.as_ptr(), 128) }, "Lead Vox");
    }

    #[test]
    fn wstring_truncates_instead_of_overflowing() {
        let mut buf = [0 as TChar; 4];
        copy_wstring("abcdefgh", &mut buf);
        assert_eq!(buf[3], 0, "must stay NUL-terminated");
        assert_eq!(unsafe { read_wstring(buf.as_ptr(), 4) }, "abc");
    }
}
