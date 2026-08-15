//! Drives the built `.vst3` binary the way a host would, without a host.
//!
//! These tests `dlopen` the actual cdylib, pull `GetPluginFactory` out of it, and go through
//! the real COM vtables — so they exercise the shipped artifact, not just the Rust behind it.
//! Everything a DAW does on load is covered here: enumerate classes, instantiate, negotiate
//! bus arrangements, set up processing, activate, push audio, and save/restore state.
//!
//! Vision's own track table is private, so the Track tests stand a `bedrock_core::hub::Hub` up
//! on a spare realm and let the plugin connect to that. The Vision test does the mirror image:
//! it activates the real plugin and points a `TrackLink` at it.

#![allow(non_snake_case)]

use std::ffi::{c_void, CString};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use vst3::{Class, ComPtr, ComWrapper, Interface, Steinberg::Vst::*, Steinberg::*};

use bedrock_core::hub::{Hub, LinkStatus, TrackLink};
use bedrock_core::protocol::Frame;

/// Realms used only by this file, kept clear of the ones bedrock_core's tests claim.
mod realm {
    pub const TRACK_PUBLISHES: u16 = 60;
    pub const TRACK_RESPECTS_SEND: u16 = 61;
    pub const VISION_BINDS: u16 = 62;
    pub const TRACK_REALM_PARAM: u16 = 63;
}

const TRACK_CID: TUID = vst3::uid(0xB3D40C4B, 0x71A4402E, 0x8F1C6D22, 0x54A10001);
const VISION_CID: TUID = vst3::uid(0xB3D40C4B, 0x71A4402E, 0x8F1C6D22, 0x54A10002);

// ---------------------------------------------------------------------------------------------
// Loading the built artifact
// ---------------------------------------------------------------------------------------------

fn library_path() -> PathBuf {
    let exe = std::env::current_exe().expect("test executable path");
    // .../target/<profile>/deps/<test binary>  ->  .../target/<profile>/
    let dir = exe
        .parent()
        .and_then(|p| p.parent())
        .expect("target profile directory");
    let name = if cfg!(target_os = "windows") {
        "bedrock.dll"
    } else if cfg!(target_os = "macos") {
        "libbedrock.dylib"
    } else {
        "libbedrock.so"
    };
    dir.join(name)
}

type GetFactoryFn = unsafe extern "system" fn() -> *mut IPluginFactory;

/// The loaded module. The `Library` must outlive every object created from it.
struct Module {
    _lib: libloading::Library,
    factory: ComPtr<IPluginFactory>,
}

fn load() -> Module {
    let path = library_path();
    assert!(
        path.exists(),
        "{} has not been built; run `cargo build` first",
        path.display()
    );
    // Safety: the library is our own cdylib, built from this workspace.
    unsafe {
        let lib = libloading::Library::new(&path).expect("dlopen the plugin");
        let get: libloading::Symbol<GetFactoryFn> = lib
            .get(b"GetPluginFactory\0")
            .expect("GetPluginFactory must be exported");
        let raw = get();
        assert!(!raw.is_null(), "factory was null");
        let factory = ComPtr::from_raw(raw).expect("factory pointer");
        Module { _lib: lib, factory }
    }
}

impl Module {
    /// Instantiates a class and returns it as `IComponent`.
    fn create(&self, cid: &TUID) -> ComPtr<IComponent> {
        unsafe {
            let mut obj: *mut c_void = std::ptr::null_mut();
            let res = self.factory.createInstance(
                cid.as_ptr() as FIDString,
                IComponent::IID.as_ptr() as FIDString,
                &mut obj,
            );
            assert_eq!(res, kResultOk, "createInstance failed");
            assert!(!obj.is_null());
            ComPtr::from_raw(obj as *mut IComponent).expect("component pointer")
        }
    }
}

/// Everything a host does between "instantiate" and "the plugin is running".
fn bring_up(component: &ComPtr<IComponent>, sample_rate: f64, block_size: i32) {
    unsafe {
        assert_eq!(component.initialize(std::ptr::null_mut()), kResultOk);

        let processor = component
            .cast::<IAudioProcessor>()
            .expect("IAudioProcessor must be available");

        let mut stereo: SpeakerArrangement = 0x3;
        assert_eq!(
            processor.setBusArrangements(&mut stereo, 1, &mut stereo, 1),
            kResultTrue,
            "stereo in/out should be accepted"
        );

        let mut setup = ProcessSetup {
            processMode: ProcessModes_::kRealtime as int32,
            symbolicSampleSize: SymbolicSampleSizes_::kSample32 as int32,
            maxSamplesPerBlock: block_size,
            sampleRate: sample_rate,
        };
        assert_eq!(processor.setupProcessing(&mut setup), kResultOk);
        assert_eq!(component.setActive(1), kResultOk);
        assert_eq!(processor.setProcessing(1), kResultOk);
    }
}

fn tear_down(component: &ComPtr<IComponent>) {
    unsafe {
        let _ = component.setActive(0);
        let _ = component.terminate();
    }
}

/// Runs one block of audio through the plugin and returns the output.
fn process_block(component: &ComPtr<IComponent>, input: &[Vec<f32>]) -> Vec<Vec<f32>> {
    unsafe {
        let processor = component.cast::<IAudioProcessor>().expect("processor");
        let frames = input[0].len();

        let mut in_data: Vec<Vec<f32>> = input.to_vec();
        let mut out_data: Vec<Vec<f32>> = vec![vec![0.0; frames]; input.len()];

        let mut in_ptrs: Vec<*mut f32> = in_data.iter_mut().map(|c| c.as_mut_ptr()).collect();
        let mut out_ptrs: Vec<*mut f32> = out_data.iter_mut().map(|c| c.as_mut_ptr()).collect();

        let mut in_bus: AudioBusBuffers = std::mem::zeroed();
        in_bus.numChannels = in_ptrs.len() as i32;
        in_bus.__field0.channelBuffers32 = in_ptrs.as_mut_ptr();

        let mut out_bus: AudioBusBuffers = std::mem::zeroed();
        out_bus.numChannels = out_ptrs.len() as i32;
        out_bus.__field0.channelBuffers32 = out_ptrs.as_mut_ptr();

        let mut data: ProcessData = std::mem::zeroed();
        data.processMode = ProcessModes_::kRealtime as int32;
        data.symbolicSampleSize = SymbolicSampleSizes_::kSample32 as int32;
        data.numSamples = frames as i32;
        data.numInputs = 1;
        data.numOutputs = 1;
        data.inputs = &mut in_bus;
        data.outputs = &mut out_bus;

        assert_eq!(processor.process(&mut data), kResultOk);
        out_data
    }
}

fn set_param(component: &ComPtr<IComponent>, id: u32, normalized: f64) {
    unsafe {
        let controller = component
            .cast::<IEditController>()
            .expect("single-component effect must expose IEditController");
        assert_eq!(controller.setParamNormalized(id, normalized), kResultOk);
    }
}

fn sine(freq: f32, amp: f32, n: usize, sr: f32) -> Vec<f32> {
    (0..n)
        .map(|i| amp * (2.0 * std::f32::consts::PI * freq * i as f32 / sr).sin())
        .collect()
}

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

/// Feeds `seconds` of a tone through the plugin in `block_size` chunks.
fn pump_audio(component: &ComPtr<IComponent>, freq: f32, sr: f32, block_size: usize, blocks: usize) {
    let mut phase = 0usize;
    for _ in 0..blocks {
        let chunk: Vec<f32> = (0..block_size)
            .map(|i| {
                (2.0 * std::f32::consts::PI * freq * (phase + i) as f32 / sr).sin()
            })
            .collect();
        phase += block_size;
        process_block(component, &[chunk.clone(), chunk]);
    }
}

// ---------------------------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------------------------

#[test]
fn the_module_exports_a_factory_with_both_plugins() {
    let module = load();
    unsafe {
        let mut info: PFactoryInfo = std::mem::zeroed();
        assert_eq!(module.factory.getFactoryInfo(&mut info), kResultOk);

        assert_eq!(module.factory.countClasses(), 2);

        let mut names = Vec::new();
        for i in 0..2 {
            let mut ci: PClassInfo = std::mem::zeroed();
            assert_eq!(module.factory.getClassInfo(i, &mut ci), kResultOk);
            let category = std::ffi::CStr::from_ptr(ci.category.as_ptr())
                .to_string_lossy()
                .into_owned();
            assert_eq!(
                category, "Audio Module Class",
                "hosts only load classes in this category"
            );
            names.push(
                std::ffi::CStr::from_ptr(ci.name.as_ptr())
                    .to_string_lossy()
                    .into_owned(),
            );
        }
        assert!(names.contains(&"Bedrock Track".to_string()), "{names:?}");
        assert!(names.contains(&"Bedrock Vision".to_string()), "{names:?}");
    }
}

#[test]
fn the_factory_reports_analyzer_subcategories() {
    let module = load();
    unsafe {
        let factory2 = module
            .factory
            .cast::<IPluginFactory2>()
            .expect("IPluginFactory2");
        for i in 0..2 {
            let mut ci: PClassInfo2 = std::mem::zeroed();
            assert_eq!(factory2.getClassInfo2(i, &mut ci), kResultOk);
            let sub = std::ffi::CStr::from_ptr(ci.subCategories.as_ptr())
                .to_string_lossy()
                .into_owned();
            assert_eq!(sub, "Fx|Analyzer");
        }
    }
}

#[test]
fn an_unknown_class_id_is_refused() {
    let module = load();
    unsafe {
        let bogus: TUID = vst3::uid(0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF);
        let mut obj: *mut c_void = std::ptr::null_mut();
        let res = module.factory.createInstance(
            bogus.as_ptr() as FIDString,
            IComponent::IID.as_ptr() as FIDString,
            &mut obj,
        );
        assert_ne!(res, kResultOk);
        assert!(obj.is_null());
    }
}

#[test]
fn both_plugins_expose_the_single_component_interfaces() {
    let module = load();
    for cid in [&TRACK_CID, &VISION_CID] {
        let component = module.create(cid);
        assert!(component.cast::<IAudioProcessor>().is_some());
        assert!(
            component.cast::<IEditController>().is_some(),
            "a single-component effect must answer IEditController on the same object"
        );
        unsafe {
            // A single-component effect signals "no separate controller class" this way.
            let mut cid_out: TUID = [0; 16];
            assert_ne!(
                component.getControllerClassId(&mut cid_out),
                kResultOk,
                "must not advertise a separate controller class"
            );
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Buses and audio
// ---------------------------------------------------------------------------------------------

#[test]
fn both_plugins_present_one_stereo_bus_each_way() {
    let module = load();
    for cid in [&TRACK_CID, &VISION_CID] {
        let component = module.create(cid);
        unsafe {
            assert_eq!(
                component.getBusCount(
                    MediaTypes_::kAudio as MediaType,
                    BusDirections_::kInput as BusDirection
                ),
                1
            );
            assert_eq!(
                component.getBusCount(
                    MediaTypes_::kAudio as MediaType,
                    BusDirections_::kOutput as BusDirection
                ),
                1
            );
            assert_eq!(
                component.getBusCount(
                    MediaTypes_::kEvent as MediaType,
                    BusDirections_::kInput as BusDirection
                ),
                0,
                "neither plugin takes MIDI"
            );

            let mut info: BusInfo = std::mem::zeroed();
            assert_eq!(
                component.getBusInfo(
                    MediaTypes_::kAudio as MediaType,
                    BusDirections_::kInput as BusDirection,
                    0,
                    &mut info
                ),
                kResultOk
            );
            assert_eq!(info.channelCount, 2);
        }
    }
}

#[test]
fn mismatched_channel_counts_are_refused() {
    let module = load();
    let component = module.create(&TRACK_CID);
    unsafe {
        let processor = component.cast::<IAudioProcessor>().unwrap();
        let mut mono: SpeakerArrangement = 0x1;
        let mut stereo: SpeakerArrangement = 0x3;
        assert_eq!(
            processor.setBusArrangements(&mut mono, 1, &mut stereo, 1),
            kResultFalse,
            "an analysis insert must not change the channel count"
        );
        // Mono in / mono out is fine.
        assert_eq!(
            processor.setBusArrangements(&mut mono, 1, &mut mono, 1),
            kResultTrue
        );
    }
}

#[test]
fn both_plugins_pass_audio_through_untouched() {
    let module = load();
    for cid in [&TRACK_CID, &VISION_CID] {
        let component = module.create(cid);
        bring_up(&component, 48_000.0, 512);

        let left = sine(440.0, 0.7, 512, 48_000.0);
        let right = sine(660.0, 0.3, 512, 48_000.0);
        let out = process_block(&component, &[left.clone(), right.clone()]);

        assert_eq!(out[0], left, "left channel was altered");
        assert_eq!(out[1], right, "right channel was altered");
        tear_down(&component);
    }
}

#[test]
fn both_plugins_report_zero_latency() {
    let module = load();
    for cid in [&TRACK_CID, &VISION_CID] {
        let component = module.create(cid);
        bring_up(&component, 48_000.0, 512);
        unsafe {
            let processor = component.cast::<IAudioProcessor>().unwrap();
            assert_eq!(processor.getLatencySamples(), 0);
            assert_eq!(processor.getTailSamples(), 0);
        }
        tear_down(&component);
    }
}

// ---------------------------------------------------------------------------------------------
// Parameters and state
// ---------------------------------------------------------------------------------------------

#[test]
fn parameters_enumerate_and_format() {
    let module = load();
    let component = module.create(&VISION_CID);
    unsafe {
        let controller = component.cast::<IEditController>().unwrap();
        assert_eq!(controller.getParameterCount(), 5);

        let mut titles = Vec::new();
        for i in 0..controller.getParameterCount() {
            let mut info: ParameterInfo = std::mem::zeroed();
            assert_eq!(controller.getParameterInfo(i, &mut info), kResultOk);
            titles.push(String::from_utf16_lossy(
                &info.title[..info.title.iter().position(|&c| c == 0).unwrap_or(0)],
            ));
        }
        assert_eq!(titles, ["Realm", "Palette", "Fill", "Legend", "Grid"]);

        // The palette parameter should read back as a name, not a number.
        let mut text: String128 = [0; 128];
        assert_eq!(
            controller.getParamStringByValue(1, 0.0, &mut text),
            kResultOk
        );
        let rendered =
            String::from_utf16_lossy(&text[..text.iter().position(|&c| c == 0).unwrap_or(0)]);
        assert_eq!(rendered, "Spectrum");
    }
}

/// An in-memory `IBStream`, which is all the plugin needs to save and restore.
struct MemoryStream {
    buffer: Mutex<Vec<u8>>,
    cursor: Mutex<usize>,
}

impl MemoryStream {
    fn new() -> MemoryStream {
        MemoryStream {
            buffer: Mutex::new(Vec::new()),
            cursor: Mutex::new(0),
        }
    }

    fn rewind(&self) {
        *self.cursor.lock().unwrap() = 0;
    }
}

impl Class for MemoryStream {
    type Interfaces = (IBStream,);
}

impl IBStreamTrait for MemoryStream {
    unsafe fn read(
        &self,
        buffer: *mut c_void,
        numBytes: int32,
        numBytesRead: *mut int32,
    ) -> tresult {
        let data = self.buffer.lock().unwrap();
        let mut cursor = self.cursor.lock().unwrap();
        let want = numBytes.max(0) as usize;
        let available = data.len().saturating_sub(*cursor).min(want);
        if available > 0 {
            std::ptr::copy_nonoverlapping(
                data[*cursor..].as_ptr(),
                buffer as *mut u8,
                available,
            );
            *cursor += available;
        }
        if !numBytesRead.is_null() {
            *numBytesRead = available as int32;
        }
        kResultOk
    }

    unsafe fn write(
        &self,
        buffer: *mut c_void,
        numBytes: int32,
        numBytesWritten: *mut int32,
    ) -> tresult {
        let mut data = self.buffer.lock().unwrap();
        let n = numBytes.max(0) as usize;
        let src = std::slice::from_raw_parts(buffer as *const u8, n);
        data.extend_from_slice(src);
        if !numBytesWritten.is_null() {
            *numBytesWritten = n as int32;
        }
        kResultOk
    }

    unsafe fn seek(&self, pos: int64, mode: int32, result: *mut int64) -> tresult {
        let len = self.buffer.lock().unwrap().len() as i64;
        let mut cursor = self.cursor.lock().unwrap();
        let base = match mode {
            x if x == IBStream_::IStreamSeekMode_::kIBSeekSet as int32 => 0,
            x if x == IBStream_::IStreamSeekMode_::kIBSeekCur as int32 => *cursor as i64,
            _ => len,
        };
        *cursor = (base + pos).clamp(0, len) as usize;
        if !result.is_null() {
            *result = *cursor as i64;
        }
        kResultOk
    }

    unsafe fn tell(&self, pos: *mut int64) -> tresult {
        if !pos.is_null() {
            *pos = *self.cursor.lock().unwrap() as i64;
        }
        kResultOk
    }
}

#[test]
fn state_survives_a_save_and_reload() {
    let module = load();

    let saved = ComWrapper::new(MemoryStream::new());
    let stream = saved.to_com_ptr::<IBStream>().unwrap();

    // Set every parameter away from its default, then save.
    let first = module.create(&VISION_CID);
    set_param(&first, 0, first_realm_normalized());
    set_param(&first, 1, 1.0); // palette: last entry
    set_param(&first, 2, 0.75); // fill
    set_param(&first, 3, 0.0); // legend off
    unsafe {
        assert_eq!(first.getState(stream.as_ptr()), kResultOk);
    }

    // Load into a fresh instance and compare.
    saved.rewind();
    let second = module.create(&VISION_CID);
    unsafe {
        assert_eq!(second.setState(stream.as_ptr()), kResultOk);
        let controller = second.cast::<IEditController>().unwrap();
        assert!((controller.getParamNormalized(0) - first_realm_normalized()).abs() < 1e-6);
        assert!((controller.getParamNormalized(1) - 1.0).abs() < 1e-6);
        assert!((controller.getParamNormalized(2) - 0.75).abs() < 1e-6);
        assert!(controller.getParamNormalized(3) < 0.5);
    }
}

fn first_realm_normalized() -> f64 {
    // Realm 7 of 0..=99.
    7.0 / 99.0
}

#[test]
fn garbage_state_is_rejected_rather_than_applied() {
    let module = load();
    let stream = ComWrapper::new(MemoryStream::new());
    {
        let mut buf = stream.buffer.lock().unwrap();
        buf.extend_from_slice(b"not a bedrock state blob at all");
    }
    let com = stream.to_com_ptr::<IBStream>().unwrap();

    let component = module.create(&VISION_CID);
    unsafe {
        let before = component
            .cast::<IEditController>()
            .unwrap()
            .getParamNormalized(1);
        assert_ne!(component.setState(com.as_ptr()), kResultOk);
        let after = component
            .cast::<IEditController>()
            .unwrap()
            .getParamNormalized(1);
        assert_eq!(before, after, "a bad blob must not disturb live parameters");
    }
}

// ---------------------------------------------------------------------------------------------
// The actual product: Track publishing and Vision collecting
// ---------------------------------------------------------------------------------------------

#[test]
fn a_track_instance_publishes_its_spectrum_to_a_listening_hub() {
    let hub = Hub::start(realm::TRACK_PUBLISHES).expect("stand in for Vision");

    let module = load();
    let component = module.create(&TRACK_CID);
    // Parameter 0 is Realm, stepped over 0..=99.
    set_param(&component, 0, realm::TRACK_PUBLISHES as f64 / 99.0);
    bring_up(&component, 48_000.0, 512);

    assert!(
        wait_for(Duration::from_secs(10), || hub
            .registry()
            .lock()
            .unwrap()
            .len()
            == 1),
        "the Track plugin never registered with the hub"
    );

    // 1 kHz at full scale, long enough to prime the FFT window and emit several frames.
    pump_audio(&component, 1000.0, 48_000.0, 512, 40);

    assert!(
        wait_for(Duration::from_secs(10), || {
            hub.registry()
                .lock()
                .unwrap()
                .ordered()
                .first()
                .is_some_and(|t| t.has_frame)
        }),
        "no spectrum frame arrived from the Track plugin"
    );

    let registry = hub.registry().lock().unwrap();
    let track = registry.ordered()[0];
    let frame: Frame = track.frame;

    // The tone should dominate: find the loudest bin and check it sits at 1 kHz.
    let loudest = (0..bedrock_core::NUM_BINS)
        .max_by_key(|&i| frame.bins[i])
        .unwrap();
    let peak_hz = bedrock_core::analyzer::bin_frequency(loudest);
    assert!(
        (peak_hz - 1000.0).abs() < 120.0,
        "expected the peak near 1 kHz, got {peak_hz:.0} Hz"
    );
    assert!(
        frame.bin_db(loudest) > -6.0,
        "a full-scale tone should read loud, got {:.1} dBFS",
        frame.bin_db(loudest)
    );

    drop(registry);
    tear_down(&component);
}

#[test]
fn turning_send_off_stops_the_track_publishing() {
    let hub = Hub::start(realm::TRACK_RESPECTS_SEND).expect("hub");

    let module = load();
    let component = module.create(&TRACK_CID);
    set_param(&component, 0, realm::TRACK_RESPECTS_SEND as f64 / 99.0);
    set_param(&component, 2, 0.0); // Send off
    bring_up(&component, 48_000.0, 512);

    assert!(
        wait_for(Duration::from_secs(10), || hub
            .registry()
            .lock()
            .unwrap()
            .len()
            == 1),
        "the track should still connect and appear, just without a spectrum"
    );

    pump_audio(&component, 1000.0, 48_000.0, 512, 40);
    thread::sleep(Duration::from_millis(200));

    assert!(
        !hub.registry().lock().unwrap().ordered()[0].has_frame,
        "Send is off, so no spectrum should have been published"
    );
    tear_down(&component);
}

#[test]
fn changing_the_realm_parameter_moves_the_track() {
    let from = Hub::start(realm::TRACK_REALM_PARAM).expect("hub a");
    let to = Hub::start(realm::TRACK_REALM_PARAM + 1).expect("hub b");

    let module = load();
    let component = module.create(&TRACK_CID);
    set_param(&component, 0, realm::TRACK_REALM_PARAM as f64 / 99.0);
    bring_up(&component, 48_000.0, 512);

    assert!(
        wait_for(Duration::from_secs(10), || from
            .registry()
            .lock()
            .unwrap()
            .len()
            == 1),
        "track should start on the first realm"
    );

    set_param(&component, 0, (realm::TRACK_REALM_PARAM + 1) as f64 / 99.0);

    assert!(
        wait_for(Duration::from_secs(10), || {
            to.registry().lock().unwrap().len() == 1
                && from.registry().lock().unwrap().is_empty()
        }),
        "changing Realm should move the track between hubs"
    );
    tear_down(&component);
}

#[test]
fn an_activated_vision_instance_accepts_track_connections() {
    let module = load();
    let component = module.create(&VISION_CID);
    set_param(&component, 0, realm::VISION_BINDS as f64 / 99.0);
    bring_up(&component, 48_000.0, 512);

    // Vision binds the realm on activation, so a Track should now find it.
    let link = TrackLink::new(0x4242, realm::VISION_BINDS);
    link.set_identity("Harness", 0, None);

    assert!(
        wait_for(Duration::from_secs(10), || link.status()
            == LinkStatus::Connected),
        "Vision did not accept the connection on its realm"
    );

    tear_down(&component);
}

#[test]
fn vision_offers_a_resizable_view_on_this_platform() {
    let module = load();
    let component = module.create(&VISION_CID);
    unsafe {
        let controller = component.cast::<IEditController>().unwrap();
        let name = CString::new("editor").unwrap();
        let view = controller.createView(name.as_ptr());
        assert!(!view.is_null(), "Vision must offer an editor");

        let view = ComPtr::from_raw(view).unwrap();
        assert_eq!(view.canResize(), kResultTrue);

        let mut rect: ViewRect = std::mem::zeroed();
        assert_eq!(view.getSize(&mut rect), kResultOk);
        assert!(rect.right > 0 && rect.bottom > 0);

        // A too-small request must be grown to the minimum, not accepted as-is.
        let mut tiny = ViewRect {
            left: 0,
            top: 0,
            right: 20,
            bottom: 20,
        };
        assert_eq!(view.checkSizeConstraint(&mut tiny), kResultTrue);
        assert!(
            tiny.right > 20 && tiny.bottom > 20,
            "the view should refuse to shrink below its minimum"
        );
    }
}

#[test]
fn track_offers_no_view_and_leaves_the_host_its_generic_editor() {
    let module = load();
    let component = module.create(&TRACK_CID);
    unsafe {
        let controller = component.cast::<IEditController>().unwrap();
        let name = CString::new("editor").unwrap();
        assert!(
            controller.createView(name.as_ptr()).is_null(),
            "Track's three parameters are better served by the host's own editor"
        );
    }
}
